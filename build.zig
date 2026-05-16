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
    });
    const zsx = theme_pipe.zsx;
    const publr_template_module = theme_pipe.publr_template_module;
    const transpile_zsx_cmd = theme_pipe.transpile_zsx_cmd;
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
    // cached, recompiled only when vendor sources change.
    const vendor_lib = vendors.library(b, target, optimize, .{});
    exe.linkLibC();
    exe.addIncludePath(b.path("vendor")); // for @cImport headers
    exe.linkLibrary(vendor_lib);

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
        .{ "static_interact_portal_js", "static/interact/portal.js" },
        .{ "static_interact_focus_trap_js", "static/interact/focus-trap.js" },
        .{ "static_interact_dismiss_js", "static/interact/dismiss.js" },
        .{ "static_interact_components_js", "static/interact/components.js" },
        .{ "static_interact_index_js", "static/interact/index.js" },
        .{ "static_interact_repeater_js", "static/interact/repeater.js" },
        .{ "static_media_selection_js", "static/media-selection.js" },
        .{ "static_interact_websocket_js", "static/interact/websocket.js" },
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

    // Single views module — generated views.zig provides namespace hierarchy
    const views = b.createModule(.{
        .root_source_file = gen_views.path(b, "views.zig"),
        .imports = &.{.{ .name = "zsx", .module = zsx_views }},
    });

    // Theme module — generated from .publr templates
    const theme = b.createModule(.{
        .root_source_file = gen_theme.path(b, "views.zig"),
        .imports = &.{.{ .name = "zsx", .module = zsx_views }},
    });

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
    const seed_module = reg.simple("seed", "src/core/schema/seed.zig", &.{ "schema_registry", "field", "db", "sync" });

    // Shared leaves (no deps)
    _ = reg.leaf("url", "src/url.zig");
    const mime_module = reg.leaf("mime", "src/mime.zig");
    const multipart_module = reg.leaf("multipart", "src/multipart.zig");

    // Core modules
    const middleware_module = reg.simple("middleware", "src/middleware.zig", &.{"url"});
    const plugin_utils_module = reg.simple("plugin_utils", "src/plugin_utils.zig", &.{"middleware"});
    const pagination_module = reg.simple("pagination", "src/pagination.zig", &.{"plugin_utils"});
    const router_module = reg.simple("router", "src/router.zig", &.{"middleware"});
    const db_module = reg.leaf("db", "src/core/db.zig");
    db_module.addIncludePath(b.path("vendor"));
    _ = reg.simple("publish_hooks", "src/publish_hooks.zig", &.{"db"});
    const modules_api_module = reg.simple("modules", "src/modules/mod.zig", &.{ "router", "db", "publr_config" });
    _ = reg.leaf("id_gen", "src/core/id_gen.zig");
    const schema_sync_module = reg.simple("schema_sync", "src/core/schema/sync.zig", &.{"db"});
    // schema_sync is also imported as "sync" by seed_module.
    reg.register("sync", schema_sync_module);
    const core_init_module = reg.simple("core_init", "src/core/init.zig", &.{ "db", "schema_sync", "seed", "schema_registry", "schemas" });

    // =========================================================================
    // Database Initialization Tool (comptime schema generation)
    // =========================================================================
    db_init_build.wire(b, .{
        .schema_registry = schema_registry_module,
        .field = field_module,
        .seed = seed_module,
        .exe = exe,
        .project_dir = project_dir,
        .config_path = config_path,
        .watch_mode = watch_mode,
    });

    const time_util_module = reg.leaf("time_util", "src/time_util.zig");
    const core_time_module = reg.leaf("core_time", "src/core/time.zig");
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
    const csrf_module = reg.simple("csrf", "src/csrf.zig", &.{ "middleware", "auth_middleware" });
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

    // Forward-referenced imports for each discovered plugin:
    //   - registry: created above; plugins call into it for layout helpers.
    //   - views: each plugin module is exposed to views/ so view components
    //     can import any plugin's exports (e.g. settings_tabs.zsx reads
    //     plugin_settings.tabs).
    for (plugins.plugins) |p| {
        p.module.addImport("registry", registry_module);
        views.addImport(b.fmt("plugin_{s}", .{p.name}), p.module);
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
        "views",      "admin_api",    "auth",            "auth_middleware", "cms",
        "csrf",       "db",           "image",           "media",           "media_handler",
        "middleware", "schema_media", "seed",            "storage",         "svg_sanitize",
        "tpl",        "actions",      "content_actions", "schema_registry", "schema_db_types",
        "schemas",
    });
    reg.attachAll(exe.root_module, &.{
        "views",             "admin_api",       "auth",             "auth_middleware", "cms",
        "csrf",              "db",              "image",            "media",           "media_handler",
        "middleware",        "schema_media",    "seed",             "storage",         "svg_sanitize",
        "tpl",               "theme",           "template_context", "publish_hooks",   "publr_ui",
        "modules",           "module_admin",    "cli_main",         "actions",         "content_actions",
        // src/rest/*.zig is relative-imported by src/http.zig — these are the
        // modules the REST tree reaches for that aren't already shared.
        "core_time",         "media_query",     "mime",             "multipart",       "taxonomy",
        "rest_test_helpers", "router",          "url",              "field",           "content_type",
        "schemas",           "schema_registry", "schema_sync",      "core_init",       "media_sync",
        "websocket",         "presence",        "schema_db_types",
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
    vendors.addAll(b, exe_tests, .{});

    reg.register("registry", registry_module);
    reg.attachAll(exe_tests.root_module, &.{
        "views",             "modules",      "module_admin",    "cli_main",
        "core_time",         "media_query",  "mime",            "taxonomy",
        "rest_test_helpers", "registry",     "admin_api",       "schema_media",
        "core_init",         "auth",         "storage",         "svg_sanitize",
        "media",             "media_sync",   "media_handler",   "image",
        "multipart",         "actions",      "cms",             "entry_storage",
        "field",             "content_type", "schema_registry", "field_types",
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
    vendors.addAll(b, storage_tests, .{});
    const run_storage_tests = b.addRunArtifact(storage_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_rest_tests.step);
    test_step.dependOn(&run_publr_template_tests.step);
    test_step.dependOn(&run_publr_preprocess_tests.step);
    test_step.dependOn(&run_publr_routes_tests.step);
    test_step.dependOn(&run_storage_tests.step);

    // Verify step: runs all tests + WASM build.
    const verify_step = b.step("verify", "Run tests and verify WASM build");
    verify_step.dependOn(test_step);

    // =========================================================================
    // Browser WASM Build (full CMS with embedded SQLite)
    // =========================================================================
    const wasm_result = wasm_build.build(b, .{
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
        .plugins = plugins.plugins,
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
        }),
    });
    const run_dev_server = b.addRunArtifact(dev_server_exe);
    run_dev_server.setCwd(b.path("."));
    if (b.args) |passthrough| run_dev_server.addArgs(passthrough);
    dev_browser_step.dependOn(&run_dev_server.step);
}
