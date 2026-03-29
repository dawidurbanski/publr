//! Version History Management
//!
//! Handles entry version tracking, comparison, restoration, and pruning.
//! Provides structured version history with field-level attribution and
//! diff generation for UI presentation.

const std = @import("std");
const time_util = @import("time_util");
const db_mod = @import("db");
const Db = db_mod.Db;
const field_mod = @import("field");
const registry = @import("schema_registry");
const id_gen = @import("id_gen");

const Allocator = std.mem.Allocator;

/// Version record with author information and metadata
pub const Version = struct {
    id: []const u8,
    entry_id: []const u8,
    parent_id: ?[]const u8,
    data: []const u8,
    author_id: ?[]const u8,
    author_email: ?[]const u8,
    author_display_name: ?[]const u8 = null,
    created_at: i64,
    version_type: []const u8,
    is_current: bool,
    release_name: ?[]const u8 = null,
    collaborators: ?[]const u8 = null,

    /// Returns display_name if non-empty, otherwise email, otherwise "System"
    pub fn authorLabel(self: Version) []const u8 {
        if (self.author_display_name) |dn| {
            if (dn.len > 0) return dn;
        }
        return self.author_email orelse "System";
    }
};

/// Structured field comparison result
pub const FieldComparison = struct {
    key: []const u8,
    old_value: []const u8,
    new_value: []const u8,
    changed: bool,
    changed_by: ?[]const u8 = null, // display name (or email) of who last changed this field
    changed_by_email: ?[]const u8 = null, // email of who last changed this field (for gravatar)
    changed_by_id: ?[]const u8 = null, // user ID of who last changed this field (for hard lock validation)
};

/// List versions for an entry, newest first. Joins users for author email.
pub fn listVersions(allocator: Allocator, db: *Db, entry_id: []const u8, opts: struct {
    limit: u32 = 50,
}) ![]Version {
    var stmt = try db.prepare(
        \\SELECT ev.id, ev.entry_id, ev.parent_id, ev.data_json,
        \\       ev.author_id, u.email, ev.created_at, ev.version_type,
        \\       (e.current_version_id = ev.id) AS is_current,
        \\       r.name AS release_name,
        \\       ev.collaborators, u.display_name
        \\FROM content_versions ev
        \\JOIN content_entries e ON e.id = ev.entry_id
        \\LEFT JOIN users u ON u.id = ev.author_id
        \\LEFT JOIN release_entries ri ON ri.to_version_id = ev.id AND ri.entry_id = ev.entry_id
        \\LEFT JOIN releases r ON r.id = ri.release_id AND r.name IS NOT NULL
        \\WHERE ev.entry_id = ?1
        \\  AND ev.version_type != 'autosave'
        \\ORDER BY ev.created_at DESC
        \\LIMIT ?2
    );
    defer stmt.deinit();

    try stmt.bindText(1, entry_id);
    try stmt.bindInt(2, @intCast(opts.limit));

    var items: std.ArrayListUnmanaged(Version) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, .{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .entry_id = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .parent_id = if (stmt.columnText(2)) |v| try allocator.dupe(u8, v) else null,
            .data = try allocator.dupe(u8, stmt.columnText(3) orelse "{}"),
            .author_id = if (stmt.columnText(4)) |v| try allocator.dupe(u8, v) else null,
            .author_email = if (stmt.columnText(5)) |v| try allocator.dupe(u8, v) else null,
            .created_at = stmt.columnInt(6),
            .version_type = try allocator.dupe(u8, stmt.columnText(7) orelse "edit"),
            .is_current = stmt.columnInt(8) == 1,
            .release_name = if (stmt.columnText(9)) |v| try allocator.dupe(u8, v) else null,
            .collaborators = if (stmt.columnText(10)) |v| try allocator.dupe(u8, v) else null,
            .author_display_name = if (stmt.columnText(11)) |v| try allocator.dupe(u8, v) else null,
        });
    }

    return items.toOwnedSlice(allocator);
}

