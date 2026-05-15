//! Basic count queries against the media table: total, unreviewed (synced),
//! and unsorted (not in any term of a taxonomy).

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// Count media records. Replaces the previous 8-way branch with a single
/// dynamic builder. Note: `visibility` and `mime_type` use `=` (exact match),
/// not `LIKE` — preserving the original semantics. For wildcard mime matching
/// callers should use `listMedia` with `mime_patterns` (then `.len`).
pub fn countMedia(db: *Db, opts: struct {
    visibility: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    search: ?[]const u8 = null,
}) !u32 {
    // The simplest hot path: no filters at all.
    if (opts.visibility == null and opts.mime_type == null and opts.search == null) {
        var stmt = try db.prepare("SELECT COUNT(*) FROM media");
        defer stmt.deinit();
        _ = try stmt.step();
        return @intCast(stmt.columnInt(0));
    }

    // SQL is bounded (max ~100 chars: literal keywords + `?N` placeholders
    // only — user values are bound separately). Fixed buffer is safe per
    // the CLAUDE.md exception (size-bounded, no user-controlled content).
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("SELECT COUNT(*) FROM media WHERE 1=1");

    var bind_idx: u32 = 1;
    if (opts.visibility) |_| {
        try w.print(" AND visibility = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.mime_type) |_| {
        try w.print(" AND mime_type = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.search) |_| {
        try w.print(" AND filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    var stmt = try db.prepare(fbs.getWritten());
    defer stmt.deinit();

    var b: u32 = 1;
    if (opts.visibility) |v| {
        try stmt.bindText(@intCast(b), v);
        b += 1;
    }
    if (opts.mime_type) |m| {
        try stmt.bindText(@intCast(b), m);
        b += 1;
    }
    if (opts.search) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count unreviewed (synced) media with optional search and date filters.
pub fn countUnreviewedMedia(allocator: Allocator, db: *Db, search_term: ?[]const u8, year: ?u16, month: ?u8) !u32 {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);
    try w.writeAll("SELECT COUNT(*) FROM media WHERE json_extract(data, '$.synced') = 1");

    var bind_idx: u32 = 1;
    try common.appendSearchFilter(w, search_term, &bind_idx, "");
    try common.appendDateFilters(w, year, month, &bind_idx, "");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    try common.bindSearchFilter(&stmt, search_term, &b);
    try common.bindDateFilters(&stmt, year, month, &b);

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count media not in any term of a given taxonomy.
pub fn countUnsortedMedia(db: *Db, taxonomy_id: []const u8) !u32 {
    var stmt = try db.prepare(
        \\SELECT COUNT(*) FROM media WHERE id NOT IN (
        \\  SELECT mt.media_id FROM media_terms mt
        \\  JOIN terms t ON t.id = mt.term_id
        \\  WHERE t.taxonomy_id = ?1
        \\)
    );
    defer stmt.deinit();
    try stmt.bindText(1, taxonomy_id);
    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}
