const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build ZSX transpiler
    const zsx_transpiler = b.addExecutable(.{
        .name = "zsx_transpile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zsx_transpile.zig"),
            .target = b.graph.host,
        }),
    });

    // Run ZSX transpiler for views
    const transpile_zsx_cmd = b.addRunArtifact(zsx_transpiler);
    transpile_zsx_cmd.setCwd(b.path("."));
    transpile_zsx_cmd.addArgs(&.{ "src/views", "src/gen/views" });

    // Build ZSX formatter
    const zsx_formatter = b.addExecutable(.{
        .name = "zsx_format",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zsx_format.zig"),
            .target = b.graph.host,
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
    const publr_config = @import("publr.zon");
    if (@hasField(@TypeOf(publr_config), "build")) {
        if (@hasField(@TypeOf(publr_config.build), "preBuild")) {
            inline for (publr_config.build.preBuild) |cmd| {
                const hook = b.addSystemCommand(&cmd);
                exe.step.dependOn(&hook.step);
            }
        }
    }

    // Link libc for SQLite
    exe.linkLibC();

    // Add SQLite C source
    exe.addCSourceFile(.{
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
    exe.addIncludePath(b.path("vendor"));

    // Add STB image processing (decode, resize, encode)
    exe.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{},
    });

    // Add libwebp (two-file amalgamation: libwebp.c + libwebp.h)
    // Split amalgamation: same file compiled 124 times with different PART values
    for (0..124) |part| {
        var buf: [32]u8 = undefined;
        const flag = std.fmt.bufPrint(&buf, "-DWEBP_AMALGAMATION_PART={d}", .{part}) catch unreachable;
        exe.addCSourceFile(.{ .file = b.path("vendor/libwebp.c"), .flags = &.{flag} });
    }

    // Import project config (publr.zon)
    exe.root_module.addAnonymousImport("publr_config", .{
        .root_source_file = b.path("publr.zon"),
    });

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
    exe.root_module.addAnonymousImport("static_theme_css", .{
        .root_source_file = b.path("themes/demo/static/theme.css"),
    });

    // Import ZSX runtime
    const zsx_runtime = b.createModule(.{
        .root_source_file = b.path("src/tools/zsx_runtime.zig"),
    });

    // Import generated ZSX component views (shared modules)
    const zsx_components_toggle = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/toggle.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_dialog = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/dialog.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_dropdown = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/dropdown.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_select_menu = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/select_menu.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_popover = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/popover.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_tooltip = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/tooltip.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_tabs = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/tabs.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_switch_input = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/switch_input.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_checkbox_group = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/checkbox_group.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_components_radio_group = b.createModule(.{
        .root_source_file = b.path("src/gen/views/components/radio_group.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });

    // Create ZSX view modules
    const zsx_base = b.createModule(.{
        .root_source_file = b.path("src/gen/views/base.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_index = b.createModule(.{
        .root_source_file = b.path("src/gen/views/index.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_layout = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/layout.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_dashboard = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/dashboard.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_posts_list = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/posts/list.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_posts_edit = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/posts/edit.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_users_list = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/users/list.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_users_new = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/users/new.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_users_edit = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/users/edit.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_users_profile = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/users/profile.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_components = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/components.zig"),
        .imports = &.{
            .{ .name = "zsx_runtime", .module = zsx_runtime },
            .{ .name = "zsx_components_toggle", .module = zsx_components_toggle },
            .{ .name = "zsx_components_dialog", .module = zsx_components_dialog },
            .{ .name = "zsx_components_dropdown", .module = zsx_components_dropdown },
            .{ .name = "zsx_components_select_menu", .module = zsx_components_select_menu },
            .{ .name = "zsx_components_popover", .module = zsx_components_popover },
            .{ .name = "zsx_components_tooltip", .module = zsx_components_tooltip },
            .{ .name = "zsx_components_tabs", .module = zsx_components_tabs },
            .{ .name = "zsx_components_switch_input", .module = zsx_components_switch_input },
            .{ .name = "zsx_components_checkbox_group", .module = zsx_components_checkbox_group },
            .{ .name = "zsx_components_radio_group", .module = zsx_components_radio_group },
        },
    });
    const zsx_admin_setup = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/setup.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_login = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/login.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_admin_design_system = b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/design_system.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_error_404 = b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_404.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_error_500 = b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_500.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    });
    const zsx_error_500_dev = b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_500_dev.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
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
    init_db_cmd.addArg("data/publr.db");

    // Main exe depends on database init
    exe.step.dependOn(&init_db_cmd.step);

    // CMS query API
    const cms_module = b.createModule(.{
        .root_source_file = b.path("src/cms.zig"),
        .imports = &.{
            .{ .name = "field", .module = field_module },
            .{ .name = "schema_registry", .module = schema_registry_module },
            .{ .name = "db", .module = db_module },
        },
    });
    // Storage backend
    const storage_module = b.createModule(.{
        .root_source_file = b.path("src/storage.zig"),
    });
    // Media CRUD API
    const media_module = b.createModule(.{
        .root_source_file = b.path("src/media.zig"),
        .imports = &.{
            .{ .name = "db", .module = db_module },
            .{ .name = "cms", .module = cms_module },
            .{ .name = "schema_media", .module = schema_media_module },
            .{ .name = "storage", .module = storage_module },
        },
    });

    const tpl_module = b.createModule(.{
        .root_source_file = b.path("src/tpl.zig"),
    });
    const auth_module = b.createModule(.{
        .root_source_file = b.path("src/auth.zig"),
        .imports = &.{.{ .name = "db", .module = db_module }},
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

    // Add icons to layout module (needs icons for search/logout icons)
    zsx_admin_layout.addImport("icons", icons_module);

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
            .{ .name = "zsx_admin_dashboard", .module = zsx_admin_dashboard },
            .{ .name = "zsx_admin_layout", .module = zsx_admin_layout },
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
            .{ .name = "zsx_admin_posts_list", .module = zsx_admin_posts_list },
            .{ .name = "zsx_admin_posts_edit", .module = zsx_admin_posts_edit },
            .{ .name = "zsx_admin_layout", .module = zsx_admin_layout },
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
            .{ .name = "zsx_admin_users_list", .module = zsx_admin_users_list },
            .{ .name = "zsx_admin_users_new", .module = zsx_admin_users_new },
            .{ .name = "zsx_admin_users_edit", .module = zsx_admin_users_edit },
            .{ .name = "zsx_admin_users_profile", .module = zsx_admin_users_profile },
            .{ .name = "zsx_admin_layout", .module = zsx_admin_layout },
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
            .{ .name = "zsx_admin_layout", .module = zsx_admin_layout },
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
            .{ .name = "zsx_admin_components", .module = zsx_admin_components },
            .{ .name = "zsx_admin_layout", .module = zsx_admin_layout },
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
            .{ .name = "zsx_admin_design_system", .module = zsx_admin_design_system },
            .{ .name = "zsx_admin_layout", .module = zsx_admin_layout },
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
            .{ .name = "zsx_admin_layout", .module = zsx_admin_layout },
            .{ .name = "plugin_dashboard", .module = plugin_dashboard },
            .{ .name = "plugin_posts", .module = plugin_posts },
            .{ .name = "plugin_users", .module = plugin_users },
            .{ .name = "plugin_settings", .module = plugin_settings },
            .{ .name = "plugin_components", .module = plugin_components },
            .{ .name = "plugin_design_system", .module = plugin_design_system },
        },
    });

    // Add registry to plugins (must be done after registry_module is created)
    plugin_dashboard.addImport("registry", registry_module);
    plugin_posts.addImport("registry", registry_module);
    plugin_users.addImport("registry", registry_module);
    plugin_settings.addImport("registry", registry_module);
    plugin_components.addImport("registry", registry_module);
    plugin_design_system.addImport("registry", registry_module);

    // Add imports to main executable
    exe.root_module.addImport("zsx_base", zsx_base);
    exe.root_module.addImport("zsx_index", zsx_index);
    exe.root_module.addImport("zsx_admin_layout", zsx_admin_layout);
    exe.root_module.addImport("zsx_admin_dashboard", zsx_admin_dashboard);
    exe.root_module.addImport("zsx_admin_posts_list", zsx_admin_posts_list);
    exe.root_module.addImport("zsx_admin_posts_edit", zsx_admin_posts_edit);
    exe.root_module.addImport("zsx_admin_users_list", zsx_admin_users_list);
    exe.root_module.addImport("zsx_admin_users_new", zsx_admin_users_new);
    exe.root_module.addImport("zsx_admin_users_edit", zsx_admin_users_edit);
    exe.root_module.addImport("zsx_admin_users_profile", zsx_admin_users_profile);
    exe.root_module.addImport("zsx_admin_components", zsx_admin_components);
    exe.root_module.addImport("zsx_admin_setup", zsx_admin_setup);
    exe.root_module.addImport("zsx_admin_login", zsx_admin_login);
    exe.root_module.addImport("zsx_admin_design_system", zsx_admin_design_system);
    exe.root_module.addImport("zsx_error_404", zsx_error_404);
    exe.root_module.addImport("zsx_error_500", zsx_error_500);
    exe.root_module.addImport("zsx_error_500_dev", zsx_error_500_dev);
    exe.root_module.addImport("admin_api", admin_api_module);
    exe.root_module.addImport("icons", icons_module);

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
    exe.root_module.addImport("media", media_module);
    exe.root_module.addImport("media_handler", media_handler_module);
    exe.root_module.addImport("image", image_module);

    // Add plugin modules to main exe
    exe.root_module.addImport("plugin_dashboard", plugin_dashboard);
    exe.root_module.addImport("plugin_posts", plugin_posts);
    exe.root_module.addImport("plugin_users", plugin_users);
    exe.root_module.addImport("plugin_settings", plugin_settings);
    exe.root_module.addImport("plugin_components", plugin_components);
    exe.root_module.addImport("plugin_design_system", plugin_design_system);

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
        .flags = &.{},
    });

    // Add libwebp (same split amalgamation as main exe)
    for (0..124) |part| {
        var buf: [32]u8 = undefined;
        const flag = std.fmt.bufPrint(&buf, "-DWEBP_AMALGAMATION_PART={d}", .{part}) catch unreachable;
        exe_tests.addCSourceFile(.{ .file = b.path("vendor/libwebp.c"), .flags = &.{flag} });
    }

    // Add imports to test executable
    exe_tests.root_module.addImport("zsx_base", zsx_base);
    exe_tests.root_module.addImport("zsx_index", zsx_index);
    exe_tests.root_module.addImport("zsx_admin_layout", zsx_admin_layout);
    exe_tests.root_module.addImport("zsx_admin_dashboard", zsx_admin_dashboard);
    exe_tests.root_module.addImport("zsx_admin_posts_list", zsx_admin_posts_list);
    exe_tests.root_module.addImport("zsx_admin_posts_edit", zsx_admin_posts_edit);
    exe_tests.root_module.addImport("zsx_admin_users_list", zsx_admin_users_list);
    exe_tests.root_module.addImport("zsx_admin_users_new", zsx_admin_users_new);
    exe_tests.root_module.addImport("zsx_admin_users_edit", zsx_admin_users_edit);
    exe_tests.root_module.addImport("zsx_admin_users_profile", zsx_admin_users_profile);
    exe_tests.root_module.addImport("zsx_admin_components", zsx_admin_components);
    exe_tests.root_module.addImport("zsx_admin_setup", zsx_admin_setup);
    exe_tests.root_module.addImport("zsx_admin_login", zsx_admin_login);
    exe_tests.root_module.addImport("zsx_admin_design_system", zsx_admin_design_system);
    exe_tests.root_module.addImport("zsx_error_404", zsx_error_404);
    exe_tests.root_module.addImport("zsx_error_500", zsx_error_500);
    exe_tests.root_module.addImport("zsx_error_500_dev", zsx_error_500_dev);
    exe_tests.root_module.addImport("registry", registry_module);
    exe_tests.root_module.addImport("admin_api", admin_api_module);
    exe_tests.root_module.addImport("icons", icons_module);
    exe_tests.root_module.addImport("schema_media", schema_media_module);
    exe_tests.root_module.addImport("storage", storage_module);
    exe_tests.root_module.addImport("media", media_module);
    exe_tests.root_module.addImport("media_handler", media_handler_module);
    exe_tests.root_module.addImport("image", image_module);

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

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

    // Link libc for SQLite
    browser_wasm.linkLibC();

    // Add SQLite C source (same as native build)
    browser_wasm.addCSourceFile(.{
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
    browser_wasm.addIncludePath(b.path("vendor"));

    // Add ZSX runtime and views (same as native)
    browser_wasm.root_module.addImport("zsx_base", zsx_base);
    browser_wasm.root_module.addImport("zsx_admin_layout", zsx_admin_layout);
    browser_wasm.root_module.addImport("zsx_admin_dashboard", zsx_admin_dashboard);
    browser_wasm.root_module.addImport("zsx_admin_setup", zsx_admin_setup);
    browser_wasm.root_module.addImport("zsx_admin_login", zsx_admin_login);
    browser_wasm.root_module.addImport("zsx_admin_users_list", zsx_admin_users_list);
    browser_wasm.root_module.addImport("zsx_admin_users_new", zsx_admin_users_new);
    browser_wasm.root_module.addImport("zsx_admin_users_edit", zsx_admin_users_edit);
    browser_wasm.root_module.addImport("zsx_admin_posts_list", zsx_admin_posts_list);
    browser_wasm.root_module.addImport("zsx_admin_posts_edit", zsx_admin_posts_edit);
    browser_wasm.root_module.addImport("zsx_admin_users_profile", zsx_admin_users_profile);
    browser_wasm.root_module.addImport("zsx_admin_design_system", zsx_admin_design_system);
    browser_wasm.root_module.addImport("zsx_admin_components", zsx_admin_components);
    browser_wasm.root_module.addImport("zsx_error_404", zsx_error_404);

    // Embed static assets
    browser_wasm.root_module.addAnonymousImport("static_admin_css", .{
        .root_source_file = b.path("static/admin.css"),
    });
    browser_wasm.root_module.addAnonymousImport("static_admin_js", .{
        .root_source_file = b.path("static/admin.js"),
    });

    // Browser build depends on transpile step
    browser_wasm.step.dependOn(&transpile_zsx_cmd.step);

    // Install to browser/ directory
    const browser_install = b.addInstallArtifact(browser_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "browser" } },
    });
    browser_step.dependOn(&browser_install.step);
}