/// Get a single version by ID
pub fn getVersion(allocator: Allocator, db: *Db, version_id: []const u8) !?Version {
    var stmt = try db.prepare(
        \\SELECT ev.id, ev.entry_id, ev.parent_id, ev.data_json,
        \\       ev.author_id, u.email, ev.created_at, ev.version_type,
        \\       (e.current_version_id = ev.id) AS is_current,
        \\       ev.collaborators, u.display_name
        \\FROM content_versions ev
        \\JOIN content_entries e ON e.id = ev.entry_id
        \\LEFT JOIN users u ON u.id = ev.author_id
        \\WHERE ev.id = ?1
    );
    defer stmt.deinit();

    try stmt.bindText(1, version_id);

    if (!try stmt.step()) return null;

    return .{
        .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
        .entry_id = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
        .parent_id = if (stmt.columnText(2)) |v| try allocator.dupe(u8, v) else null,
        .data = try allocator.dupe(u8, stmt.columnText(3) orelse "{}"),
        .author_id = if (stmt.columnText(4)) |v| try allocator.dupe(u8, v) else null,
        .author_email = if (stmt.columnText(5)) |v| try allocator.dupe(u8, v) else null,
        .created_at = stmt.columnInt(6),
        .version_type = try allocator.dupe(u8, stmt.columnText(7) orelse "edit"),
        .is_current = stmt.columnInt(8) == 1,
        .collaborators = if (stmt.columnText(9)) |v| try allocator.dupe(u8, v) else null,
        .author_display_name = if (stmt.columnText(10)) |v| try allocator.dupe(u8, v) else null,
    };
}

/// Restore a previous version: creates a new 'restored' version with the old data,
/// pointing parent_id to the current version. Updates content_entries.data and current_version_id.
pub fn restoreVersion(
    allocator: Allocator,
    db: *Db,
    entry_id: []const u8,
    source_version_id: []const u8,
    author_id: ?[]const u8,
) !void {
    // Get the source version's data
    const source = try getVersion(allocator, db, source_version_id) orelse return error.VersionNotFound;

    // Delegate to restoreVersionWithData with the source version's data
    try restoreVersionWithData(db, entry_id, source.data, author_id);
}

/// Format a unix timestamp as a relative time string ("2 hours ago", "yesterday", etc.)
pub fn formatRelativeTime(allocator: Allocator, timestamp: i64) ![]const u8 {
    const now = time_util.timestamp();
    const diff = now - timestamp;

    if (diff < 0) return try allocator.dupe(u8, "just now");
    if (diff < 60) return try allocator.dupe(u8, "just now");
    if (diff < 3600) {
        const mins: u64 = @intCast(@divFloor(diff, 60));
        return if (mins == 1)
            try allocator.dupe(u8, "1 minute ago")
        else
            try std.fmt.allocPrint(allocator, "{d} minutes ago", .{mins});
    }
    if (diff < 86400) {
        const hours: u64 = @intCast(@divFloor(diff, 3600));
        return if (hours == 1)
            try allocator.dupe(u8, "1 hour ago")
        else
            try std.fmt.allocPrint(allocator, "{d} hours ago", .{hours});
    }
    if (diff < 604800) {
        const days: u64 = @intCast(@divFloor(diff, 86400));
        return if (days == 1)
            try allocator.dupe(u8, "yesterday")
        else
            try std.fmt.allocPrint(allocator, "{d} days ago", .{days});
    }

    const weeks: u64 = @intCast(@divFloor(diff, 604800));
    return if (weeks == 1)
        try allocator.dupe(u8, "1 week ago")
    else
        try std.fmt.allocPrint(allocator, "{d} weeks ago", .{weeks});
}

