//! Browser WASM build target: compiles the full CMS to wasm32-wasi with an
//! embedded SQLite (blob-backed) storage, separate from the native server.

const std = @import("std");
const helpers = @import("helpers.zig");
const plugins_mod = @import("plugins.zig");
const vendors = @import("vendors.zig");

pub const Deps = struct {
    /// Vendor build options — includes plugin-contributed C sources +
    /// static libs for the wasm32-wasi target.
    vendor_opts: vendors.Opts,
    /// Shared imports common to native exe and WASM exe.
    shared_imports: []const std.Build.Module.Import,
    /// Modules WASM-only modules need to import.
    views: *std.Build.Module,
    db: *std.Build.Module,
    storage: *std.Build.Module,
    middleware: *std.Build.Module,
    auth_middleware: *std.Build.Module,
    media: *std.Build.Module,
    media_handler: *std.Build.Module,
    image: *std.Build.Module,
    admin_api: *std.Build.Module,
    registry: *std.Build.Module,
    route_match: *std.Build.Module,
    /// Editor-plugin registry — used by the editor-assets handler module
    /// when registering the /admin/editors/* route in src/wasm/main.zig.
    editors: *std.Build.Module,
    /// Plugins discovered by build/plugins.zig — wasm_storage is wired into
    /// each post-hoc because plugins may conditionally @import it.
    plugins: []const plugins_mod.Plugin,
    /// Resolved schema source file (strict or loose) for the active build.
    /// Wired as the `schema_sql` anonymous import on the WASM exe.
    schema_sql_path: std.Build.LazyPath,
    /// Comptime config inputs.
    setup_bg_dark: bool,
    /// The transpile step the WASM exe must run after.
    transpile_step: *std.Build.Step,
    /// JIT-compiled Tailwind utilities (admin scope). Embedded for /static/publr.css.
    jit_css_output: std.Build.LazyPath,
};

pub const Result = struct {
    /// `zig build browser`
    browser_step: *std.Build.Step,
    /// Step `verify` should depend on so the WASM build is checked too.
    install_step: *std.Build.Step,
};

