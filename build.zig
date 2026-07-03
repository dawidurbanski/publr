const std = @import("std");
const helpers = @import("build/helpers.zig");
const plugins_mod = @import("build/plugins.zig");
const content_types_mod = @import("build/content_types.zig");
const wasm_build = @import("build/wasm.zig");
const db_init_build = @import("build/db_init.zig");
const theme_build = @import("build/theme.zig");
const vendors = @import("build/vendors.zig");

const addImports = helpers.addImports;
const sanitizeImportName = helpers.sanitizeImportName;
const getMimeForBuild = helpers.getMimeForBuild;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const watch_mode = b.option(bool, "watch", "Skip preBuild hooks and init_db (used by --watch rebuilds)") orelse false;
    const setup_bg_dark = b.option(bool, "setup-bg-dark", "Use dark background on setup page (comptime config demo)") orelse false;
    // HMR mode: when true, the ZSX transpiler emits views in hmr mode
    // (literals lifted to a `L` lookup table, per-fn `manifest_nodes`,
    // `data-component="<view>:<Fn>"` spliced onto the root element, and a
    // `captureProps` call at the top of every component body for prop
    // persistence across hot swaps). The `--hmr` flag enables both
    // `--hmr` and `--hmr-capture-props` on the underlying zsx_transpile
    // CLI; demos that want manifest-only (no prop capture) drive
    // zsx_transpile directly.
    //
    // Default: enabled in Debug optimize, disabled otherwise. Debug is
    // the dev workflow (`zig build run -- serve --dev`), so HMR comes
    // along for free without the user having to type `-Dhmr=true`.
    // Release builds skip it (smaller binaries, no mutable view globals).
    // Override either default with `-Dhmr=true` / `-Dhmr=false`.
    const hmr = b.option(bool, "hmr", "Generate views in hmr mode (literals lifted to L, manifest_nodes exported, data-component attribute injected, captureProps emitted). Defaults to true in Debug, false otherwise.") orelse (optimize == .Debug);
    // CSS minify override. Default null = follow the optimize gate (Debug
    // unminified, Release minified). Set explicitly with -Dminify=true/false
    // to override — e.g. `zig build run -Dminify=true` for a Debug build that
    // ships minified CSS, or `-Dminify=false` to inspect a release build's
    // generated CSS in readable form.
    const minify_css = b.option(bool, "minify", "Minify generated CSS (default: follows -Doptimize)");

    // External source tree options (for recompilation from ~/.publr/src/)
    const config_path = b.option([]const u8, "config-path", "Absolute path to publr.zon (external source tree builds)");
    const plugins_path = b.option([]const u8, "plugins-path", "Absolute path to plugins directory (external source tree builds)");
    const project_dir = b.option([]const u8, "project-dir", "Absolute path to project directory (external source tree builds — resolves themes, data)");
    _ = plugins_path; // Reserved for future plugin discovery

    // Theme name: --theme option (external builds) > publr.zon .theme field > "default"
    const theme_name: []const u8 = b.option([]const u8, "theme", "Theme directory name (overrides publr.zon .theme)") orelse blk: {
        const publr_config = @import("publr.zon");
        break :blk if (@hasField(@TypeOf(publr_config), "theme"))
            publr_config.theme
        else
            "default";
    };
    const theme_path = b.pathJoin(&.{ "themes", theme_name });
    const theme_static_rel = b.pathJoin(&.{ "themes", theme_name, "public" });

    // Theme-level config (optional: themes/<name>/publr.zon)
    const theme_config_path = b.pathJoin(&.{ "themes", theme_name, "publr.zon" });
    const has_theme_config = blk: {
        if (project_dir != null) break :blk false;
        b.build_root.handle.access(theme_config_path, .{}) catch break :blk false;
        break :blk true;
    };
    const theme_config_module: ?*std.Build.Module = if (has_theme_config)
        b.createModule(.{ .root_source_file = b.path(theme_config_path) })
    else
        null;

    // =========================================================================
    // Theme + ZSX pipeline (build/theme.zig)
    // =========================================================================
    const theme_pipe = theme_build.wire(b, .{
        .project_dir = project_dir,
        .theme_path = theme_path,
        .target = target,
        .optimize = optimize,
        .minify_css = minify_css,
        .hmr = hmr,
    });
    const zsx = theme_pipe.zsx;
    const publr_template_module = theme_pipe.publr_template_module;
    const transpile_zsx_cmd = theme_pipe.transpile_zsx_cmd;
    const zsx_transpiler = theme_pipe.zsx_transpiler;
    const transpile_theme_cmd = theme_pipe.transpile_theme_cmd;
    const gen_views = theme_pipe.gen_views;
    const gen_theme = theme_pipe.gen_theme;
    const jit_css_output = theme_pipe.jit_css_output;
    const theme_jit_css_output = theme_pipe.theme_jit_css_output;
    const build_opts = theme_pipe.build_opts;

    const exe = b.addExecutable(.{
        .name = "publr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.step.dependOn(&transpile_zsx_cmd.step);
    exe.step.dependOn(&transpile_theme_cmd.step);

    // Note: preBuild/postBuild hooks from publr.zon run during `publr build` CLI,
    // not during `zig build`. This avoids hard failures when tools aren't installed.

    // Vendor static library — SQLite, stb_image, libwebp compiled once and
    // cached, recompiled only when vendor sources change. Plugins under
    // `plugins/<name>/vendor/` (C sources) and `plugins/<name>/lib/<target>.a`
    // (static libs) are folded in here so their extension code shares the
    // SQLite build.
    // Plugin manifest pre-scan: walks plugins/<name>/manifest.zon BEFORE
    // module registration so build-time choices (schema flavor, sqlite
    // source dir) can be wired into the right modules. Full plugin module
    // discovery still happens later via plugins_mod.load.
    const plugin_prescan = plugins_mod.preScan(b, &.{"plugins"});
    const native_vendor_opts = withPluginSqliteOverride(collectPluginVendor(b, false), plugin_prescan);
    const wasm_vendor_opts = withPluginSqliteOverride(collectPluginVendor(b, true), plugin_prescan);
    const vendor_lib = vendors.library(b, target, optimize, native_vendor_opts);
    exe.linkLibC();
    exe.addIncludePath(b.path("vendor")); // for @cImport headers
    exe.linkLibrary(vendor_lib);
    vendors.linkStaticLibs(exe, native_vendor_opts);

    // Import project config (publr.zon) — from config-path in external builds
    const publr_config_module = b.createModule(.{
        .root_source_file = if (config_path) |cp|
            .{ .cwd_relative = cp }
        else
            b.path("publr.zon"),
    });
    exe.root_module.addImport("publr_config", publr_config_module);
    exe.root_module.addOptions("build_options", build_opts);
    // Theme config: theme's own publr.zon, or empty fallback
    if (theme_config_module) |m| {
        exe.root_module.addImport("theme_config", m);
    } else {
        const empty_config = b.addWriteFiles();
        exe.root_module.addImport("theme_config", b.createModule(.{
            .root_source_file = empty_config.add("theme_config_empty.zon", ".{}"),
        }));
    }

    // Embed static assets. Each tuple is (import-name, file-path) — files
    // are read at build time and surfaced to the runtime via @embedFile.
    const static_files = .{
        .{ "static_admin_css", "static/admin.css" },
        .{ "static_logo_svg", "static/logo.svg" },
        .{ "static_preflight_css", "vendor/jit/preflight.css" },
        .{ "static_tokens_css", "vendor/tokens.css" },
        .{ "static_admin_js", "static/admin.js" },
        .{ "static_interact_core_js", "static/interact/core.js" },
        .{ "static_interact_toggle_js", "static/interact/toggle.js" },
        .{ "static_interact_kv_picker_js", "static/interact/kv-picker.js" },
        .{ "static_interact_portal_js", "static/interact/portal.js" },
        .{ "static_interact_focus_trap_js", "static/interact/focus-trap.js" },
        .{ "static_interact_dismiss_js", "static/interact/dismiss.js" },
        .{ "static_interact_components_js", "static/interact/components.js" },
        .{ "static_interact_index_js", "static/interact/index.js" },
        .{ "static_interact_repeater_js", "static/interact/repeater.js" },
        .{ "static_shell_js", "static/shell.js" },
        .{ "static_p_dropdown_js", "static/p/dropdown.js" },
        .{ "static_media_selection_js", "static/media-selection.js" },
        .{ "static_interact_websocket_js", "static/interact/websocket.js" },
        // PublrJS runtime (data-p-* stores) — second system
        // alongside interact/core.js, for the dashboard demo (#101).
        .{ "static_publr_js", "static/publr.js" },
        .{ "static_publr_query_js", "static/publr-query.js" },
        .{ "static_publr_position_js", "static/publr-position.js" },
        .{ "static_publr_focus_js", "static/publr-focus.js" },
        .{ "static_dashboard_demo_js", "static/dashboard-demo.js" },
    };
    inline for (static_files) |sf| {
        exe.root_module.addAnonymousImport(sf[0], .{ .root_source_file = b.path(sf[1]) });
    }
    // JIT-emitted CSS isn't on disk — generated by the JIT compiler.
    exe.root_module.addAnonymousImport("static_jit_css", .{ .root_source_file = jit_css_output });
    exe.root_module.addAnonymousImport("static_interact_presence_js", .{
        .root_source_file = b.path("static/interact/presence.js"),
    });
    // =========================================================================
    // Theme Static Assets — scan, embed, and generate lookup module
    // =========================================================================
    const theme_static_module = theme_build.staticAssetsModule(b, .{
        .theme_static_rel = theme_static_rel,
        .project_dir = project_dir,
        .theme_jit_css_output = theme_jit_css_output,
    });
    exe.root_module.addImport("theme_static", theme_static_module);

    // Design system amalgamation — components, CSS, JS as string constants
    const publr_ui = b.createModule(.{
        .root_source_file = b.path("vendor/publr_ui.zig"),
    });

    // ZSX runtime for views (same amalgamation, views only use .runtime)
    const zsx_views = b.createModule(.{
        .root_source_file = b.path("vendor/zsx.zig"),
    });

    // HMR module: the generated views emit `try @import("hmr").captureProps(...)`
    // at the top of every component body when transpiled with --hmr-capture-props.
    // src/hmr.zig is the real implementation: it persists per-render props to
    // `.publr/hmr/<route_hash>/<view>-<seq>.zon`, keyed by the request's
    // threadlocal RequestContext. Production builds use the same module; the
    // module is internally gated on the dev_mode flag set by http.serve at
    // startup, so captureProps is a no-op when --dev wasn't passed.
    const hmr_module = b.createModule(.{
        .root_source_file = b.path("src/hmr.zig"),
    });

    // Single views module — generated views.zig provides namespace hierarchy
    const views = b.createModule(.{
        .root_source_file = gen_views.path(b, "views.zig"),
        .imports = &.{
            .{ .name = "zsx", .module = zsx_views },
            .{ .name = "hmr", .module = hmr_module },
        },
    });

    // Theme module — generated from .publr templates
    const theme = b.createModule(.{
        .root_source_file = gen_theme.path(b, "views.zig"),
        .imports = &.{
            .{ .name = "zsx", .module = zsx_views },
            .{ .name = "hmr", .module = hmr_module },
        },
    });

    // =========================================================================
    // View registry (task-03 of cms-hmr-fast-path)
    // =========================================================================
    // In HMR mode, build a tool that walks every .zsx source and emits a flat
    // table of `(view_name → &manifest, &setL, &render-from-zon)` entries.
    // The swap loop in task-06 consumes this table at runtime to find the
    // view a saved .zsx belongs to in O(1) and re-render it from persisted
    // props without a full rebuild.
    //
    // Inline mode (no `-Dhmr`) emits an empty stub so the runtime module
    // compiles unchanged. registry_runtime.init() is a no-op when entries
    // is empty.
    const view_registry_gen = b.addExecutable(.{
        .name = "registry_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/registry_gen.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "zsx", .module = zsx }},
        }),
    });

    const view_registry_run = b.addRunArtifact(view_registry_gen);
    const view_registry_path = view_registry_run.addOutputFileArg("view_registry.zig");
    if (hmr) {
        view_registry_run.addArg("views=src/views");
        // Register inputs for cache invalidation so editing a .zsx
        // re-runs the codegen even if nothing else changed.
        var vw = b.build_root.handle.openDir("src/views", .{ .iterate = true }) catch
            @panic("cannot open src/views");
        defer vw.close();
        var walker = vw.walk(b.allocator) catch @panic("cannot walk src/views");
        defer walker.deinit();
        while (walker.next() catch @panic("walk error")) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zsx")) {
                view_registry_run.addFileInput(b.path(b.pathJoin(&.{ "src/views", entry.path })));
            }
        }
    } else {
        // Inline mode: emit an empty stub by feeding the generator an
        // empty (or non-existent) views label. Codegen still runs but
        // produces zero entries. Saves the conditional-compilation
        // complexity in registry_runtime.zig.
        const empty_dir = b.addWriteFiles();
        const empty_path = empty_dir.getDirectory();
        view_registry_run.addPrefixedDirectoryArg("views=", empty_path);
    }

    const view_registry_module = b.createModule(.{
        .root_source_file = view_registry_path,
        .imports = &.{
            .{ .name = "zsx", .module = zsx_views },
            .{ .name = "views", .module = views },
        },
    });

    const view_registry_runtime_module = b.createModule(.{
        .root_source_file = b.path("src/view_registry_runtime.zig"),
        .imports = &.{.{ .name = "view_registry", .module = view_registry_module }},
    });
    exe.root_module.addImport("view_registry_runtime", view_registry_runtime_module);
    // The HMR middleware in src/http.zig uses `@import("hmr")` (named module)
    // so the same file isn't pulled into the root module via a relative path
    // and a named import simultaneously — Zig would reject the dup.
    exe.root_module.addImport("hmr", hmr_module);

    // Route table generator — walks pages/, produces routes.zig
    const publr_routes_module = b.createModule(.{
        .root_source_file = b.path("src/tools/publr_routes.zig"),
    });
    const publr_gen_routes = b.addExecutable(.{
        .name = "publr_gen_routes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/publr_gen_routes.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "publr_routes", .module = publr_routes_module }},
        }),
    });

    // Run route generator: pages/ dir → routes.zig
    const gen_routes_cmd = b.addRunArtifact(publr_gen_routes);
    // Input: the theme directory (--project-dir for external builds, local otherwise)
    const theme_dir: std.Build.LazyPath = if (project_dir) |pd|
        .{ .cwd_relative = b.pathJoin(&.{ pd, theme_path }) }
    else
        b.path(theme_path);
    gen_routes_cmd.addDirectoryArg(theme_dir);
    const gen_routes_dir = gen_routes_cmd.addOutputDirectoryArg("theme_routes");

    // Register .publr page files for cache invalidation
    if (project_dir == null) {
        const pages_path = b.pathJoin(&.{ theme_path, "content" });
        var pages_dir_h = b.build_root.handle.openDir(pages_path, .{ .iterate = true }) catch null;
        if (pages_dir_h) |*pd| {
            defer pd.close();
            var walker = pd.walk(b.allocator) catch @panic("cannot walk pages");
            defer walker.deinit();
            while (walker.next() catch @panic("walk error")) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".publr")) {
                    gen_routes_cmd.addFileInput(b.path(b.pathJoin(&.{ pages_path, entry.path })));
                }
            }
        }
    }

    // Theme routes module
    const theme_routes = b.createModule(.{
        .root_source_file = gen_routes_dir.path(b, "routes.zig"),
        .imports = &.{.{ .name = "theme", .module = theme }},
    });
    exe.root_module.addImport("theme_routes", theme_routes);

    // =========================================================================
    // Module Registry — declares core, schema, and shared modules compactly.
    // External modules (publr_config, publr_ui) are registered so others can
    // reference them by name. finalize() at the end resolves cross-deps.
    // =========================================================================
    var reg = helpers.ModuleRegistry.init(b);
    reg.register("publr_config", publr_config_module);
    reg.register("publr_ui", publr_ui);

    // Schemas
    const field_module = reg.leaf("field", "src/core/schema/field.zig");
    _ = reg.simple("content_type", "src/core/schema/content_type.zig", &.{ "field", "middleware" });
    _ = reg.simple("field_types", "src/core/schema/field_types.zig", &.{"field"});
    _ = reg.simple("schema_db_types", "src/core/schema/db_types.zig", &.{ "db", "field", "content_type" });
    // schema_media is the only per-schema module — reused by db_init, main exe,
    // WASM build, and admin plugins. post.zig and page.zig are relative-imported
    // by src/schemas/mod.zig, so they compile as part of schemas_module.
    const schema_media_module = reg.simple("schema_media", "src/schemas/media.zig", &.{ "field", "content_type" });
    const schemas_module = reg.simple("schemas", "src/schemas/mod.zig", &.{ "field", "content_type", "schema_media" });
    // Compile-in content type discovery. Today scans the conventional plugin
    // dirs for `pub const content_types: []const ContentTypeDef` — empty
    // slice when nothing exposes one. Wired into `schema_registry` so the
    // runtime accessors can iterate `compiled_in_types`.
    const content_types_discovery = content_types_mod.discover(
        b,
        &.{ "src/modules/admin", "plugins" },
        &.{
            .{ .name = "content_type", .module = reg.get("content_type") },
            .{ .name = "field", .module = field_module },
        },
    );
    reg.register("compiled_in_content_types", content_types_discovery.module);
    const schema_registry_module = reg.simple("schema_registry", "src/core/schema/registry.zig", &.{ "field", "content_type", "schemas", "compiled_in_content_types" });
    const seed_module = reg.simple("seed", "src/core/schema/seed.zig", &.{ "schema_registry", "field", "db" });

    // Editor plugins registry. Content types declare which editor renders
    // their entry edit page via `ContentTypeDef.editor` (default "form").
    // Built-ins live in src/editors.zig; route dispatch lands in task-03.
    _ = reg.simple("editors", "src/editors.zig", &.{ "middleware", "content_type" });

    // Plugin SDK (dual-mode: native + wasm32-freestanding). Plugins import
    // it as `@import("publr_sdk")`. The SDK selects backend by target arch;
    // both the native exe and freestanding plugin builds use this module
    // unchanged. Task-01 of wasm-plugin-promotion — spike surface only.
    _ = reg.leaf("publr_sdk", "sdk/publr_sdk.zig");

    // Shared leaves (no deps)
    _ = reg.leaf("url", "src/url.zig");
    const mime_module = reg.leaf("mime", "src/mime.zig");
    const multipart_module = reg.leaf("multipart", "src/multipart.zig");

    // Core modules
    const middleware_module = reg.simple("middleware", "src/middleware.zig", &.{"url"});
    const plugin_utils_module = reg.simple("plugin_utils", "src/plugin_utils.zig", &.{"middleware"});
    const pagination_module = reg.simple("pagination", "src/pagination.zig", &.{"plugin_utils"});
    const route_match_module = reg.simple("route_match", "src/route_match.zig", &.{"middleware"});
    const router_module = reg.simple("router", "src/router.zig", &.{ "middleware", "route_match" });
    const db_module = reg.leaf("db", "src/core/db.zig");
    db_module.addIncludePath(b.path("vendor"));
    _ = reg.simple("publish_hooks", "src/publish_hooks.zig", &.{"db"});
    const modules_api_module = reg.simple("modules", "src/modules/mod.zig", &.{ "router", "db", "publr_config" });
    _ = reg.leaf("id_gen", "src/core/id_gen.zig");
    // Active schema source — strict by default, loose when a plugin's
    // manifest.zon declares `.requires_schema = .loose`. Wired as an
    // anonymous `schema_sql` import on every module that does
    // `@embedFile("schema_sql")` (core_init, seed, the init_db tool,
    // the WASM exe). No wrapper .zig file — the build attaches the
    // path directly.
    const active_schema_sql_path: std.Build.LazyPath = b.path(if (plugin_prescan.requires_loose_schema)
        "src/core/schema/content_schema_loose.sql"
    else
        "src/core/schema/content_schema.sql");
    const core_init_module = reg.simple("core_init", "src/core/init.zig", &.{ "db", "seed", "schema_registry", "schemas" });
    core_init_module.addAnonymousImport("schema_sql", .{ .root_source_file = active_schema_sql_path });

    // =========================================================================
    // Database Initialization Tool (comptime schema generation)
    // =========================================================================
    db_init_build.wire(b, .{
        .schema_registry = schema_registry_module,
        .field = field_module,
        .seed = seed_module,
        .schema_sql_path = active_schema_sql_path,
        .exe = exe,
        .project_dir = project_dir,
        .config_path = config_path,
        .watch_mode = watch_mode,
    });

    const time_util_module = reg.leaf("time_util", "src/time_util.zig");
    const core_time_module = reg.leaf("core_time", "src/core/time.zig");
    const db_path_module = reg.leaf("db_path", "src/db_path.zig");
    _ = reg.simple("version", "src/core/version.zig", &.{ "db", "time_util", "field", "schema_registry", "id_gen" });
    _ = reg.simple("release", "src/core/release.zig", &.{ "db", "id_gen", "time_util", "version" });
    _ = reg.simple("query", "src/core/query.zig", &.{ "db", "entry", "schema_registry", "content_type" });
    _ = reg.leaf("entry", "src/core/entry.zig");
    _ = reg.simple("entry_storage", "src/core/entry_storage.zig", &.{ "db", "field", "content_type", "entry" });
    const cms_module = reg.simple("cms", "src/core/content.zig", &.{ "db", "id_gen", "query", "version", "release", "core_init", "schemas", "publish_hooks", "entry_storage", "schema_registry", "content_type", "field" });
    const storage_module = reg.simple("storage", "src/core/storage.zig", &.{"time_util"});
    _ = reg.leaf("svg_sanitize", "src/svg_sanitize.zig");
    const taxonomy_module = reg.simple("taxonomy", "src/core/taxonomy.zig", &.{ "db", "id_gen" });
    const template_context_module = reg.simple("template_context", "src/core/template_context.zig", &.{ "cms", "schema_registry", "taxonomy", "db", "publr_config", "middleware" });
    const media_module = reg.simple("media", "src/core/media.zig", &.{ "db", "cms", "schema_media", "storage", "svg_sanitize", "id_gen", "taxonomy", "media_query" });
    _ = reg.simple("media_query", "src/core/media_query.zig", &.{ "db", "cms", "media", "taxonomy" });
    const media_sync_module = reg.simple("media_sync", "src/core/media_sync.zig", &.{ "db", "media", "storage", "svg_sanitize", "mime" });
    media_sync_module.addIncludePath(b.path("vendor"));
    const tpl_module = reg.leaf("tpl", "src/tpl.zig");
    const auth_module = reg.simple("auth", "src/core/auth.zig", &.{ "db", "time_util" });
    const auth_middleware_module = reg.simple("auth_middleware", "src/auth_middleware.zig", &.{ "middleware", "auth", "db" });
    const csrf_module = reg.simple("csrf", "src/csrf.zig", &.{ "middleware", "auth_middleware", "multipart" });
    _ = reg.simple("actions", "src/actions.zig", &.{ "middleware", "csrf" });
    const admin_api_module = reg.simple("admin_api", "src/admin_api.zig", &.{ "middleware", "publr_ui", "actions", "content_type", "schemas", "schema_registry" });
    const image_module = reg.leaf("image", "src/image.zig");
    image_module.addIncludePath(b.path("vendor"));
    const media_handler_module = reg.simple("media_handler", "src/media_handler.zig", &.{ "storage", "auth_middleware", "middleware", "image", "url", "mime" });
    const gravatar_module = reg.leaf("gravatar", "src/gravatar.zig");
    const websocket_module = reg.leaf("websocket", "src/websocket.zig");
    const presence_module = reg.simple("presence", "src/core/presence.zig", &.{ "websocket", "gravatar" });

    // Resolve the named dep graph — wires every reg.simple(...) module.
    reg.finalize();

    views.addImport("publr_ui", publr_ui);

    // =========================================================================
    // CLI dispatcher
    // =========================================================================
    // src/cli/main.zig pulls in every cli/*.zig peer via relative imports, so
    // we only declare the dispatcher as a module. Its imports list is the
    // union of shared modules any cli/*.zig file reaches for.
    //
    // Test helpers live in src/tests/ — outside src/cli/, so Zig refuses
    // relative @import across the boundary. They stay as named modules.
    const cli_test_helpers_module = b.createModule(.{
        .root_source_file = b.path("src/tests/cli_helpers.zig"),
    });
    const rest_test_helpers_module = b.createModule(.{
        .root_source_file = b.path("src/tests/rest_helpers.zig"),
        .imports = &.{
            .{ .name = "core_init", .module = core_init_module },
            .{ .name = "auth", .module = auth_module },
        },
    });
    const cli_main_module = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .imports = &.{
            .{ .name = "core_init", .module = core_init_module },
            .{ .name = "core_time", .module = core_time_module },
            .{ .name = "db", .module = db_module },
            .{ .name = "cms", .module = cms_module },
            .{ .name = "schemas", .module = schemas_module },
            .{ .name = "schema_registry", .module = schema_registry_module },
            .{ .name = "content_type", .module = reg.get("content_type") },
            .{ .name = "field", .module = field_module },
            .{ .name = "auth", .module = auth_module },
            .{ .name = "media", .module = media_module },
            .{ .name = "media_sync", .module = media_sync_module },
            .{ .name = "mime", .module = mime_module },
            .{ .name = "storage", .module = storage_module },
            .{ .name = "taxonomy", .module = taxonomy_module },
            .{ .name = "cli_test_helpers", .module = cli_test_helpers_module },
            .{ .name = "db_path", .module = db_path_module },
        },
    });

    // REST endpoints (src/rest/*.zig) are relative-imported by src/http.zig,
    // which is itself relative-imported by src/main.zig. The union of shared
    // modules they need is attached to the main exe further below.

    // =========================================================================
    // Plugin Modules
    // =========================================================================
    // Plugins are auto-discovered from src/modules/admin/ (built-in) and
    // plugins/ (project plugins, sibling to themes/). See loadPlugins() at
    // the bottom of this file. Drop a new file/dir into either location and
    // it auto-registers — no edits here.
    const plugin_imports = [_]std.Build.Module.Import{
        .{ .name = "admin_api", .module = admin_api_module },
        .{ .name = "middleware", .module = middleware_module },
        .{ .name = "tpl", .module = tpl_module },
        .{ .name = "db", .module = db_module },
        .{ .name = "csrf", .module = csrf_module },
        .{ .name = "auth", .module = auth_module },
        .{ .name = "auth_middleware", .module = auth_middleware_module },
        .{ .name = "views", .module = views },
        .{ .name = "schemas", .module = schemas_module },
        .{ .name = "cms", .module = cms_module },
        .{ .name = "field", .module = field_module },
        .{ .name = "content_type", .module = reg.get("content_type") },
        .{ .name = "gravatar", .module = gravatar_module },
        .{ .name = "time_util", .module = time_util_module },
        .{ .name = "presence", .module = presence_module },
        .{ .name = "websocket", .module = websocket_module },
        .{ .name = "media", .module = media_module },
        .{ .name = "media_sync", .module = media_sync_module },
        .{ .name = "media_handler", .module = media_handler_module },
        .{ .name = "storage", .module = storage_module },
        .{ .name = "schema_media", .module = schema_media_module },
        .{ .name = "multipart", .module = multipart_module },
        .{ .name = "plugin_utils", .module = plugin_utils_module },
        .{ .name = "pagination", .module = pagination_module },
        .{ .name = "publr_config", .module = publr_config_module },
        .{ .name = "schema_registry", .module = schema_registry_module },
        .{ .name = "editors", .module = reg.get("editors") },
    };
    const plugins = plugins_mod.load(b, &.{ "src/modules/admin", "plugins" }, &plugin_imports);

    const module_admin_module = b.createModule(.{
        .root_source_file = b.path("src/modules/admin/mod.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "router", .module = router_module },
            .{ .name = "modules", .module = modules_api_module },
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
        },
    });

    // =========================================================================
    // Registry Module (consumes the auto-discovered plugin manifest)
    // =========================================================================
    const registry_module = b.createModule(.{
        .root_source_file = b.path("src/registry.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "publr_ui", .module = publr_ui },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "gravatar", .module = gravatar_module },
            .{ .name = "views", .module = views },
            .{ .name = "schemas", .module = schemas_module },
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
        },
    });

    // admin_api needs the rendering deps + registry for declarative registerPage.
    // Added post-hoc because registry imports admin_api (resolved at compile time).
    admin_api_module.addImport("tpl", tpl_module);
    admin_api_module.addImport("views", views);
    admin_api_module.addImport("csrf", csrf_module);
    admin_api_module.addImport("auth_middleware", auth_middleware_module);
    admin_api_module.addImport("gravatar", gravatar_module);
    admin_api_module.addImport("registry", registry_module);

    // Editors registry aggregates plugin-registered editors via the plugin
    // manifest. Post-hoc import because plugins.load runs later than the
    // schema-section module registration where `editors` is first created.
    reg.get("editors").addImport("plugin_registry", plugins.manifest_module);

    // Plugin-facing modules that depend on the auto-discovered plugin
    // manifest (built after plugins.load() so the manifest exists).
    //   - save_hooks: fires after each saveEntry, comptime-collected from
    //     plugins. Attachment point for sync capture, indexing, etc.
    //   - db_open_hooks: fires after each Db.init, same pattern.
    //   - sync_transport: WS-based outbound transport for plugin use.
    const save_hooks_module = b.createModule(.{
        .root_source_file = b.path("src/save_hooks.zig"),
        .imports = &.{
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
            .{ .name = "db", .module = db_module },
        },
    });
    reg.register("save_hooks", save_hooks_module);

    const db_open_hooks_module = b.createModule(.{
        .root_source_file = b.path("src/db_open_hooks.zig"),
        .imports = &.{
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
            .{ .name = "db", .module = db_module },
        },
    });
    reg.register("db_open_hooks", db_open_hooks_module);

    const apply_remote_hooks_module = b.createModule(.{
        .root_source_file = b.path("src/apply_remote_hooks.zig"),
        .imports = &.{
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
            .{ .name = "db", .module = db_module },
        },
    });
    reg.register("apply_remote_hooks", apply_remote_hooks_module);

    const sync_catchup_hooks_module = b.createModule(.{
        .root_source_file = b.path("src/sync_catchup_hooks.zig"),
        .imports = &.{
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
            .{ .name = "db", .module = db_module },
        },
    });
    reg.register("sync_catchup_hooks", sync_catchup_hooks_module);

    // KV variables — editor-facing named string store with comptime plugin
    // registration. Plugins export `pub const kv_vars: []const kv.Def` and
    // the module's collector picks them up via @hasDecl, matching the
    // save_hooks pattern. Runtime resolves values from the `kv` table or
    // via computed-fn dispatch.
    const kv_module = b.createModule(.{
        .root_source_file = b.path("src/kv/registry.zig"),
        .imports = &.{
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
            .{ .name = "db", .module = db_module },
            .{ .name = "save_hooks", .module = save_hooks_module },
            .{ .name = "publish_hooks", .module = reg.get("publish_hooks") },
        },
    });
    reg.register("kv", kv_module);

    // cms (src/core/content.zig) wires kv.refs.afterSave and kv.refs.dropEntryRefs
    // into the save/delete paths. Added post-hoc here for the same reason as
    // save_hooks below — kv_module depends on plugin_registry which is set up
    // after plugins.load().
    cms_module.addImport("kv", kv_module);

    // The "variables" admin plugin AND the "content" admin plugin (whose
    // render.zig injects the kv picker script + JSON onto every content
    // edit page) both need the kv module. Plugins are discovered by
    // plugins.load() with a fixed `plugin_imports` list; kv can't be in
    // that list because it's created after plugins.load() (it needs
    // plugins.manifest_module + save_hooks_module). Wire it in post-hoc.
    for (plugins.plugins) |p| {
        if (std.mem.eql(u8, p.name, "variables") or std.mem.eql(u8, p.name, "content")) {
            p.module.addImport("kv", kv_module);
        }
    }

    // Render hooks — fired pre-write to the response stream. Mirrors save_hooks
    // (comptime plugin collector) plus a hardcoded core hook for KV live-var
    // substitution. Defined here because it depends on kv_module above.
    const render_hooks_module = b.createModule(.{
        .root_source_file = b.path("src/render_hooks.zig"),
        .imports = &.{
            .{ .name = "db", .module = db_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "plugin_registry", .module = plugins.manifest_module },
            .{ .name = "kv", .module = kv_module },
        },
    });
    reg.register("render_hooks", render_hooks_module);

    // Router calls render_hooks.beforeWrite(...) right before sendResponse,
    // and reads the global Db via auth_middleware.auth. Both added post-hoc
    // because they depend on modules defined after router_module.
    router_module.addImport("render_hooks", render_hooks_module);
    router_module.addImport("auth_middleware", auth_middleware_module);

    // Outbound sync transport — calls a JS import in WASM, broadcasts via
    // websocket.registry on native (server is the relay; save_hooks here
    // capture local changes for cross-replica fanout). The websocket dep
    // is comptime-gated in the source.
    const sync_transport_module = b.createModule(.{
        .root_source_file = b.path("src/sync_transport.zig"),
        .imports = &.{
            .{ .name = "websocket", .module = reg.get("websocket") },
        },
    });
    reg.register("sync_transport", sync_transport_module);

    // Relay-side sync token: random base64 stored at data/sync_token, used
    // by /admin/ws/sync to authenticate replicas that can't share cookies.
    const sync_token_module = b.createModule(.{
        .root_source_file = b.path("src/sync_token.zig"),
        .target = target,
    });
    reg.register("sync_token", sync_token_module);

    // cms (src/core/content.zig) fires save_hooks.afterSave at the end of
    // saveEntry; core_init (src/core/init.zig) fires db_open_hooks.fireAll
    // after each Db.init. Added post-hoc because both need plugin_registry
    // which only exists after plugins.load().
    cms_module.addImport("save_hooks", save_hooks_module);
    core_init_module.addImport("db_open_hooks", db_open_hooks_module);

    // Forward-referenced imports for each discovered plugin:
    //   - registry: created above; plugins call into it for layout helpers.
    //   - save_hooks + db_open_hooks: after-save + post-open hook APIs.
    //   - sync_transport: WS-based outbound transport for sync use.
    //   - views: each plugin module is exposed to views/ so view components
    //     can import any plugin's exports (e.g. settings_tabs.zsx reads
    //     plugin_settings.tabs).
    for (plugins.plugins) |p| {
        p.module.addImport("registry", registry_module);
        p.module.addImport("save_hooks", save_hooks_module);
        p.module.addImport("db_open_hooks", db_open_hooks_module);
        p.module.addImport("apply_remote_hooks", apply_remote_hooks_module);
        p.module.addImport("sync_catchup_hooks", sync_catchup_hooks_module);
        p.module.addImport("sync_transport", reg.get("sync_transport"));
        p.module.addImport("sync_token", reg.get("sync_token"));
        views.addImport(b.fmt("plugin_{s}", .{p.name}), p.module);

        // Per-plugin ZSX views: if `plugins/<name>/views/` exists, run the
        // shared transpiler over it and expose the generated namespace to
        // the plugin as `plugin_views`. Keeps each plugin's view code
        // self-contained (no cross-references into src/views).
        const views_path = b.fmt("plugins/{s}/views", .{p.name});
        if (b.build_root.handle.openDir(views_path, .{ .iterate = true })) |opened| {
            var d = opened;
            defer d.close();

            const pv_cmd = b.addRunArtifact(zsx_transpiler);
            // Mirror the hmr flag onto plugin-view transpiles so plugin
            // components participate in the same hot-swap fast path as
            // core views. Flags must precede positional args.
            if (hmr) pv_cmd.addArgs(&.{ "--hmr", "--hmr-capture-props" });
            pv_cmd.addDirectoryArg(b.path(views_path));
            const pv_out = pv_cmd.addOutputDirectoryArg("views");

            // Feed this plugin's class manifest into the admin JIT compile so
            // classes that only exist in plugin views (incl. `:class` reactive
            // bindings) get real CSS rules — build-time, same as core views.
            theme_pipe.jit_cmd.addFileArg(pv_out.path(b, "css_classes.txt"));

            // Register .zsx files for content-based cache invalidation.
            var walker = d.walk(b.allocator) catch @panic("walk plugin views");
            defer walker.deinit();
            while (walker.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.basename, ".zsx")) continue;
                pv_cmd.addFileInput(b.path(b.pathJoin(&.{ views_path, entry.path })));
            }

            const pv_mod = b.createModule(.{
                .root_source_file = pv_out.path(b, "views.zig"),
                .imports = &.{
                    .{ .name = "zsx", .module = zsx_views },
                    .{ .name = "hmr", .module = hmr_module },
                },
            });
            pv_mod.addImport("publr_ui", publr_ui);
            p.module.addImport("plugin_views", pv_mod);
        } else |_| {}
    }

    // Register a few externally-built modules so the exe wiring can pull
    // them via the registry (theme, module_admin, etc. are created above).
    reg.register("views", views);
    reg.register("theme", theme);
    reg.register("template_context", template_context_module);
    reg.register("module_admin", module_admin_module);
    reg.register("cli_main", cli_main_module);
    reg.register("rest_test_helpers", rest_test_helpers_module);

    // content_actions wires the eight `content.<verb>` action handlers into
    // the dispatcher. It imports plugin_content (the auto-discovered content
    // plugin module) to call its per-CT `*For` impls. Built after plugins
    // are loaded so that import is available.
    const content_actions_module = b.createModule(.{
        .root_source_file = b.path("src/content_actions.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "actions", .module = reg.get("actions") },
            .{ .name = "schema_registry", .module = schema_registry_module },
            .{ .name = "content_type", .module = reg.get("content_type") },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "views", .module = views },
        },
    });
    for (plugins.plugins) |p| {
        if (std.mem.eql(u8, p.name, "content")) {
            content_actions_module.addImport("plugin_content", p.module);
        }
    }
    reg.register("content_actions", content_actions_module);

    // Shared imports common to native exe + WASM (passed to wasm_build later).
    const shared_imports = reg.importsFor(&.{
        "views",              "admin_api",    "auth",            "auth_middleware", "cms",
        "csrf",               "db",           "image",           "media",           "media_handler",
        "middleware",         "schema_media", "seed",            "storage",         "svg_sanitize",
        "tpl",                "actions",      "content_actions", "schema_registry", "schema_db_types",
        "schemas",            "save_hooks",   "db_open_hooks",   "sync_transport",  "apply_remote_hooks",
        "sync_catchup_hooks", "editors",
    });
    reg.attachAll(exe.root_module, &.{
        "views",             "admin_api",       "auth",               "auth_middleware",    "cms",
        "csrf",              "db",              "image",              "media",              "media_handler",
        "middleware",        "schema_media",    "seed",               "storage",            "svg_sanitize",
        "tpl",               "theme",           "template_context",   "publish_hooks",      "publr_ui",
        "modules",           "module_admin",    "cli_main",           "actions",            "content_actions",
        // src/rest/*.zig is relative-imported by src/http.zig — these are the
        // modules the REST tree reaches for that aren't already shared.
        "core_time",         "media_query",     "mime",               "multipart",          "taxonomy",
        "rest_test_helpers", "router",          "url",                "field",              "content_type",
        "schemas",           "schema_registry", "core_init",          "media_sync",         "websocket",
        "presence",          "schema_db_types", "db_path",            "save_hooks",         "db_open_hooks",
        "sync_transport",    "sync_token",      "apply_remote_hooks", "sync_catchup_hooks", "plugin_utils",
        "editors",
    });

    // Add plugin modules to main exe
    // Plugin modules are exposed to the exe so non-plugin code (e.g. websocket
    // handlers) can directly import a specific plugin's helpers. Most code
    // should reach plugins via plugin_registry; this is the escape hatch.
    for (plugins.plugins) |p| {
        exe.root_module.addImport(b.fmt("plugin_{s}", .{p.name}), p.module);
    }

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Tests depend on transpile step
    exe_tests.step.dependOn(&transpile_zsx_cmd.step);

    // Test exe links the vendor C sources directly (rather than via the
    // shared lib) so test-only compile flags can diverge if needed later.
    vendors.addAll(b, exe_tests, native_vendor_opts);
    vendors.linkStaticLibs(exe_tests, native_vendor_opts);

    // Expose plugin modules to the test exe so tests inside plugin files
    // (e.g. plugins/cr-sqlite/sync.zig) are reachable from the test
    // root's import graph and get discovered by Zig's test runner.
    for (plugins.plugins) |p| {
        exe_tests.root_module.addImport(b.fmt("plugin_{s}", .{p.name}), p.module);
    }

    reg.register("registry", registry_module);
    reg.attachAll(exe_tests.root_module, &.{
        "views",             "modules",            "module_admin",       "cli_main",
        "core_time",         "media_query",        "mime",               "taxonomy",
        "rest_test_helpers", "registry",           "admin_api",          "schema_media",
        "core_init",         "auth",               "storage",            "svg_sanitize",
        "media",             "media_sync",         "media_handler",      "image",
        "multipart",         "actions",            "cms",                "entry_storage",
        "field",             "content_type",       "schema_registry",    "field_types",
        "db_path",           "save_hooks",         "db_open_hooks",      "sync_transport",
        "sync_token",        "apply_remote_hooks", "sync_catchup_hooks", "editors",
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(b.getInstallStep());

    // Source-level tests now live alongside each pub fn file.
    // Keep dedicated steps for compatibility; they run the same unified suite.
    const run_core_tests = run_exe_tests;
    const run_cli_tests = run_exe_tests;
    const run_rest_tests = run_exe_tests;

    const test_core_step = b.step("test-core", "Run core integration tests");
    test_core_step.dependOn(&run_core_tests.step);

    const test_cli_step = b.step("test-cli", "Run CLI e2e tests");
    test_cli_step.dependOn(&run_cli_tests.step);

    const test_rest_step = b.step("test-rest", "Run REST integration tests");
    test_rest_step.dependOn(&run_rest_tests.step);

    // Publr template tool tests (needs zsx module)
    const publr_template_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/publr_template.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zsx", .module = zsx }},
        }),
    });
    const run_publr_template_tests = b.addRunArtifact(publr_template_tests);

    // Publr preprocessor tests
    const publr_preprocess_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/publr_preprocess.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "publr_template", .module = publr_template_module }},
        }),
    });
    const run_publr_preprocess_tests = b.addRunArtifact(publr_preprocess_tests);

    // Publr route table tests
    const publr_routes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/publr_routes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_publr_routes_tests = b.addRunArtifact(publr_routes_tests);

    // File watcher tests (task-04 of cms-hmr-fast-path). Standalone module
    // — no other src/ imports, no vendor libs needed. The main test exe
    // can't see it yet because `main.zig` doesn't import it (deferred until
    // task-08 wires the watcher into the dev event loop), so we give it
    // its own test target wired into `zig build test` and `verify` below.
    const watcher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/watcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_watcher_tests = b.addRunArtifact(watcher_tests);

    // Watcher module — exposed by name so the HMR swap loop (task-06) and
    // task-08's dev event loop can `@import("watcher")`. Same source as
    // the test target above; named here for non-test consumers.
    const watcher_module = b.createModule(.{
        .root_source_file = b.path("src/watcher.zig"),
    });
    // task-08: main.zig's `runDevMode` drives the watcher poll loop in
    // process and ships events into the swap loop, so the main exe must
    // be able to `@import("watcher")`.
    exe.root_module.addImport("watcher", watcher_module);

    // Runtime JIT module — exposes `jit.compile(allocator, theme, classes)`
    // to dev-time recompile from rendered HTML. The same source is also
    // used as a build-time executable in build/theme.zig (jit_compiler);
    // here we wrap it as an importable module so the HMR loop can call
    // into it without forking a subprocess.
    const jit_runtime_module = b.createModule(.{
        .root_source_file = b.path("vendor/jit/jit.zig"),
        .imports = &.{
            .{ .name = "zsx", .module = zsx_views },
        },
    });

    // Themes as .zon imports so the runtime JIT merges them at comptime
    // the same way build/theme.zig does. Keeps build-time and runtime
    // CSS byte-identical for the same class set (no late divergence).
    const default_theme_zon = b.createModule(.{
        .root_source_file = b.path("vendor/jit/default-theme.zon"),
        .imports = &.{.{ .name = "jit", .module = jit_runtime_module }},
    });
    const ds_theme_zon = b.createModule(.{
        .root_source_file = b.path("vendor/jit/ds-tokens.zon"),
        .imports = &.{.{ .name = "jit", .module = jit_runtime_module }},
    });

    // CSS JIT module — small wrapper that walks rendered HTML for
    // `class="…"` attributes and feeds the jit compiler. Used by the
    // HMR loop after a fast-path swap to keep DS utility classes in
    // sync with what was just rendered (the build-time scan misses
    // backtick-assembled class strings).
    const css_jit_module = b.createModule(.{
        .root_source_file = b.path("src/css_jit.zig"),
        .imports = &.{
            .{ .name = "jit", .module = jit_runtime_module },
            .{ .name = "default_theme", .module = default_theme_zon },
            .{ .name = "ds_theme", .module = ds_theme_zon },
        },
    });

    // Runtime CSS override holder — populated by the HMR loop after a
    // fast-path swap, read by the static handler when serving admin.css.
    // Its own module so writer (hmr_loop) and reader (static handler in
    // exe root) don't need a cross-module relative import.
    const runtime_css_module = b.createModule(.{
        .root_source_file = b.path("src/runtime_css.zig"),
    });
    exe.root_module.addImport("runtime_css", runtime_css_module);

    // HMR swap loop (task-06 of cms-hmr-fast-path). Pulls together the
    // watcher events, the runtime view registry, the persisted prop
    // metadata, and the (task-07-supplied) broadcaster callback.
    // Standalone test target wired into `zig build test` + `verify`,
    // mirroring watcher/hmr.
    const hmr_loop_module = b.createModule(.{
        .root_source_file = b.path("src/hmr_loop.zig"),
        .imports = &.{
            .{ .name = "watcher", .module = watcher_module },
            .{ .name = "view_registry_runtime", .module = view_registry_runtime_module },
            .{ .name = "hmr", .module = hmr_module },
            .{ .name = "zsx", .module = zsx_views },
            .{ .name = "css_jit", .module = css_jit_module },
            .{ .name = "runtime_css", .module = runtime_css_module },
        },
    });
    exe.root_module.addImport("hmr_loop", hmr_loop_module);

    // HMR WebSocket push channel (task-07 of cms-hmr-fast-path). The
    // dev-only `/__hmr/ws` endpoint + the `/__hmr/render?name=<view>`
    // refetch endpoint. Wires to the swap loop's broadcaster callback
    // and feeds JSON messages to the inline live-reload client.
    const hmr_ws_module = b.createModule(.{
        .root_source_file = b.path("src/hmr_ws.zig"),
        .imports = &.{
            .{ .name = "router", .module = reg.get("router") },
            .{ .name = "websocket", .module = websocket_module },
            .{ .name = "view_registry_runtime", .module = view_registry_runtime_module },
            .{ .name = "hmr", .module = hmr_module },
            .{ .name = "hmr_loop", .module = hmr_loop_module },
            .{ .name = "plugin_utils", .module = plugin_utils_module },
        },
    });
    exe.root_module.addImport("hmr_ws", hmr_ws_module);

    const hmr_ws_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hmr_ws.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "router", .module = reg.get("router") },
                .{ .name = "websocket", .module = websocket_module },
                .{ .name = "view_registry_runtime", .module = view_registry_runtime_module },
                .{ .name = "hmr", .module = hmr_module },
                .{ .name = "hmr_loop", .module = hmr_loop_module },
                .{ .name = "plugin_utils", .module = plugin_utils_module },
            },
        }),
    });
    // Same rationale as hmr_loop_tests: the runtime registry transitively
    // touches sqlite/stb via the views tree.
    vendors.addAll(b, hmr_ws_tests, native_vendor_opts);
    vendors.linkStaticLibs(hmr_ws_tests, native_vendor_opts);
    const run_hmr_ws_tests = b.addRunArtifact(hmr_ws_tests);

    const hmr_loop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hmr_loop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "watcher", .module = watcher_module },
                .{ .name = "view_registry_runtime", .module = view_registry_runtime_module },
                .{ .name = "hmr", .module = hmr_module },
                .{ .name = "zsx", .module = zsx_views },
                .{ .name = "css_jit", .module = css_jit_module },
                .{ .name = "runtime_css", .module = runtime_css_module },
            },
        }),
    });
    // The runtime view_registry pulls in the generated `views` module,
    // which transitively imports plugin modules that touch sqlite/stb.
    // Link the vendor lib so the test exe can resolve those symbols at
    // link time even though the swap-loop tests never call into them.
    vendors.addAll(b, hmr_loop_tests, native_vendor_opts);
    vendors.linkStaticLibs(hmr_loop_tests, native_vendor_opts);
    const run_hmr_loop_tests = b.addRunArtifact(hmr_loop_tests);

    // HMR prop-capture tests (task-05 of cms-hmr-fast-path). Standalone
    // module, mirrors the watcher_tests setup — main.zig doesn't import
    // hmr.zig (only the generated view tree does, and that's hidden behind
    // -Dhmr), so we give it its own test target wired into `test` + `verify`.
    const hmr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hmr.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_hmr_tests = b.addRunArtifact(hmr_tests);

    // Storage / schema test aggregator. The Zig 0.15 test runner only walks
    // the test root's import graph for test discovery, so we use a
    // dedicated wrapper in src/tests/ that pulls in entry_storage via a
    // named import. Modules are wired by name so SQL paths and the
    // SQLite vendor lib resolve correctly.
    const storage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/storage_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "entry_storage", .module = reg.get("entry_storage") },
                .{ .name = "db", .module = reg.get("db") },
                .{ .name = "field", .module = reg.get("field") },
                .{ .name = "content_type", .module = reg.get("content_type") },
                .{ .name = "taxonomy", .module = reg.get("taxonomy") },
                .{ .name = "query", .module = reg.get("query") },
                .{ .name = "entry", .module = reg.get("entry") },
            },
        }),
    });
    vendors.addAll(b, storage_tests, native_vendor_opts);
    vendors.linkStaticLibs(storage_tests, native_vendor_opts);
    const run_storage_tests = b.addRunArtifact(storage_tests);

    // Editor registry tests. Wrapper file at `src/tests/editors_tests.zig`
    // rather than editors.zig itself, because editors.zig is referenced by
    // the plugin manifest (each plugin imports `editors`), so using it as a
    // test root would put the same file in two modules. See the wrapper's
    // header for context.
    const editors_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/editors_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "editors", .module = reg.get("editors") },
                .{ .name = "middleware", .module = reg.get("middleware") },
                .{ .name = "content_type", .module = reg.get("content_type") },
            },
        }),
    });
    // Plugin tree (incl. gutenberg) transitively pulls in cms → sqlite,
    // so link the vendor libs to the test binary the same way storage_tests does.
    vendors.addAll(b, editors_tests, native_vendor_opts);
    vendors.linkStaticLibs(editors_tests, native_vendor_opts);
    const run_editors_tests = b.addRunArtifact(editors_tests);

    // Editor asset-serving route tests — dedicated target for the same
    // reason as editors_tests (test root must reach the file via imports).
    const editor_assets_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http_handlers/editor_assets.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "router", .module = reg.get("router") },
                .{ .name = "editors", .module = reg.get("editors") },
            },
        }),
    });
    const run_editor_assets_tests = b.addRunArtifact(editor_assets_tests);

    // KV variables test aggregator. Mirrors storage_tests pattern: test root
    // in src/tests/ so the schema SQL path resolves via std.fs.cwd, and Zig
    // 0.15's test discovery walks down through the @import("kv") edge.
    const kv_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/kv_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kv", .module = reg.get("kv") },
                .{ .name = "db", .module = reg.get("db") },
                .{ .name = "publish_hooks", .module = reg.get("publish_hooks") },
                .{ .name = "cms", .module = reg.get("cms") },
            },
        }),
    });
    vendors.addAll(b, kv_tests, native_vendor_opts);
    vendors.linkStaticLibs(kv_tests, native_vendor_opts);
    const run_kv_tests = b.addRunArtifact(kv_tests);

    // SDK spike — task-01 of wasm-plugin-promotion. The native-target test
    // exercises the SDK's native backend via the spike example plugin; the
    // freestanding WASM step verifies the SAME plugin source compiles cleanly
    // for wasm32-freestanding. WAMR-driven execution parity lands in task-02.
    const spike_plugin_native = b.createModule(.{
        .root_source_file = b.path("examples/plugins/spike/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "publr_sdk", .module = reg.get("publr_sdk") },
        },
    });
    const sdk_spike_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/sdk_spike_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "publr_sdk", .module = reg.get("publr_sdk") },
                .{ .name = "spike_plugin", .module = spike_plugin_native },
            },
        }),
    });
    const run_sdk_spike_tests = b.addRunArtifact(sdk_spike_tests);

    // Freestanding WASM build of the same plugin source. Compiled as a
    // dynamic library (artifact) and installed under `zig-out/plugins/`.
    // Task-02 will load this through WAMR; for now we just need it to compile.
    const spike_wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const spike_plugin_wasm_module = b.createModule(.{
        .root_source_file = b.path("examples/plugins/spike/main.zig"),
        .target = spike_wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "publr_sdk", .module = b.createModule(.{
                .root_source_file = b.path("sdk/publr_sdk.zig"),
                .target = spike_wasm_target,
                .optimize = .ReleaseSmall,
            }) },
        },
    });
    const spike_wasm = b.addExecutable(.{
        .name = "spike",
        .root_module = spike_plugin_wasm_module,
    });
    spike_wasm.entry = .disabled;
    spike_wasm.rdynamic = true;
    const install_spike_wasm = b.addInstallArtifact(spike_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "plugins" } },
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_rest_tests.step);
    test_step.dependOn(&run_publr_template_tests.step);
    test_step.dependOn(&run_publr_preprocess_tests.step);
    test_step.dependOn(&run_publr_routes_tests.step);
    test_step.dependOn(&run_storage_tests.step);
    test_step.dependOn(&run_kv_tests.step);

    // Isolated step so KV tests can be run independently of the broader test
    // graph (useful when other unrelated targets are temporarily broken).
    const test_kv_step = b.step("test-kv", "Run KV variable tests in isolation");
    test_kv_step.dependOn(&run_kv_tests.step);
    test_step.dependOn(&run_editors_tests.step);
    test_step.dependOn(&run_editor_assets_tests.step);
    test_step.dependOn(&run_sdk_spike_tests.step);
    test_step.dependOn(&run_watcher_tests.step);
    test_step.dependOn(&run_hmr_tests.step);
    test_step.dependOn(&run_hmr_loop_tests.step);
    test_step.dependOn(&run_hmr_ws_tests.step);

    // Isolated step for the HMR swap loop tests. The main `test` step
    // depends on `test-core`/`test-cli`/`test-rest` which currently fail
    // due to user WIP elsewhere (kv refs); the swap loop tests don't
    // need that surface and can be exercised independently.
    const test_hmr_loop_step = b.step("test-hmr-loop", "Run HMR swap loop tests in isolation");
    test_hmr_loop_step.dependOn(&run_hmr_loop_tests.step);

    // Isolated step for the HMR WebSocket tests — same rationale.
    const test_hmr_ws_step = b.step("test-hmr-ws", "Run HMR WebSocket tests in isolation");
    test_hmr_ws_step.dependOn(&run_hmr_ws_tests.step);

    // Verify step: runs all tests + WASM build.
    const verify_step = b.step("verify", "Run tests and verify WASM build");
    verify_step.dependOn(test_step);
    verify_step.dependOn(&install_spike_wasm.step);

    // =========================================================================
    // Browser WASM Build (full CMS with embedded SQLite)
    // =========================================================================
    const wasm_result = wasm_build.build(b, .{
        .vendor_opts = wasm_vendor_opts,
        .shared_imports = shared_imports,
        .views = views,
        .db = db_module,
        .storage = storage_module,
        .middleware = middleware_module,
        .auth_middleware = auth_middleware_module,
        .media = media_module,
        .media_handler = media_handler_module,
        .image = image_module,
        .admin_api = admin_api_module,
        .registry = registry_module,
        .route_match = route_match_module,
        .editors = reg.get("editors"),
        .plugins = plugins.plugins,
        .schema_sql_path = b.path(if (plugin_prescan.requires_loose_schema)
            "src/core/schema/content_schema_loose.sql"
        else
            "src/core/schema/content_schema.sql"),
        .setup_bg_dark = setup_bg_dark,
        .transpile_step = &transpile_zsx_cmd.step,
        .jit_css_output = jit_css_output,
    });
    _ = wasm_result.browser_step; // top-level `zig build browser` step
    verify_step.dependOn(wasm_result.install_step);

    // =========================================================================
    // Browser Bundle (source + .o files + manifest for browser compilation)
    // =========================================================================
    const browser_bundle_step = b.step("browser-bundle", "Create CMS source bundle for browser compilation");

    const bundle_tool = b.addExecutable(.{
        .name = "browser_bundle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/browser_bundle.zig"),
            .target = b.graph.host,
        }),
    });

    const run_bundle = b.addRunArtifact(bundle_tool);
    run_bundle.addArg(b.pathJoin(&.{ "zig-out", "browser-bundle" }));
    run_bundle.addDirectoryArg(gen_views);
    run_bundle.setCwd(b.path("."));

    // Bundle depends on transpile step (needs generated views)
    run_bundle.step.dependOn(&transpile_zsx_cmd.step);

    browser_bundle_step.dependOn(&run_bundle.step);

    // =========================================================================
    // Browser Dev Server — serves browser/, zig-out/browser/cms.wasm, static/
    // (replaces the previous Vite setup).
    // =========================================================================
    const dev_browser_step = b.step("dev-browser", "Serve the browser WASM CMS preview (replaces `vite dev`)");

    const dev_server_exe = b.addExecutable(.{
        .name = "dev_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/dev_server.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "mime", .module = mime_module },
            },
        }),
    });
    const run_dev_server = b.addRunArtifact(dev_server_exe);
    run_dev_server.setCwd(b.path("."));
    if (b.args) |passthrough| run_dev_server.addArgs(passthrough);
    // Ensure the served WASM blob is always built (and rebuilt when its
    // inputs, like the embedded starter `data/publr.db`, have changed)
    // before the dev server starts handing it out.
    run_dev_server.step.dependOn(wasm_result.install_step);
    dev_browser_step.dependOn(&run_dev_server.step);
}

