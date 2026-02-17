const std = @import("std");
const Db = @import("db").Db;
const cms = @import("cms");
const schemas = @import("schemas");
const common = @import("cli_common");
const fmt = @import("cli_format");

const FieldKV = struct {
    name: []const u8,
    value: []const u8,
};

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (args.len < 2) return error.MissingContentType;
    const type_id = args[1];

    if (std.mem.eql(u8, sub, "list")) return dispatchByType(type_id, .list, allocator, db, opts, args[2..], null);
    if (std.mem.eql(u8, sub, "create")) return dispatchByType(type_id, .create, allocator, db, opts, args[2..], null);
    if (std.mem.eql(u8, sub, "get")) {
        if (args.len < 3) return error.MissingEntryId;
        return dispatchByType(type_id, .get, allocator, db, opts, args[3..], args[2]);
    }
    if (std.mem.eql(u8, sub, "update")) {
        if (args.len < 3) return error.MissingEntryId;
        return dispatchByType(type_id, .update, allocator, db, opts, args[3..], args[2]);
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (args.len < 3) return error.MissingEntryId;
        return dispatchByType(type_id, .delete, allocator, db, opts, args[3..], args[2]);
    }
    if (std.mem.eql(u8, sub, "publish")) {
        if (args.len < 3) return error.MissingEntryId;
        return dispatchByType(type_id, .publish, allocator, db, opts, args[3..], args[2]);
    }
    if (std.mem.eql(u8, sub, "unpublish")) {
        if (args.len < 3) return error.MissingEntryId;
        return dispatchByType(type_id, .unpublish, allocator, db, opts, args[3..], args[2]);
    }
    if (std.mem.eql(u8, sub, "discard")) {
        if (args.len < 3) return error.MissingEntryId;
        return dispatchByType(type_id, .discard, allocator, db, opts, args[3..], args[2]);
    }
    if (std.mem.eql(u8, sub, "archive")) {
        if (args.len < 3) return error.MissingEntryId;
        return dispatchByType(type_id, .archive, allocator, db, opts, args[3..], args[2]);
    }
    return error.UnknownContentCommand;
}

const Action = enum {
    list,
    get,
    create,
    update,
    delete,
    publish,
    unpublish,
    discard,
    archive,
};

fn dispatchByType(type_id: []const u8, action: Action, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8, entry_id: ?[]const u8) !void {
    inline for (schemas.content_types) |CT| {
        if (std.mem.eql(u8, type_id, CT.type_id)) {
            return switch (action) {
                .list => listEntries(CT, allocator, db, opts, args),
                .get => getEntry(CT, allocator, db, opts, entry_id.?, args),
                .create => createEntry(CT, allocator, db, opts, args),
                .update => updateEntry(CT, allocator, db, opts, entry_id.?, args),
                .delete => deleteEntry(CT, db, opts, entry_id.?, args),
                .publish => publishEntry(allocator, db, opts, entry_id.?, args),
                .unpublish => unpublishEntry(db, opts, entry_id.?),
                .discard => discardEntry(db, opts, entry_id.?),
                .archive => archiveEntry(db, opts, entry_id.?),
            };
        }
    }
    return error.UnknownContentType;
}

fn listEntries(comptime CT: type, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    var status: ?[]const u8 = null;
    var limit: ?u32 = 20;
    var offset: ?u32 = null;
    var order_by: []const u8 = "created_at";
    var order_dir: cms.OrderDir = .desc;
    var filters: std.ArrayList(cms.MetaFilter) = .{};
    defer filters.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--status")) {
            i += 1;
            if (i >= args.len) return error.MissingStatus;
            status = args[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingLimit;
            limit = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--offset")) {
            i += 1;
            if (i >= args.len) return error.MissingOffset;
            offset = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--order")) {
            i += 1;
            if (i >= args.len) return error.MissingOrder;
            order_by = args[i];
        } else if (std.mem.eql(u8, arg, "--asc")) {
            order_dir = .asc;
        } else if (std.mem.eql(u8, arg, "--desc")) {
            order_dir = .desc;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) return error.MissingFilter;
            const pair = args[i];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidFilter;
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            try filters.append(allocator, .{
                .key = key,
                .op = .eq,
                .value = .{ .text = val },
            });
        }
    }

    const items = try cms.listEntries(CT, allocator, db, .{
        .status = status,
        .limit = limit,
        .offset = offset,
        .order_by = order_by,
        .order_dir = order_dir,
        .meta_filters = filters.items,
    });
    defer allocator.free(items);

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
            allocator.free(row[4]);
        }
    }

    for (items) |item| {
        const cols = try allocator.alloc([]const u8, 5);
        cols[0] = item.id;
        cols[1] = item.title;
        cols[2] = item.status;
        cols[3] = try std.fmt.allocPrint(allocator, "{d}", .{item.created_at});
        cols[4] = try std.fmt.allocPrint(allocator, "{d}", .{item.updated_at});
        try rows.append(allocator, cols);
    }

    try fmt.printTable(
        &.{ "ID", "Title", "Status", "Created", "Updated" },
        rows.items,
        opts.quiet,
        allocator,
    );
}

