//! Release Management
//!
//! Handles publishing, reverting, scheduling, and batch releases.
//! Extracted from cms.zig for separation of concerns.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;
const id_gen = @import("id_gen");
const time_util = @import("time_util");
const version = @import("version");

const Allocator = std.mem.Allocator;

// Re-export writeEscaped for internal use (used by collectCollaborators)
const writeEscaped = version.writeEscaped;

/// Generate a release ID (rel_ prefix + 16 random alphanumeric chars)
pub const generateReleaseId = id_gen.generateReleaseId;

/// Error returned when a release operation is blocked
pub const ReleaseError = error{
    ReleaseNotFound,
    InvalidReleaseStatus,
    EntryModifiedSinceRelease,
};

/// Lightweight struct for pending release dropdowns
pub const PendingReleaseOption = struct {
    id: []const u8,
    name: []const u8,
};

/// Struct for release list items
pub const ReleaseListItem = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    item_count: i64,
    author_email: ?[]const u8,
    created_at: i64,
};

/// Struct for a single release item in the detail view
pub const ReleaseDetailItem = struct {
    entry_id: []const u8,
    entry_title: []const u8,
    entry_status: []const u8,
    content_type_id: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    fields: ?[]const u8,
};

/// Full release detail (header + items)
pub const ReleaseDetail = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    author_email: ?[]const u8,
    created_at: i64,
    released_at: ?i64,
    scheduled_for: ?i64,
    reverted_at: ?i64,
    items: []const ReleaseDetailItem,
};

/// Info about which fields of an entry are in pending releases.
pub const EntryReleaseFieldInfo = struct {
    release_id: []const u8,
    release_name: []const u8,
    fields: ?[]const u8, // JSON array of field names, or null for full publish
    scheduled_for: ?i64 = null,
};

