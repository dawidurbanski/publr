const std = @import("std");
const Db = @import("db").Db;
const media = @import("media");
const media_sync = @import("media_sync");
const mime = @import("mime");
const storage = @import("storage");
const common = @import("cli_common");
const fmt = @import("cli_format");

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) return listMedia(allocator, db, opts, args[1..]);
    if (std.mem.eql(u8, sub, "upload")) return uploadMedia(allocator, db, opts, args[1..]);
    if (std.mem.eql(u8, sub, "get")) {
        if (args.len < 2) return error.MissingMediaId;
        return getMedia(allocator, db, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (args.len < 2) return error.MissingMediaId;
        return deleteMedia(db, opts, args[1], args[2..]);
    }
    if (std.mem.eql(u8, sub, "sync")) return syncMedia(allocator, db, opts);
    return error.UnknownMediaCommand;
}

fn listMedia(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    var list_opts = media.MediaListOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mime")) {
            i += 1;
            if (i >= args.len) return error.MissingMimeFilter;
            list_opts.mime_patterns = args[i];
        } else if (std.mem.eql(u8, arg, "--visibility")) {
            i += 1;
            if (i >= args.len) return error.MissingVisibility;
            list_opts.visibility = args[i];
        } else if (std.mem.eql(u8, arg, "--search")) {
            i += 1;
            if (i >= args.len) return error.MissingSearch;
            list_opts.search = args[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingLimit;
            list_opts.limit = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--year")) {
            i += 1;
            if (i >= args.len) return error.MissingYear;
            list_opts.year = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--month")) {
            i += 1;
            if (i >= args.len) return error.MissingMonth;
            list_opts.month = try std.fmt.parseInt(u8, args[i], 10);
        }
    }

    const items = try media.listMedia(allocator, db, list_opts);
    defer {
        for (items) |item| {
            allocator.free(item.id);
            allocator.free(item.filename);
            allocator.free(item.mime_type);
            allocator.free(item.storage_key);
            allocator.free(item.visibility);
            if (item.hash) |h| allocator.free(h);
        }
        allocator.free(items);
    }

    if (opts.format == .json) {
        try fmt.printJson(.{ .data = items });
        return;
    }
    if (opts.format == .jsonl) {
        for (items) |item| try fmt.printJsonLine(item);
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

    for (items) |item| {
        const cols = try allocator.alloc([]const u8, 6);
        cols[0] = item.id;
        cols[1] = item.filename;
        cols[2] = item.mime_type;
        cols[3] = try std.fmt.allocPrint(allocator, "{d}", .{item.size});
        cols[4] = item.visibility;
        cols[5] = try std.fmt.allocPrint(allocator, "{d}", .{item.created_at});
        try rows.append(allocator, cols);
    }

    try fmt.printTable(
        &.{ "ID", "Filename", "MIME", "Size", "Visibility", "Created" },
        rows.items,
        opts.quiet,
        allocator,
    );
}

fn uploadMedia(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingUploadPath;

    var visibility = media.Visibility.public;
    var files: std.ArrayList([]const u8) = .{};
    defer files.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--visibility")) {
            i += 1;
            if (i >= args.len) return error.MissingVisibility;
            visibility = if (std.mem.eql(u8, args[i], "private")) .private else .public;
        } else {
            try files.append(allocator, args[i]);
        }
    }
    if (files.items.len == 0) return error.MissingUploadPath;

    var uploaded: std.ArrayList(media.MediaRecord) = .{};
    defer {
        for (uploaded.items) |item| {
            allocator.free(item.id);
            allocator.free(item.filename);
            allocator.free(item.mime_type);
            allocator.free(item.storage_key);
            allocator.free(item.visibility);
            if (item.hash) |h| allocator.free(h);
        }
        uploaded.deinit(allocator);
    }

    for (files.items) |path| {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024);
        defer allocator.free(data);
        const basename = std.fs.path.basename(path);
        const mime_type = mime.fromPath(path);

        const record = try media.uploadMedia(allocator, db, storage.filesystem, .{
            .filename = basename,
            .mime_type = mime_type,
            .data = data,
            .visibility = visibility,
        });
        try uploaded.append(allocator, record);
    }

    if (opts.format == .json) {
        try fmt.printJson(.{ .data = uploaded.items });
    } else if (opts.format == .jsonl) {
        for (uploaded.items) |item| try fmt.printJsonLine(item);
    } else if (!opts.quiet) {
        for (uploaded.items) |item| {
            std.debug.print("Uploaded {s} ({s})\n", .{ item.id, item.filename });
        }
    }
}