fn getEntry(comptime CT: type, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, id_or_slug: []const u8, args: []const []const u8) !void {
    var version_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--version")) {
            i += 1;
            if (i >= args.len) return error.MissingVersionId;
            version_id = args[i];
        }
    }

    if (version_id) |vid| {
        const version = try cms.getVersion(allocator, db, vid) orelse return error.VersionNotFound;
        defer freeVersion(allocator, version);
        if (opts.format == .json or opts.format == .jsonl) {
            try fmt.printJson(.{ .data = version });
        } else {
            std.debug.print("{s}\n", .{version.data});
        }
        return;
    }

    const item = try cms.getEntry(CT, allocator, db, id_or_slug) orelse return error.EntryNotFound;

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = item });
        return;
    }

    const data_json = try CT.stringifyData(allocator, item.data);
    defer allocator.free(data_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data_json, .{});
    defer parsed.deinit();

    var rows: std.ArrayList(fmt.KeyValueRow) = .{};
    defer rows.deinit(allocator);
    try rows.append(allocator, .{ .key = "id", .value = item.id });
    try rows.append(allocator, .{ .key = "status", .value = item.status });
    try rows.append(allocator, .{ .key = "title", .value = item.title });

    if (parsed.value == .object) {
        var iter = parsed.value.object.iterator();
        while (iter.next()) |kv| {
            const value_str = try valueToString(allocator, kv.value_ptr.*);
            defer allocator.free(value_str);
            try rows.append(allocator, .{
                .key = kv.key_ptr.*,
                .value = try allocator.dupe(u8, value_str),
            });
        }
    }
    defer {
        var idx: usize = 3;
        while (idx < rows.items.len) : (idx += 1) allocator.free(rows.items[idx].value);
    }

    try fmt.printKeyValueRows(rows.items, opts.quiet, allocator);
}

fn createEntry(comptime CT: type, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    var author: ?[]const u8 = null;
    var locale: ?[]const u8 = null;
    var status: []const u8 = "draft";
    var json_path: ?[]const u8 = null;
    var fields: std.ArrayList(FieldKV) = .{};
    defer fields.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--field")) {
            i += 1;
            if (i >= args.len) return error.MissingFieldValue;
            const pair = args[i];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidField;
            try fields.append(allocator, .{ .name = pair[0..eq], .value = pair[eq + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= args.len) return error.MissingJsonPath;
            json_path = args[i];
        } else if (std.mem.eql(u8, arg, "--author")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthor;
            author = args[i];
        } else if (std.mem.eql(u8, arg, "--locale")) {
            i += 1;
            if (i >= args.len) return error.MissingLocale;
            locale = args[i];
        } else if (std.mem.eql(u8, arg, "--status")) {
            i += 1;
            if (i >= args.len) return error.MissingStatus;
            status = args[i];
        }
    }

    const data = if (json_path) |path|
        try parseDataFromJson(CT, allocator, path)
    else
        try parseDataFromFields(CT, allocator, fields.items, null);

    try validateRequiredFields(CT, data);

    const entry = try cms.saveEntry(CT, allocator, db, null, data, .{
        .author_id = author,
        .locale = locale,
        .status = status,
    });

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = entry });
    } else if (!opts.quiet) {
        std.debug.print("Created entry {s} ({s})\n", .{ entry.id, entry.status });
    }
}

