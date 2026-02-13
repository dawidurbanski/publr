//! Media query and count functions.
//!
//! Extracted from media.zig. Provides list, count, and date-period
//! queries for media records, including folder/tag filtering.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;
const cms = @import("cms");
const media_mod = @import("media");
const taxonomy = @import("taxonomy");

const Allocator = std.mem.Allocator;

const MediaRecord = media_mod.MediaRecord;
const MediaListOptions = media_mod.MediaListOptions;

/// List media with optional filtering (supports mime_patterns for wildcard mime type matching)
pub fn listMedia(
    allocator: Allocator,
    db: *Db,
    opts: MediaListOptions,
) ![]MediaRecord {
    // Get mime patterns for filtering
    const mime_patterns = try opts.getMimePatterns(allocator);

    // If no mime_patterns, use the simpler cms.listWithMeta
    if (mime_patterns.len == 0) {
        return cms.listWithMeta(MediaRecord, allocator, db, .{
            .table = "media",
            .id_column = "id",
            .meta_table = "media_meta",
            .meta_fk = "media_id",
            .select_cols = "id, filename, mime_type, size, width, height, storage_key, visibility, hash, data, created_at, updated_at",
            .visibility = opts.visibility,
            .mime_type = opts.mime_type,
            .filename_search = opts.search,
            .limit = opts.limit,
            .offset = opts.offset,
            .order_by = opts.order_by,
            .order_dir = opts.order_dir,
            .meta_filters = opts.meta_filters,
            .parse_row = parseMediaRowFn,
        });
    }

    // Build custom query with mime_patterns support
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator,
        \\SELECT id, filename, mime_type, size, width, height,
        \\storage_key, visibility, hash, data, created_at, updated_at
        \\FROM media WHERE 1=1
    );

    var bind_idx: u32 = 1;

    const w = sql_buf.writer(allocator);

    // Visibility filter
    if (opts.visibility != null) {
        try w.print(" AND visibility = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // Search filter
    if (opts.search != null) {
        try w.print(" AND filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // Mime patterns filter (OR)
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll(")");
    }

    // Year filter
    if (opts.year != null) {
        try w.print(" AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // Month filter
    if (opts.month != null) {
        try w.print(" AND CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // ORDER BY
    try w.print(" ORDER BY {s} {s}", .{
        opts.order_by, if (opts.order_dir == .asc) "ASC" else "DESC",
    });

    // LIMIT
    if (opts.limit != null) {
        try w.print(" LIMIT ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // OFFSET
    if (opts.offset != null) {
        try w.print(" OFFSET ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    // Bind parameters
    var b: u32 = 1;
    if (opts.visibility) |v| {
        try stmt.bindText(@intCast(b), v);
        b += 1;
    }
    if (opts.search) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    if (opts.year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (opts.month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }
    if (opts.limit) |l| {
        try stmt.bindInt(@intCast(b), @intCast(l));
        b += 1;
    }
    if (opts.offset) |off| {
        try stmt.bindInt(@intCast(b), @intCast(off));
    }

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

fn parseMediaRowFn(allocator: Allocator, stmt: *Statement) !MediaRecord {
    return media_mod.parseMediaRow(allocator, stmt);
}

/// List media filtered by folder IDs (OR -- in any folder) and tag IDs (AND -- must have all tags).
/// folder_ids use OR semantics: media in ANY of the given folders.
/// tag_ids use AND semantics: media must have ALL given tags.
pub fn listMediaByFolderAndTags(
    allocator: Allocator,
    db: *Db,
    folder_ids: []const []const u8,
    tag_ids: []const []const u8,
    opts: MediaListOptions,
) ![]MediaRecord {
    // Degenerate cases
    if (folder_ids.len == 0 and tag_ids.len == 0) return listMedia(allocator, db, opts);
    if (folder_ids.len == 0) return listMediaByTerms(allocator, db, tag_ids, opts);
    if (folder_ids.len == 1 and tag_ids.len == 0) return listMediaByTerm(allocator, db, folder_ids[0], opts);

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT m.id, m.filename, m.mime_type, m.size, m.width, m.height,
        \\m.storage_key, m.visibility, m.hash, m.data, m.created_at, m.updated_at
        \\FROM media m WHERE m.id IN (
        \\SELECT media_id FROM media_terms WHERE term_id IN (
    );

    // Folder placeholders: ?1, ?2, ... (OR semantics)
    var bind_idx: u32 = 1;
    for (0..folder_ids.len) |i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("?{d}", .{bind_idx});
        bind_idx += 1;
    }
    try w.writeAll("))");

    // Tag filter: AND semantics -- media must have ALL tags
    if (tag_ids.len > 0) {
        try w.writeAll(" AND m.id IN (SELECT media_id FROM media_terms WHERE term_id IN (");
        for (0..tag_ids.len) |i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.print(") GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    // Get mime patterns for filtering
    const mime_patterns = try opts.getMimePatterns(allocator);

    // Search filter
    if (opts.search != null) {
        try w.print(" AND m.filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // Mime patterns filter (OR)
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("m.mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll(")");
    }

    // Date filters
    if (opts.year != null) {
        try w.print(" AND CAST(strftime('%Y', m.created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.month != null) {
        try w.print(" AND CAST(strftime('%m', m.created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // ORDER BY
    try w.print(" ORDER BY m.{s} {s}", .{
        opts.order_by,
        if (opts.order_dir == .asc) "ASC" else "DESC",
    });

    // LIMIT
    if (opts.limit != null) {
        try w.print(" LIMIT ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // OFFSET
    if (opts.offset != null) {
        try w.print(" OFFSET ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    // Bind folder IDs
    var b: u32 = 1;
    for (folder_ids) |fid| {
        try stmt.bindText(@intCast(b), fid);
        b += 1;
    }
    // Bind tag IDs
    for (tag_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    // Bind tag count
    if (tag_ids.len > 0) {
        try stmt.bindInt(@intCast(b), @intCast(tag_ids.len));
        b += 1;
    }
    // Bind search
    if (opts.search) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    // Bind mime patterns
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    // Bind date filters
    if (opts.year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (opts.month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }
    // Bind limit
    if (opts.limit) |l| {
        try stmt.bindInt(@intCast(b), @intCast(l));
        b += 1;
    }
    // Bind offset
    if (opts.offset) |off| {
        try stmt.bindInt(@intCast(b), @intCast(off));
    }

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// List media filtered by term_id. Returns media IDs in that term.
pub fn listMediaByTerm(
    allocator: Allocator,
    db: *Db,
    term_id: []const u8,
    opts: MediaListOptions,
) ![]MediaRecord {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT m.id, m.filename, m.mime_type, m.size, m.width, m.height,
        \\m.storage_key, m.visibility, m.hash, m.data, m.created_at, m.updated_at
        \\FROM media m
        \\JOIN media_terms mt ON mt.media_id = m.id
        \\WHERE mt.term_id = ?1
    );

    // Get mime patterns for filtering
    const mime_patterns = try opts.getMimePatterns(allocator);

    var bind_idx: u32 = 2;
    if (opts.search != null) {
        try w.print(" AND m.filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("m.mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll(")");
    }
    if (opts.year != null) {
        try w.print(" AND CAST(strftime('%Y', m.created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.month != null) {
        try w.print(" AND CAST(strftime('%m', m.created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    try w.print(" ORDER BY m.{s} {s}", .{
        opts.order_by, if (opts.order_dir == .asc) "ASC" else "DESC",
    });

    if (opts.limit != null) {
        try w.print(" LIMIT ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.offset != null) {
        try w.print(" OFFSET ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try stmt.bindText(1, term_id);
    var b: u32 = 2;
    if (opts.search) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    if (opts.year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (opts.month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }
    if (opts.limit) |l| {
        try stmt.bindInt(@intCast(b), @intCast(l));
        b += 1;
    }
    if (opts.offset) |off| {
        try stmt.bindInt(@intCast(b), @intCast(off));
    }

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// List media filtered by multiple term IDs (AND -- media must have ALL terms).
/// Combines folder + tag filtering in a single query.
pub fn listMediaByTerms(
    allocator: Allocator,
    db: *Db,
    term_ids: []const []const u8,
    opts: MediaListOptions,
) ![]MediaRecord {
    if (term_ids.len == 0) return listMedia(allocator, db, opts);
    if (term_ids.len == 1) return listMediaByTerm(allocator, db, term_ids[0], opts);

    // Build: SELECT ... FROM media m WHERE m.id IN (
    //   SELECT media_id FROM media_terms WHERE term_id IN (?1, ?2, ...)
    //   GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?N
    // ) ORDER BY ... LIMIT ...
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT m.id, m.filename, m.mime_type, m.size, m.width, m.height,
        \\m.storage_key, m.visibility, m.hash, m.data, m.created_at, m.updated_at
        \\FROM media m WHERE m.id IN (
        \\SELECT media_id FROM media_terms WHERE term_id IN (
    );

    // Append ?1, ?2, ... for each term
    for (0..term_ids.len) |i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("?{d}", .{i + 1});
    }

    // HAVING COUNT = N
    var bind_idx: u32 = @intCast(term_ids.len + 1);
    try w.print(") GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?{d})", .{bind_idx});
    bind_idx += 1;

    // Get mime patterns for filtering
    const mime_patterns = try opts.getMimePatterns(allocator);

    // Search filter
    if (opts.search != null) {
        try w.print(" AND m.filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // Mime patterns filter (OR)
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("m.mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll(")");
    }

    // Date filters
    if (opts.year != null) {
        try w.print(" AND CAST(strftime('%Y', m.created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.month != null) {
        try w.print(" AND CAST(strftime('%m', m.created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // ORDER BY
    try w.print(" ORDER BY m.{s} {s}", .{
        opts.order_by,
        if (opts.order_dir == .asc) "ASC" else "DESC",
    });

    // LIMIT
    if (opts.limit != null) {
        try w.print(" LIMIT ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    // OFFSET
    if (opts.offset != null) {
        try w.print(" OFFSET ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    // Bind term IDs
    var b: u32 = 1;
    for (term_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    // Bind count
    try stmt.bindInt(@intCast(b), @intCast(term_ids.len));
    b += 1;
    // Bind search
    if (opts.search) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    // Bind mime patterns
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    // Bind date filters
    if (opts.year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (opts.month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }
    // Bind limit
    if (opts.limit) |l| {
        try stmt.bindInt(@intCast(b), @intCast(l));
        b += 1;
    }
    // Bind offset
    if (opts.offset) |off| {
        try stmt.bindInt(@intCast(b), @intCast(off));
    }

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// List media not in any term of a given taxonomy (unsorted)
pub fn listUnsortedMedia(
    allocator: Allocator,
    db: *Db,
    taxonomy_id: []const u8,
    opts: MediaListOptions,
) ![]MediaRecord {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT id, filename, mime_type, size, width, height,
        \\storage_key, visibility, hash, data, created_at, updated_at
        \\FROM media WHERE id NOT IN (
        \\  SELECT mt.media_id FROM media_terms mt
        \\  JOIN terms t ON t.id = mt.term_id
        \\  WHERE t.taxonomy_id = ?1
        \\)
    );

    // Get mime patterns for filtering
    const mime_patterns = try opts.getMimePatterns(allocator);

    var bind_idx: u32 = 2;
    if (opts.search != null) {
        try w.print(" AND filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    // Mime patterns filter (OR)
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll(")");
    }
    if (opts.year != null) {
        try w.print(" AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.month != null) {
        try w.print(" AND CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    try w.print(" ORDER BY {s} {s}", .{
        opts.order_by, if (opts.order_dir == .asc) "ASC" else "DESC",
    });

    if (opts.limit != null) {
        try w.print(" LIMIT ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.offset != null) {
        try w.print(" OFFSET ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try stmt.bindText(1, taxonomy_id);
    var b: u32 = 2;
    if (opts.search) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    // Bind mime patterns
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    if (opts.year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (opts.month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }
    if (opts.limit) |l| {
        try stmt.bindInt(@intCast(b), @intCast(l));
        b += 1;
    }
    if (opts.offset) |off| {
        try stmt.bindInt(@intCast(b), @intCast(off));
    }

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// List unreviewed (synced) media
pub fn listUnreviewedMedia(
    allocator: Allocator,
    db: *Db,
    opts: MediaListOptions,
) ![]MediaRecord {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT id, filename, mime_type, size, width, height,
        \\storage_key, visibility, hash, data, created_at, updated_at
        \\FROM media WHERE json_extract(data, '$.synced') = 1
    );

    var bind_idx: u32 = 1;
    if (opts.search != null) {
        try w.print(" AND filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.year != null) {
        try w.print(" AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.month != null) {
        try w.print(" AND CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    try w.print(" ORDER BY {s} {s}", .{
        opts.order_by, if (opts.order_dir == .asc) "ASC" else "DESC",
    });

    if (opts.limit != null) {
        try w.print(" LIMIT ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (opts.offset != null) {
        try w.print(" OFFSET ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    if (opts.search) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    if (opts.year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (opts.month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }
    if (opts.limit) |l| {
        try stmt.bindInt(@intCast(b), @intCast(l));
        b += 1;
    }
    if (opts.offset) |off| {
        try stmt.bindInt(@intCast(b), @intCast(off));
    }

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

// =============================================================================
// Count Functions
// =============================================================================

/// Count media records
pub fn countMedia(db: *Db, opts: struct {
    visibility: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    search: ?[]const u8 = null,
}) !u32 {
    if (opts.visibility != null and opts.mime_type != null) {
        if (opts.search) |_| {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE visibility = ?1 AND mime_type = ?2 AND filename LIKE ?3");
            defer stmt.deinit();
            try stmt.bindText(1, opts.visibility.?);
            try stmt.bindText(2, opts.mime_type.?);
            try stmt.bindText(3, opts.search.?);
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        } else {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE visibility = ?1 AND mime_type = ?2");
            defer stmt.deinit();
            try stmt.bindText(1, opts.visibility.?);
            try stmt.bindText(2, opts.mime_type.?);
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        }
    } else if (opts.visibility != null) {
        if (opts.search) |_| {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE visibility = ?1 AND filename LIKE ?2");
            defer stmt.deinit();
            try stmt.bindText(1, opts.visibility.?);
            try stmt.bindText(2, opts.search.?);
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        } else {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE visibility = ?1");
            defer stmt.deinit();
            try stmt.bindText(1, opts.visibility.?);
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        }
    } else if (opts.mime_type != null) {
        if (opts.search) |_| {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE mime_type = ?1 AND filename LIKE ?2");
            defer stmt.deinit();
            try stmt.bindText(1, opts.mime_type.?);
            try stmt.bindText(2, opts.search.?);
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        } else {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE mime_type = ?1");
            defer stmt.deinit();
            try stmt.bindText(1, opts.mime_type.?);
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        }
    } else {
        if (opts.search) |_| {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE filename LIKE ?1");
            defer stmt.deinit();
            try stmt.bindText(1, opts.search.?);
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        } else {
            var stmt = try db.prepare("SELECT COUNT(*) FROM media");
            defer stmt.deinit();
            _ = try stmt.step();
            return @intCast(stmt.columnInt(0));
        }
    }
}

/// Count unreviewed (synced) media
pub fn countUnreviewedMedia(allocator: Allocator, db: *Db, search_term: ?[]const u8, year: ?u16, month: ?u8) !u32 {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);
    try w.writeAll("SELECT COUNT(*) FROM media WHERE json_extract(data, '$.synced') = 1");

    var bind_idx: u32 = 1;
    if (search_term != null) {
        try w.print(" AND filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (year != null) {
        try w.print(" AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (month != null) {
        try w.print(" AND CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    if (search_term) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    if (year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count media not in any term of a given taxonomy (e.g. unsorted -- no folder)
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

/// Count media with a specific tag, filtered by active folder, other tags, and mime patterns.
/// Used for contextual sidebar counts that respond to the current filter state.
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
    // Get mime patterns for filtering
    const opts: MediaListOptions = .{ .mime_patterns = mime_patterns_str };
    const mime_patterns = try opts.getMimePatterns(allocator);

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

    // Folder constraint
    if (folder_id != null) {
        try w.writeAll(" AND mt.media_id IN (SELECT media_id FROM media_terms WHERE term_id IN (SELECT id FROM folder_tree))");
    }

    // Tag constraint
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

    // Search constraint
    if (search_term != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE filename LIKE ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    // Mime patterns filter (OR)
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND mt.media_id IN (SELECT id FROM media WHERE (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll("))");
    }

    // Date constraints
    if (year != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }
    if (month != null) {
        try w.print(" AND mt.media_id IN (SELECT id FROM media WHERE CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d})", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
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
    if (search_term) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    // Bind mime patterns
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    if (year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count media in a folder's subtree, filtered by active tags (AND) and mime patterns.
/// Used for contextual folder counts in the sidebar.
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
    // Get mime patterns for filtering
    const opts: MediaListOptions = .{ .mime_patterns = mime_patterns_str };
    const mime_patterns = try opts.getMimePatterns(allocator);

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
    // Mime patterns filter (OR)
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
    if (search_term) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    // Bind mime patterns
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    if (year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count all media matching given tags (AND) and search term.
/// Used for contextual "All Files" count in the sidebar.
pub fn countAllInContext(
    allocator: Allocator,
    db: *Db,
    tag_ids: []const []const u8,
    search_term: ?[]const u8,
    year: ?u16,
    month: ?u8,
) !u32 {
    if (tag_ids.len == 0 and search_term == null and year == null and month == null) {
        return countMedia(db, .{});
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
    if (search_term != null) {
        try w.print(" AND filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (year != null) {
        try w.print(" AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (month != null) {
        try w.print(" AND CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
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
    if (search_term) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    if (year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count media not in any folder that also match all given tags (AND) and mime patterns.
/// Used for contextual "unsorted/default" count in the sidebar.
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
    // Get mime patterns for filtering
    const opts: MediaListOptions = .{ .mime_patterns = mime_patterns_str };
    const mime_patterns = try opts.getMimePatterns(allocator);

    if (tag_ids.len == 0 and search_term == null and year == null and month == null and mime_patterns.len == 0) {
        return countUnsortedMedia(db, taxonomy_id);
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
    if (search_term != null) {
        try w.print(" AND filename LIKE ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    // Mime patterns filter (OR)
    if (mime_patterns.len > 0) {
        try w.writeAll(" AND (");
        for (mime_patterns, 0..) |_, i| {
            if (i > 0) try w.writeAll(" OR ");
            try w.print("mime_type LIKE ?{d}", .{bind_idx});
            bind_idx += 1;
        }
        try w.writeAll(")");
    }
    if (year != null) {
        try w.print(" AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    if (month != null) {
        try w.print(" AND CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?{d}", .{bind_idx});
        bind_idx += 1;
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
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
    if (search_term) |s| {
        try stmt.bindText(@intCast(b), s);
        b += 1;
    }
    // Bind mime patterns
    for (mime_patterns) |pattern| {
        try stmt.bindText(@intCast(b), pattern);
        b += 1;
    }
    if (year) |y| {
        try stmt.bindInt(@intCast(b), @intCast(y));
        b += 1;
    }
    if (month) |m| {
        try stmt.bindInt(@intCast(b), @intCast(m));
        b += 1;
    }

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

// =============================================================================
// Date Queries
// =============================================================================

/// A distinct year/month period found in media created_at timestamps
pub const DatePeriod = struct { year: u16, month: u8 };

/// Get distinct year/month periods from media created_at, ordered newest first.
pub fn getDistinctDatePeriods(allocator: Allocator, db: *Db) ![]DatePeriod {
    var stmt = try db.prepare(
        \\SELECT DISTINCT
        \\  CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER),
        \\  CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER)
        \\FROM media ORDER BY 1 DESC, 2 DESC
    );
    defer stmt.deinit();

    var items: std.ArrayListUnmanaged(DatePeriod) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const y = stmt.columnInt(0);
        const m = stmt.columnInt(1);
        if (y > 0 and m > 0 and m <= 12) {
            try items.append(allocator, .{
                .year = @intCast(y),
                .month = @intCast(m),
            });
        }
    }

    return items.toOwnedSlice(allocator);
}

/// Get distinct years from media (deduplicated from periods)
pub fn getDistinctYears(allocator: Allocator, db: *Db) ![]u16 {
    var stmt = try db.prepare(
        "SELECT DISTINCT CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) FROM media ORDER BY 1 DESC",
    );
    defer stmt.deinit();

    var items: std.ArrayListUnmanaged(u16) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const y = stmt.columnInt(0);
        if (y > 0) try items.append(allocator, @intCast(y));
    }

    return items.toOwnedSlice(allocator);
}

/// Get months available in a given year
pub fn getMonthsForYear(allocator: Allocator, db: *Db, year: u16) ![]u8 {
    var stmt = try db.prepare(
        "SELECT DISTINCT CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) FROM media WHERE CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?1 ORDER BY 1 DESC",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, @intCast(year));

    var items: std.ArrayListUnmanaged(u8) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const m = stmt.columnInt(0);
        if (m > 0 and m <= 12) try items.append(allocator, @intCast(m));
    }

    return items.toOwnedSlice(allocator);
}
