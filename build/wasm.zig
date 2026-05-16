//! Browser WASM build target: compiles the full CMS to wasm32-wasi with an
//! embedded SQLite (blob-backed) storage, separate from the native server.

const std = @import("std");
const helpers = @import("helpers.zig");
const plugins_mod = @import("plugins.zig");
const vendors = @import("vendors.zig");

pub const Deps = struct {
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
    /// Plugins discovered by build/plugins.zig — wasm_storage is wired into
    /// each post-hoc because plugins may conditionally @import it.
    plugins: []const plugins_mod.Plugin,
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
            .root_source_file = b.path("src/wasm_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    browser_wasm.rdynamic = true;

    // Vendor static library for WASM — separate from native because of
    // different SQLite flags (single-threaded, no load_extension).
    const vendor_lib_wasm = vendors.library(b, wasm_target, .ReleaseSmall, .{ .wasm = true });
    browser_wasm.linkLibC();
    browser_wasm.addIncludePath(b.path("vendor"));
    browser_wasm.linkLibrary(vendor_lib_wasm);

    // WASM-specific modules
    const wasm_storage_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_storage.zig"),
        .imports = &.{
            .{ .name = "db", .module = deps.db },
            .{ .name = "storage", .module = deps.storage },
        },
    });
    const wasm_media_handler_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_media_handler.zig"),
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
        .root_source_file = b.path("src/wasm_router.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = deps.middleware },
            .{ .name = "admin_api", .module = deps.admin_api },
            .{ .name = "route_match", .module = deps.route_match },
        },
    });
    const wasm_static_handler_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_static_handler.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = deps.middleware },
        },
    });
    wasm_static_handler_module.addAnonymousImport("static_tokens_css", .{ .root_source_file = b.path("vendor/tokens.css") });
    wasm_static_handler_module.addAnonymousImport("static_preflight_css", .{ .root_source_file = b.path("vendor/jit/preflight.css") });
    wasm_static_handler_module.addAnonymousImport("static_jit_css", .{ .root_source_file = deps.jit_css_output });

    // WASM exe shares most modules with the native exe; add WASM-only extras.
    helpers.addImports(browser_wasm.root_module, deps.shared_imports);
    helpers.addImports(browser_wasm.root_module, &.{
        .{ .name = "registry", .module = deps.registry },
        .{ .name = "wasm_router", .module = wasm_router_module },
        .{ .name = "wasm_storage", .module = wasm_storage_module },
        .{ .name = "wasm_media_handler", .module = wasm_media_handler_module },
        .{ .name = "wasm_static_handler", .module = wasm_static_handler_module },
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
