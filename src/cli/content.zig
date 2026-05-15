const std = @import("std");
const Db = @import("db").Db;
const cms = @import("cms");
const schema_registry = @import("schema_registry");
const common = @import("common.zig");
const fmt = @import("format.zig");

const FieldKV = struct {
    name: []const u8,
    value: []const u8,
};

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (args.len < 2) return error.MissingContentType;
    const type_id = args[1];

    if (std.mem.eql(u8, sub, "list")) return listEntries(type_id, allocator, db, opts, args[2..]);
    if (std.mem.eql(u8, sub, "create")) return createEntry(type_id, allocator, db, opts, args[2..]);
    if (std.mem.eql(u8, sub, "get")) {
        if (args.len < 3) return error.MissingEntryId;
        return getEntry(type_id, allocator, db, opts, args[2], args[3..]);
    }
    if (std.mem.eql(u8, sub, "update")) {
        if (args.len < 3) return error.MissingEntryId;
        return updateEntry(type_id, allocator, db, opts, args[2], args[3..]);
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (args.len < 3) return error.MissingEntryId;
        return deleteEntry(db, opts, args[2], args[3..]);
    }
    if (std.mem.eql(u8, sub, "publish")) {
        if (args.len < 3) return error.MissingEntryId;
        return publishEntry(allocator, db, opts, args[2], args[3..]);
    }
    if (std.mem.eql(u8, sub, "unpublish")) {
        if (args.len < 3) return error.MissingEntryId;
        return unpublishEntry(db, opts, args[2]);
    }
    if (std.mem.eql(u8, sub, "discard")) {
        if (args.len < 3) return error.MissingEntryId;
        return discardEntry(db, opts, args[2]);
    }
    if (std.mem.eql(u8, sub, "archive")) {
        if (args.len < 3) return error.MissingEntryId;
        return archiveEntry(db, opts, args[2]);
    }
    return error.UnknownContentCommand;
}

fn listEntries(type_id: []const u8, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    _ = schema_registry.findById(type_id) orelse return error.UnknownContentType;

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

    const items = try cms.query.listEntries(allocator, db, type_id, .{
        .status = status,
        .limit = limit,
        .offset = offset,
        .order_by = order_by,
        .order_dir = order_dir,
        .meta_filters = filters.items,
    });
    defer {
        for (items) |*item| @constCast(item).deinit(allocator);
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
        for (rows.items) |row| {
            allocator.free(row[3]);
            allocator.free(row[4]);
            allocator.free(row);
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

fn getEntry(type_id: []const u8, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, id_or_slug: []const u8, args: []const []const u8) !void {
    _ = schema_registry.findById(type_id) orelse return error.UnknownContentType;

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

    var item = (try cms.query.getEntry(allocator, db, type_id, id_or_slug)) orelse return error.EntryNotFound;
    defer item.deinit(allocator);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = item });
        return;
    }

    var rows: std.ArrayList(fmt.KeyValueRow) = .{};
    defer rows.deinit(allocator);
    try rows.append(allocator, .{ .key = "id", .value = item.id });
    try rows.append(allocator, .{ .key = "status", .value = item.status });
    try rows.append(allocator, .{ .key = "title", .value = item.title });

    var owned_values: std.ArrayList([]const u8) = .{};
    defer {
        for (owned_values.items) |v| allocator.free(v);
        owned_values.deinit(allocator);
    }

    var it = item.data.inner.iterator();
    while (it.next()) |kv| {
        const value_str = try fieldValueToString(allocator, kv.value_ptr.*);
        try owned_values.append(allocator, value_str);
        try rows.append(allocator, .{ .key = kv.key_ptr.*, .value = value_str });
    }

    try fmt.printKeyValueRows(rows.items, opts.quiet, allocator);
}

fn createEntry(type_id: []const u8, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const def = schema_registry.findById(type_id) orelse return error.UnknownContentType;

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

    const data_json = if (json_path) |path|
        try readJsonFile(allocator, path)
    else
        try buildJsonFromFields(allocator, def, fields.items, null);
    defer allocator.free(data_json);

    try validateRequiredFields(def, data_json);

    var entry = try cms.saveEntry(allocator, db, type_id, null, data_json, .{
        .author_id = author,
        .locale = locale,
        .status = status,
    });
    defer entry.deinit(allocator);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = entry });
    } else if (!opts.quiet) {
        std.debug.print("Created entry {s} ({s})\n", .{ entry.id, entry.status });
    }
}

fn updateEntry(type_id: []const u8, allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, entry_id: []const u8, args: []const []const u8) !void {
    const def = schema_registry.findById(type_id) orelse return error.UnknownContentType;

    var existing = (try cms.query.getEntry(allocator, db, type_id, entry_id)) orelse return error.EntryNotFound;
    defer existing.deinit(allocator);

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

    const data_json = if (json_path) |path|
        try readJsonFile(allocator, path)
    else
        try buildJsonFromFields(allocator, def, fields.items, existing.data);
    defer allocator.free(data_json);

    var updated = try cms.saveEntry(allocator, db, type_id, entry_id, data_json, .{
        .author_id = author,
        .locale = locale,
    });
    defer updated.deinit(allocator);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = updated });
    } else if (!opts.quiet) {
        std.debug.print("Updated entry {s} ({s})\n", .{ updated.id, updated.status });
    }
}

