//! Context-aware counts: count media within the *current* filter state.
//! Used by the media sidebar to show how many items each tag/folder/bucket
//! would contain given the active search/year/month/mime filters.
//!
//! Two filter shapes appear here:
//!   - `countTagInContext`, `countFolderInContext` start `FROM media_terms mt`
//!     so each filter wraps the media check in `mt.media_id IN (SELECT id
//!     FROM media WHERE ...)`. The `common.append*` helpers don't fit cleanly
//!     here; the SQL is laid out inline.
//!   - `countAllInContext`, `countUnsortedInContext` start `FROM media` and
//!     CAN use the shared helpers.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const taxonomy = @import("taxonomy");
const common = @import("common.zig");
const count_basic = @import("count_basic.zig");

const Allocator = std.mem.Allocator;

/// Count media with a specific tag, filtered by active folder, other tags,
/// and mime patterns. Used for contextual sidebar counts.
pub fn countTagInContext(
    allocator: Allocator,
    db: *Db,
    tag_id: []const u8,
    folder_id: ?[]const u8,
    required_tag_ids: []const []const u8,
    search_term: ?[]const u8,
    year: ?u16,
    month: ?u8,
    mime_patterns_str: ?[]const u8,
) !u32 {
    const mime_patterns = try common.getMimePatterns(allocator, mime_patterns_str);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    // No context filters -> simple count
    if (folder_id == null and required_tag_ids.len == 0 and search_term == null and year == null and month == null and mime_patterns.len == 0) {
        return taxonomy.countMediaInTerm(db, tag_id);
    }

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    var bind_idx: u32 = 1;

    // CTE for folder tree if folder is active
    if (folder_id != null) {
        try w.print("WITH RECURSIVE folder_tree(id) AS (SELECT id FROM terms WHERE id = ?{d}", .{bind_idx});
        bind_idx += 1;
        try w.writeAll(" UNION ALL SELECT t.id FROM terms t JOIN folder_tree ft ON t.parent_id = ft.id) ");
    }

    try w.print("SELECT COUNT(DISTINCT mt.media_id) FROM media_terms mt WHERE mt.term_id = ?{d}", .{bind_idx});
    bind_idx += 1;

    if (folder_id != null) {
        try w.writeAll(" AND mt.media_id IN (SELECT media_id FROM media_terms WHERE term_id IN (SELECT id FROM folder_tree))");
    }

    if (required_tag_ids.len > 0) {
        try w.writeAll(" AND mt.media_id IN (SELECT media_id FROM media_terms WHERE term_id IN (");
        for (0..required_tag_ids.len) |i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.print(") GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    if (search_term != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE filename LIKE ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    if (mime_patterns.len > 0) {
        try w.writeAll(" AND mt.media_id IN (SELECT id FROM media WHERE (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll("))");
    }

    if (year != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }
    if (month != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    if (folder_id) |fid| {
        try stmt.bindText(@intCast(b), fid);
        b += 1;
    }
    try stmt.bindText(@intCast(b), tag_id);
    b += 1;
    for (required_tag_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    if (required_tag_ids.len > 0) {
        try stmt.bindInt(@intCast(b), @intCast(required_tag_ids.len));
        b += 1;
    }
    try common.bindSearchFilter(&stmt, search_term, &b);
    try common.bindMimePatterns(&stmt, mime_patterns, &b);
    try common.bindDateFilters(&stmt, year, month, &b);

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count media in a folder's subtree, filtered by active tags (AND) and mime patterns.
pub fn countFolderInContext(
    allocator: Allocator,
    db: *Db,
    folder_id: []const u8,
    tag_ids: []const []const u8,
    search_term: ?[]const u8,
    year: ?u16,
    month: ?u8,
    mime_patterns_str: ?[]const u8,
) !u32 {
    const mime_patterns = try common.getMimePatterns(allocator, mime_patterns_str);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    if (tag_ids.len == 0 and search_term == null and year == null and month == null and mime_patterns.len == 0) {
        return taxonomy.countMediaInFolderRecursive(db, folder_id);
    }

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\WITH RECURSIVE folder_tree(id) AS (
        \\  SELECT id FROM terms WHERE id = ?1
        \\  UNION ALL
        \\  SELECT t.id FROM terms t JOIN folder_tree ft ON t.parent_id = ft.id
        \\)
        \\SELECT COUNT(DISTINCT mt.media_id) FROM media_terms mt
        \\WHERE mt.term_id IN (SELECT id FROM folder_tree)
    );

    var bind_idx: u32 = 2;

    if (tag_ids.len > 0) {
        try w.writeAll(" AND mt.media_id IN (SELECT media_id FROM media_terms WHERE term_id IN (");
        for (0..tag_ids.len) |i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.print(") GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }
    if (search_term != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE filename LIKE ?{d})", .{bind_idx});
        bind_idx += 1;
    }
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND mt.media_id IN (SELECT id FROM media WHERE (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll("))");
    }
    if (year != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }
    if (month != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    try stmt.bindText(@intCast(b), folder_id);
    b += 1;
    for (tag_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    if (tag_ids.len > 0) {
        try stmt.bindInt(@intCast(b), @intCast(tag_ids.len));
        b += 1;
    }
    try common.bindSearchFilter(&stmt, search_term, &b);
    try common.bindMimePatterns(&stmt, mime_patterns, &b);
    try common.bindDateFilters(&stmt, year, month, &b);

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count all media matching given tags (AND) and search term.
pub fn countAllInContext(
    allocator: Allocator,
    db: *Db,
    tag_ids: []const []const u8,
    search_term: ?[]const u8,
    year: ?u16,
    month: ?u8,
) !u32 {
    if (tag_ids.len == 0 and search_term == null and year == null and month == null) {
        return count_basic.countMedia(db, .{});
    }

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);
    try w.writeAll("SELECT COUNT(*) FROM media WHERE 1=1");
    var bind_idx: u32 = 1;

    if (tag_ids.len > 0) {
        try w.writeAll(" AND id IN (SELECT media_id FROM media_terms WHERE term_id IN (");
        for (0..tag_ids.len) |i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.print(") GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    // FROM is `media`, so we can use the shared helpers for the remaining clauses.
    try common.appendSearchFilter(w, search_term, &bind_idx, "");
    try common.appendDateFilters(w, year, month, &bind_idx, "");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    for (tag_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    if (tag_ids.len > 0) {
        try stmt.bindInt(@intCast(b), @intCast(tag_ids.len));
        b += 1;
    }
    try common.bindSearchFilter(&stmt, search_term, &b);
    try common.bindDateFilters(&stmt, year, month, &b);

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count media not in any folder (of the given taxonomy) that also match
/// all given tags (AND) and mime patterns.
pub fn countUnsortedInContext(
    allocator: Allocator,
    db: *Db,
    taxonomy_id: []const u8,
    tag_ids: []const []const u8,
    search_term: ?[]const u8,
    year: ?u16,
    month: ?u8,
    mime_patterns_str: ?[]const u8,
) !u32 {
    const mime_patterns = try common.getMimePatterns(allocator, mime_patterns_str);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    if (tag_ids.len == 0 and search_term == null and year == null and month == null and mime_patterns.len == 0) {
        return count_basic.countUnsortedMedia(db, taxonomy_id);
    }

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT COUNT(*) FROM media WHERE id NOT IN (
        \\  SELECT mt.media_id FROM media_terms mt
        \\  JOIN terms t ON t.id = mt.term_id
        \\  WHERE t.taxonomy_id = ?1
        \\)
    );

    var bind_idx: u32 = 2;

    if (tag_ids.len > 0) {
        try w.writeAll(" AND id IN (SELECT media_id FROM media_terms WHERE term_id IN (");
        for (0..tag_ids.len) |i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.print(") GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    // FROM is `media`, so the remaining filters use the shared helpers.
    try common.appendSearchFilter(w, search_term, &bind_idx, "");
    try common.appendMimePatterns(w, mime_patterns, &bind_idx, "");
    try common.appendDateFilters(w, year, month, &bind_idx, "");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    try stmt.bindText(@intCast(b), taxonomy_id);
    b += 1;
    for (tag_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    if (tag_ids.len > 0) {
        try stmt.bindInt(@intCast(b), @intCast(tag_ids.len));
        b += 1;
    }
    try common.bindSearchFilter(&stmt, search_term, &b);
    try common.bindMimePatterns(&stmt, mime_patterns, &b);
    try common.bindDateFilters(&stmt, year, month, &b);

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}