fn updateEntry(comptime CT: type, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, entry_id: []const u8, args: []const []const u8) !void {
    const existing = try cms.getEntry(CT, allocator, db, entry_id) orelse return error.EntryNotFound;

    var author: ?[]const u8 = null;
    var locale: ?[]const u8 = null;
    var json_path: ?[]const u8 = null;
    var fields: std.ArrayList(FieldKV) = .{};
    defer fields.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--field")) {
            i += 1;
            if (i >= args.len) return error.MissingFieldValue;
            const pair = args[i];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidField;
            try fields.append(allocator, .{ .name = pair[0..eq], .value = pair[eq + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= args.len) return error.MissingJsonPath;
            json_path = args[i];
        } else if (std.mem.eql(u8, arg, "--author")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthor;
            author = args[i];
        } else if (std.mem.eql(u8, arg, "--locale")) {
            i += 1;
            if (i >= args.len) return error.MissingLocale;
            locale = args[i];
        }
    }

    const data = if (json_path) |path|
        try parseDataFromJson(CT, allocator, path)
    else
        try parseDataFromFields(CT, allocator, fields.items, existing.data);

    const updated = try cms.saveEntry(CT, allocator, db, entry_id, data, .{
        .author_id = author,
        .locale = locale,
    });

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = updated });
    } else if (!opts.quiet) {
        std.debug.print("Updated entry {s} ({s})\n", .{ updated.id, updated.status });
    }
}

fn deleteEntry(comptime CT: type, db: *Db, opts: common.GlobalOptions, entry_id: []const u8, args: []const []const u8) !void {
    _ = CT;
    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) force = true;
    }

    const confirmed = try common.promptConfirm("Delete entry?", force);
    if (!confirmed) return;
    try cms.deleteEntry(db, entry_id);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .deleted = true, .id = entry_id } });
    } else if (!opts.quiet) {
        std.debug.print("Deleted entry {s}\n", .{entry_id});
    }
}

fn publishEntry(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, entry_id: []const u8, args: []const []const u8) !void {
    var author: ?[]const u8 = null;
    var fields: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--author")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthor;
            author = args[i];
        } else if (std.mem.eql(u8, args[i], "--fields")) {
            i += 1;
            if (i >= args.len) return error.MissingFields;
            fields = try csvToJsonArray(allocator, args[i]);
        }
    }
    defer if (fields) |f| allocator.free(f);

    try cms.publishEntry(allocator, db, entry_id, author, fields);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .published = true, .id = entry_id } });
    } else if (!opts.quiet) {
        std.debug.print("Published entry {s}\n", .{entry_id});
    }
}

fn unpublishEntry(db: *Db, opts: common.GlobalOptions, entry_id: []const u8) !void {
    try cms.unpublishEntry(db, entry_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .unpublished = true, .id = entry_id } });
    } else if (!opts.quiet) {
        std.debug.print("Unpublished entry {s}\n", .{entry_id});
    }
}

fn discardEntry(db: *Db, opts: common.GlobalOptions, entry_id: []const u8) !void {
    try cms.discardToPublished(db, entry_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .discarded = true, .id = entry_id } });
    } else if (!opts.quiet) {
        std.debug.print("Discarded changes for {s}\n", .{entry_id});
    }
}

fn archiveEntry(db: *Db, opts: common.GlobalOptions, entry_id: []const u8) !void {
    try cms.archiveEntry(db, entry_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .archived = true, .id = entry_id } });
    } else if (!opts.quiet) {
        std.debug.print("Archived entry {s}\n", .{entry_id});
    }
}

fn parseDataFromJson(comptime CT: type, allocator: std.mem.Allocator, path: []const u8) !CT.Data {
    const json_text = if (std.mem.eql(u8, path, "-")) blk: {
        const stdin = std.fs.File.stdin();
        break :blk try stdin.readToEndAlloc(allocator, 16 * 1024 * 1024);
    } else try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(json_text);

    const parsed = try CT.parseData(allocator, json_text);
    return parsed.value;
}

fn parseDataFromFields(comptime CT: type, allocator: std.mem.Allocator, fields: []const FieldKV, existing: ?CT.Data) !CT.Data {
    var data = if (existing) |cur|
        cur
    else blk: {
        break :blk std.mem.zeroInit(CT.Data, .{});
    };

    for (fields) |field| {
        var matched = false;
        inline for (std.meta.fields(CT.Data)) |df| {
            if (std.mem.eql(u8, field.name, df.name)) {
                matched = true;
                @field(data, df.name) = try convertFieldValue(df.type, allocator, field.value);
            }
        }
        if (!matched) return error.UnknownField;
    }

    return data;
}