fn appendFlowHistory(
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

fn mirrorPublishedState(db: *Db, entry_id: []const u8, published_version: []const u8, status: []const u8, actor_id: ?[]const u8) !void {
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

/// Get the current_version_id for an entry
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

/// Get the published version's data for an entry (for smart change detection).
/// Returns null if no published version exists (i.e. entry was never published).
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
/// No history entry is created -- this silently reverts current_version_id
/// and content_entries.data back to the published snapshot.
pub fn discardToPublished(db: *Db, entry_id: []const u8) !void {
    // Get published version id and data
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

    // Reset entry to published state
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
/// Returns a new JSON string with all published fields + selected fields overlaid from draft.
pub fn mergeJsonFields(allocator: Allocator, published_json: []const u8, draft_json: []const u8, field_names: []const []const u8) ![]const u8 {
    const pub_parsed = std.json.parseFromSlice(std.json.Value, allocator, published_json, .{}) catch
        return try allocator.dupe(u8, published_json);
    defer pub_parsed.deinit();

    const draft_parsed = std.json.parseFromSlice(std.json.Value, allocator, draft_json, .{}) catch
        return try allocator.dupe(u8, published_json);
    defer draft_parsed.deinit();

    const pub_obj = if (pub_parsed.value == .object) pub_parsed.value.object else return try allocator.dupe(u8, published_json);
    const draft_obj = if (draft_parsed.value == .object) draft_parsed.value.object else return try allocator.dupe(u8, published_json);

    // Build merged JSON string: start with all published fields, overlay selected from draft
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

        // Write key
        try w.print("\"{s}\":", .{entry.key_ptr.*});

        // Check if this field should come from draft
        var use_draft = false;
        for (field_names) |fname| {
            if (std.mem.eql(u8, fname, entry.key_ptr.*)) {
                use_draft = true;
                break;
            }
        }

        if (use_draft) {
            if (draft_obj.get(entry.key_ptr.*)) |draft_val| {
                try writeJsonValue(w, draft_val);
            } else {
                try writeJsonValue(w, entry.value_ptr.*);
            }
        } else {
            try writeJsonValue(w, entry.value_ptr.*);
        }
    }

    // Add any draft-only fields that are in the selection but not in published
    for (field_names) |fname| {
        if (!pub_obj.contains(fname)) {
            if (draft_obj.get(fname)) |draft_val| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("\"{s}\":", .{fname});
                try writeJsonValue(w, draft_val);
            }
        }
    }

    try w.writeByte('}');
    return try buf.toOwnedSlice(allocator);
}

/// Write a JSON value to a writer
fn writeJsonValue(w: anytype, value: std.json.Value) !void {
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

/// Publish a single entry by creating an instant release and publishing it.
/// Handles both full and partial (field-level) publish through the same
/// publishBatchRelease path -- one code path for all publishing.
pub fn publishEntry(allocator: Allocator, db: *Db, entry_id: []const u8, author_id: ?[]const u8, fields_json: ?[]const u8) !void {
    // Skip if already published with same version and no partial fields
    if (fields_json == null) {
        var e_stmt = try db.prepare("SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1");
        defer e_stmt.deinit();
        try e_stmt.bindText(1, entry_id);
        if (!try e_stmt.step()) return error.EntryNotFound;
        const to_version = e_stmt.columnText(0) orelse return error.EntryNotFound;
        if (e_stmt.columnText(1)) |fv| {
            if (std.mem.eql(u8, fv, to_version)) return;
        }
    }

    // Create pending release (instant = unnamed)
    const release_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            \\INSERT INTO releases (id, name, status, author_id, created_at)
            \\VALUES (?1, NULL, 'pending', ?2, unixepoch())
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        if (author_id) |aid| try stmt.bindText(2, aid) else try stmt.bindNull(2);
        _ = try stmt.step();
    }

    // Add single item -- addToRelease reads from/to versions from content_entries table
    try addToRelease(db, &release_id, entry_id, fields_json);

    // Publish through the single shared path
    try publishBatchRelease(allocator, db, &release_id);
}

/// Revert a released release: for each item, create a new version with
/// from_version's data, update current_version_id, set status to 'reverted'.
/// Blocked if any entry's current_version_id != the release item's to_version.
pub fn revertRelease(db: *Db, release_id: []const u8, author_id: ?[]const u8) (Db.Error || ReleaseError)!void {
    // 1. Load release -- must be status='released'
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "released")) return ReleaseError.InvalidReleaseStatus;
    }

    // 2. Check blocking condition for all items
    {
        var stmt = try db.prepare(
            \\SELECT ri.entry_id FROM release_entries ri
            \\JOIN content_entries e ON e.id = ri.entry_id
            \\WHERE ri.release_id = ?1
            \\  AND e.current_version_id != ri.to_version_id
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (try stmt.step()) return ReleaseError.EntryModifiedSinceRelease;
    }

    // 3. For each item, create new version with from_version's data
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.from_version_id, ri.to_version_id
            \\FROM release_entries ri
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const entry_id = items_stmt.columnText(0) orelse continue;
            const from_version = items_stmt.columnText(1);
            const current_to = items_stmt.columnText(2) orelse continue;

            // Get data to restore: from_version's data, or empty JSON if from_version is NULL (new entry)
            var data: []const u8 = "{}";
            var data_stmt: ?Statement = null;
            defer if (data_stmt) |*s| s.deinit();

            if (from_version) |fv| {
                var stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
                try stmt.bindText(1, fv);
                if (try stmt.step()) {
                    data = stmt.columnText(0) orelse "{}";
                }
                data_stmt = stmt;
            }

            // Create new version
            const new_vid = id_gen.generateVersionId();
            {
                var v_stmt = try db.prepare(
                    \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, version_type)
                    \\VALUES (?1, ?2, ?3, ?4, ?5, 'reverted')
                );
                defer v_stmt.deinit();

                try v_stmt.bindText(1, &new_vid);
                try v_stmt.bindText(2, entry_id);
                try v_stmt.bindText(3, current_to);
                try v_stmt.bindText(4, data);
                if (author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);

                _ = try v_stmt.step();
            }

            // Update entry
            {
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET current_version_id = ?1, data = ?2, updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();

                try u_stmt.bindText(1, &new_vid);
                try u_stmt.bindText(2, data);
                try u_stmt.bindText(3, entry_id);

                _ = try u_stmt.step();
            }
        }
    }

    // 4. Update release status
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'reverted', reverted_at = unixepoch() WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// Re-release a reverted release: for each item, create a new version with
/// to_version's data, update current_version_id, set status back to 'released'.
/// Blocked if any entry has been modified since the revert.
pub fn reReleaseReverted(db: *Db, release_id: []const u8, author_id: ?[]const u8) (Db.Error || ReleaseError)!void {
    // 1. Load release -- must be status='reverted'
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "reverted")) return ReleaseError.InvalidReleaseStatus;
    }

    // 2. Check blocking: current_version_id must be the version created by the revert.
    //    That version's parent_id == to_version, so we check that current_version_id's
    //    parent matches to_version for each item.
    {
        var stmt = try db.prepare(
            \\SELECT ri.entry_id FROM release_entries ri
            \\JOIN content_entries e ON e.id = ri.entry_id
            \\JOIN content_versions ev ON ev.id = e.current_version_id
            \\WHERE ri.release_id = ?1
            \\  AND (ev.parent_id IS NULL OR ev.parent_id != ri.to_version_id)
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (try stmt.step()) return ReleaseError.EntryModifiedSinceRelease;
    }

    // 3. For each item, create new version with to_version's data
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.to_version_id
            \\FROM release_entries ri
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const entry_id = items_stmt.columnText(0) orelse continue;
            const to_version = items_stmt.columnText(1) orelse continue;

            // Get to_version's data
            var data: []const u8 = "{}";
            var data_stmt: ?Statement = null;
            defer if (data_stmt) |*s| s.deinit();
            {
                var stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
                try stmt.bindText(1, to_version);
                if (try stmt.step()) {
                    data = stmt.columnText(0) orelse "{}";
                }
                data_stmt = stmt;
            }

            // Get current version id (parent for new version)
            var current_vid: ?[]const u8 = null;
            var cv_stmt: ?Statement = null;
            defer if (cv_stmt) |*s| s.deinit();
            {
                var stmt = try db.prepare("SELECT current_version_id FROM content_entries WHERE id = ?1");
                try stmt.bindText(1, entry_id);
                if (try stmt.step()) {
                    current_vid = stmt.columnText(0);
                }
                cv_stmt = stmt;
            }

            // Create new version
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

            // Update entry
            {
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET current_version_id = ?1, data = ?2, updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();

                try u_stmt.bindText(1, &new_vid);
                try u_stmt.bindText(2, data);
                try u_stmt.bindText(3, entry_id);

                _ = try u_stmt.step();
            }
        }
    }

    // 4. Update release status back to released
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'released', released_at = unixepoch(), reverted_at = NULL WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// Set a pending release to scheduled state with a target timestamp.
/// No execution -- just stores the state for future use.
pub fn scheduleRelease(db: *Db, release_id: []const u8, scheduled_for: i64) (Db.Error || ReleaseError)!void {
    var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
    const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
    if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;

    var u_stmt = try db.prepare(
        "UPDATE releases SET status = 'scheduled', scheduled_for = ?1 WHERE id = ?2",
    );
    defer u_stmt.deinit();
    try u_stmt.bindInt(1, scheduled_for);
    try u_stmt.bindText(2, release_id);
    _ = try u_stmt.step();
}

