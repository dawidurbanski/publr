//! Internal helpers shared across release/*.zig — not part of the public
//! release API. Includes the two new extractions (`requireReleaseStatus`,
//! `loadVersionData`) and the existing JSON writers + flow-history helpers.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");

const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const ReleaseError = types.ReleaseError;

/// Assert that a release's status is one of `expected`. Replaces the eight
/// hand-written copies of "prepare SELECT status / bindText / step / compare"
/// scattered across release.zig. Returns ReleaseNotFound if the release row
/// doesn't exist, InvalidReleaseStatus if the status doesn't match.
pub fn requireReleaseStatus(
    db: *Db,
    release_id: []const u8,
    expected: []const []const u8,
) (Db.Error || ReleaseError)!void {
    var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
    const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
    for (expected) |e| if (std.mem.eql(u8, status, e)) return;
    return ReleaseError.InvalidReleaseStatus;
}

/// Load a version's data_json by id, duped to the caller's allocator.
/// Replaces the awkward `var data_stmt: ?Statement = null; defer if (data_stmt) |*s| s.deinit();`
/// pattern that appeared in 6 places — the statement was kept alive only so
/// the slice it returned stayed valid. Owning a duped slice is cleaner.
pub fn loadVersionData(allocator: Allocator, db: *Db, version_id: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, version_id);
    if (!try stmt.step()) return null;
    const s = stmt.columnText(0) orelse return null;
    return try allocator.dupe(u8, s);
}

/// Append a row to the entry_flow_history table.
pub fn appendFlowHistory(
    db: *Db,
    anchor_id: []const u8,
    version_id: ?[]const u8,
    action: []const u8,
    user_id: ?[]const u8,
    from_step: ?i64,
    to_step: ?i64,
    details: ?[]const u8,
) !void {
    const history_id = id_gen.generatePrefixedId("fh_", 16);
    var stmt = try db.prepare(
        \\INSERT INTO entry_flow_history (id, anchor_id, version_id, action, user_id, from_step, to_step, details, created_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, unixepoch())
    );
    defer stmt.deinit();
    try stmt.bindText(1, &history_id);
    try stmt.bindText(2, anchor_id);
    if (version_id) |vid| try stmt.bindText(3, vid) else try stmt.bindNull(3);
    try stmt.bindText(4, action);
    if (user_id) |uid| try stmt.bindText(5, uid) else try stmt.bindNull(5);
    if (from_step) |s| try stmt.bindInt(6, s) else try stmt.bindNull(6);
    if (to_step) |s| try stmt.bindInt(7, s) else try stmt.bindNull(7);
    if (details) |d| try stmt.bindText(8, d) else try stmt.bindNull(8);
    _ = try stmt.step();
}

/// Update an entry's published_version_id + archived flag, and emit the
/// terminal flow_history rows when a release transitions to published/archived.
pub fn mirrorPublishedState(db: *Db, entry_id: []const u8, published_version: []const u8, status: []const u8, actor_id: ?[]const u8) !void {
    var stmt = try db.prepare(
        \\UPDATE content_entries
        \\SET published_version_id = ?1, archived = ?2, updated_at = unixepoch()
        \\WHERE id = ?3
    );
    defer stmt.deinit();
    try stmt.bindText(1, published_version);
    try stmt.bindInt(2, if (std.mem.eql(u8, status, "archived")) 1 else 0);
    try stmt.bindText(3, entry_id);
    _ = try stmt.step();

    if (!std.mem.eql(u8, status, "published") and !std.mem.eql(u8, status, "archived")) return;

    var flow_stmt = try db.prepare("SELECT flow_id, current_step FROM entry_flow_state WHERE anchor_id = ?1");
    defer flow_stmt.deinit();
    try flow_stmt.bindText(1, entry_id);

    const terminal_action = if (std.mem.eql(u8, status, "archived")) "archive" else "publish";
    if (try flow_stmt.step()) {
        const flow_id = flow_stmt.columnText(0) orelse "default_publish";
        const current_step = flow_stmt.columnInt(1);
        const details = try std.fmt.allocPrint(db.allocator, "{{\"flow_id\":\"{s}\",\"terminal_action\":\"{s}\"}}", .{ flow_id, terminal_action });
        defer db.allocator.free(details);

        try appendFlowHistory(db, entry_id, published_version, "flow_entered", actor_id, null, current_step, details);
        try appendFlowHistory(db, entry_id, published_version, "step_started", actor_id, current_step, current_step, null);
        try appendFlowHistory(db, entry_id, published_version, "step_completed", actor_id, current_step, current_step, null);
        try appendFlowHistory(db, entry_id, published_version, "terminal_action", actor_id, current_step, null, details);
        try appendFlowHistory(db, entry_id, published_version, "flow_completed", actor_id, current_step, null, details);
    } else {
        const details = try std.fmt.allocPrint(db.allocator, "{{\"flow_id\":\"default_publish\",\"terminal_action\":\"{s}\"}}", .{terminal_action});
        defer db.allocator.free(details);
        try appendFlowHistory(db, entry_id, published_version, "flow_entered", actor_id, null, 0, details);
        try appendFlowHistory(db, entry_id, published_version, "step_started", actor_id, 0, 0, null);
        try appendFlowHistory(db, entry_id, published_version, "step_completed", actor_id, 0, 0, null);
        try appendFlowHistory(db, entry_id, published_version, "terminal_action", actor_id, 0, null, details);
        try appendFlowHistory(db, entry_id, published_version, "flow_completed", actor_id, 0, null, details);
    }

    var c_stmt = try db.prepare("DELETE FROM entry_flow_claims WHERE anchor_id = ?1");
    defer c_stmt.deinit();
    try c_stmt.bindText(1, entry_id);
    _ = try c_stmt.step();

    var f_stmt = try db.prepare("DELETE FROM entry_flow_state WHERE anchor_id = ?1");
    defer f_stmt.deinit();
    try f_stmt.bindText(1, entry_id);
    _ = try f_stmt.step();
}

/// Write a JSON value to a writer (recursive). Used by mergeJsonFields.
pub fn writeJsonValue(w: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| {
            try w.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                }
            }
            try w.writeByte('"');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("\"{s}\":", .{entry.key_ptr.*});
                try writeJsonValue(w, entry.value_ptr.*);
            }
            try w.writeByte('}');
        },
        .number_string => |s| try w.writeAll(s),
    }
}

/// Stringify a JSON value for display, truncating long strings.
pub fn stringifyJsonValue(allocator: Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .null => return try allocator.dupe(u8, "null"),
        .bool => |b| return try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| return try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .string => |s| {
            if (s.len > 80) {
                const truncated = try allocator.alloc(u8, 83);
                @memcpy(truncated[0..80], s[0..80]);
                @memcpy(truncated[80..83], "...");
                return truncated;
            }
            return try allocator.dupe(u8, s);
        },
        .array => |arr| return try std.fmt.allocPrint(allocator, "[{d} items]", .{arr.items.len}),
        .object => |obj| return try std.fmt.allocPrint(allocator, "{{{d} fields}}", .{obj.count()}),
        .number_string => |s| return try allocator.dupe(u8, s),
    }
}