fn convertFieldValue(comptime T: type, allocator: std.mem.Allocator, raw: []const u8) !T {
    if (T == []const u8) return raw;
    if (T == ?[]const u8) return if (raw.len == 0) null else raw;
    if (T == bool) {
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        return error.InvalidBoolean;
    }
    if (T == ?bool) {
        if (raw.len == 0) return null;
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        return error.InvalidBoolean;
    }
    if (T == i64) return try std.fmt.parseInt(i64, raw, 10);
    if (T == ?i64) return if (raw.len == 0) null else try std.fmt.parseInt(i64, raw, 10);
    if (T == i32) return try std.fmt.parseInt(i32, raw, 10);
    if (T == ?i32) return if (raw.len == 0) null else try std.fmt.parseInt(i32, raw, 10);
    if (T == u32) return try std.fmt.parseInt(u32, raw, 10);
    if (T == ?u32) return if (raw.len == 0) null else try std.fmt.parseInt(u32, raw, 10);
    if (T == []const []const u8) {
        var parts: std.ArrayList([]const u8) = .{};
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len == 0) continue;
            try parts.append(allocator, trimmed);
        }
        return try parts.toOwnedSlice(allocator);
    }
    return error.UnsupportedFieldType;
}

fn validateRequiredFields(comptime CT: type, data: CT.Data) !void {
    inline for (CT.schema) |field| {
        if (!field.required) continue;
        inline for (std.meta.fields(CT.Data)) |df| {
            if (comptime std.mem.eql(u8, df.name, field.name)) {
                const value = @field(data, df.name);
                if (@TypeOf(value) == []const u8 and value.len == 0) {
                    return error.MissingRequiredField;
                }
                if (@TypeOf(value) == ?[]const u8 and value == null) {
                    return error.MissingRequiredField;
                }
            }
        }
    }
}

fn csvToJsonArray(allocator: std.mem.Allocator, csv: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('[');
    var first = true;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('"');
        try writeJsonEscaped(w, trimmed);
        try w.writeByte('"');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(allocator);
}

fn writeJsonEscaped(w: anytype, value: []const u8) !void {
    for (value) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(ch),
    };
}

fn valueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        else => blk: {
            var list: std.ArrayList(u8) = .{};
            errdefer list.deinit(allocator);
            const writer = list.writer(allocator);
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            break :blk try list.toOwnedSlice(allocator);
        },
    };
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

test "cli content: argument validation branches" {
    var dummy_db: Db = undefined;
    try std.testing.expectError(error.MissingContentType, run(std.testing.allocator, &dummy_db, .{}, &.{"list"}));
    try std.testing.expectError(error.UnknownContentCommand, run(std.testing.allocator, &dummy_db, .{}, &.{ "unknown", "post" }));
}

test "cli content: lifecycle via CLI binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    const slug = try helpers.unique("cli-content");
    defer std.testing.allocator.free(slug);
    const entry_id = try helpers.createPostViaFields(&runner, "CLI Content", slug, "Body");
    defer std.testing.allocator.free(entry_id);

    var get = try runner.run(&.{ "content", "get", "post", entry_id, "--format", "json" });
    defer get.deinit();
    try helpers.runner_mod.expectSuccess(get);
    try helpers.runner_mod.expectStdoutContains(get, "CLI Content");

    var update = try runner.run(&.{ "content", "update", "post", entry_id, "--field", "title=Updated", "--format", "json" });
    defer update.deinit();
    try helpers.runner_mod.expectSuccess(update);

    var publish = try runner.run(&.{ "content", "publish", "post", entry_id, "--format", "json" });
    defer publish.deinit();
    try helpers.runner_mod.expectSuccess(publish);

    var unpublish = try runner.run(&.{ "content", "unpublish", "post", entry_id, "--format", "json" });
    defer unpublish.deinit();
    try helpers.runner_mod.expectSuccess(unpublish);

    var delete = try runner.run(&.{ "content", "delete", "post", entry_id, "--force", "--format", "json" });
    defer delete.deinit();
    try helpers.runner_mod.expectSuccess(delete);
}

test "cli content: public API coverage" {
    _ = run;
}