/// Create a pending (batch) release with a name.
pub fn createPendingRelease(db: *Db, name: []const u8, author_id: ?[]const u8) (Db.Error || error{OutOfMemory})![20]u8 {
    const release_id = generateReleaseId();

    var stmt = try db.prepare(
        \\INSERT INTO releases (id, name, status, author_id, created_at)
        \\VALUES (?1, ?2, 'pending', ?3, unixepoch())
    );
    defer stmt.deinit();
    try stmt.bindText(1, &release_id);
    try stmt.bindText(2, name);
    if (author_id) |aid| try stmt.bindText(3, aid) else try stmt.bindNull(3);
    _ = try stmt.step();

    return release_id;
}

/// Add an entry to a pending release. Uses INSERT OR REPLACE so
/// re-adding the same entry updates the version references.
/// Reads from_version (published_version_id) and to_version (current_version_id)
/// directly from the content_entries table -- callers never supply these.
pub fn addToRelease(
    db: *Db,
    release_id: []const u8,
    entry_id: []const u8,
    fields: ?[]const u8,
) (Db.Error || ReleaseError)!void {
    // Validate release is pending
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    // Always read version refs from content_entries -- single source of truth
    var e_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1",
    );
    defer e_stmt.deinit();
    try e_stmt.bindText(1, entry_id);
    if (!try e_stmt.step()) return ReleaseError.ReleaseNotFound;
    const to_version = e_stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
    const from_version = e_stmt.columnText(1);

    var stmt = try db.prepare(
        \\INSERT OR REPLACE INTO release_entries (release_id, entry_id, from_version_id, to_version_id, selected_fields)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    try stmt.bindText(2, entry_id);
    if (from_version) |fv| try stmt.bindText(3, fv) else try stmt.bindNull(3);
    try stmt.bindText(4, to_version);
    if (fields) |f| try stmt.bindText(5, f) else try stmt.bindNull(5);
    _ = try stmt.step();
}

