//! Build-time DB initializer: compiles `src/tools/init_db.zig` against the
//! schema modules and runs it before the main exe is built. Skipped in
//! watch-mode rebuilds and external source-tree builds (where the DB lives
//! in the user's project directory and is managed by the running CMS).

const std = @import("std");
const vendors = @import("vendors.zig");

pub const Deps = struct {
    schema_registry: *std.Build.Module,
    field: *std.Build.Module,
    seed: *std.Build.Module,
    /// Resolved active schema (strict or loose) wired as an anonymous
    /// `schema_sql` import on the init_db tool. Plugin-manifest-driven.
    schema_sql_path: std.Build.LazyPath,
    /// Main exe Compile step; its build step gets a dependency on init_db
    /// when applicable.
    exe: *std.Build.Step.Compile,
    /// External project directory (absolute path) — when set, the DB lives
    /// at <project_dir>/data/publr.db instead of ./data/publr.db.
    project_dir: ?[]const u8,
    /// `--config-path` external builds skip the init dependency (DB already
    /// exists in the project directory).
    config_path: ?[]const u8,
    /// `-Dwatch=true` rebuilds skip the init dependency (DB already there).
    watch_mode: bool,
};

pub fn wire(b: *std.Build, deps: Deps) void {
    const init_db = b.addExecutable(.{
        .name = "init_db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/init_db.zig"),
            .target = b.graph.host,
        }),
    });
    init_db.linkLibC();
    vendors.addIncludePaths(b, init_db.root_module, .{});
    vendors.addSqlite(b, init_db, .{});
    init_db.root_module.addImport("schema_registry", deps.schema_registry);
    init_db.root_module.addImport("field", deps.field);
    init_db.root_module.addImport("seed", deps.seed);
    init_db.root_module.addAnonymousImport("schema_sql", .{ .root_source_file = deps.schema_sql_path });

    const init_db_cmd = b.addRunArtifact(init_db);
    init_db_cmd.addArg(if (deps.project_dir) |pd|
        b.pathJoin(&.{ pd, "data/publr.db" })
    else
        "data/publr.db");

    if (!deps.watch_mode and deps.config_path == null) {
        deps.exe.step.dependOn(&init_db_cmd.step);
    }
}
