//! Entry-level operations used by both the publish path and the editor —
//! version lookup, published-data fetch, discard-to-published, and the
//! partial-publish merge helper.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const internal = @import("internal.zig");

const Allocator = std.mem.Allocator;

/// Get the current_version_id for an entry. Caller owns the returned slice.
pub fn getEntryVersionId(db: *Db, entry_id: []const u8) !?[]const u8 {
    var stmt = try db.prepare(
        "SELECT current_version_id FROM content_entries WHERE id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    if (try stmt.step()) {
        if (stmt.columnText(0)) |v| {
            return try db.allocator.dupe(u8, v);
        }
    }
    return null;
}

/// Get the published version's data for an entry. Null if no published
/// version exists (entry never published).
pub fn getPublishedData(allocator: Allocator, db: *Db, entry_id: []const u8) !?[]const u8 {
    var stmt = try db.prepare(
        \\SELECT ev.data_json FROM content_entries e
        \\JOIN content_versions ev ON ev.id = e.published_version_id
        \\WHERE e.id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    if (try stmt.step()) {
        if (stmt.columnText(0)) |d| {
            return try allocator.dupe(u8, d);
        }
    }
    return null;
}

/// Discard WIP changes by resetting an entry to its published version.
/// No history entry is created — silently reverts current_version_id and
/// content_entries.data back to the published snapshot.
pub fn discardToPublished(db: *Db, entry_id: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT e.published_version_id, ev.data_json
        \\FROM content_entries e
        \\JOIN content_versions ev ON ev.id = e.published_version_id
        \\WHERE e.id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    if (!try stmt.step()) return;

    const published_vid = stmt.columnText(0) orelse return;
    const published_data = stmt.columnText(1) orelse return;

    // Extract title and slug from published data for content_entries table
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, published_data, .{}) catch null;
    defer if (parsed) |p| p.deinit();

    var title: []const u8 = "";
    var slug: ?[]const u8 = null;

    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get("title")) |t| {
                if (t == .string) title = t.string;
            }
            if (p.value.object.get("slug")) |s| {
                if (s == .string) slug = s.string;
            }
        }
    }

    var u_stmt = try db.prepare(
        \\UPDATE content_entries SET current_version_id = ?1, data = ?2,
        \\    title = ?3, slug = ?4, status = 'published', updated_at = unixepoch()
        \\WHERE id = ?5
    );
    defer u_stmt.deinit();
    try u_stmt.bindText(1, published_vid);
    try u_stmt.bindText(2, published_data);
    try u_stmt.bindText(3, title);
    if (slug) |s| try u_stmt.bindText(4, s) else try u_stmt.bindNull(4);
    try u_stmt.bindText(5, entry_id);
    _ = try u_stmt.step();
}

/// Merge selected fields from draft JSON into published JSON.
/// Returns a new JSON string with all published fields + selected fields
/// overlaid from draft.
pub fn mergeJsonFields(allocator: Allocator, published_json: []const u8, draft_json: []const u8, field_names: []const []const u8) ![]const u8 {
    const pub_parsed = std.json.parseFromSlice(std.json.Value, allocator, published_json, .{}) catch
        return try allocator.dupe(u8, published_json);
    defer pub_parsed.deinit();

    const draft_parsed = std.json.parseFromSlice(std.json.Value, allocator, draft_json, .{}) catch
        return try allocator.dupe(u8, published_json);
    defer draft_parsed.deinit();

    const pub_obj = if (pub_parsed.value == .object) pub_parsed.value.object else return try allocator.dupe(u8, published_json);
    const draft_obj = if (draft_parsed.value == .object) draft_parsed.value.object else return try allocator.dupe(u8, published_json);

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var first = true;

    // Write all published fields, substituting selected ones from draft
    var pub_it = pub_obj.iterator();
    while (pub_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\":", .{entry.key_ptr.*});

        var use_draft = false;
        for (field_names) |fname| {
            if (std.mem.eql(u8, fname, entry.key_ptr.*)) {
                use_draft = true;
                break;
            }
        }

        if (use_draft) {
            if (draft_obj.get(entry.key_ptr.*)) |draft_val| {
                try internal.writeJsonValue(w, draft_val);
            } else {
                try internal.writeJsonValue(w, entry.value_ptr.*);
            }
        } else {
            try internal.writeJsonValue(w, entry.value_ptr.*);
        }
    }

    // Add any draft-only fields that are in the selection but not in published
    for (field_names) |fname| {
        if (!pub_obj.contains(fname)) {
            if (draft_obj.get(fname)) |draft_val| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("\"{s}\":", .{fname});
                try internal.writeJsonValue(w, draft_val);
            }
        }
    }

    try w.writeByte('}');
    return try buf.toOwnedSlice(allocator);
}

test "mergeJsonFields overlays selected fields and keeps others" {
    const merged = try mergeJsonFields(
        std.testing.allocator,
        "{\"title\":\"Published\",\"body\":\"Keep\",\"count\":1}",
        "{\"title\":\"Draft\",\"body\":\"DraftBody\",\"new_field\":\"new\"}",
        &.{ "title", "new_field" },
    );
    defer std.testing.allocator.free(merged);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, merged, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("Draft", obj.get("title").?.string);
    try std.testing.expectEqualStrings("Keep", obj.get("body").?.string);
    try std.testing.expectEqualStrings("new", obj.get("new_field").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("count").?.integer);
}

test "mergeJsonFields falls back to published json on parse failures" {
    const bad_published = try mergeJsonFields(std.testing.allocator, "{bad", "{\"title\":\"Draft\"}", &.{"title"});
    defer std.testing.allocator.free(bad_published);
    try std.testing.expectEqualStrings("{bad", bad_published);

    const bad_draft = try mergeJsonFields(std.testing.allocator, "{\"title\":\"Published\"}", "{bad", &.{"title"});
    defer std.testing.allocator.free(bad_draft);
    try std.testing.expectEqualStrings("{\"title\":\"Published\"}", bad_draft);
}