pub fn build(b: *std.Build, deps: Deps) Result {
    const browser_step = b.step("browser", "Build browser WASM module");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const browser_wasm = b.addExecutable(.{
        .name = "cms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm/main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    browser_wasm.rdynamic = true;

    // Vendor static library for WASM — separate from native because of
    // different SQLite flags (single-threaded, no load_extension). Plugin
    // contributions (C sources + static libs) are folded in via vendor_opts.
    const vendor_lib_wasm = vendors.library(b, wasm_target, .ReleaseSmall, deps.vendor_opts);
    browser_wasm.linkLibC();
    browser_wasm.addIncludePath(b.path("vendor"));
    for (deps.vendor_opts.extra_include_paths) |p| browser_wasm.addIncludePath(p);
    browser_wasm.linkLibrary(vendor_lib_wasm);
    vendors.linkStaticLibs(browser_wasm, deps.vendor_opts);

    // error.zig lives outside src/wasm/, so wire it in as a named module
    // (relative @import("..") is disallowed across module root boundaries).
    const error_pages_module = b.createModule(.{
        .root_source_file = b.path("src/error.zig"),
        .imports = deps.shared_imports,
    });
    browser_wasm.root_module.addAnonymousImport("schema_sql", .{
        .root_source_file = deps.schema_sql_path,
    });

    // Optional "starter DB" — if `data/publr.db` exists at build time,
    // embed it into the WASM blob. On first init (OPFS empty), the WASM
    // worker deserializes this instead of running schema+seed from
    // scratch, so the in-browser CMS starts with the same content types
    // and data the native instance has. See wasm/main.zig:cms_init.
    // When the file doesn't exist, embed an empty placeholder so the
    // @embedFile declaration always resolves.
    const starter_db_path = "data/publr.db";
    const starter_db_lazy: std.Build.LazyPath = blk: {
        if (b.build_root.handle.access(starter_db_path, .{})) {
            break :blk b.path(starter_db_path);
        } else |_| {
            const empty_wf = b.addWriteFiles();
            break :blk empty_wf.add("empty_starter_db.bin", "");
        }
    };
    browser_wasm.root_module.addAnonymousImport("starter_db", .{
        .root_source_file = starter_db_lazy,
    });

    // WASM-specific modules
    const wasm_storage_module = b.createModule(.{
        .root_source_file = b.path("src/wasm/storage.zig"),
        .imports = &.{
            .{ .name = "db", .module = deps.db },
            .{ .name = "storage", .module = deps.storage },
        },
    });
    const wasm_media_handler_module = b.createModule(.{
        .root_source_file = b.path("src/wasm/media_handler.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = deps.middleware },
            .{ .name = "wasm_storage", .module = wasm_storage_module },
            .{ .name = "auth_middleware", .module = deps.auth_middleware },
            .{ .name = "media_handler", .module = deps.media_handler },
            .{ .name = "image", .module = deps.image },
            .{ .name = "storage", .module = deps.storage },
        },
    });
    const wasm_router_module = b.createModule(.{
        .root_source_file = b.path("src/wasm/router.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = deps.middleware },
            .{ .name = "admin_api", .module = deps.admin_api },
            .{ .name = "route_match", .module = deps.route_match },
        },
    });
    const wasm_static_handler_module = b.createModule(.{
        .root_source_file = b.path("src/wasm/static_handler.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = deps.middleware },
        },
    });
    wasm_static_handler_module.addAnonymousImport("static_tokens_css", .{ .root_source_file = b.path("vendor/tokens.css") });
    wasm_static_handler_module.addAnonymousImport("static_preflight_css", .{ .root_source_file = b.path("vendor/jit/preflight.css") });
    wasm_static_handler_module.addAnonymousImport("static_jit_css", .{ .root_source_file = deps.jit_css_output });

    // Editor assets handler — same source as native (src/http_handlers/editor_assets.zig).
    // Exposed as a named module here because the WASM exe's root is
    // src/wasm/main.zig and relative imports can't cross module roots.
    const editor_assets_module = b.createModule(.{
        .root_source_file = b.path("src/http_handlers/editor_assets.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = deps.middleware },
            .{ .name = "editors", .module = deps.editors },
        },
    });

    // WASM exe shares most modules with the native exe; add WASM-only extras.
    helpers.addImports(browser_wasm.root_module, deps.shared_imports);
    helpers.addImports(browser_wasm.root_module, &.{
        .{ .name = "registry", .module = deps.registry },
        .{ .name = "wasm_router", .module = wasm_router_module },
        .{ .name = "wasm_storage", .module = wasm_storage_module },
        .{ .name = "wasm_media_handler", .module = wasm_media_handler_module },
        .{ .name = "wasm_static_handler", .module = wasm_static_handler_module },
        .{ .name = "editor_assets", .module = editor_assets_module },
        .{ .name = "error_pages", .module = error_pages_module },
    });

    // Comptime config module (generated from build options)
    const wasm_config_files = b.addWriteFiles();
    const wasm_config_source = wasm_config_files.add("config.zig", std.fmt.allocPrint(
        b.allocator,
        "pub const setup_bg_dark: bool = {};",
        .{deps.setup_bg_dark},
    ) catch unreachable);
    const wasm_config_module = b.createModule(.{ .root_source_file = wasm_config_source });
    browser_wasm.root_module.addImport("config", wasm_config_module);

    // wasm_storage is conditionally @import-ed inside media + each plugin.
    deps.media.addImport("wasm_storage", wasm_storage_module);
    for (deps.plugins) |p| {
        p.module.addImport("wasm_storage", wasm_storage_module);
        // Expose each plugin module to wasm/main.zig the same way the
        // native exe does — escape hatch for code that needs to call a
        // specific plugin's helpers (e.g. cms_apply_remote_changeset
        // forwarding into the cr-sqlite plugin's sync.applyChangeset).
        browser_wasm.root_module.addImport(b.fmt("plugin_{s}", .{p.name}), p.module);
    }

    browser_wasm.step.dependOn(deps.transpile_step);

    const browser_install = b.addInstallArtifact(browser_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "browser" } },
    });
    browser_step.dependOn(&browser_install.step);

    return .{
        .browser_step = browser_step,
        .install_step = &browser_install.step,
    };
}