fn deleteEntry(db: *Db, opts: common.GlobalOptions, entry_id: []const u8, args: []const []const u8) !void {
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

fn readJsonFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        const stdin = std.fs.File.stdin();
        return stdin.readToEndAlloc(allocator, 16 * 1024 * 1024);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
}

/// Build a JSON object from CLI --field args. Starts from `existing` (if
/// any) via a FieldMap snapshot, applies updates, then emits JSON keyed by
/// field name with values coerced according to each field's `field_type_id`.
fn buildJsonFromFields(
    allocator: std.mem.Allocator,
    def: *const @import("content_type").ContentTypeDef,
    fields: []const FieldKV,
    existing: ?cms.query.FieldMap,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var first = true;
    for (def.fields) |f| {
        // Look up new value first, fall back to existing.
        const raw_new: ?[]const u8 = blk: {
            for (fields) |kv| {
                if (std.mem.eql(u8, kv.name, f.name)) break :blk kv.value;
            }
            break :blk null;
        };

        if (raw_new == null and existing == null) continue;

        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('"');
        try writeJsonEscaped(w, f.name);
        try w.writeAll("\":");

        if (raw_new) |raw| {
            try writeFieldJsonValue(w, f.field_type_id, raw);
        } else if (existing) |em| {
            try writeFieldMapValue(w, em.get(f.name));
        }
    }

    // Also pass through any --field that aren't on the schema (forgiving).
    for (fields) |kv| {
        var on_schema = false;
        for (def.fields) |f| {
            if (std.mem.eql(u8, f.name, kv.name)) {
                on_schema = true;
                break;
            }
        }
        if (on_schema) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('"');
        try writeJsonEscaped(w, kv.name);
        try w.writeAll("\":\"");
        try writeJsonEscaped(w, kv.value);
        try w.writeByte('"');
    }

    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

fn writeFieldJsonValue(w: anytype, field_type_id: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, field_type_id, "boolean")) {
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) {
            try w.writeAll("true");
        } else if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0") or raw.len == 0) {
            try w.writeAll("false");
        } else return error.InvalidBoolean;
        return;
    }
    if (std.mem.eql(u8, field_type_id, "integer")) {
        if (raw.len == 0) {
            try w.writeAll("null");
        } else {
            _ = try std.fmt.parseInt(i64, raw, 10);
            try w.writeAll(raw);
        }
        return;
    }
    if (std.mem.eql(u8, field_type_id, "number") or std.mem.eql(u8, field_type_id, "real")) {
        if (raw.len == 0) {
            try w.writeAll("null");
        } else {
            _ = try std.fmt.parseFloat(f64, raw);
            try w.writeAll(raw);
        }
        return;
    }
    if (std.mem.eql(u8, field_type_id, "taxonomy") or std.mem.eql(u8, field_type_id, "ref_multi")) {
        // CSV of IDs
        try w.writeByte('[');
        var first = true;
        var it = std.mem.splitScalar(u8, raw, ',');
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
        return;
    }
    // Default: emit as string.
    try w.writeByte('"');
    try writeJsonEscaped(w, raw);
    try w.writeByte('"');
}

fn writeFieldMapValue(w: anytype, val: ?cms.query.FieldValue) !void {
    const v = val orelse {
        try w.writeAll("null");
        return;
    };
    switch (v) {
        .text => |s| {
            try w.writeByte('"');
            try writeJsonEscaped(w, s);
            try w.writeByte('"');
        },
        .int => |n| try w.print("{d}", .{n}),
        .real => |n| try w.print("{d}", .{n}),
        .bool_ => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |t| try w.print("{d}", .{t}),
        .json => |j| try w.print("{f}", .{std.json.fmt(j, .{})}),
        .null_ => try w.writeAll("null"),
    }
}

fn validateRequiredFields(def: *const @import("content_type").ContentTypeDef, data_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MissingRequiredField;
    for (def.fields) |f| {
        if (!f.required) continue;
        const v = parsed.value.object.get(f.name) orelse return error.MissingRequiredField;
        switch (v) {
            .string => |s| if (s.len == 0) return error.MissingRequiredField,
            .null => return error.MissingRequiredField,
            else => {},
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

fn fieldValueToString(allocator: std.mem.Allocator, value: cms.query.FieldValue) ![]const u8 {
    return switch (value) {
        .text => |s| try allocator.dupe(u8, s),
        .int => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .real => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .bool_ => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .datetime => |t| try std.fmt.allocPrint(allocator, "{d}", .{t}),
        .null_ => try allocator.dupe(u8, "null"),
        .json => |j| blk: {
            var list: std.ArrayList(u8) = .{};
            errdefer list.deinit(allocator);
            const writer = list.writer(allocator);
            try writer.print("{f}", .{std.json.fmt(j, .{})});
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
