//! Term-filtered list queries: media filtered by folder ids (OR), tag ids (AND),
//! a single term, or a multi-term AND set.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const media_mod = @import("media");
const common = @import("common.zig");
const list_basic = @import("list_basic.zig");

const Allocator = std.mem.Allocator;
const MediaRecord = media_mod.MediaRecord;
const MediaListOptions = media_mod.MediaListOptions;

/// List media filtered by folder IDs (OR — in any folder) and tag IDs (AND — must have all tags).
pub fn listMediaByFolderAndTags(
    allocator: Allocator,
    db: *Db,
    folder_ids: []const []const u8,
    tag_ids: []const []const u8,
    opts: MediaListOptions,
) ![]MediaRecord {
    if (folder_ids.len == 0 and tag_ids.len == 0) return list_basic.listMedia(allocator, db, opts);
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

    var bind_idx: u32 = 1;
    for (0..folder_ids.len) |i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("?{d}", .{bind_idx});
        bind_idx += 1;
    }
    try w.writeAll("))");

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

    const mime_patterns = try common.getMimePatterns(allocator, opts.mime_patterns);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    try common.appendSearchFilter(w, opts.search, &bind_idx, "m.");
    try common.appendMimePatterns(w, mime_patterns, &bind_idx, "m.");
    try common.appendDateFilters(w, opts.year, opts.month, &bind_idx, "m.");
    try common.appendOrderLimitOffset(w, opts.order_by, opts.order_dir == .asc, opts.limit, opts.offset, &bind_idx, "m.");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    for (folder_ids) |fid| {
        try stmt.bindText(@intCast(b), fid);
        b += 1;
    }
    for (tag_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    if (tag_ids.len > 0) {
        try stmt.bindInt(@intCast(b), @intCast(tag_ids.len));
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

/// List media filtered by a single term_id.
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

    const mime_patterns = try common.getMimePatterns(allocator, opts.mime_patterns);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    var bind_idx: u32 = 2;
    try common.appendSearchFilter(w, opts.search, &bind_idx, "m.");
    try common.appendMimePatterns(w, mime_patterns, &bind_idx, "m.");
    try common.appendDateFilters(w, opts.year, opts.month, &bind_idx, "m.");
    try common.appendOrderLimitOffset(w, opts.order_by, opts.order_dir == .asc, opts.limit, opts.offset, &bind_idx, "m.");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try stmt.bindText(1, term_id);
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

/// List media that have ALL given term_ids (AND across folder + tags).
pub fn listMediaByTerms(
    allocator: Allocator,
    db: *Db,
    term_ids: []const []const u8,
    opts: MediaListOptions,
) ![]MediaRecord {
    if (term_ids.len == 0) return list_basic.listMedia(allocator, db, opts);
    if (term_ids.len == 1) return listMediaByTerm(allocator, db, term_ids[0], opts);

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    try w.writeAll(
        \\SELECT m.id, m.filename, m.mime_type, m.size, m.width, m.height,
        \\m.storage_key, m.visibility, m.hash, m.data, m.created_at, m.updated_at
        \\FROM media m WHERE m.id IN (
        \\SELECT media_id FROM media_terms WHERE term_id IN (
    );

    for (0..term_ids.len) |i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("?{d}", .{i + 1});
    }

    var bind_idx: u32 = @intCast(term_ids.len + 1);
    try w.print(") GROUP BY media_id HAVING COUNT(DISTINCT term_id) = ?{d})", .{bind_idx});
    bind_idx += 1;

    const mime_patterns = try common.getMimePatterns(allocator, opts.mime_patterns);
    defer {
        for (mime_patterns) |p| allocator.free(p);
        allocator.free(mime_patterns);
    }

    try common.appendSearchFilter(w, opts.search, &bind_idx, "m.");
    try common.appendMimePatterns(w, mime_patterns, &bind_idx, "m.");
    try common.appendDateFilters(w, opts.year, opts.month, &bind_idx, "m.");
    try common.appendOrderLimitOffset(w, opts.order_by, opts.order_dir == .asc, opts.limit, opts.offset, &bind_idx, "m.");

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var b: u32 = 1;
    for (term_ids) |tid| {
        try stmt.bindText(@intCast(b), tid);
        b += 1;
    }
    try stmt.bindInt(@intCast(b), @intCast(term_ids.len));
    b += 1;
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
