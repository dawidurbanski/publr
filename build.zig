const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const watch_mode = b.option(bool, "watch", "Skip preBuild hooks and init_db (used by --watch rebuilds)") orelse false;
    const setup_bg_dark = b.option(bool, "setup-bg-dark", "Use dark background on setup page (comptime config demo)") orelse false;

    // External source tree options (for recompilation from ~/.publr/src/)
    const config_path = b.option([]const u8, "config-path", "Absolute path to publr.zon (external source tree builds)");
    const plugins_path = b.option([]const u8, "plugins-path", "Absolute path to plugins directory (external source tree builds)");
    const project_dir = b.option([]const u8, "project-dir", "Absolute path to project directory (external source tree builds — resolves themes, data)");
    _ = plugins_path; // Reserved for future plugin discovery

    // ZSX amalgamation — single vendor/zsx.zig for all build tools + runtime
    const zsx = b.createModule(.{
        .root_source_file = b.path("vendor/zsx.zig"),
    });

    // Thin entry points for build tools (generated at build time)
    const zsx_entries = b.addWriteFiles();
    const transpile_entry = zsx_entries.add("zsx_transpile_main.zig",
        \\const z = @import("zsx");
        \\pub fn main() !void { return z.transpile.main(); }
        \\
    );
    const format_entry = zsx_entries.add("zsx_format_main.zig",
        \\const z = @import("zsx");
        \\pub fn main() !void { return z.format.main(); }
        \\
    );

    // Build ZSX transpiler
    const zsx_transpiler = b.addExecutable(.{
        .name = "zsx_transpile",
        .root_module = b.createModule(.{
            .root_source_file = transpile_entry,
            .target = b.graph.host,
            .imports = &.{.{ .name = "zsx", .module = zsx }},
        }),
    });

    // Run ZSX transpiler for views (cacheable: declared inputs + output directory)
    const transpile_zsx_cmd = b.addRunArtifact(zsx_transpiler);
    transpile_zsx_cmd.addDirectoryArg(b.path("src/views"));
    const gen_views = transpile_zsx_cmd.addOutputDirectoryArg("views");

    // Register .zsx files for content-based cache checking
    {
        var views_dir = b.build_root.handle.openDir("src/views", .{ .iterate = true }) catch
            @panic("cannot open src/views");
        defer views_dir.close();
        var walker = views_dir.walk(b.allocator) catch @panic("cannot walk src/views");
        defer walker.deinit();
        while (walker.next() catch @panic("walk error")) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zsx")) {
                transpile_zsx_cmd.addFileInput(b.path(b.pathJoin(&.{ "src/views", entry.path })));
            }
        }
    }

    // Build ZSX formatter
    const zsx_formatter = b.addExecutable(.{
        .name = "zsx_format",
        .root_module = b.createModule(.{
            .root_source_file = format_entry,
            .target = b.graph.host,
            .imports = &.{.{ .name = "zsx", .module = zsx }},
        }),
    });

    // Format step (zig build fmt)
    const fmt_step = b.step("fmt", "Format ZSX files");
    const fmt_cmd = b.addRunArtifact(zsx_formatter);
    fmt_cmd.setCwd(b.path("."));
    fmt_cmd.addArgs(&.{"src/views"});
    fmt_step.dependOn(&fmt_cmd.step);

    const exe = b.addExecutable(.{
        .name = "publr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Main exe depends on transpile step (init_db dependency added later)
    exe.step.dependOn(&transpile_zsx_cmd.step);

    // Run preBuild hooks from publr.zon (theme tooling, asset pipelines, etc.)
    // Skipped in watch mode (watchers handle independently) and external builds
    // (recompile endpoint runs hooks separately before invoking zig build)
    if (!watch_mode and config_path == null) {
        const publr_config = @import("publr.zon");
        if (@hasField(@TypeOf(publr_config), "build")) {
            if (@hasField(@TypeOf(publr_config.build), "preBuild")) {
                inline for (publr_config.build.preBuild) |cmd| {
                    const hook = b.addSystemCommand(&cmd);
                    exe.step.dependOn(&hook.step);
                }
            }
        }
    }

    // Vendor static library — SQLite, stb_image, libwebp compiled once and cached.
    // Only recompiled when vendor sources change, not when Zig code changes.
    const vendor_lib = b.addLibrary(.{
        .name = "publr_vendors",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    vendor_lib.linkLibC();
    vendor_lib.addIncludePath(b.path("vendor"));
    vendor_lib.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=2",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    // stb_image_resize2 does intentional misaligned uint64 stores in stbir__pack_coefficients,
    // which triggers UBSan in debug builds. Disable alignment sanitizer for this file.
    vendor_lib.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{"-fno-sanitize=alignment"},
    });
    // libwebp split amalgamation: same file compiled 124 times with different PART values
    for (0..124) |part| {
        var buf: [32]u8 = undefined;
        const flag = std.fmt.bufPrint(&buf, "-DWEBP_AMALGAMATION_PART={d}", .{part}) catch unreachable;
        vendor_lib.addCSourceFile(.{ .file = b.path("vendor/libwebp.c"), .flags = &.{flag} });
    }

    // Link vendor lib + libc into exe
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

    // Embed static assets
    exe.root_module.addAnonymousImport("static_admin_css", .{
        .root_source_file = b.path("static/admin.css"),
    });
    exe.root_module.addAnonymousImport("static_admin_js", .{
        .root_source_file = b.path("static/admin.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_core_js", .{
        .root_source_file = b.path("static/interact/core.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_toggle_js", .{
        .root_source_file = b.path("static/interact/toggle.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_portal_js", .{
        .root_source_file = b.path("static/interact/portal.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_focus_trap_js", .{
        .root_source_file = b.path("static/interact/focus-trap.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_dismiss_js", .{
        .root_source_file = b.path("static/interact/dismiss.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_components_js", .{
        .root_source_file = b.path("static/interact/components.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_index_js", .{
        .root_source_file = b.path("static/interact/index.js"),
    });
    exe.root_module.addAnonymousImport("static_media_selection_js", .{
        .root_source_file = b.path("static/media-selection.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_websocket_js", .{
        .root_source_file = b.path("static/interact/websocket.js"),
    });
    exe.root_module.addAnonymousImport("static_interact_presence_js", .{
        .root_source_file = b.path("static/interact/presence.js"),
    });
    exe.root_module.addAnonymousImport("static_theme_css", .{
        .root_source_file = if (project_dir) |pd|
            .{ .cwd_relative = b.pathJoin(&.{ pd, "themes/demo/static/theme.css" }) }
        else
            b.path("themes/demo/static/theme.css"),
    });

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

    // =========================================================================
    // Schema Modules
    // =========================================================================
    const field_module = b.createModule(.{
        .root_source_file = b.path("src/schema/field.zig"),
    });
    const content_type_module = b.createModule(.{
        .root_source_file = b.path("src/schema/content_type.zig"),
        .imports = &.{.{ .name = "field", .module = field_module }},
    });

    // Core content type schemas
    const schema_post_module = b.createModule(.{
        .root_source_file = b.path("src/schemas/post.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "content_type", .module = content_type_module },
        },
    });
    const schema_page_module = b.createModule(.{
        .root_source_file = b.path("src/schemas/page.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "content_type", .module = content_type_module },
        },
    });
    const schema_author_module = b.createModule(.{
        .root_source_file = b.path("src/schemas/author.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "content_type", .module = content_type_module },
        },
    });

    const schema_media_module = b.createModule(.{
        .root_source_file = b.path("src/schemas/media.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "content_type", .module = content_type_module },
        },
    });

    // Aggregated core schemas module
    const schemas_module = b.createModule(.{
        .root_source_file = b.path("src/schemas/mod.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "content_type", .module = content_type_module },
            .{ .name = "schema_post", .module = schema_post_module },
            .{ .name = "schema_page", .module = schema_page_module },
            .{ .name = "schema_author", .module = schema_author_module },
            .{ .name = "schema_media", .module = schema_media_module },
        },
    });

    // Schema registry (merges all layers)
    const schema_registry_module = b.createModule(.{
        .root_source_file = b.path("src/schema/registry.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "content_type", .module = content_type_module },
            .{ .name = "schemas", .module = schemas_module },
        },
    });

    // Note: schema_sync_module needs db_module, which is defined below.
    // We'll add the import after db_module is created.

    // =========================================================================
    // Core Modules (shared between main exe and plugins)
    // =========================================================================
    const middleware_module = b.createModule(.{
        .root_source_file = b.path("src/middleware.zig"),
    });
    const router_module = b.createModule(.{
        .root_source_file = b.path("src/router.zig"),
        .imports = &.{.{ .name = "middleware", .module = middleware_module }},
    });
    const db_module = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
    });
    db_module.addIncludePath(b.path("vendor"));

    // Schema sync (needs db_module)
    const schema_sync_module = b.createModule(.{
        .root_source_file = b.path("src/schema/sync.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "schema_registry", .module = schema_registry_module },
            .{ .name = "db", .module = db_module },
        },
    });

    // =========================================================================
    // Database Initialization Tool (comptime schema generation)
    // =========================================================================
    const init_db = b.addExecutable(.{
        .name = "init_db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/init_db.zig"),
            .target = b.graph.host,
        }),
    });
    init_db.linkLibC();
    init_db.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=2",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    init_db.addIncludePath(b.path("vendor"));

    // Add schema modules to init_db
    init_db.root_module.addImport("schema_registry", schema_registry_module);
    init_db.root_module.addImport("field", field_module);

    // Run init_db as build step
    const init_db_cmd = b.addRunArtifact(init_db);
    init_db_cmd.addArg(if (project_dir) |pd|
        b.pathJoin(&.{ pd, "data/publr.db" })
    else
        "data/publr.db");

    // Main exe depends on database init
    // Skipped in watch mode (DB already initialized) and external builds
    // (DB exists in project directory, managed by the running CMS)
    if (!watch_mode and config_path == null) {
        exe.step.dependOn(&init_db_cmd.step);
    }

    // Time utility (avoids 128-bit math on WASI for non-LLVM backend)
    const time_util_module = b.createModule(.{
        .root_source_file = b.path("src/time_util.zig"),
    });

    // CMS query API
    const cms_module = b.createModule(.{
        .root_source_file = b.path("src/cms.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "schema_registry", .module = schema_registry_module },
            .{ .name = "db", .module = db_module },
            .{ .name = "time_util", .module = time_util_module },
        },
    });
    // Storage backend
    const storage_module = b.createModule(.{
        .root_source_file = b.path("src/storage.zig"),
        .imports = &.{
            .{ .name = "time_util", .module = time_util_module },
        },
    });
    // SVG sanitizer
    const svg_sanitize_module = b.createModule(.{
        .root_source_file = b.path("src/svg_sanitize.zig"),
    });
    // Media CRUD API
    const media_module = b.createModule(.{
        .root_source_file = b.path("src/media.zig"),
        .imports = &.{
            .{ .name = "db", .module = db_module },
            .{ .name = "cms", .module = cms_module },
            .{ .name = "schema_media", .module = schema_media_module },
            .{ .name = "storage", .module = storage_module },
            .{ .name = "svg_sanitize", .module = svg_sanitize_module },
        },
    });
    // Media filesystem sync
    const media_sync_module = b.createModule(.{
        .root_source_file = b.path("src/media_sync.zig"),
        .imports = &.{
            .{ .name = "db", .module = db_module },
            .{ .name = "media", .module = media_module },
            .{ .name = "storage", .module = storage_module },
            .{ .name = "svg_sanitize", .module = svg_sanitize_module },
        },
    });
    media_sync_module.addIncludePath(b.path("vendor"));

    const tpl_module = b.createModule(.{
        .root_source_file = b.path("src/tpl.zig"),
    });
    const auth_module = b.createModule(.{
        .root_source_file = b.path("src/auth.zig"),
        .imports = &.{
            .{ .name = "db", .module = db_module },
            .{ .name = "time_util", .module = time_util_module },
        },
    });
    const auth_middleware_module = b.createModule(.{
        .root_source_file = b.path("src/auth_middleware.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "auth", .module = auth_module },
            .{ .name = "db", .module = db_module },
        },
    });
    const csrf_module = b.createModule(.{
        .root_source_file = b.path("src/csrf.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
        },
    });
    const admin_api_module = b.createModule(.{
        .root_source_file = b.path("src/admin_api.zig"),
        .imports = &.{.{ .name = "middleware", .module = middleware_module }},
    });
    // Image processing (stb + libwebp wrappers)
    const image_module = b.createModule(.{
        .root_source_file = b.path("src/image.zig"),
    });
    image_module.addIncludePath(b.path("vendor"));
    // Media serve handler
    const media_handler_module = b.createModule(.{
        .root_source_file = b.path("src/media_handler.zig"),
        .imports = &.{
            .{ .name = "storage", .module = storage_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "image", .module = image_module },
        },
    });
    const icons_module = b.createModule(.{
        .root_source_file = b.path("src/icons.zig"),
    });
    const gravatar_module = b.createModule(.{
        .root_source_file = b.path("src/gravatar.zig"),
    });
    const websocket_module = b.createModule(.{
        .root_source_file = b.path("src/websocket.zig"),
    });
    const presence_module = b.createModule(.{
        .root_source_file = b.path("src/presence.zig"),
        .imports = &.{
            .{ .name = "websocket", .module = websocket_module },
            .{ .name = "gravatar", .module = gravatar_module },
        },
    });

    // Add icons to views module (layout.zsx needs icons for search/logout icons)
    views.addImport("icons", icons_module);

    // =========================================================================
    // Plugin Modules
    // =========================================================================
    const plugin_dashboard = b.createModule(.{
        .root_source_file = b.path("src/plugins/dashboard.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "db", .module = db_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "media", .module = media_module },
            .{ .name = "views", .module = views },
        },
    });
    const plugin_posts = b.createModule(.{
        .root_source_file = b.path("src/plugins/posts.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "db", .module = db_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "cms", .module = cms_module },
            .{ .name = "schemas", .module = schemas_module },
            .{ .name = "schema_sync", .module = schema_sync_module },
            .{ .name = "gravatar", .module = gravatar_module },
            .{ .name = "views", .module = views },
            .{ .name = "time_util", .module = time_util_module },
        },
    });
    const plugin_users = b.createModule(.{
        .root_source_file = b.path("src/plugins/users.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "auth", .module = auth_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "views", .module = views },
        },
    });
    const plugin_settings = b.createModule(.{
        .root_source_file = b.path("src/plugins/settings.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth", .module = auth_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "views", .module = views },
        },
    });
    const plugin_components = b.createModule(.{
        .root_source_file = b.path("src/plugins/components.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "views", .module = views },
        },
    });
    const plugin_design_system = b.createModule(.{
        .root_source_file = b.path("src/plugins/design_system.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "views", .module = views },
        },
    });
    const plugin_content_types = b.createModule(.{
        .root_source_file = b.path("src/plugins/content_types.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "views", .module = views },
        },
    });
    const plugin_media = b.createModule(.{
        .root_source_file = b.path("src/plugins/media.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "media", .module = media_module },
            .{ .name = "media_sync", .module = media_sync_module },
            .{ .name = "storage", .module = storage_module },
            .{ .name = "schema_media", .module = schema_media_module },
            .{ .name = "media_handler", .module = media_handler_module },
            .{ .name = "db", .module = db_module },
            .{ .name = "views", .module = views },
        },
    });

    const plugin_releases = b.createModule(.{
        .root_source_file = b.path("src/plugins/releases.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "cms", .module = cms_module },
            .{ .name = "views", .module = views },
        },
    });

    // =========================================================================
    // Registry Module (imports all plugins)
    // =========================================================================
    const registry_module = b.createModule(.{
        .root_source_file = b.path("src/registry.zig"),
        .imports = &.{
            .{ .name = "admin_api", .module = admin_api_module },
            .{ .name = "icons", .module = icons_module },
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "tpl", .module = tpl_module },
            .{ .name = "csrf", .module = csrf_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "gravatar", .module = gravatar_module },
            .{ .name = "views", .module = views },
            .{ .name = "plugin_dashboard", .module = plugin_dashboard },
            .{ .name = "plugin_posts", .module = plugin_posts },
            .{ .name = "plugin_media", .module = plugin_media },
            .{ .name = "plugin_users", .module = plugin_users },
            .{ .name = "plugin_settings", .module = plugin_settings },
            .{ .name = "plugin_components", .module = plugin_components },
            .{ .name = "plugin_design_system", .module = plugin_design_system },
            .{ .name = "plugin_content_types", .module = plugin_content_types },
            .{ .name = "plugin_releases", .module = plugin_releases },
        },
    });

    // Add registry to plugins (must be done after registry_module is created)
    plugin_dashboard.addImport("registry", registry_module);
    plugin_posts.addImport("registry", registry_module);
    plugin_media.addImport("registry", registry_module);
    plugin_users.addImport("registry", registry_module);
    plugin_settings.addImport("registry", registry_module);
    plugin_settings.addImport("publr_config", publr_config_module);
    plugin_components.addImport("registry", registry_module);
    plugin_design_system.addImport("registry", registry_module);
    plugin_content_types.addImport("registry", registry_module);
    plugin_releases.addImport("registry", registry_module);

    // Add views namespace and core imports to main executable
    exe.root_module.addImport("views", views);
    exe.root_module.addImport("admin_api", admin_api_module);
    exe.root_module.addImport("icons", icons_module);
    exe.root_module.addImport("publr_ui", publr_ui);

    // Add core modules to main exe
    exe.root_module.addImport("middleware", middleware_module);
    exe.root_module.addImport("router", router_module);
    exe.root_module.addImport("tpl", tpl_module);
    exe.root_module.addImport("db", db_module);
    exe.root_module.addImport("csrf", csrf_module);
    exe.root_module.addImport("auth", auth_module);
    exe.root_module.addImport("auth_middleware", auth_middleware_module);

    // Add schema modules to main exe
    exe.root_module.addImport("field", field_module);
    exe.root_module.addImport("content_type", content_type_module);
    exe.root_module.addImport("schemas", schemas_module);
    exe.root_module.addImport("schema_registry", schema_registry_module);
    exe.root_module.addImport("schema_sync", schema_sync_module);
    exe.root_module.addImport("schema_media", schema_media_module);
    exe.root_module.addImport("cms", cms_module);
    exe.root_module.addImport("storage", storage_module);
    exe.root_module.addImport("svg_sanitize", svg_sanitize_module);
    exe.root_module.addImport("media", media_module);
    exe.root_module.addImport("media_sync", media_sync_module);
    exe.root_module.addImport("media_handler", media_handler_module);
    exe.root_module.addImport("image", image_module);
    exe.root_module.addImport("websocket", websocket_module);
    exe.root_module.addImport("presence", presence_module);

    // Add plugin modules to main exe
    exe.root_module.addImport("plugin_dashboard", plugin_dashboard);
    exe.root_module.addImport("plugin_posts", plugin_posts);
    exe.root_module.addImport("plugin_media", plugin_media);
    exe.root_module.addImport("plugin_users", plugin_users);
    exe.root_module.addImport("plugin_settings", plugin_settings);
    exe.root_module.addImport("plugin_components", plugin_components);
    exe.root_module.addImport("plugin_design_system", plugin_design_system);
    exe.root_module.addImport("plugin_content_types", plugin_content_types);
    exe.root_module.addImport("plugin_releases", plugin_releases);

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

    exe_tests.linkLibC();
    exe_tests.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=2",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    exe_tests.addIncludePath(b.path("vendor"));

    // Add STB image processing
    exe_tests.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{"-fno-sanitize=alignment"},
    });

    // Add libwebp (same split amalgamation as main exe)
    for (0..124) |part| {
        var buf: [32]u8 = undefined;
        const flag = std.fmt.bufPrint(&buf, "-DWEBP_AMALGAMATION_PART={d}", .{part}) catch unreachable;
        exe_tests.addCSourceFile(.{ .file = b.path("vendor/libwebp.c"), .flags = &.{flag} });
    }

    // Add imports to test executable
    exe_tests.root_module.addImport("views", views);
    exe_tests.root_module.addImport("registry", registry_module);
    exe_tests.root_module.addImport("admin_api", admin_api_module);
    exe_tests.root_module.addImport("icons", icons_module);
    exe_tests.root_module.addImport("schema_media", schema_media_module);
    exe_tests.root_module.addImport("storage", storage_module);
    exe_tests.root_module.addImport("svg_sanitize", svg_sanitize_module);
    exe_tests.root_module.addImport("media", media_module);
    exe_tests.root_module.addImport("media_sync", media_sync_module);
    exe_tests.root_module.addImport("media_handler", media_handler_module);
    exe_tests.root_module.addImport("image", image_module);

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Verify step: runs tests + WASM build (use before completing tasks)
    const verify_step = b.step("verify", "Run tests and verify WASM build");
    verify_step.dependOn(&run_exe_tests.step);

    // =========================================================================
    // Browser WASM Build (full CMS with embedded SQLite)
    // =========================================================================
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

    // WASM-specific settings
    browser_wasm.rdynamic = true;

    // Vendor static library for WASM (separate from native — different SQLite flags)
    const vendor_lib_wasm = b.addLibrary(.{
        .name = "publr_vendors",
        .root_module = b.createModule(.{
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    vendor_lib_wasm.linkLibC();
    vendor_lib_wasm.addIncludePath(b.path("vendor"));
    vendor_lib_wasm.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=0", // Single-threaded for WASM
            "-DSQLITE_TEMP_STORE=2",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
        },
    });
    vendor_lib_wasm.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{"-fno-sanitize=alignment"},
    });
    for (0..124) |part| {
        var buf: [32]u8 = undefined;
        const flag = std.fmt.bufPrint(&buf, "-DWEBP_AMALGAMATION_PART={d}", .{part}) catch unreachable;
        vendor_lib_wasm.addCSourceFile(.{ .file = b.path("vendor/libwebp.c"), .flags = &.{flag} });
    }

    // Link vendor lib + libc into WASM build
    browser_wasm.linkLibC();
    browser_wasm.addIncludePath(b.path("vendor")); // for @cImport headers
    browser_wasm.linkLibrary(vendor_lib_wasm);

    // Add views namespace (same as native)
    browser_wasm.root_module.addImport("views", views);

    // WASM storage module (SQLite blob backend)
    const wasm_storage_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_storage.zig"),
        .imports = &.{
            .{ .name = "db", .module = db_module },
            .{ .name = "storage", .module = storage_module },
        },
    });

    // WASM media handler module (serves media from SQLite blobs)
    const wasm_media_handler_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_media_handler.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "wasm_storage", .module = wasm_storage_module },
            .{ .name = "auth_middleware", .module = auth_middleware_module },
            .{ .name = "media_handler", .module = media_handler_module },
            .{ .name = "image", .module = image_module },
            .{ .name = "storage", .module = storage_module },
        },
    });

    // WASM router module
    const wasm_router_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_router.zig"),
        .imports = &.{
            .{ .name = "middleware", .module = middleware_module },
            .{ .name = "admin_api", .module = admin_api_module },
        },
    });

    // Add core modules to WASM build
    browser_wasm.root_module.addImport("db", db_module);
    browser_wasm.root_module.addImport("tpl", tpl_module);
    browser_wasm.root_module.addImport("auth", auth_module);
    browser_wasm.root_module.addImport("middleware", middleware_module);
    browser_wasm.root_module.addImport("admin_api", admin_api_module);
    browser_wasm.root_module.addImport("registry", registry_module);
    browser_wasm.root_module.addImport("wasm_router", wasm_router_module);
    browser_wasm.root_module.addImport("auth_middleware", auth_middleware_module);
    browser_wasm.root_module.addImport("csrf", csrf_module);
    browser_wasm.root_module.addImport("icons", icons_module);

    // Media/storage modules for WASM
    browser_wasm.root_module.addImport("storage", storage_module);
    browser_wasm.root_module.addImport("svg_sanitize", svg_sanitize_module);
    browser_wasm.root_module.addImport("cms", cms_module);
    browser_wasm.root_module.addImport("media", media_module);
    browser_wasm.root_module.addImport("image", image_module);
    browser_wasm.root_module.addImport("schema_media", schema_media_module);
    browser_wasm.root_module.addImport("media_handler", media_handler_module);
    browser_wasm.root_module.addImport("wasm_storage", wasm_storage_module);
    browser_wasm.root_module.addImport("wasm_media_handler", wasm_media_handler_module);
    browser_wasm.root_module.addImport("schema_sync", schema_sync_module);

    // Comptime config module (generated from build options)
    const wasm_config_files = b.addWriteFiles();
    const wasm_config_source = wasm_config_files.add("config.zig", std.fmt.allocPrint(
        b.allocator,
        "pub const setup_bg_dark: bool = {};",
        .{setup_bg_dark},
    ) catch unreachable);
    const wasm_config_module = b.createModule(.{ .root_source_file = wasm_config_source });
    browser_wasm.root_module.addImport("config", wasm_config_module);

    // Add wasm_storage to modules that conditionally import it
    media_module.addImport("wasm_storage", wasm_storage_module);
    plugin_media.addImport("wasm_storage", wasm_storage_module);

    // Browser build depends on transpile step
    browser_wasm.step.dependOn(&transpile_zsx_cmd.step);

    // Install to browser/ directory
    const browser_install = b.addInstallArtifact(browser_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "browser" } },
    });
    browser_step.dependOn(&browser_install.step);

    // Wire verify step to also check WASM build
    verify_step.dependOn(&browser_install.step);

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
}