/// Remove an entry from a pending release.
pub fn removeFromRelease(db: *Db, release_id: []const u8, entry_id: []const u8) (Db.Error || ReleaseError)!void {
    // Validate release is pending
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    var stmt = try db.prepare(
        "DELETE FROM release_entries WHERE release_id = ?1 AND entry_id = ?2",
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    try stmt.bindText(2, entry_id);
    _ = try stmt.step();
}

/// Archive a release (any status except pending). Archived releases are hidden
/// from the list by default but can still be viewed directly.
pub fn archiveRelease(db: *Db, release_id: []const u8) (Db.Error || ReleaseError)!void {
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    var stmt = try db.prepare(
        "UPDATE releases SET status = 'archived' WHERE id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    _ = try stmt.step();
}

/// Collect unique collaborators between from_version and to_version for an entry.
/// Returns a JSON array like [{"id":"u1","email":"a@b.com","name":"Alice"},{"id":"u2","email":"c@d.com","name":""}].
/// Includes all version authors in the range, plus the publisher who triggered the release.
fn collectCollaborators(
    allocator: Allocator,
    db: *Db,
    entry_id: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    publisher_id: ?[]const u8,
) !?[]const u8 {
    // Get the created_at of from_version (0 if null = first publish, include all)
    var from_time: i64 = 0;
    if (from_version) |fv| {
        var t_stmt = try db.prepare("SELECT created_at FROM content_versions WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, fv);
        if (try t_stmt.step()) {
            from_time = t_stmt.columnInt(0);
        }
    }

    // Get to_version's created_at as upper bound
    var to_time: i64 = std.math.maxInt(i32);
    {
        var t_stmt = try db.prepare("SELECT created_at FROM content_versions WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, to_version);
        if (try t_stmt.step()) {
            to_time = t_stmt.columnInt(0);
        }
    }

    const Collab = struct { id: []const u8, email: []const u8, name: []const u8 };
    var collabs: std.ArrayListUnmanaged(Collab) = .{};
    defer {
        for (collabs.items) |c| {
            allocator.free(c.id);
            allocator.free(c.email);
            allocator.free(c.name);
        }
        collabs.deinit(allocator);
    }

    // Collect unique authors from versions in the range
    {
        var stmt = try db.prepare(
            \\SELECT DISTINCT ev.author_id, u.email, u.display_name
            \\FROM content_versions ev
            \\JOIN users u ON u.id = ev.author_id
            \\WHERE ev.entry_id = ?1
            \\  AND ev.author_id IS NOT NULL
            \\  AND ev.created_at > ?2
            \\  AND ev.created_at <= ?3
        );
        defer stmt.deinit();
        try stmt.bindText(1, entry_id);
        try stmt.bindInt(2, from_time);
        try stmt.bindInt(3, to_time);

        while (try stmt.step()) {
            const aid = stmt.columnText(0) orelse continue;
            const email = stmt.columnText(1) orelse continue;
            const name = stmt.columnText(2) orelse "";

            try collabs.append(allocator, .{
                .id = try allocator.dupe(u8, aid),
                .email = try allocator.dupe(u8, email),
                .name = try allocator.dupe(u8, name),
            });
        }
    }

    // Add publisher if not already present
    if (publisher_id) |pid| {
        var exists = false;
        for (collabs.items) |c| {
            if (std.mem.eql(u8, c.id, pid)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            var pu_stmt = try db.prepare("SELECT email, display_name FROM users WHERE id = ?1");
            defer pu_stmt.deinit();
            try pu_stmt.bindText(1, pid);
            if (try pu_stmt.step()) {
                if (pu_stmt.columnText(0)) |email| {
                    const name = pu_stmt.columnText(1) orelse "";
                    try collabs.append(allocator, .{
                        .id = try allocator.dupe(u8, pid),
                        .email = try allocator.dupe(u8, email),
                        .name = try allocator.dupe(u8, name),
                    });
                }
            }
        }
    }

    if (collabs.items.len == 0) return null;

    // Serialize to JSON
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('[');
    for (collabs.items, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, c.id);
        try w.writeAll("\",\"email\":\"");
        try writeEscaped(w, c.email);
        try w.writeAll("\",\"name\":\"");
        try writeEscaped(w, c.name);
        try w.writeAll("\"}");
    }
    try w.writeByte(']');

    return try buf.toOwnedSlice(allocator);
}

/// Publish a batch release: for each item, set entry status to 'published',
/// then mark release as 'released'.
pub fn publishBatchRelease(allocator: Allocator, db: *Db, release_id: []const u8) !void {
    // Validate release is pending
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    // Fetch release author
    var release_author_id: ?[]const u8 = null;
    {
        var a_stmt = try db.prepare("SELECT author_id FROM releases WHERE id = ?1");
        defer a_stmt.deinit();
        try a_stmt.bindText(1, release_id);
        if (try a_stmt.step()) {
            if (a_stmt.columnText(0)) |aid| {
                release_author_id = try allocator.dupe(u8, aid);
            }
        }
    }
    defer if (release_author_id) |a| allocator.free(a);

    // For each item: apply to_version data and set status/published_version_id
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.to_version_id, ev.data_json, ri.selected_fields, ri.from_version_id
            \\FROM release_entries ri
            \\JOIN content_versions ev ON ev.id = ri.to_version_id
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const eid = items_stmt.columnText(0) orelse continue;
            const to_vid = items_stmt.columnText(1) orelse continue;
            const to_data = items_stmt.columnText(2) orelse continue;
            const fields = items_stmt.columnText(3);
            const from_vid = items_stmt.columnText(4);

            if (fields) |fields_json| {
                // Partial publish: merge selected fields into published version
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, fields_json, .{}) catch continue;
                defer parsed.deinit();

                if (parsed.value != .array) continue;

                const arr = parsed.value.array;
                var names = allocator.alloc([]const u8, arr.items.len) catch continue;
                defer allocator.free(names);
                var count: usize = 0;

                for (arr.items) |item| {
                    if (item == .string) {
                        names[count] = item.string;
                        count += 1;
                    }
                }
                if (count == 0) continue;
                const field_names = names[0..count];

                // Get current published data
                const published_data = getPublishedData(allocator, db, eid) catch continue orelse continue;
                defer allocator.free(published_data);

                // Merge: published + selected fields from to_version data
                const merged_data = mergeJsonFields(allocator, published_data, to_data, field_names) catch continue;
                defer allocator.free(merged_data);

                // Collect collaborators from version chain
                const collab_json = collectCollaborators(
                    allocator,
                    db,
                    eid,
                    from_vid,
                    to_vid,
                    release_author_id,
                ) catch null;
                defer if (collab_json) |c| allocator.free(c);

                // Create new version with merged data, author, and collaborators
                const new_vid = id_gen.generateVersionId();
                {
                    var v_stmt = try db.prepare(
                        \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, version_type, collaborators)
                        \\VALUES (?1, ?2, ?3, ?4, ?5, 'published', ?6)
                    );
                    defer v_stmt.deinit();
                    try v_stmt.bindText(1, &new_vid);
                    try v_stmt.bindText(2, eid);
                    try v_stmt.bindText(3, to_vid);
                    try v_stmt.bindText(4, merged_data);
                    try v_stmt.bindNull(5);
                    if (collab_json) |cj| try v_stmt.bindText(6, cj) else try v_stmt.bindNull(6);
                    _ = try v_stmt.step();
                }

                // Update release_entries.to_version to point to the new published version
                {
                    var ri_stmt = try db.prepare(
                        "UPDATE release_entries SET to_version_id = ?1 WHERE release_id = ?2 AND entry_id = ?3",
                    );
                    defer ri_stmt.deinit();
                    try ri_stmt.bindText(1, &new_vid);
                    try ri_stmt.bindText(2, release_id);
                    try ri_stmt.bindText(3, eid);
                    _ = try ri_stmt.step();
                }

                // Determine status: compare merged (new published) vs current draft
                var cur_stmt2 = try db.prepare(
                    \\SELECT ev.data_json FROM content_entries e
                    \\JOIN content_versions ev ON ev.id = e.current_version_id
                    \\WHERE e.id = ?1
                );
                defer cur_stmt2.deinit();
                try cur_stmt2.bindText(1, eid);
                const still_changed = if (try cur_stmt2.step())
                    if (cur_stmt2.columnText(0)) |cur_data|
                        !std.mem.eql(u8, cur_data, merged_data)
                    else
                        true
                else
                    true;

                const new_status: []const u8 = if (still_changed) "changed" else "published";
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET status = ?1, published_version_id = ?2,
                    \\published_at = unixepoch(), updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, new_status);
                try u_stmt.bindText(2, &new_vid);
                try u_stmt.bindText(3, eid);
                _ = try u_stmt.step();

                try mirrorPublishedState(db, eid, &new_vid, new_status, release_author_id);
            } else {
                // Full publish: set published_version_id, determine status
                var cur_stmt2 = try db.prepare(
                    \\SELECT ev.data_json FROM content_entries e
                    \\JOIN content_versions ev ON ev.id = e.current_version_id
                    \\WHERE e.id = ?1
                );
                defer cur_stmt2.deinit();
                try cur_stmt2.bindText(1, eid);
                const still_changed = if (try cur_stmt2.step())
                    if (cur_stmt2.columnText(0)) |cur_data|
                        !std.mem.eql(u8, cur_data, to_data)
                    else
                        false
                else
                    false;

                const new_status: []const u8 = if (still_changed) "changed" else "published";
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET status = ?1, published_version_id = ?2,
                    \\published_at = unixepoch(), updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, new_status);
                try u_stmt.bindText(2, to_vid);
                try u_stmt.bindText(3, eid);
                _ = try u_stmt.step();

                try mirrorPublishedState(db, eid, to_vid, new_status, release_author_id);

                // Mark the published version's type and store collaborators
                {
                    const collab_json = collectCollaborators(
                        allocator,
                        db,
                        eid,
                        from_vid,
                        to_vid,
                        release_author_id,
                    ) catch null;
                    defer if (collab_json) |c| allocator.free(c);

                    var vt_stmt = try db.prepare(
                        "UPDATE content_versions SET version_type = 'published', collaborators = ?1 WHERE id = ?2",
                    );
                    defer vt_stmt.deinit();
                    if (collab_json) |cj| try vt_stmt.bindText(1, cj) else try vt_stmt.bindNull(1);
                    try vt_stmt.bindText(2, to_vid);
                    _ = try vt_stmt.step();
                }
            }
        }
    }

    // Mark release as released
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'released', released_at = unixepoch() WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// List releases with optional status filter.
pub fn listReleases(allocator: Allocator, db: *Db, opts: struct {
    status: ?[]const u8 = null,
    limit: u32 = 50,
    include_archived: bool = false,
}) ![]ReleaseListItem {
    // Build query dynamically based on filter
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(
        \\SELECT r.id, r.name, r.status,
        \\  COUNT(ri.entry_id) as item_count,
        \\  u.email, r.created_at
        \\FROM releases r
        \\LEFT JOIN release_entries ri ON ri.release_id = r.id
        \\LEFT JOIN users u ON u.id = r.author_id
        \\WHERE r.name IS NOT NULL
    );

    if (opts.status) |_| {
        try w.writeAll(" AND r.status = ?1");
    }

    if (!opts.include_archived) {
        try w.writeAll(" AND r.status != 'archived'");
    }

    try w.writeAll(" GROUP BY r.id ORDER BY r.created_at DESC");
    try w.print(" LIMIT {d}", .{opts.limit});

    const sql = try buf.toOwnedSlice(allocator);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    if (opts.status) |s| try stmt.bindText(1, s);

    var results: std.ArrayList(ReleaseListItem) = .{};
    errdefer results.deinit(allocator);

    while (try stmt.step()) {
        const item = ReleaseListItem{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .name = try allocator.dupe(u8, stmt.columnText(1) orelse "(unnamed)"),
            .status = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
            .item_count = stmt.columnInt(3),
            .author_email = if (stmt.columnText(4)) |e| try allocator.dupe(u8, e) else null,
            .created_at = stmt.columnInt(5),
        };
        try results.append(allocator, item);
    }

    return results.toOwnedSlice(allocator);
}

