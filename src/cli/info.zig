const std = @import("std");
const Db = @import("db").Db;
const common = @import("cli_common");
const fmt = @import("cli_format");
const registry = @import("schema_registry");

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions) !void {
    var total_entries: i64 = 0;
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM content_anchors");
        defer stmt.deinit();
        if (!try stmt.step()) return error.MissingCountRow;
        total_entries = stmt.columnInt(0);
    }

    var total_media: i64 = 0;
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM media");
        defer stmt.deinit();
        if (!try stmt.step()) return error.MissingCountRow;
        total_media = stmt.columnInt(0);
    }

    if (opts.format == .json or opts.format == .jsonl) {
        var counts: std.ArrayList(struct { type_id: []const u8, count: i64 }) = .{};
        defer counts.deinit(allocator);
        for (registry.registered_types) |info| {
            try counts.append(allocator, .{
                .type_id = info.id,
                .count = try countForType(db, info.id),
            });
        }

        try fmt.printJson(.{ .data = .{
            .version = "dev",
            .db_path = opts.db_path,
            .total_entries = total_entries,
            .total_media = total_media,
            .content_types = counts.items,
        } });
        return;
    }

    std.debug.print("Version: dev\n", .{});
    std.debug.print("DB Path: {s}\n", .{opts.db_path});
    std.debug.print("Total Entries: {d}\n", .{total_entries});
    std.debug.print("Total Media: {d}\n", .{total_media});
    if (!opts.quiet) {
        std.debug.print("Content Types:\n", .{});
        for (registry.registered_types) |info| {
            std.debug.print("  - {s}: {d}\n", .{ info.id, try countForType(db, info.id) });
        }
    }
}

fn countForType(db: *Db, type_id: []const u8) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM content_anchors WHERE content_type = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, type_id);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "cli info: command output via CLI binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    var info = try runner.run(&.{ "info", "--format", "json" });
    defer info.deinit();
    try helpers.runner_mod.expectSuccess(info);
    try helpers.runner_mod.expectStdoutContains(info, "\"version\"");
    try helpers.runner_mod.expectStdoutContains(info, "\"content_types\"");
}

test "cli info: public API coverage" {
    _ = run;
}
