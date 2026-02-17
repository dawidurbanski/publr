const std = @import("std");
const Db = @import("db").Db;
const cms = @import("cms");
const common = @import("cli_common");
const fmt = @import("cli_format");

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) {
        if (args.len < 2) return error.MissingEntryId;
        return listVersions(allocator, db, opts, args[1], args[2..]);
    }
    if (std.mem.eql(u8, sub, "get")) {
        if (args.len < 2) return error.MissingVersionId;
        return getVersion(allocator, db, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "diff")) {
        if (args.len < 3) return error.MissingVersionIds;
        return diffVersions(allocator, db, opts, args[1], args[2]);
    }
    if (std.mem.eql(u8, sub, "restore")) {
        if (args.len < 3) return error.MissingRestoreArgs;
        return restoreVersion(allocator, db, opts, args[1], args[2], args[3..]);
    }
    return error.UnknownVersionCommand;
}

fn listVersions(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, entry_id: []const u8, args: []const []const u8) !void {
    var limit: u32 = 10;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingLimit;
            limit = try std.fmt.parseInt(u32, args[i], 10);
        }
    }

    const versions = try cms.listVersions(allocator, db, entry_id, .{ .limit = limit });
    defer {
        for (versions) |v| freeVersion(allocator, v);
        allocator.free(versions);
    }

    if (opts.format == .json) {
        try fmt.printJson(.{ .data = versions });
        return;
    }
    if (opts.format == .jsonl) {
        for (versions) |v| try fmt.printJsonLine(v);
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }
    defer {
        for (rows.items) |row| allocator.free(row[4]);
    }

    for (versions) |v| {
        const cols = try allocator.alloc([]const u8, 5);
        cols[0] = v.id;
        cols[1] = v.version_type;
        cols[2] = v.author_display_name orelse v.author_email orelse "system";
        cols[3] = if (v.is_current) "true" else "false";
        cols[4] = try std.fmt.allocPrint(allocator, "{d}", .{v.created_at});
        try rows.append(allocator, cols);
    }
    try fmt.printTable(&.{ "Version ID", "Type", "Author", "Current", "Created" }, rows.items, opts.quiet, allocator);
}

fn getVersion(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, version_id: []const u8) !void {
    const version = try cms.getVersion(allocator, db, version_id) orelse return error.VersionNotFound;
    defer freeVersion(allocator, version);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = version });
        return;
    }

    var stdout = std.fs.File.stdout().writer(&.{});
    try stdout.interface.print("Version: {s}\nEntry: {s}\nType: {s}\n\n{s}\n", .{
        version.id,
        version.entry_id,
        version.version_type,
        version.data,
    });
}

fn diffVersions(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, a: []const u8, b: []const u8) !void {
    const old_v = try cms.getVersion(allocator, db, a) orelse return error.VersionNotFound;
    defer freeVersion(allocator, old_v);
    const new_v = try cms.getVersion(allocator, db, b) orelse return error.VersionNotFound;
    defer freeVersion(allocator, new_v);

    const diff = try cms.compareVersionFields(allocator, old_v.data, new_v.data);
    defer {
        for (diff) |item| {
            allocator.free(item.key);
            allocator.free(item.old_value);
            allocator.free(item.new_value);
        }
        allocator.free(diff);
    }

    if (opts.format == .json) {
        try fmt.printJson(.{ .data = diff });
        return;
    }
    if (opts.format == .jsonl) {
        for (diff) |item| try fmt.printJsonLine(item);
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }

    for (diff) |item| {
        if (!item.changed) continue;
        const cols = try allocator.alloc([]const u8, 4);
        cols[0] = item.key;
        cols[1] = item.old_value;
        cols[2] = item.new_value;
        cols[3] = item.changed_by orelse "";
        try rows.append(allocator, cols);
    }
    try fmt.printTable(&.{ "Field", "Old", "New", "Changed By" }, rows.items, opts.quiet, allocator);
}

fn restoreVersion(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, entry_id: []const u8, version_id: []const u8, args: []const []const u8) !void {
    var author: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--author")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthor;
            author = args[i];
        }
    }
    try cms.restoreVersion(allocator, db, entry_id, version_id, author);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .restored = true, .entry_id = entry_id, .version_id = version_id } });
    } else if (!opts.quiet) {
        std.debug.print("Restored entry {s} to version {s}\n", .{ entry_id, version_id });
    }
}

fn freeVersion(allocator: std.mem.Allocator, v: cms.Version) void {
    allocator.free(v.id);
    allocator.free(v.entry_id);
    if (v.parent_id) |pid| allocator.free(pid);
    allocator.free(v.data);
    if (v.author_id) |aid| allocator.free(aid);
    if (v.author_email) |email| allocator.free(email);
    allocator.free(v.version_type);
    if (v.release_name) |name| allocator.free(name);
    if (v.collaborators) |c| allocator.free(c);
    if (v.author_display_name) |dn| allocator.free(dn);
}

test "cli version: argument validation branches" {
    var dummy_db: Db = undefined;
    try std.testing.expectError(error.MissingEntryId, run(std.testing.allocator, &dummy_db, .{}, &.{"list"}));
    try std.testing.expectError(error.MissingVersionId, run(std.testing.allocator, &dummy_db, .{}, &.{"get"}));
    try std.testing.expectError(error.UnknownVersionCommand, run(std.testing.allocator, &dummy_db, .{}, &.{"unknown"}));
}

test "cli version: list get diff restore via CLI binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    const slug = try helpers.unique("cli-version");
    defer std.testing.allocator.free(slug);
    const entry_id = try helpers.createPostViaFields(&runner, "Version A", slug, "Body");
    defer std.testing.allocator.free(entry_id);

    var update = try runner.run(&.{ "content", "update", "post", entry_id, "--field", "title=Version B", "--format", "json" });
    defer update.deinit();
    try helpers.runner_mod.expectSuccess(update);

    var list = try runner.run(&.{ "version", "list", entry_id, "--format", "json" });
    defer list.deinit();
    try helpers.runner_mod.expectSuccess(list);

    const ids = try helpers.versionPairIds(&runner, entry_id);
    defer std.testing.allocator.free(ids.latest);
    defer std.testing.allocator.free(ids.previous);

    var get = try runner.run(&.{ "version", "get", ids.latest, "--format", "json" });
    defer get.deinit();
    try helpers.runner_mod.expectSuccess(get);

    var diff = try runner.run(&.{ "version", "diff", ids.previous, ids.latest, "--format", "json" });
    defer diff.deinit();
    try helpers.runner_mod.expectSuccess(diff);

    var restore = try runner.run(&.{ "version", "restore", entry_id, ids.previous, "--format", "json" });
    defer restore.deinit();
    try helpers.runner_mod.expectSuccess(restore);
}

test "cli version: public API coverage" {
    _ = run;
}