/// Get full release detail (header + items with entry info).
pub fn getRelease(allocator: Allocator, db: *Db, release_id: []const u8) !?ReleaseDetail {
    // Fetch header
    var h_stmt = try db.prepare(
        \\SELECT r.id, COALESCE(r.name, ''), r.status, u.email,
        \\  r.created_at, r.released_at, r.scheduled_for, r.reverted_at
        \\FROM releases r
        \\LEFT JOIN users u ON u.id = r.author_id
        \\WHERE r.id = ?1
    );
    defer h_stmt.deinit();
    try h_stmt.bindText(1, release_id);
    if (!try h_stmt.step()) return null;

    const id = try allocator.dupe(u8, h_stmt.columnText(0) orelse "");
    const name = try allocator.dupe(u8, h_stmt.columnText(1) orelse "");
    const status = try allocator.dupe(u8, h_stmt.columnText(2) orelse "");
    const author_email = if (h_stmt.columnText(3)) |e| try allocator.dupe(u8, e) else null;
    const created_at = h_stmt.columnInt(4);
    const released_at: ?i64 = if (h_stmt.columnIsNull(5)) null else h_stmt.columnInt(5);
    const scheduled_for: ?i64 = if (h_stmt.columnIsNull(6)) null else h_stmt.columnInt(6);
    const reverted_at: ?i64 = if (h_stmt.columnIsNull(7)) null else h_stmt.columnInt(7);

    // Fetch items
    var i_stmt = try db.prepare(
        \\SELECT ri.entry_id, COALESCE(e.title, '(untitled)'), COALESCE(e.status, ''),
        \\  COALESCE(e.content_type_id, 'post'), ri.from_version_id, ri.to_version_id, ri.selected_fields
        \\FROM release_entries ri
        \\LEFT JOIN content_entries e ON e.id = ri.entry_id
        \\WHERE ri.release_id = ?1
    );
    defer i_stmt.deinit();
    try i_stmt.bindText(1, release_id);

    var items: std.ArrayList(ReleaseDetailItem) = .{};
    errdefer items.deinit(allocator);

    while (try i_stmt.step()) {
        try items.append(allocator, .{
            .entry_id = try allocator.dupe(u8, i_stmt.columnText(0) orelse ""),
            .entry_title = try allocator.dupe(u8, i_stmt.columnText(1) orelse "(untitled)"),
            .entry_status = try allocator.dupe(u8, i_stmt.columnText(2) orelse ""),
            .content_type_id = try allocator.dupe(u8, i_stmt.columnText(3) orelse "post"),
            .from_version = if (i_stmt.columnText(4)) |v| try allocator.dupe(u8, v) else null,
            .to_version = try allocator.dupe(u8, i_stmt.columnText(5) orelse ""),
            .fields = if (i_stmt.columnText(6)) |f| try allocator.dupe(u8, f) else null,
        });
    }

    return ReleaseDetail{
        .id = id,
        .name = name,
        .status = status,
        .author_email = author_email,
        .created_at = created_at,
        .released_at = released_at,
        .scheduled_for = scheduled_for,
        .reverted_at = reverted_at,
        .items = try items.toOwnedSlice(allocator),
    };
}