/// Compare two JSON data strings field-by-field, returning structured data
/// for all fields (union of keys from both objects).
pub fn compareVersionFields(allocator: Allocator, old_data: []const u8, new_data: []const u8) ![]FieldComparison {
    const old_parsed = std.json.parseFromSlice(std.json.Value, allocator, old_data, .{}) catch
        return &.{};
    defer old_parsed.deinit();

    const new_parsed = std.json.parseFromSlice(std.json.Value, allocator, new_data, .{}) catch
        return &.{};
    defer new_parsed.deinit();

    const old_obj = if (old_parsed.value == .object) old_parsed.value.object else return &.{};
    const new_obj = if (new_parsed.value == .object) new_parsed.value.object else return &.{};

    var items: std.ArrayListUnmanaged(FieldComparison) = .{};
    errdefer items.deinit(allocator);

    // Keys from new version
    var new_it = new_obj.iterator();
    while (new_it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const new_val = jsonValueToString(allocator, entry.value_ptr.*) catch try allocator.dupe(u8, "");
        const old_val = if (old_obj.get(key)) |ov| jsonValueToString(allocator, ov) catch try allocator.dupe(u8, "") else try allocator.dupe(u8, "");

        try items.append(allocator, .{
            .key = key,
            .old_value = old_val,
            .new_value = new_val,
            .changed = !std.mem.eql(u8, old_val, new_val),
        });
    }

    // Keys only in old version (removed fields)
    var old_it = old_obj.iterator();
    while (old_it.next()) |entry| {
        if (!new_obj.contains(entry.key_ptr.*)) {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const old_val = jsonValueToString(allocator, entry.value_ptr.*) catch try allocator.dupe(u8, "");

            try items.append(allocator, .{
                .key = key,
                .old_value = old_val,
                .new_value = try allocator.dupe(u8, ""),
                .changed = true,
            });
        }
    }

    return items.toOwnedSlice(allocator);
}

/// Walk the version chain from current back to old_version and determine
/// who last changed each field. Populates `changed_by` on the FieldComparison items.
pub fn populateFieldAuthors(allocator: Allocator, db: *Db, fields: []FieldComparison, current_version_id: []const u8, old_version_id: []const u8) void {
    // Walk parent_id chain from current to old, collecting (data, author_label) pairs
    const ChainEntry = struct { data: []const u8, label: ?[]const u8, email: ?[]const u8, author_id: ?[]const u8 };
    var chain: std.ArrayListUnmanaged(ChainEntry) = .{};
    defer {
        for (chain.items) |item| {
            allocator.free(item.data);
            if (item.label) |l| allocator.free(l);
            if (item.email) |e| allocator.free(e);
            if (item.author_id) |a| allocator.free(a);
        }
        chain.deinit(allocator);
    }

    var walk_id: ?[]const u8 = allocator.dupe(u8, current_version_id) catch return;
    defer if (walk_id) |w| allocator.free(w);

    var steps: usize = 0;
    while (walk_id) |wid| {
        if (steps > 100) break; // safety limit
        steps += 1;

        var stmt = db.prepare(
            \\SELECT ev.data_json, u.email, ev.parent_id, u.display_name, ev.author_id
            \\FROM content_versions ev
            \\LEFT JOIN users u ON u.id = ev.author_id
            \\WHERE ev.id = ?1
        ) catch break;
        defer stmt.deinit();
        stmt.bindText(1, wid) catch break;
        if (!(stmt.step() catch break)) break;

        const data = allocator.dupe(u8, stmt.columnText(0) orelse "{}") catch break;
        // Prefer display_name over email
        const display_name = stmt.columnText(3);
        const email = stmt.columnText(1);
        const label = if (display_name) |dn| (if (dn.len > 0) allocator.dupe(u8, dn) catch null else if (email) |e| allocator.dupe(u8, e) catch null else null) else if (email) |e| allocator.dupe(u8, e) catch null else null;
        const email_dupe = if (email) |e| allocator.dupe(u8, e) catch null else null;
        const aid = if (stmt.columnText(4)) |a| allocator.dupe(u8, a) catch null else null;
        chain.append(allocator, .{ .data = data, .label = label, .email = email_dupe, .author_id = aid }) catch break;

        const at_old = std.mem.eql(u8, wid, old_version_id);
        if (at_old) break;

        if (stmt.columnText(2)) |parent| {
            allocator.free(wid);
            walk_id = allocator.dupe(u8, parent) catch null;
        } else break;
    }

    if (chain.items.len < 2) return;

    // chain is [current, parent, grandparent, ..., old] — walk adjacent pairs
    // For each pair (newer, older): fields that differ were changed by newer's author
    for (0..chain.items.len - 1) |i| {
        const newer = chain.items[i];
        const older = chain.items[i + 1];

        const newer_parsed = std.json.parseFromSlice(std.json.Value, allocator, newer.data, .{}) catch continue;
        defer newer_parsed.deinit();
        const older_parsed = std.json.parseFromSlice(std.json.Value, allocator, older.data, .{}) catch continue;
        defer older_parsed.deinit();

        if (newer_parsed.value != .object or older_parsed.value != .object) continue;
        const newer_obj = newer_parsed.value.object;
        const older_obj = older_parsed.value.object;

        for (fields) |*f| {
            if (!f.changed or f.changed_by != null) continue; // already attributed

            const newer_val = newer_obj.get(f.key);
            const older_val = older_obj.get(f.key);

            const differs = if (newer_val) |nv| blk: {
                if (older_val) |ov| {
                    const nv_str = jsonValueToString(allocator, nv) catch continue;
                    defer allocator.free(nv_str);
                    const ov_str = jsonValueToString(allocator, ov) catch continue;
                    defer allocator.free(ov_str);
                    break :blk !std.mem.eql(u8, nv_str, ov_str);
                } else break :blk true;
            } else older_val != null;

            if (differs) {
                // This version introduced the change for this field
                if (newer.label) |l| {
                    f.changed_by = allocator.dupe(u8, l) catch null;
                }
                if (newer.email) |e| {
                    f.changed_by_email = allocator.dupe(u8, e) catch null;
                }
                if (newer.author_id) |a| {
                    f.changed_by_id = allocator.dupe(u8, a) catch null;
                }
            }
        }
    }
}

