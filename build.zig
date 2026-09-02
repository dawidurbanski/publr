const std = @import("std");
const browser = @import("build/browser.zig");
const core = @import("build/core.zig");
const vendors = @import("build/vendors.zig");
const smoke = @import("build/smoke.zig");
const scripts = @import("build/scripts.zig");
const parity = @import("build/parity.zig");
const plugins = @import("build/plugins.zig");
const hook = @import("build/hook.zig");
const tidy = @import("build/tidy.zig");
const wasm = @import("build/wasm.zig");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(builder.args == null or builder.args.?.len > 0);

    const library = core.add_module(builder, target, optimize);
    const exe = builder.addExecutable(.{
        .name = "publr",
        .root_module = core.add_entry(builder, "src/main.zig", library),
    });
    const run_cmd = builder.addRunArtifact(exe);
    const tests = builder.addTest(.{ .root_module = library });
    const fmt_check = builder.addFmt(.{
        .paths = &.{ "build.zig", "build", "src", "scripts" },
        .check = true,
    });

    builder.installArtifact(exe);

    run_cmd.step.dependOn(builder.getInstallStep());

    if (builder.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = builder.step("test", "Run all tests");
    const verify_step = builder.step("verify", "Run every gate check");
    const test_exe_step = builder.step("test-exe", "Build the test binary for a debugger");

    test_exe_step.dependOn(&builder.addInstallArtifact(tests, .{
        .dest_sub_path = "publr-tests",
    }).step);

    test_step.dependOn(&builder.addRunArtifact(tests).step);
    scripts.add_tests(builder, test_step);
    plugins.add_tests(builder, library, test_step);
    parity.add_tests(builder, library, test_step);

    verify_step.dependOn(test_step);
    verify_step.dependOn(wasm.add_check(builder));
    verify_step.dependOn(&fmt_check.step);
    verify_step.dependOn(tidy.add_check(builder));
    verify_step.dependOn(smoke.add_check(builder, exe));

    const parity_step = parity.add_check(builder, exe, library);

    verify_step.dependOn(parity_step);

    builder.step("run", "Run publr").dependOn(&run_cmd.step);
    builder.step("parity", "Run every printed example").dependOn(parity_step);

    const browser_step = browser.add_step(builder);

    verify_step.dependOn(browser_step);

    if (hook.add_check(builder, exe, browser_step)) |local_hook| {
        verify_step.dependOn(local_hook);
    }

    vendors.add_import_step(builder);
    vendors.add_cache_check_step(builder);
}