/// List pending releases (lightweight, for dropdown).
pub fn listPendingReleases(allocator: Allocator, db: *Db) ![]PendingReleaseOption {
    var stmt = try db.prepare(
        "SELECT id, name FROM releases WHERE status = 'pending' ORDER BY created_at DESC",
    );
    defer stmt.deinit();

    var results: std.ArrayList(PendingReleaseOption) = .{};
    errdefer results.deinit(allocator);

    while (try stmt.step()) {
        try results.append(allocator, .{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .name = try allocator.dupe(u8, stmt.columnText(1) orelse "(unnamed)"),
        });
    }

    return results.toOwnedSlice(allocator);
}

/// Get IDs of pending releases that contain a given entry.
pub fn getEntryPendingReleaseIds(allocator: Allocator, db: *Db, entry_id: []const u8) ![][]const u8 {
    var stmt = try db.prepare(
        \\SELECT ri.release_id FROM release_entries ri
        \\JOIN releases r ON r.id = ri.release_id
        \\WHERE ri.entry_id = ?1 AND r.status = 'pending'
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);

    var results: std.ArrayList([]const u8) = .{};
    errdefer results.deinit(allocator);
    while (try stmt.step()) {
        try results.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
    }
    return results.toOwnedSlice(allocator);
}

/// Get pending release items for an entry, with release name and field list.
pub fn getEntryPendingReleaseFields(allocator: Allocator, db: *Db, entry_id: []const u8) ![]const EntryReleaseFieldInfo {
    var stmt = try db.prepare(
        \\SELECT ri.release_id, r.name, ri.selected_fields, r.scheduled_for
        \\FROM release_entries ri
        \\JOIN releases r ON r.id = ri.release_id
        \\WHERE ri.entry_id = ?1 AND (r.status = 'pending' OR r.status = 'scheduled') AND r.name IS NOT NULL
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);

    var results: std.ArrayList(EntryReleaseFieldInfo) = .{};
    errdefer results.deinit(allocator);
    while (try stmt.step()) {
        try results.append(allocator, .{
            .release_id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .release_name = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .fields = if (stmt.columnText(2)) |f| try allocator.dupe(u8, f) else null,
            .scheduled_for = if (stmt.columnIsNull(3)) null else stmt.columnInt(3),
        });
    }
    return results.toOwnedSlice(allocator);
}

/// A single field conflict in a release
pub const ReleaseFieldConflict = struct {
    entry_id: []const u8,
    entry_title: []const u8,
    field_name: []const u8,
    release_value: []const u8,
    current_value: []const u8,
};

