const std = @import("std");
const vendors = @import("vendors.zig");
const plugins = @import("plugins.zig");

pub fn add_module(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const publr_sqlite = builder.dependency("publr_sqlite", .{
        .target = target,
        .release = optimize != .Debug,
    });
    const publr_http = builder.dependency("publr_http", .{
        .target = target,
        .release = optimize != .Debug,
    });
    const publr_auth = builder.dependency("publr_auth", .{
        .target = target,
        .release = optimize != .Debug,
    });
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/publr.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "publr_sqlite", .module = publr_sqlite.module("publr_sqlite") },
            .{ .name = "publr_http", .module = publr_http.module("publr_http") },
            .{ .name = "publr_auth", .module = publr_auth.module("publr_auth") },
        },
    });

    vendors.add_include_paths(builder, module);
    module.linkLibrary(vendors.add_library(builder, target));
    plugins.add(builder, module);

    std.debug.assert(module.link_libc == true);
    std.debug.assert(module.root_source_file != null);

    return module;
}

pub fn add_entry(
    builder: *std.Build,
    root: []const u8,
    library: *std.Build.Module,
) *std.Build.Module {
    std.debug.assert(root.len > 0);
    std.debug.assert(library.root_source_file != null);

    const module = builder.createModule(.{
        .root_source_file = builder.path(root),
        .target = library.resolved_target,
        .optimize = library.optimize,
        .link_libc = true,
    });

    module.addImport("publr", library);

    return module;
}
