//! `listMedia` — the unfiltered/visibility/mime/search/date list query.
//!
//! Fast path: when no mime_patterns are present, defers to the generic
//! `cms.listWithMeta` helper (which handles visibility + simple mime_type
//! exact-match + search + meta filters). Custom path runs only when
//! mime_patterns are present (wildcards like `image/*` need an OR-chain).

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const cms = @import("cms");
const media_mod = @import("media");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const MediaRecord = media_mod.MediaRecord;
const MediaListOptions = media_mod.MediaListOptions;

pub fn listMedia(
    allocator: Allocator,
    db: *Db,
    opts: MediaListOptions,
) ![]MediaRecord {
    const mime_patterns = try common.getMimePatterns(allocator, opts.mime_patterns);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    // Fast path: simple filters go through cms.listWithMeta
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

    // Custom path: mime_patterns need an OR-chain
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT id, filename, mime_type, size, width, height,
        \\storage_key, visibility, hash, data, created_at, updated_at
        \\FROM media WHERE 1=1
    );

    var bind_idx: u32 = 1;

    if (opts.visibility != null) {
        try w.print(" AND visibility = ?{d}", .{bind_idx});
        bind_idx += 1;
    }
    try common.appendSearchFilter(w, opts.search, &bind_idx, "");
    try common.appendMimePatterns(w, mime_patterns, &bind_idx, "");
    try common.appendDateFilters(w, opts.year, opts.month, &bind_idx, "");
    try common.appendOrderLimitOffset(w, opts.order_by, opts.order_dir == .asc, opts.limit, opts.offset, &bind_idx, "");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    if (opts.visibility) |v| {
        try stmt.bindText(@intCast(b), v);
        b += 1;
    }
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

fn parseMediaRowFn(allocator: Allocator, stmt: *db_mod.Statement) !MediaRecord {
    return media_mod.parseMediaRow(allocator, stmt);
}