/// Detect conflicts for a release: fields where from_version_id != current published_version_id.
/// Returns list of per-field conflicts showing release vs current published values.
pub fn detectReleaseConflicts(allocator: Allocator, db: *Db, release_id: []const u8) ![]const ReleaseFieldConflict {
    // For each release_entries row with selected_fields, compare from_version_id vs published_version_id
    var items_stmt = try db.prepare(
        \\SELECT ri.entry_id, COALESCE(e.title, '(untitled)'),
        \\  ri.from_version_id, e.published_version_id,
        \\  ri.selected_fields, ri.to_version_id
        \\FROM release_entries ri
        \\JOIN content_entries e ON e.id = ri.entry_id
        \\WHERE ri.release_id = ?1
    );
    defer items_stmt.deinit();
    try items_stmt.bindText(1, release_id);

    var conflicts: std.ArrayList(ReleaseFieldConflict) = .{};
    errdefer conflicts.deinit(allocator);

    while (try items_stmt.step()) {
        const entry_id = items_stmt.columnText(0) orelse continue;
        const entry_title = items_stmt.columnText(1) orelse "(untitled)";
        const from_vid = items_stmt.columnText(2);
        const published_vid = items_stmt.columnText(3);

        // No conflict if from_version matches current published version
        if (from_vid) |fv| {
            if (published_vid) |pv| {
                if (std.mem.eql(u8, fv, pv)) continue;
            } else continue; // from_vid set but no published — shouldn't happen, skip
        } else {
            if (published_vid == null) continue; // Both null — first publish, no conflict
            // from_vid null but published exists — entry was published after staging
        }

        const fields_json = items_stmt.columnText(4);
        const to_vid = items_stmt.columnText(5) orelse continue;

        // Get the release's snapshot data (to_version)
        var to_data: []const u8 = "{}";
        var to_stmt: ?Statement = null;
        defer if (to_stmt) |*s| s.deinit();
        {
            var stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
            try stmt.bindText(1, to_vid);
            if (try stmt.step()) {
                to_data = stmt.columnText(0) orelse "{}";
            }
            to_stmt = stmt;
        }

        // Get current published data
        const pub_data = getPublishedData(allocator, db, entry_id) catch continue orelse continue;
        defer allocator.free(pub_data);

        if (fields_json) |fj| {
            // Partial publish — compare per-field
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, fj, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .array) continue;

            const to_parsed = std.json.parseFromSlice(std.json.Value, allocator, to_data, .{}) catch continue;
            defer to_parsed.deinit();
            const to_obj = if (to_parsed.value == .object) to_parsed.value.object else continue;

            const pub_parsed = std.json.parseFromSlice(std.json.Value, allocator, pub_data, .{}) catch continue;
            defer pub_parsed.deinit();
            const pub_obj = if (pub_parsed.value == .object) pub_parsed.value.object else continue;

            // Get from_version data for comparison
            var from_data: []const u8 = "{}";
            var from_alloc: ?[]const u8 = null;
            defer if (from_alloc) |fa| allocator.free(fa);
            if (from_vid) |fv| {
                var fstmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
                defer fstmt.deinit();
                try fstmt.bindText(1, fv);
                if (try fstmt.step()) {
                    if (fstmt.columnText(0)) |fd| {
                        from_alloc = try allocator.dupe(u8, fd);
                        from_data = from_alloc.?;
                    }
                }
            }
            const from_parsed = std.json.parseFromSlice(std.json.Value, allocator, from_data, .{}) catch continue;
            defer from_parsed.deinit();
            const from_obj = if (from_parsed.value == .object) from_parsed.value.object else continue;

            for (parsed.value.array.items) |field_item| {
                if (field_item != .string) continue;
                const fname = field_item.string;

                // Get values: from_version[field], published[field], to_version[field]
                const from_val = from_obj.get(fname);
                const pub_val = pub_obj.get(fname);

                // Conflict exists if the published value has changed since staging
                // (from_version[field] != current_published[field])
                const from_str = if (from_val) |v| stringifyJsonValue(allocator, v) catch null else null;
                defer if (from_str) |s| allocator.free(s);
                const pub_str = if (pub_val) |v| stringifyJsonValue(allocator, v) catch null else null;
                defer if (pub_str) |s| allocator.free(s);

                const from_s = from_str orelse "";
                const pub_s = pub_str orelse "";
                if (std.mem.eql(u8, from_s, pub_s)) continue;

                // This field has a conflict
                const release_val = if (to_obj.get(fname)) |v| stringifyJsonValue(allocator, v) catch try allocator.dupe(u8, "?") else try allocator.dupe(u8, "(not set)");
                try conflicts.append(allocator, .{
                    .entry_id = try allocator.dupe(u8, entry_id),
                    .entry_title = try allocator.dupe(u8, entry_title),
                    .field_name = try allocator.dupe(u8, fname),
                    .release_value = release_val,
                    .current_value = try allocator.dupe(u8, pub_s),
                });
            }
        } else {
            // Full publish — just note a generic conflict for the whole entry
            try conflicts.append(allocator, .{
                .entry_id = try allocator.dupe(u8, entry_id),
                .entry_title = try allocator.dupe(u8, entry_title),
                .field_name = try allocator.dupe(u8, "(full entry)"),
                .release_value = try allocator.dupe(u8, "(full snapshot)"),
                .current_value = try allocator.dupe(u8, "(modified since staging)"),
            });
        }
    }

    return conflicts.toOwnedSlice(allocator);
}

