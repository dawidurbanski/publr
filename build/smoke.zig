const std = @import("std");

pub fn add_check(builder: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    std.debug.assert(builder.build_root.path != null);

    const smoke = builder.addExecutable(.{
        .name = "smoke",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/smoke.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = builder.addRunArtifact(smoke);

    run.addArtifactArg(exe);
    run.addArg(builder.pathFromRoot(".zig-cache/smoke"));
    run.has_side_effects = true;

    std.debug.assert(run.argv.items.len == 3);

    return &run.step;
}
