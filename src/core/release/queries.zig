//! Read-only release queries: list, get detail, list pending, get pending
//! release ids/fields for an entry. Used by the admin UI sidebar and list.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;

const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const PendingReleaseOption = types.PendingReleaseOption;
const ReleaseListItem = types.ReleaseListItem;
const ReleaseDetailItem = types.ReleaseDetailItem;
const ReleaseDetail = types.ReleaseDetail;
const EntryReleaseFieldInfo = types.EntryReleaseFieldInfo;

/// List releases with optional status filter.
pub fn listReleases(allocator: Allocator, db: *Db, opts: struct {
    status: ?[]const u8 = null,
    limit: u32 = 50,
    include_archived: bool = false,
}) ![]ReleaseListItem {
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