/// Restore a version with arbitrary merged data. Creates a 'restored' version
/// with the given data, updates content_entries.data, title, slug, status from the JSON.
pub fn restoreVersionWithData(
    db: *Db,
    entry_id: []const u8,
    data: []const u8,
    author_id: ?[]const u8,
) !void {
    // Get current version id and check if entry is published
    var cur_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1",
    );
    defer cur_stmt.deinit();
    try cur_stmt.bindText(1, entry_id);
    if (!try cur_stmt.step()) return error.EntryNotFound;
    const current_vid = cur_stmt.columnText(0);
    const is_published = cur_stmt.columnText(1) != null;

    // Create new version with merged data
    const new_vid = id_gen.generateVersionId();

    {
        var v_stmt = try db.prepare(
            \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, version_type)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 'restored')
        );
        defer v_stmt.deinit();

        try v_stmt.bindText(1, &new_vid);
        try v_stmt.bindText(2, entry_id);
        if (current_vid) |cv| try v_stmt.bindText(3, cv) else try v_stmt.bindNull(3);
        try v_stmt.bindText(4, data);
        if (author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);

        _ = try v_stmt.step();
    }

    // Extract title, slug, status from data JSON for content_entries update
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch null;
    defer if (parsed) |p| p.deinit();

    var title: []const u8 = "";
    var slug: ?[]const u8 = null;
    var status: []const u8 = "draft";

    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get("title")) |v| {
                if (v == .string) title = v.string;
            }
            if (p.value.object.get("slug")) |v| {
                if (v == .string) slug = v.string;
            }
            if (p.value.object.get("status")) |v| {
                if (v == .string) status = v.string;
            }
        }
    }

    // Update entry — if published, also update published_version_id so restore goes live immediately
    if (is_published) {
        var u_stmt = try db.prepare(
            \\UPDATE content_entries SET current_version_id = ?1, published_version_id = ?1, data = ?2,
            \\    title = ?3, slug = ?4, status = ?5, updated_at = unixepoch()
            \\WHERE id = ?6
        );
        defer u_stmt.deinit();

        try u_stmt.bindText(1, &new_vid);
        try u_stmt.bindText(2, data);
        try u_stmt.bindText(3, title);
        if (slug) |s| try u_stmt.bindText(4, s) else try u_stmt.bindNull(4);
        try u_stmt.bindText(5, status);
        try u_stmt.bindText(6, entry_id);

        _ = try u_stmt.step();
    } else {
        var u_stmt = try db.prepare(
            \\UPDATE content_entries SET current_version_id = ?1, data = ?2,
            \\    title = ?3, slug = ?4, status = ?5, updated_at = unixepoch()
            \\WHERE id = ?6
        );
        defer u_stmt.deinit();

        try u_stmt.bindText(1, &new_vid);
        try u_stmt.bindText(2, data);
        try u_stmt.bindText(3, title);
        if (slug) |s| try u_stmt.bindText(4, s) else try u_stmt.bindNull(4);
        try u_stmt.bindText(5, status);
        try u_stmt.bindText(6, entry_id);

        _ = try u_stmt.step();
    }

    // Enforce retention limit
    try pruneVersions(db, entry_id);
}

