const std = @import("std");
const common = @import("cli_common");
const core_init = @import("core_init");
const fmt = @import("cli_format");

pub fn run(allocator: std.mem.Allocator, opts: common.GlobalOptions, args: []const []const u8) !void {
    _ = allocator;
    const sub = args[0];
    if (std.mem.eql(u8, sub, "init")) return dbInit(opts);
    if (std.mem.eql(u8, sub, "seed")) return dbSeed(opts);
    if (std.mem.eql(u8, sub, "export")) {
        if (args.len < 2) return error.MissingExportPath;
        return dbExport(opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "import")) {
        if (args.len < 2) return error.MissingImportPath;
        return dbImport(opts, args[1], args[2..]);
    }
    return error.UnknownDbCommand;
}

fn dbInit(opts: common.GlobalOptions) !void {
    var db = try core_init.initDatabase(std.heap.page_allocator, opts.db_path);
    defer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .initialized = true, .db = opts.db_path } });
    } else if (!opts.quiet) {
        std.debug.print("Initialized database: {s}\n", .{opts.db_path});
    }
}

fn dbSeed(opts: common.GlobalOptions) !void {
    var db = try core_init.initDatabase(std.heap.page_allocator, opts.db_path);
    defer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .seeded = true, .db = opts.db_path } });
    } else if (!opts.quiet) {
        std.debug.print("Seeded database: {s}\n", .{opts.db_path});
    }
}

fn dbExport(opts: common.GlobalOptions, path: []const u8) !void {
    try std.fs.cwd().copyFile(opts.db_path, std.fs.cwd(), path, .{});
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .exported = true, .path = path } });
    } else if (!opts.quiet) {
        std.debug.print("Exported database to: {s}\n", .{path});
    }
}

fn dbImport(opts: common.GlobalOptions, path: []const u8, args: []const []const u8) !void {
    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) force = true;
    }

    const exists = blk: {
        std.fs.cwd().access(opts.db_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (exists and !force) {
        const confirmed = try common.promptConfirm("Overwrite destination database?", false);
        if (!confirmed) return;
    }

    try std.fs.cwd().copyFile(path, std.fs.cwd(), opts.db_path, .{ .override_mode = 0o644 });
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .imported = true, .from = path, .to = opts.db_path } });
    } else if (!opts.quiet) {
        std.debug.print("Imported database from {s}\n", .{path});
    }
}

test "cli db: argument validation branches" {
    try std.testing.expectError(error.MissingExportPath, run(std.testing.allocator, .{}, &.{"export"}));
    try std.testing.expectError(error.MissingImportPath, run(std.testing.allocator, .{}, &.{"import"}));
    try std.testing.expectError(error.UnknownDbCommand, run(std.testing.allocator, .{}, &.{"unknown"}));
}

test "cli db: init seed export import via CLI binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();

    var init_result = try runner.run(&.{ "db", "init", "--format", "json" });
    defer init_result.deinit();
    try helpers.runner_mod.expectSuccess(init_result);

    var seed_result = try runner.run(&.{ "db", "seed", "--format", "json" });
    defer seed_result.deinit();
    try helpers.runner_mod.expectSuccess(seed_result);

    const backup = try std.fmt.allocPrint(std.testing.allocator, "/tmp/publr-db-backup-{d}.db", .{std.time.nanoTimestamp()});
    defer std.testing.allocator.free(backup);
    defer std.fs.cwd().deleteFile(backup) catch {};

    var export_result = try runner.run(&.{ "db", "export", backup, "--format", "json" });
    defer export_result.deinit();
    try helpers.runner_mod.expectSuccess(export_result);

    const import_db = try std.fmt.allocPrint(std.testing.allocator, "/tmp/publr-db-import-{d}.db", .{std.time.nanoTimestamp()});
    defer std.testing.allocator.free(import_db);
    defer std.fs.cwd().deleteFile(import_db) catch {};

    var import_result = try runner.run(&.{ "db", "import", backup, "--db", import_db, "--force", "--format", "json" });
    defer import_result.deinit();
    try helpers.runner_mod.expectSuccess(import_result);
}

test "cli db: public API coverage" {
    _ = run;
}
