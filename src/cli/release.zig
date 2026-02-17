const std = @import("std");
const Db = @import("db").Db;
const cms = @import("cms");
const common = @import("cli_common");
const fmt = @import("cli_format");

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) return listReleases(allocator, db, opts, args[1..]);
    if (std.mem.eql(u8, sub, "show")) {
        if (args.len < 2) return error.MissingReleaseId;
        return showRelease(allocator, db, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 2) return error.MissingReleaseName;
        return createRelease(db, opts, args[1], args[2..]);
    }
    if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 3) return error.MissingReleaseAddArgs;
        return addToRelease(db, opts, args[1], args[2], args[3..]);
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (args.len < 3) return error.MissingReleaseRemoveArgs;
        return removeFromRelease(db, opts, args[1], args[2]);
    }
    if (std.mem.eql(u8, sub, "publish")) {
        if (args.len < 2) return error.MissingReleaseId;
        return publishRelease(allocator, db, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "revert")) {
        if (args.len < 2) return error.MissingReleaseId;
        return revertRelease(db, opts, args[1], args[2..]);
    }
    if (std.mem.eql(u8, sub, "schedule")) {
        if (args.len < 3) return error.MissingScheduleArgs;
        return scheduleRelease(db, opts, args[1], args[2]);
    }
    if (std.mem.eql(u8, sub, "archive")) {
        if (args.len < 2) return error.MissingReleaseId;
        return archiveRelease(db, opts, args[1]);
    }
    return error.UnknownReleaseCommand;
}

fn listReleases(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    var status: ?[]const u8 = null;
    var limit: u32 = 50;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--status")) {
            i += 1;
            if (i >= args.len) return error.MissingStatus;
            status = args[i];
        } else if (std.mem.eql(u8, args[i], "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingLimit;
            limit = try std.fmt.parseInt(u32, args[i], 10);
        }
    }

    const releases = try cms.listReleases(allocator, db, .{ .status = status, .limit = limit });
    defer {
        for (releases) |item| {
            allocator.free(item.id);
            allocator.free(item.name);
            allocator.free(item.status);
            if (item.author_email) |e| allocator.free(e);
        }
        allocator.free(releases);
    }

    if (opts.format == .json) {
        try fmt.printJson(.{ .data = releases });
        return;
    }
    if (opts.format == .jsonl) {
        for (releases) |item| try fmt.printJsonLine(item);
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }
    defer {
        for (rows.items) |row| {
            allocator.free(row[3]);
            allocator.free(row[5]);
        }
    }

    for (releases) |item| {
        const cols = try allocator.alloc([]const u8, 6);
        cols[0] = item.id;
        cols[1] = item.name;
        cols[2] = item.status;
        cols[3] = try std.fmt.allocPrint(allocator, "{d}", .{item.item_count});
        cols[4] = item.author_email orelse "";
        cols[5] = try std.fmt.allocPrint(allocator, "{d}", .{item.created_at});
        try rows.append(allocator, cols);
    }

    try fmt.printTable(&.{ "ID", "Name", "Status", "Items", "Author", "Created" }, rows.items, opts.quiet, allocator);
}

fn showRelease(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, release_id: []const u8) !void {
    const detail = try cms.getRelease(allocator, db, release_id) orelse return error.ReleaseNotFound;
    defer freeReleaseDetail(allocator, detail);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = detail });
        return;
    }

    std.debug.print("Release {s} ({s}) status={s}\n", .{ detail.id, detail.name, detail.status });
    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }
    for (detail.items) |item| {
        const cols = try allocator.alloc([]const u8, 4);
        cols[0] = item.entry_id;
        cols[1] = item.entry_title;
        cols[2] = item.content_type_id;
        cols[3] = item.fields orelse "*";
        try rows.append(allocator, cols);
    }
    try fmt.printTable(&.{ "Entry ID", "Title", "Type", "Fields" }, rows.items, opts.quiet, allocator);
}

fn createRelease(db: *Db, opts: common.GlobalOptions, name: []const u8, args: []const []const u8) !void {
    var author: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--author")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthor;
            author = args[i];
        }
    }

    const id = try cms.createPendingRelease(db, name, author);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .id = id, .name = name } });
    } else if (!opts.quiet) {
        std.debug.print("Created release {s}\n", .{id});
    }
}

fn addToRelease(db: *Db, opts: common.GlobalOptions, release_id: []const u8, entry_id: []const u8, args: []const []const u8) !void {
    var fields: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--fields")) {
            i += 1;
            if (i >= args.len) return error.MissingFields;
            fields = args[i];
        }
    }
    try cms.addToRelease(db, release_id, entry_id, fields);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .added = true, .release_id = release_id, .entry_id = entry_id } });
    } else if (!opts.quiet) {
        std.debug.print("Added {s} to release {s}\n", .{ entry_id, release_id });
    }
}