/// Compute a field-level diff between two JSON data strings.
/// Returns HTML showing changes per field.
pub fn diffVersions(allocator: Allocator, old_data: []const u8, new_data: []const u8) ![]const u8 {
    // Parse both JSON objects
    const old_parsed = std.json.parseFromSlice(std.json.Value, allocator, old_data, .{}) catch
        return try allocator.dupe(u8, "<p class=\"diff-error\">Could not parse old version data</p>");
    defer old_parsed.deinit();

    const new_parsed = std.json.parseFromSlice(std.json.Value, allocator, new_data, .{}) catch
        return try allocator.dupe(u8, "<p class=\"diff-error\">Could not parse new version data</p>");
    defer new_parsed.deinit();

    const old_obj = if (old_parsed.value == .object) old_parsed.value.object else return try allocator.dupe(u8, "");
    const new_obj = if (new_parsed.value == .object) new_parsed.value.object else return try allocator.dupe(u8, "");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("<div class=\"diff\">");

    // Check fields in new version (changed + added)
    var new_it = new_obj.iterator();
    while (new_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const new_val = jsonValueToString(allocator, entry.value_ptr.*) catch "";
        const old_val = if (old_obj.get(key)) |ov| jsonValueToString(allocator, ov) catch "" else "";

        if (old_val.len == 0 and new_val.len == 0) continue;

        if (!old_obj.contains(key)) {
            // Added field
            try w.writeAll("<div class=\"diff-field diff-added\"><span class=\"diff-key\">");
            try w.writeAll(key);
            try w.writeAll("</span><span class=\"diff-badge\">added</span><div class=\"diff-val diff-new\">");
            try writeEscaped(w, new_val);
            try w.writeAll("</div></div>");
        } else if (!std.mem.eql(u8, old_val, new_val)) {
            // Changed field
            try w.writeAll("<div class=\"diff-field diff-changed\"><span class=\"diff-key\">");
            try w.writeAll(key);
            try w.writeAll("</span><span class=\"diff-badge\">changed</span><div class=\"diff-val diff-old\">");
            try writeEscaped(w, old_val);
            try w.writeAll("</div><div class=\"diff-val diff-new\">");
            try writeEscaped(w, new_val);
            try w.writeAll("</div></div>");
        }
    }

    // Check fields removed (in old but not new)
    var old_it = old_obj.iterator();
    while (old_it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!new_obj.contains(key)) {
            const old_val = jsonValueToString(allocator, entry.value_ptr.*) catch "";
            try w.writeAll("<div class=\"diff-field diff-removed\"><span class=\"diff-key\">");
            try w.writeAll(key);
            try w.writeAll("</span><span class=\"diff-badge\">removed</span><div class=\"diff-val diff-old\">");
            try writeEscaped(w, old_val);
            try w.writeAll("</div></div>");
        }
    }

    try w.writeAll("</div>");

    return buf.toOwnedSlice(allocator);
}

/// Convert a JSON value to a display string
pub fn jsonValueToString(allocator: Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .null => try allocator.dupe(u8, ""),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .array, .object => blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            buf.writer(allocator).print("{f}", .{std.json.fmt(value, .{})}) catch
                break :blk try allocator.dupe(u8, "[complex value]");
            break :blk buf.toOwnedSlice(allocator) catch try allocator.dupe(u8, "[complex value]");
        },
        else => try allocator.dupe(u8, ""),
    };
}

