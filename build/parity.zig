const std = @import("std");
const core = @import("core.zig");

pub fn add_check(
    builder: *std.Build,
    exe: *std.Build.Step.Compile,
    library: *std.Build.Module,
) *std.Build.Step {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    const parity = builder.addExecutable(.{
        .name = "parity",
        .root_module = core.add_entry(builder, "scripts/parity.zig", library),
    });

    const run = builder.addRunArtifact(parity);

    run.addArtifactArg(exe);
    run.addArg(builder.pathFromRoot(".zig-cache/parity"));
    run.has_side_effects = true;

    std.debug.assert(run.argv.items.len == 3);

    return &run.step;
}

pub fn add_tests(
    builder: *std.Build,
    library: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    const tests = builder.addTest(.{
        .root_module = core.add_entry(builder, "scripts/parity.zig", library),
    });

    test_step.dependOn(&builder.addRunArtifact(tests).step);
}