fn removeFromRelease(db: *Db, opts: common.GlobalOptions, release_id: []const u8, entry_id: []const u8) !void {
    try cms.removeFromRelease(db, release_id, entry_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .removed = true, .release_id = release_id, .entry_id = entry_id } });
    } else if (!opts.quiet) {
        std.debug.print("Removed {s} from release {s}\n", .{ entry_id, release_id });
    }
}

fn publishRelease(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, release_id: []const u8) !void {
    try cms.publishBatchRelease(allocator, db, release_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .published = true, .release_id = release_id } });
    } else if (!opts.quiet) {
        std.debug.print("Published release {s}\n", .{release_id});
    }
}

fn revertRelease(db: *Db, opts: common.GlobalOptions, release_id: []const u8, args: []const []const u8) !void {
    var author: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--author")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthor;
            author = args[i];
        }
    }
    try cms.revertRelease(db, release_id, author);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .reverted = true, .release_id = release_id } });
    } else if (!opts.quiet) {
        std.debug.print("Reverted release {s}\n", .{release_id});
    }
}

fn scheduleRelease(db: *Db, opts: common.GlobalOptions, release_id: []const u8, value: []const u8) !void {
    const ts = try common.parseIsoTimestamp(value);
    if (ts <= std.time.timestamp()) return error.ScheduleMustBeFuture;
    try cms.scheduleRelease(db, release_id, ts);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .scheduled = true, .release_id = release_id, .scheduled_for = ts } });
    } else if (!opts.quiet) {
        std.debug.print("Scheduled release {s}\n", .{release_id});
    }
}

fn archiveRelease(db: *Db, opts: common.GlobalOptions, release_id: []const u8) !void {
    try cms.archiveRelease(db, release_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .archived = true, .release_id = release_id } });
    } else if (!opts.quiet) {
        std.debug.print("Archived release {s}\n", .{release_id});
    }
}

fn freeReleaseDetail(allocator: std.mem.Allocator, detail: cms.ReleaseDetail) void {
    allocator.free(detail.id);
    allocator.free(detail.name);
    allocator.free(detail.status);
    if (detail.author_email) |email| allocator.free(email);
    for (detail.items) |item| {
        allocator.free(item.entry_id);
        allocator.free(item.entry_title);
        allocator.free(item.entry_status);
        allocator.free(item.content_type_id);
        if (item.from_version) |from| allocator.free(from);
        allocator.free(item.to_version);
        if (item.fields) |fields| allocator.free(fields);
    }
    allocator.free(detail.items);
}

test "cli release: argument validation branches" {
    var dummy_db: Db = undefined;
    try std.testing.expectError(error.MissingReleaseId, run(std.testing.allocator, &dummy_db, .{}, &.{"show"}));
    try std.testing.expectError(error.MissingReleaseName, run(std.testing.allocator, &dummy_db, .{}, &.{"create"}));
    try std.testing.expectError(error.UnknownReleaseCommand, run(std.testing.allocator, &dummy_db, .{}, &.{"unknown"}));
}

test "cli release: create add remove publish revert schedule archive" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    const slug = try helpers.unique("cli-release");
    defer std.testing.allocator.free(slug);
    const entry_id = try helpers.createPostViaFields(&runner, "Release Entry", slug, "Body");
    defer std.testing.allocator.free(entry_id);

    const release_id = try helpers.createReleaseViaCli(&runner, "CLI Release");
    defer std.testing.allocator.free(release_id);

    var add = try runner.run(&.{ "release", "add", release_id, entry_id, "--format", "json" });
    defer add.deinit();
    try helpers.runner_mod.expectSuccess(add);

    var remove = try runner.run(&.{ "release", "remove", release_id, entry_id, "--format", "json" });
    defer remove.deinit();
    try helpers.runner_mod.expectSuccess(remove);

    var add_again = try runner.run(&.{ "release", "add", release_id, entry_id, "--format", "json" });
    defer add_again.deinit();
    try helpers.runner_mod.expectSuccess(add_again);

    var publish = try runner.run(&.{ "release", "publish", release_id, "--format", "json" });
    defer publish.deinit();
    try helpers.runner_mod.expectSuccess(publish);

    var revert = try runner.run(&.{ "release", "revert", release_id, "--format", "json" });
    defer revert.deinit();
    try helpers.runner_mod.expectSuccess(revert);

    var pending_create = try runner.run(&.{ "release", "create", "Pending Schedule", "--format", "json" });
    defer pending_create.deinit();
    try helpers.runner_mod.expectSuccess(pending_create);
    const pending_id = try helpers.extractDataIdFromJson(pending_create);
    defer std.testing.allocator.free(pending_id);

    var schedule = try runner.run(&.{ "release", "schedule", pending_id, "2030-01-01T12:00:00Z", "--format", "json" });
    defer schedule.deinit();
    try helpers.runner_mod.expectSuccess(schedule);

    var archive = try runner.run(&.{ "release", "archive", release_id, "--format", "json" });
    defer archive.deinit();
    try helpers.runner_mod.expectSuccess(archive);
}

test "cli release: public API coverage" {
    _ = run;
}
