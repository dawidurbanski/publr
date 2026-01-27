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

    const exe = b.addExecutable(.{
        .name = "mz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Main exe depends on transpile step
    exe.step.dependOn(&transpile_zsx_cmd.step);

    // Run preBuild hooks from mz.zon (theme tooling, asset pipelines, etc.)
    const mz_config = @import("mz.zon");
    if (@hasField(@TypeOf(mz_config), "build")) {
        if (@hasField(@TypeOf(mz_config.build), "preBuild")) {
            inline for (mz_config.build.preBuild) |cmd| {
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

    // Import project config (mz.zon)
    exe.root_module.addAnonymousImport("mz_config", .{
        .root_source_file = b.path("mz.zon"),
    });

    // Embed static assets
    exe.root_module.addAnonymousImport("static_admin_css", .{
        .root_source_file = b.path("static/admin.css"),
    });
    exe.root_module.addAnonymousImport("static_admin_js", .{
        .root_source_file = b.path("static/admin.js"),
    });
    exe.root_module.addAnonymousImport("static_theme_css", .{
        .root_source_file = b.path("themes/demo/static/theme.css"),
    });

    // Import ZSX runtime
    const zsx_runtime = b.createModule(.{
        .root_source_file = b.path("src/zsx_runtime.zig"),
    });

    // Import generated ZSX views
    exe.root_module.addImport("zsx_base", b.createModule(.{
        .root_source_file = b.path("src/gen/views/base.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_index", b.createModule(.{
        .root_source_file = b.path("src/gen/views/index.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_admin_layout", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/layout.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_admin_dashboard", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/dashboard.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_admin_posts_list", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/posts/list.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_admin_posts_edit", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/posts/edit.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_error_404", b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_404.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_error_500", b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_500.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe.root_module.addImport("zsx_error_500_dev", b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_500_dev.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));

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

    // Add generated ZSX view imports to tests
    exe_tests.root_module.addImport("zsx_base", b.createModule(.{
        .root_source_file = b.path("src/gen/views/base.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_index", b.createModule(.{
        .root_source_file = b.path("src/gen/views/index.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_admin_layout", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/layout.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_admin_dashboard", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/dashboard.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_admin_posts_list", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/posts/list.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_admin_posts_edit", b.createModule(.{
        .root_source_file = b.path("src/gen/views/admin/posts/edit.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_error_404", b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_404.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_error_500", b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_500.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));
    exe_tests.root_module.addImport("zsx_error_500_dev", b.createModule(.{
        .root_source_file = b.path("src/gen/views/error/error_500_dev.zig"),
        .imports = &.{.{ .name = "zsx_runtime", .module = zsx_runtime }},
    }));

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
