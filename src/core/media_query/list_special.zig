//! Special-case list queries: unsorted (not in any term of a taxonomy)
//! and unreviewed (synced from disk, awaiting human review).

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const media_mod = @import("media");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const MediaRecord = media_mod.MediaRecord;
const MediaListOptions = media_mod.MediaListOptions;

/// List media not in any term of a given taxonomy (e.g. unsorted — no folder).
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

    const mime_patterns = try common.getMimePatterns(allocator, opts.mime_patterns);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    var bind_idx: u32 = 2;
    try common.appendSearchFilter(w, opts.search, &bind_idx, "");
    try common.appendMimePatterns(w, mime_patterns, &bind_idx, "");
    try common.appendDateFilters(w, opts.year, opts.month, &bind_idx, "");
    try common.appendOrderLimitOffset(w, opts.order_by, opts.order_dir == .asc, opts.limit, opts.offset, &bind_idx, "");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try stmt.bindText(1, taxonomy_id);
    var b: u32 = 2;
    try common.bindSearchFilter(&stmt, opts.search, &b);
    try common.bindMimePatterns(&stmt, mime_patterns, &b);
    try common.bindDateFilters(&stmt, opts.year, opts.month, &b);
    try common.bindLimitOffset(&stmt, opts.limit, opts.offset, &b);

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// List media flagged as synced (awaiting human review). mime_patterns is
/// intentionally not supported here — the audience for this view is admin
/// review, not type-filtering.
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
    try common.appendSearchFilter(w, opts.search, &bind_idx, "");
    try common.appendDateFilters(w, opts.year, opts.month, &bind_idx, "");
    try common.appendOrderLimitOffset(w, opts.order_by, opts.order_dir == .asc, opts.limit, opts.offset, &bind_idx, "");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    try common.bindSearchFilter(&stmt, opts.search, &b);
    try common.bindDateFilters(&stmt, opts.year, opts.month, &b);
    try common.bindLimitOffset(&stmt, opts.limit, opts.offset, &b);

    var items: std.ArrayListUnmanaged(MediaRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try media_mod.parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}