/// Write HTML-escaped text
pub fn writeEscaped(w: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

/// Prune old versions if version_history_limit is set.
/// Keeps the N most recent versions per entry, deletes the rest.
pub fn pruneVersions(db: *Db, entry_id: []const u8) !void {
    // Read the limit from settings table
    var limit_stmt = try db.prepare(
        "SELECT value FROM settings WHERE key = 'version_history_limit'",
    );
    defer limit_stmt.deinit();

    if (!try limit_stmt.step()) return; // No limit set
    const limit_str = limit_stmt.columnText(0) orelse return;

    const limit = std.fmt.parseInt(u32, limit_str, 10) catch return;
    if (limit == 0) return;

    // Delete oldest versions beyond the limit.
    // Keep the N most recent by created_at; delete the rest.
    var del_stmt = try db.prepare(
        \\DELETE FROM content_versions
        \\WHERE entry_id = ?1
        \\  AND id NOT IN (
        \\    SELECT id FROM content_versions
        \\    WHERE entry_id = ?1
        \\    ORDER BY created_at DESC
        \\    LIMIT ?2
        \\  )
    );
    defer del_stmt.deinit();

    try del_stmt.bindText(1, entry_id);
    try del_stmt.bindInt(2, @intCast(limit));

    _ = try del_stmt.step();
}

test "formatRelativeTime handles future and age buckets" {
    const now = time_util.timestamp();

    const future = try formatRelativeTime(std.testing.allocator, now + 10);
    defer std.testing.allocator.free(future);
    try std.testing.expectEqualStrings("just now", future);

    const minutes = try formatRelativeTime(std.testing.allocator, now - 120);
    defer std.testing.allocator.free(minutes);
    try std.testing.expectEqualStrings("2 minutes ago", minutes);

    const hours = try formatRelativeTime(std.testing.allocator, now - 7200);
    defer std.testing.allocator.free(hours);
    try std.testing.expectEqualStrings("2 hours ago", hours);

    const yesterday = try formatRelativeTime(std.testing.allocator, now - 86400);
    defer std.testing.allocator.free(yesterday);
    try std.testing.expectEqualStrings("yesterday", yesterday);
}

test "compareVersionFields marks changed and removed fields" {
    const fields = try compareVersionFields(
        std.testing.allocator,
        "{\"title\":\"Old\",\"body\":\"Body\",\"gone\":\"x\"}",
        "{\"title\":\"New\",\"body\":\"Body\"}",
    );
    defer {
        for (fields) |item| {
            std.testing.allocator.free(item.key);
            std.testing.allocator.free(item.old_value);
            std.testing.allocator.free(item.new_value);
        }
        std.testing.allocator.free(fields);
    }

    var saw_title = false;
    var saw_removed = false;
    for (fields) |item| {
        if (std.mem.eql(u8, item.key, "title")) {
            saw_title = true;
            try std.testing.expect(item.changed);
        }
        if (std.mem.eql(u8, item.key, "gone")) {
            saw_removed = true;
            try std.testing.expect(item.changed);
            try std.testing.expectEqualStrings("", item.new_value);
        }
    }
    try std.testing.expect(saw_title);
    try std.testing.expect(saw_removed);
}

test "jsonValueToString and writeEscaped cover scalar and escaped branches" {
    const scalar = try jsonValueToString(std.testing.allocator, .{ .bool = true });
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("true", scalar);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[]", .{});
    defer parsed.deinit();
    const complex = try jsonValueToString(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(complex);
    try std.testing.expectEqualStrings("[complex value]", complex);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeEscaped(buf.writer(std.testing.allocator), "<a&\"b>");
    try std.testing.expectEqualStrings("&lt;a&amp;&quot;b&gt;", buf.items);
}

test "core version: public API coverage" {
    _ = listVersions;
    _ = getVersion;
    _ = restoreVersion;
    _ = formatRelativeTime;
    _ = compareVersionFields;
    _ = populateFieldAuthors;
    _ = restoreVersionWithData;
    _ = diffVersions;
    _ = jsonValueToString;
    _ = writeEscaped;
    _ = pruneVersions;
}