/// Scan `plugins/<name>/lib/` for static-lib contributions to
/// `publr_vendors`. Convention:
///   - `plugins/<name>/lib/native.a` (for native) is linked in.
///   - `plugins/<name>/lib/wasm.a` (for wasm) is linked in.
/// C sources and include paths come via the `sqlite_override_dir`
/// manifest field instead (see `vendors.zig`), so a plugin can swap
/// sqlite + glue without ever touching the wider plugin-vendor surface.
fn collectPluginVendor(b: *std.Build, wasm: bool) vendors.Opts {
    var libs: std.ArrayList(std.Build.LazyPath) = .empty;

    var plugins_dir = b.build_root.handle.openDir("plugins", .{ .iterate = true }) catch {
        return .{ .wasm = wasm };
    };
    defer plugins_dir.close();
    var it = plugins_dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const name = b.dupe(entry.name);

        const lib_name = if (wasm) "wasm.a" else "native.a";
        const lib_path = b.fmt("plugins/{s}/lib/{s}", .{ name, lib_name });
        b.build_root.handle.access(lib_path, .{}) catch continue;

        libs.append(b.allocator, b.path(lib_path)) catch @panic("OOM");
    }

    return .{
        .wasm = wasm,
        .extra_c_sources = &.{},
        .extra_include_paths = &.{},
        .static_libs = libs.toOwnedSlice(b.allocator) catch @panic("OOM"),
    };
}

/// Per-plugin C-flags for vendor sources. Graduates to a plugin manifest
/// once a plugin needs custom flags.
fn pluginCFlags(plugin_name: []const u8) []const []const u8 {
    _ = plugin_name;
    return &.{};
}

/// Fold the plugin-manifest sqlite override decisions onto an existing
/// vendor opts (from collectPluginVendor). Keeps the two concerns —
/// scanning plugin vendor dirs for static libs and reading manifests for
/// the override path — wired in the right order.
fn withPluginSqliteOverride(opts: vendors.Opts, prescan: plugins_mod.PreScan) vendors.Opts {
    var out = opts;
    out.sqlite_override_dir = prescan.sqlite_override_dir;
    out.sqlite_override_extra_cflags = prescan.sqlite_override_cflags;
    return out;
}