/// Stringify a JSON value for display (truncated for readability)
fn stringifyJsonValue(allocator: Allocator, value: std.json.Value) ![]const u8 {
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

/// Publish a batch release with optional field skip list.
/// skip_fields_json: JSON array of field names to exclude from merge, or null.
pub fn publishBatchReleaseWithSkips(allocator: Allocator, db: *Db, release_id: []const u8, skip_fields_json: ?[]const u8) !void {
    // Parse skip fields if provided
    var skip_set: ?std.json.ArrayHashMap(void) = null;
    defer if (skip_set) |*ss| ss.map.deinit(allocator);

    if (skip_fields_json) |sfj| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, sfj, .{}) catch null;
        defer if (parsed) |p| p.deinit();

        if (parsed) |p| {
            if (p.value == .array) {
                var set: std.json.ArrayHashMap(void) = .{};
                for (p.value.array.items) |item| {
                    if (item == .string) {
                        set.map.put(allocator, item.string, {}) catch continue;
                    }
                }
                skip_set = set;
            }
        }
    }

    // Validate release is pending
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "pending") and !std.mem.eql(u8, status, "scheduled")) return ReleaseError.InvalidReleaseStatus;
    }

    // Fetch release author
    var release_author_id: ?[]const u8 = null;
    {
        var a_stmt = try db.prepare("SELECT author_id FROM releases WHERE id = ?1");
        defer a_stmt.deinit();
        try a_stmt.bindText(1, release_id);
        if (try a_stmt.step()) {
            if (a_stmt.columnText(0)) |aid| {
                release_author_id = try allocator.dupe(u8, aid);
            }
        }
    }
    defer if (release_author_id) |a| allocator.free(a);

    // For each item: apply to_version data and set status/published_version_id
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.to_version_id, ev.data_json, ri.selected_fields, ri.from_version_id
            \\FROM release_entries ri
            \\JOIN content_versions ev ON ev.id = ri.to_version_id
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const eid = items_stmt.columnText(0) orelse continue;
            const to_vid = items_stmt.columnText(1) orelse continue;
            const to_data = items_stmt.columnText(2) orelse continue;
            const fields = items_stmt.columnText(3);
            const from_vid = items_stmt.columnText(4);

            if (fields) |fields_json| {
                // Partial publish: merge selected fields into published version
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, fields_json, .{}) catch continue;
                defer parsed.deinit();

                if (parsed.value != .array) continue;

                const arr = parsed.value.array;
                var names = allocator.alloc([]const u8, arr.items.len) catch continue;
                defer allocator.free(names);
                var count: usize = 0;

                for (arr.items) |item| {
                    if (item == .string) {
                        // Skip fields in skip_set
                        if (skip_set) |ss| {
                            if (ss.map.contains(item.string)) continue;
                        }
                        names[count] = item.string;
                        count += 1;
                    }
                }
                if (count == 0) continue;
                const field_names = names[0..count];

                // Get current published data
                const published_data = getPublishedData(allocator, db, eid) catch continue orelse continue;
                defer allocator.free(published_data);

                // Merge: published + selected fields from to_version data
                const merged_data = mergeJsonFields(allocator, published_data, to_data, field_names) catch continue;
                defer allocator.free(merged_data);

                // Collect collaborators
                const collab_json = collectCollaborators(allocator, db, eid, from_vid, to_vid, release_author_id) catch null;
                defer if (collab_json) |c| allocator.free(c);

                // Create new version with merged data
                const new_vid = id_gen.generateVersionId();
                {
                    var v_stmt = try db.prepare(
                        \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, version_type, collaborators)
                        \\VALUES (?1, ?2, ?3, ?4, ?5, 'published', ?6)
                    );
                    defer v_stmt.deinit();
                    try v_stmt.bindText(1, &new_vid);
                    try v_stmt.bindText(2, eid);
                    try v_stmt.bindText(3, to_vid);
                    try v_stmt.bindText(4, merged_data);
                    try v_stmt.bindNull(5);
                    if (collab_json) |cj| try v_stmt.bindText(6, cj) else try v_stmt.bindNull(6);
                    _ = try v_stmt.step();
                }

                // Update release_entries.to_version
                {
                    var ri_stmt = try db.prepare(
                        "UPDATE release_entries SET to_version_id = ?1 WHERE release_id = ?2 AND entry_id = ?3",
                    );
                    defer ri_stmt.deinit();
                    try ri_stmt.bindText(1, &new_vid);
                    try ri_stmt.bindText(2, release_id);
                    try ri_stmt.bindText(3, eid);
                    _ = try ri_stmt.step();
                }

                // Determine status
                var cur_stmt2 = try db.prepare(
                    \\SELECT ev.data_json FROM content_entries e
                    \\JOIN content_versions ev ON ev.id = e.current_version_id
                    \\WHERE e.id = ?1
                );
                defer cur_stmt2.deinit();
                try cur_stmt2.bindText(1, eid);
                const still_changed = if (try cur_stmt2.step())
                    if (cur_stmt2.columnText(0)) |cur_data|
                        !std.mem.eql(u8, cur_data, merged_data)
                    else
                        true
                else
                    true;

                const new_status: []const u8 = if (still_changed) "changed" else "published";
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET status = ?1, published_version_id = ?2,
                    \\published_at = unixepoch(), updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, new_status);
                try u_stmt.bindText(2, &new_vid);
                try u_stmt.bindText(3, eid);
                _ = try u_stmt.step();

                try mirrorPublishedState(db, eid, &new_vid, new_status, release_author_id);
            } else {
                // Full publish path (same as original publishBatchRelease)
                var cur_stmt2 = try db.prepare(
                    \\SELECT ev.data_json FROM content_entries e
                    \\JOIN content_versions ev ON ev.id = e.current_version_id
                    \\WHERE e.id = ?1
                );
                defer cur_stmt2.deinit();
                try cur_stmt2.bindText(1, eid);
                const still_changed = if (try cur_stmt2.step())
                    if (cur_stmt2.columnText(0)) |cur_data|
                        !std.mem.eql(u8, cur_data, to_data)
                    else
                        false
                else
                    false;

                const new_status: []const u8 = if (still_changed) "changed" else "published";
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET status = ?1, published_version_id = ?2,
                    \\published_at = unixepoch(), updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, new_status);
                try u_stmt.bindText(2, to_vid);
                try u_stmt.bindText(3, eid);
                _ = try u_stmt.step();

                try mirrorPublishedState(db, eid, to_vid, new_status, release_author_id);

                {
                    const collab_json = collectCollaborators(allocator, db, eid, from_vid, to_vid, release_author_id) catch null;
                    defer if (collab_json) |c| allocator.free(c);
                    var vt_stmt = try db.prepare(
                        "UPDATE content_versions SET version_type = 'published', collaborators = ?1 WHERE id = ?2",
                    );
                    defer vt_stmt.deinit();
                    if (collab_json) |cj| try vt_stmt.bindText(1, cj) else try vt_stmt.bindNull(1);
                    try vt_stmt.bindText(2, to_vid);
                    _ = try vt_stmt.step();
                }
            }
        }
    }

    // Mark release as released
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'released', released_at = unixepoch() WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
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

test "core release: public API coverage" {
    _ = getEntryVersionId;
    _ = getPublishedData;
    _ = discardToPublished;
    _ = mergeJsonFields;
    _ = publishEntry;
    _ = revertRelease;
    _ = reReleaseReverted;
    _ = scheduleRelease;
    _ = createPendingRelease;
    _ = addToRelease;
    _ = removeFromRelease;
    _ = archiveRelease;
    _ = publishBatchRelease;
    _ = publishBatchReleaseWithSkips;
    _ = detectReleaseConflicts;
    _ = listReleases;
    _ = getRelease;
    _ = listPendingReleases;
    _ = getEntryPendingReleaseIds;
    _ = getEntryPendingReleaseFields;
}