fn getMedia(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, media_id: []const u8) !void {
    const item = try media.getMedia(allocator, db, media_id) orelse return error.MediaNotFound;
    defer {
        allocator.free(item.id);
        allocator.free(item.filename);
        allocator.free(item.mime_type);
        allocator.free(item.storage_key);
        allocator.free(item.visibility);
        if (item.hash) |h| allocator.free(h);
    }

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = item });
        return;
    }

    var rows = [_]fmt.KeyValueRow{
        .{ .key = "id", .value = item.id },
        .{ .key = "filename", .value = item.filename },
        .{ .key = "mime_type", .value = item.mime_type },
        .{ .key = "storage_key", .value = item.storage_key },
        .{ .key = "visibility", .value = item.visibility },
        .{ .key = "hash", .value = item.hash orelse "" },
    };
    try fmt.printKeyValueRows(&rows, opts.quiet, allocator);
}

fn deleteMedia(db: *Db, opts: common.GlobalOptions, media_id: []const u8, args: []const []const u8) !void {
    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) force = true;
    }
    const confirmed = try common.promptConfirm("Delete media?", force);
    if (!confirmed) return;

    try media.fullDeleteMedia(std.heap.page_allocator, db, storage.filesystem, media_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .deleted = true, .id = media_id } });
    } else if (!opts.quiet) {
        std.debug.print("Deleted media {s}\n", .{media_id});
    }
}

fn syncMedia(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions) !void {
    const result = try media_sync.syncFilesystem(allocator, db);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = result });
    } else if (!opts.quiet) {
        std.debug.print(
            "Sync complete: new={d} missing={d} skipped={d} errors={d}\n",
            .{ result.new_count, result.missing_count, result.skipped_count, result.error_count },
        );
    }
}

test "cli media: argument validation branches" {
    var dummy_db: Db = undefined;
    try std.testing.expectError(error.MissingMediaId, run(std.testing.allocator, &dummy_db, .{}, &.{"get"}));
    try std.testing.expectError(error.UnknownMediaCommand, run(std.testing.allocator, &dummy_db, .{}, &.{"unknown"}));
}

test "cli media: list upload get delete via CLI binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    var list = try runner.run(&.{ "media", "list", "--format", "json" });
    defer list.deinit();
    try helpers.runner_mod.expectSuccess(list);

    const file_name = try helpers.createTempMediaFile("cli-media");
    defer std.testing.allocator.free(file_name);
    defer std.fs.cwd().deleteFile(file_name) catch {};

    var upload = try runner.run(&.{ "media", "upload", file_name, "--format", "json" });
    defer upload.deinit();
    try helpers.runner_mod.expectSuccess(upload);
    const media_id = try helpers.extractFirstArrayDataIdFromJson(upload);
    defer std.testing.allocator.free(media_id);

    var get = try runner.run(&.{ "media", "get", media_id, "--format", "json" });
    defer get.deinit();
    try helpers.runner_mod.expectSuccess(get);

    var delete = try runner.run(&.{ "media", "delete", media_id, "--force", "--format", "json" });
    defer delete.deinit();
    try helpers.runner_mod.expectSuccess(delete);
}

test "cli media: public API coverage" {
    _ = run;
}
