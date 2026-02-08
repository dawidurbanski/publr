//! Media CRUD API
//!
//! Core module for media management operations. Provides create, read, list,
//! and delete operations for media files, plus sync functions for media_meta
//! and media_terms tables.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;
const cms = @import("cms");
const media_schema = @import("schema_media");
const storage = @import("storage");
const svg_sanitize = @import("svg_sanitize");

const Allocator = std.mem.Allocator;

pub const Visibility = storage.Visibility;
pub const StorageBackend = storage.StorageBackend;
pub const ImageParams = storage.ImageParams;

/// Media record from the database
pub const MediaRecord = struct {
    id: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    size: i64,
    width: ?i64,
    height: ?i64,
    storage_key: []const u8,
    visibility: []const u8,
    hash: ?[]const u8,
    data: media_schema.Media.Data,
    created_at: i64,
    updated_at: i64,
};

/// Options for listing media
pub const MediaListOptions = struct {
    /// Filter by visibility
    visibility: ?[]const u8 = null,
    /// Filter by mime type
    mime_type: ?[]const u8 = null,
    /// Filter by mime type patterns (e.g., "image/*" or "image/*,application/pdf")
    /// Supports wildcards: "image/*" matches all image types
    mime_patterns: ?[]const u8 = null,
    /// Maximum number of results
    limit: ?u32 = null,
    /// Offset for pagination
    offset: ?u32 = null,
    /// Order by field (default: created_at)
    order_by: []const u8 = "created_at",
    /// Order direction (default: descending)
    order_dir: cms.OrderDir = .desc,
    /// Meta field filters
    meta_filters: []const cms.MetaFilter = &.{},
    /// Filter by filename substring (case-insensitive LIKE %search%)
    search: ?[]const u8 = null,
    /// Filter by year (created_at)
    year: ?u16 = null,
    /// Filter by month (created_at), 1-12
    month: ?u8 = null,

    /// Convert mime_patterns to SQL LIKE patterns for binding
    /// Returns slice of patterns like ["image/%", "application/pdf"]
    pub fn getMimePatterns(self: MediaListOptions, allocator: Allocator) ![][]const u8 {
        const patterns_str = self.mime_patterns orelse return &[_][]const u8{};
        if (patterns_str.len == 0) return &[_][]const u8{};

        var result: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer result.deinit(allocator);

        var it = std.mem.splitSequence(u8, patterns_str, ",");
        while (it.next()) |pattern| {
            const trimmed = std.mem.trim(u8, pattern, " ");
            if (trimmed.len == 0) continue;

            // Convert "image/*" to "image/%" for SQL LIKE
            if (std.mem.endsWith(u8, trimmed, "/*")) {
                const sql_pattern = try std.fmt.allocPrint(allocator, "{s}%", .{trimmed[0 .. trimmed.len - 1]});
                try result.append(allocator, sql_pattern);
            } else {
                // Exact match - still use LIKE but no wildcard
                try result.append(allocator, try allocator.dupe(u8, trimmed));
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Input for creating a media record
pub const CreateMediaInput = struct {
    filename: []const u8,
    mime_type: []const u8,
    size: i64,
    width: ?i64 = null,
    height: ?i64 = null,
    storage_key: []const u8,
    visibility: Visibility = .public,
    hash: ?[]const u8 = null,
    data: media_schema.Media.Data = .{},
};

/// Generate a unique media ID with m_ prefix
pub fn generateMediaId(allocator: Allocator) ![]u8 {
    var id_buf: [24]u8 = undefined;
    id_buf[0] = 'm';
    id_buf[1] = '_';

    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (rand_buf, 0..) |byte, i| {
        id_buf[2 + i] = charset[byte % charset.len];
    }

    return try allocator.dupe(u8, id_buf[0..18]);
}

/// Create a new media record
pub fn createMedia(
    allocator: Allocator,
    db: *Db,
    input: CreateMediaInput,
) !MediaRecord {
    const id = try generateMediaId(allocator);

    // Serialize data to JSON
    const data_json = try media_schema.Media.stringifyData(allocator, input.data);
    defer allocator.free(data_json);

    var stmt = try db.prepare(
        \\INSERT INTO media (id, filename, mime_type, size, width, height, storage_key, visibility, hash, data)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
    );
    defer stmt.deinit();

    try stmt.bindText(1, id);
    try stmt.bindText(2, input.filename);
    try stmt.bindText(3, input.mime_type);
    try stmt.bindInt(4, input.size);
    if (input.width) |w| try stmt.bindInt(5, w) else try stmt.bindNull(5);
    if (input.height) |h| try stmt.bindInt(6, h) else try stmt.bindNull(6);
    try stmt.bindText(7, input.storage_key);
    try stmt.bindText(8, input.visibility.toString());
    if (input.hash) |h| try stmt.bindText(9, h) else try stmt.bindNull(9);
    try stmt.bindText(10, data_json);

    _ = try stmt.step();

    // Sync meta fields
    try syncMediaMeta(db, id, input.data);

    return try getMedia(allocator, db, id) orelse error.StepFailed;
}

/// Get a single media record by ID
pub fn getMedia(
    allocator: Allocator,
    db: *Db,
    id: []const u8,
) !?MediaRecord {
    var stmt = try db.prepare(
        "SELECT id, filename, mime_type, size, width, height, storage_key, visibility, hash, data, created_at, updated_at FROM media WHERE id = ?1",
    );
    defer stmt.deinit();

    try stmt.bindText(1, id);

    if (!try stmt.step()) {
        return null;
    }

    return try parseMediaRow(allocator, &stmt);
}

pub const FocalPoint = struct { x: u8, y: u8 };

/// Get the focal point for a media file by storage key.
/// Returns parsed x,y percentages or null if not set.
pub fn getFocalPoint(db: *Db, storage_key: []const u8) ?FocalPoint {
    var stmt = db.prepare(
        "SELECT data FROM media WHERE storage_key = ?1",
    ) catch return null;
    defer stmt.deinit();

    stmt.bindText(1, storage_key) catch return null;

    if (!(stmt.step() catch return null)) return null;

    const data_json = stmt.columnText(0) orelse return null;
    return parseFocalPointString(data_json);
}

/// Parse focal point from a JSON data string. Looks for "focal_point":"X,Y".
fn parseFocalPointString(json: []const u8) ?FocalPoint {
    // Find "focal_point":" in the JSON
    const marker = "\"focal_point\":\"";
    const start = std.mem.indexOf(u8, json, marker) orelse return null;
    const val_start = start + marker.len;
    const val_end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    const val = json[val_start..val_end];

    const comma = std.mem.indexOfScalar(u8, val, ',') orelse return null;
    const x = std.fmt.parseInt(u8, val[0..comma], 10) catch return null;
    const y = std.fmt.parseInt(u8, val[comma + 1 ..], 10) catch return null;
    if (x > 100 or y > 100) return null;
    return .{ .x = x, .y = y };
}

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
        try items.append(allocator, try parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

fn parseMediaRowFn(allocator: Allocator, stmt: *Statement) !MediaRecord {
    return parseMediaRow(allocator, stmt);
}

/// Update media metadata (data JSON + meta sync)
pub fn updateMedia(
    allocator: Allocator,
    db: *Db,
    id: []const u8,
    data: media_schema.Media.Data,
) !?MediaRecord {
    const data_json = try media_schema.Media.stringifyData(allocator, data);
    defer allocator.free(data_json);

    var stmt = try db.prepare(
        "UPDATE media SET data = ?2, updated_at = unixepoch() WHERE id = ?1",
    );
    defer stmt.deinit();

    try stmt.bindText(1, id);
    try stmt.bindText(2, data_json);
    _ = try stmt.step();

    try syncMediaMeta(db, id, data);

    return try getMedia(allocator, db, id);
}

/// Upload a file: validate, store on disk, compute hash, create DB record.
/// This is the high-level entry point for media uploads.
pub fn uploadMedia(
    allocator: Allocator,
    db: *Db,
    backend: StorageBackend,
    input: UploadInput,
) !MediaRecord {
    // Validate file extension
    if (!storage.isAllowedExtension(input.filename)) {
        return error.InvalidFileType;
    }

    // Validate size
    const max_size = input.max_size orelse storage.default_max_size;
    if (!storage.validateSize(input.data.len, max_size)) {
        return error.FileTooLarge;
    }

    // Validate mime type
    if (!storage.validateMimeType(input.mime_type)) {
        return error.InvalidMimeType;
    }

    // Sanitize SVG files
    const data = if (std.mem.eql(u8, input.mime_type, "image/svg+xml"))
        try svg_sanitize.sanitize(allocator, input.data)
    else
        input.data;
    defer if (std.mem.eql(u8, input.mime_type, "image/svg+xml")) allocator.free(data);

    // Compute SHA-256 hash
    const hash = try storage.computeHash(allocator, data);

    // Save to storage backend
    const storage_key = try backend.save(allocator, input.filename, data, input.visibility);

    // Create DB record
    return createMedia(allocator, db, .{
        .filename = input.filename,
        .mime_type = input.mime_type,
        .size = @intCast(input.data.len),
        .width = input.width,
        .height = input.height,
        .storage_key = storage_key,
        .visibility = input.visibility,
        .hash = hash,
        .data = input.metadata,
    });
}

/// Input for uploadMedia
pub const UploadInput = struct {
    filename: []const u8,
    mime_type: []const u8,
    data: []const u8,
    visibility: Visibility = .public,
    width: ?i64 = null,
    height: ?i64 = null,
    metadata: media_schema.Media.Data = .{},
    max_size: ?usize = null,
};

/// Toggle media visibility between public and private.
/// Moves the file between public and .private/ paths, updates the companion
/// file, and updates the visibility column in the database.
pub fn toggleMediaVisibility(
    allocator: Allocator,
    db: *Db,
    media_id: []const u8,
) !void {
    // Get the current record
    const record = try getMedia(allocator, db, media_id) orelse return error.NotFound;
    defer {
        allocator.free(record.id);
        allocator.free(record.filename);
        allocator.free(record.mime_type);
        allocator.free(record.storage_key);
        allocator.free(record.visibility);
        if (record.hash) |h| allocator.free(h);
    }

    const current = Visibility.fromString(record.visibility) orelse return error.InvalidData;
    const new_vis: Visibility = if (current == .public) .private else .public;

    const is_wasm = @import("builtin").target.cpu.arch == .wasm32;

    if (is_wasm) {
        // WASM: update visibility in media_files table (no filesystem)
        const wasm_storage = @import("wasm_storage");
        wasm_storage.updateVisibility(record.storage_key, new_vis) catch {};
    } else {
        // Move files on disk
        const pub_path = try storage.buildPath(allocator, record.storage_key, .public);
        defer allocator.free(pub_path);
        const priv_path = try storage.buildPath(allocator, record.storage_key, .private);
        defer allocator.free(priv_path);

        switch (current) {
            .public => {
                // Ensure private directory exists
                if (std.fs.path.dirname(priv_path)) |dir| {
                    std.fs.cwd().makePath(dir) catch {};
                }
                // Move real file to .private/
                try std.fs.cwd().rename(pub_path, priv_path);
                // Write zero-byte companion at the original public path
                const companion = try std.fs.cwd().createFile(pub_path, .{});
                companion.close();
            },
            .private => {
                // Move real file from .private/ back to public (overwrites companion)
                try std.fs.cwd().rename(priv_path, pub_path);
            },
        }
    }

    // Update DB visibility column
    var stmt = try db.prepare("UPDATE media SET visibility = ?2, updated_at = unixepoch() WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    try stmt.bindText(2, new_vis.toString());
    _ = try stmt.step();
}

/// Delete a media record (DB only, no file cleanup)
pub fn deleteMedia(db: *Db, media_id: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM media WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    _ = try stmt.step();
}

/// Full delete: remove files from storage, then remove DB record.
/// Looks up the storage key from the DB, deletes via backend, then removes the record.
pub fn fullDeleteMedia(
    allocator: Allocator,
    db: *Db,
    backend: StorageBackend,
    media_id: []const u8,
) !void {
    // Get the record to find the storage key
    const record = try getMedia(allocator, db, media_id) orelse return;
    defer {
        allocator.free(record.id);
        allocator.free(record.filename);
        allocator.free(record.mime_type);
        allocator.free(record.storage_key);
        allocator.free(record.visibility);
        if (record.hash) |h| allocator.free(h);
    }

    // Delete files from storage
    backend.delete(allocator, record.storage_key) catch |err| {
        // Log but don't fail — DB record should still be cleaned up
        std.debug.print("Warning: failed to delete storage for {s}: {}\n", .{ media_id, err });
    };

    // Delete DB record (cascades to media_meta and media_terms)
    try deleteMedia(db, media_id);
}

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

/// Sync filterable fields to media_meta table
pub fn syncMediaMeta(db: *Db, media_id: []const u8, data: media_schema.Media.Data) !void {
    // Delete existing meta for this media
    var del_stmt = try db.prepare("DELETE FROM media_meta WHERE media_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, media_id);
    _ = try del_stmt.step();

    // Insert new meta values for filterable fields
    const filterable = media_schema.Media.getFilterableFields();
    if (filterable.len == 0) return;

    var stmt = try db.prepare(
        \\INSERT INTO media_meta (media_id, key, value_text, value_int, value_real)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.deinit();

    inline for (filterable) |f| {
        if (@hasField(@TypeOf(data), f.name)) {
            const value = @field(data, f.name);

            try stmt.bindText(1, media_id);
            try stmt.bindText(2, f.name);

            switch (f.meta_type) {
                .text => {
                    if (value) |v| {
                        try stmt.bindText(3, v);
                    } else {
                        try stmt.bindNull(3);
                    }
                    try stmt.bindNull(4);
                    try stmt.bindNull(5);
                },
                .int => {
                    try stmt.bindNull(3);
                    if (value) |v| {
                        try stmt.bindInt(4, v);
                    } else {
                        try stmt.bindNull(4);
                    }
                    try stmt.bindNull(5);
                },
                .real => {
                    try stmt.bindNull(3);
                    try stmt.bindNull(4);
                    try stmt.bindNull(5);
                },
            }

            _ = try stmt.step();
            stmt.reset();
        }
    }
}

/// Sync taxonomy fields to media_terms table
pub fn syncMediaTerms(db: *Db, media_id: []const u8, term_ids: []const []const u8) !void {
    // Delete existing terms for this media
    var del_stmt = try db.prepare("DELETE FROM media_terms WHERE media_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, media_id);
    _ = try del_stmt.step();

    if (term_ids.len == 0) return;

    // Insert new term relationships
    var stmt = try db.prepare(
        "INSERT INTO media_terms (media_id, term_id) VALUES (?1, ?2)",
    );
    defer stmt.deinit();

    for (term_ids) |term_id| {
        try stmt.bindText(1, media_id);
        try stmt.bindText(2, term_id);
        _ = try stmt.step();
        stmt.reset();
    }
}

/// Add a single term to a media item (INSERT OR IGNORE — safe if already exists)
pub fn addTermToMedia(db: *Db, media_id: []const u8, term_id: []const u8) !void {
    var stmt = try db.prepare(
        "INSERT OR IGNORE INTO media_terms (media_id, term_id) VALUES (?1, ?2)",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    try stmt.bindText(2, term_id);
    _ = try stmt.step();
}

/// Remove a single term from a media item
pub fn removeTermFromMedia(db: *Db, media_id: []const u8, term_id: []const u8) !void {
    var stmt = try db.prepare(
        "DELETE FROM media_terms WHERE media_id = ?1 AND term_id = ?2",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    try stmt.bindText(2, term_id);
    _ = try stmt.step();
}

/// Replace a media item's folder assignment. Removes existing folder terms
/// (terms in the media_folders taxonomy) and assigns the new folder.
pub fn replaceMediaFolder(db: *Db, media_id: []const u8, new_folder_id: []const u8) !void {
    // Delete existing folder associations for this media
    var del_stmt = try db.prepare(
        \\DELETE FROM media_terms WHERE media_id = ?1 AND term_id IN (
        \\  SELECT id FROM terms WHERE taxonomy_id = ?2
        \\)
    );
    defer del_stmt.deinit();
    try del_stmt.bindText(1, media_id);
    try del_stmt.bindText(2, tax_media_folders);
    _ = try del_stmt.step();

    // Insert new folder association
    var ins_stmt = try db.prepare(
        "INSERT OR IGNORE INTO media_terms (media_id, term_id) VALUES (?1, ?2)",
    );
    defer ins_stmt.deinit();
    try ins_stmt.bindText(1, media_id);
    try ins_stmt.bindText(2, new_folder_id);
    _ = try ins_stmt.step();
}

/// Parse a media record from a database row
fn parseMediaRow(allocator: Allocator, stmt: *Statement) !MediaRecord {
    const id = try allocator.dupe(u8, stmt.columnText(0) orelse "");
    const filename = try allocator.dupe(u8, stmt.columnText(1) orelse "");
    const mime_type = try allocator.dupe(u8, stmt.columnText(2) orelse "");
    const size = stmt.columnInt(3);
    const width: ?i64 = if (stmt.columnIsNull(4)) null else stmt.columnInt(4);
    const height: ?i64 = if (stmt.columnIsNull(5)) null else stmt.columnInt(5);
    const storage_key = try allocator.dupe(u8, stmt.columnText(6) orelse "");
    const visibility = try allocator.dupe(u8, stmt.columnText(7) orelse "public");
    const hash: ?[]const u8 = if (stmt.columnText(8)) |h| try allocator.dupe(u8, h) else null;
    const data_json = stmt.columnText(9) orelse "{}";
    const created_at = stmt.columnInt(10);
    const updated_at = stmt.columnInt(11);

    const parsed = try media_schema.Media.parseData(allocator, data_json);

    return .{
        .id = id,
        .filename = filename,
        .mime_type = mime_type,
        .size = size,
        .width = width,
        .height = height,
        .storage_key = storage_key,
        .visibility = visibility,
        .hash = hash,
        .data = parsed.value,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

// =============================================================================
// Term Management (Folders & Tags)
// =============================================================================

pub const TermRecord = struct {
    id: []const u8,
    taxonomy_id: []const u8,
    slug: []const u8,
    name: []const u8,
    parent_id: ?[]const u8,
    description: []const u8,
    sort_order: i64,
};

/// Taxonomy IDs
pub const tax_media_folders = "tax_media_folders";
pub const tax_media_tags = "tax_media_tags";

/// Generate a unique term ID with t_ prefix
pub fn generateTermId(allocator: Allocator) ![]u8 {
    var id_buf: [20]u8 = undefined;
    id_buf[0] = 't';
    id_buf[1] = '_';

    var rand_buf: [12]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (rand_buf, 0..) |byte, i| {
        id_buf[2 + i] = charset[byte % charset.len];
    }

    return try allocator.dupe(u8, id_buf[0..14]);
}

/// Create a term (folder or tag)
pub fn createTerm(
    allocator: Allocator,
    db: *Db,
    taxonomy_id: []const u8,
    name: []const u8,
    parent_id: ?[]const u8,
) !TermRecord {
    const id = try generateTermId(allocator);
    const slug = try slugify(allocator, name);
    defer allocator.free(slug);

    var stmt = try db.prepare(
        \\INSERT INTO terms (id, taxonomy_id, slug, name, parent_id, description, sort_order)
        \\VALUES (?1, ?2, ?3, ?4, ?5, '', 0)
    );
    defer stmt.deinit();

    try stmt.bindText(1, id);
    try stmt.bindText(2, taxonomy_id);
    try stmt.bindText(3, slug);
    try stmt.bindText(4, name);
    if (parent_id) |pid| try stmt.bindText(5, pid) else try stmt.bindNull(5);

    _ = try stmt.step();

    return .{
        .id = id,
        .taxonomy_id = try allocator.dupe(u8, taxonomy_id),
        .slug = try allocator.dupe(u8, slug),
        .name = try allocator.dupe(u8, name),
        .parent_id = if (parent_id) |pid| try allocator.dupe(u8, pid) else null,
        .description = try allocator.dupe(u8, ""),
        .sort_order = 0,
    };
}

/// List terms for a taxonomy, ordered by sort_order then name
pub fn listTerms(
    allocator: Allocator,
    db: *Db,
    taxonomy_id: []const u8,
) ![]TermRecord {
    var stmt = try db.prepare(
        "SELECT id, taxonomy_id, slug, name, parent_id, description, sort_order FROM terms WHERE taxonomy_id = ?1 ORDER BY sort_order, name",
    );
    defer stmt.deinit();

    try stmt.bindText(1, taxonomy_id);

    var items: std.ArrayListUnmanaged(TermRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, .{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .taxonomy_id = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .slug = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
            .name = try allocator.dupe(u8, stmt.columnText(3) orelse ""),
            .parent_id = if (stmt.columnText(4)) |p| try allocator.dupe(u8, p) else null,
            .description = try allocator.dupe(u8, stmt.columnText(5) orelse ""),
            .sort_order = stmt.columnInt(6),
        });
    }

    return items.toOwnedSlice(allocator);
}

/// Rename a term
pub fn renameTerm(db: *Db, term_id: []const u8, new_name: []const u8) !void {
    var stmt = try db.prepare("UPDATE terms SET name = ?2 WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    try stmt.bindText(2, new_name);
    _ = try stmt.step();
}

/// Delete a term (cascades to media_terms associations)
pub fn deleteTerm(db: *Db, term_id: []const u8) !void {
    // First, unparent any children
    var unparent = try db.prepare("UPDATE terms SET parent_id = NULL WHERE parent_id = ?1");
    defer unparent.deinit();
    try unparent.bindText(1, term_id);
    _ = try unparent.step();

    var stmt = try db.prepare("DELETE FROM terms WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    _ = try stmt.step();
}

/// Move a term to a new parent (or root if new_parent_id is null)
pub fn moveTermParent(db: *Db, term_id: []const u8, new_parent_id: ?[]const u8) !void {
    var stmt = try db.prepare("UPDATE terms SET parent_id = ?2 WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    if (new_parent_id) |pid| try stmt.bindText(2, pid) else try stmt.bindNull(2);
    _ = try stmt.step();
}

/// Delete a term with filesystem-like reparenting:
/// - Children inherit the deleted folder's parent
/// - Files move to the parent folder (or become uncategorized if root)
pub fn deleteTermWithReparent(db: *Db, term_id: []const u8) !void {
    // 1. Get this term's parent_id
    var get_parent = try db.prepare("SELECT parent_id FROM terms WHERE id = ?1");
    defer get_parent.deinit();
    try get_parent.bindText(1, term_id);
    if (!try get_parent.step()) return; // term doesn't exist
    const has_parent = !get_parent.columnIsNull(0);
    const parent_id_raw = get_parent.columnText(0);

    // 2. Children inherit this term's parent
    {
        var stmt = try db.prepare("UPDATE terms SET parent_id = ?2 WHERE parent_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, term_id);
        if (has_parent) {
            try stmt.bindText(2, parent_id_raw.?);
        } else {
            try stmt.bindNull(2);
        }
        _ = try stmt.step();
    }

    // 3. Files move to parent folder (if parent exists)
    if (has_parent) {
        var stmt = try db.prepare("UPDATE media_terms SET term_id = ?2 WHERE term_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, term_id);
        try stmt.bindText(2, parent_id_raw.?);
        _ = try stmt.step();
    }
    // If no parent, CASCADE will clean up media_terms when term is deleted

    // 4. Delete the term
    {
        var stmt = try db.prepare("DELETE FROM terms WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, term_id);
        _ = try stmt.step();
    }
}

/// Get term IDs assigned to a media item, optionally filtered by taxonomy
pub fn getMediaTermIds(
    allocator: Allocator,
    db: *Db,
    media_id: []const u8,
    taxonomy_id: ?[]const u8,
) ![][]const u8 {
    var items: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer items.deinit(allocator);

    if (taxonomy_id) |tax_id| {
        var stmt = try db.prepare(
            "SELECT mt.term_id FROM media_terms mt JOIN terms t ON t.id = mt.term_id WHERE mt.media_id = ?1 AND t.taxonomy_id = ?2",
        );
        defer stmt.deinit();
        try stmt.bindText(1, media_id);
        try stmt.bindText(2, tax_id);

        while (try stmt.step()) {
            try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
        }
    } else {
        var stmt = try db.prepare("SELECT term_id FROM media_terms WHERE media_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, media_id);

        while (try stmt.step()) {
            try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
        }
    }

    return items.toOwnedSlice(allocator);
}

/// Get term names assigned to a media item for a taxonomy (for display)
pub fn getMediaTermNames(
    allocator: Allocator,
    db: *Db,
    media_id: []const u8,
    taxonomy_id: []const u8,
) ![][]const u8 {
    var stmt = try db.prepare(
        "SELECT t.name FROM media_terms mt JOIN terms t ON t.id = mt.term_id WHERE mt.media_id = ?1 AND t.taxonomy_id = ?2 ORDER BY t.name",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    try stmt.bindText(2, taxonomy_id);

    var items: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
    }

    return items.toOwnedSlice(allocator);
}

/// Count media in a specific term
pub fn countMediaInTerm(db: *Db, term_id: []const u8) !u32 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM media_terms WHERE term_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Get a folder ID plus all its descendant folder IDs using a recursive CTE.
/// Returns the folder itself + all children, grandchildren, etc.
pub fn getDescendantFolderIds(
    allocator: Allocator,
    db: *Db,
    folder_id: []const u8,
) ![]const []const u8 {
    var stmt = try db.prepare(
        \\WITH RECURSIVE folder_tree(id) AS (
        \\  SELECT id FROM terms WHERE id = ?1
        \\  UNION ALL
        \\  SELECT t.id FROM terms t JOIN folder_tree ft ON t.parent_id = ft.id
        \\)
        \\SELECT id FROM folder_tree
    );
    defer stmt.deinit();
    try stmt.bindText(1, folder_id);

    var items: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
    }

    return items.toOwnedSlice(allocator);
}

/// Count media in a folder and all its descendant folders using a recursive CTE.
pub fn countMediaInFolderRecursive(db: *Db, folder_id: []const u8) !u32 {
    var stmt = try db.prepare(
        \\WITH RECURSIVE folder_tree(id) AS (
        \\  SELECT id FROM terms WHERE id = ?1
        \\  UNION ALL
        \\  SELECT t.id FROM terms t JOIN folder_tree ft ON t.parent_id = ft.id
        \\)
        \\SELECT COUNT(*) FROM media_terms WHERE term_id IN (SELECT id FROM folder_tree)
    );
    defer stmt.deinit();
    try stmt.bindText(1, folder_id);
    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// List media filtered by folder IDs (OR — in any folder) and tag IDs (AND — must have all tags).
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

    // Tag filter: AND semantics — media must have ALL tags
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
        try items.append(allocator, try parseMediaRow(allocator, &stmt));
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
        try items.append(allocator, try parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// Check if a media record exists with a given storage key
pub fn mediaExistsByStorageKey(db: *Db, storage_key: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM media WHERE storage_key = ?1 LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, storage_key);
    return try stmt.step();
}

/// Check if a term exists in the terms table
pub fn termExists(db: *Db, term_id: []const u8) bool {
    var stmt = db.prepare("SELECT 1 FROM terms WHERE id = ?1 LIMIT 1") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, term_id) catch return false;
    return stmt.step() catch false;
}

/// Flag a media record as missing (file no longer on disk)
pub fn flagMediaMissing(db: *Db, media_id: []const u8) !void {
    // Use the data JSON to store a "missing" flag
    var stmt = try db.prepare(
        "UPDATE media SET data = json_set(data, '$.synced_missing', 1), updated_at = unixepoch() WHERE id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    _ = try stmt.step();
}

/// Mark a media record as synced (unreviewed)
pub fn markMediaSynced(db: *Db, media_id: []const u8) !void {
    var stmt = try db.prepare(
        "UPDATE media SET data = json_set(data, '$.synced', 1), updated_at = unixepoch() WHERE id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    _ = try stmt.step();
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
        try items.append(allocator, try parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// List media filtered by multiple term IDs (AND — media must have ALL terms).
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
        try items.append(allocator, try parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// Count media not in any term of a given taxonomy (e.g. unsorted — no folder)
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

    // No context filters → simple count
    if (folder_id == null and required_tag_ids.len == 0 and search_term == null and year == null and month == null and mime_patterns.len == 0) {
        return countMediaInTerm(db, tag_id);
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
        return countMediaInFolderRecursive(db, folder_id);
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
        try items.append(allocator, try parseMediaRow(allocator, &stmt));
    }

    return items.toOwnedSlice(allocator);
}

/// Simple slugify: lowercase, replace non-alphanumeric with hyphens
fn slugify(allocator: Allocator, name: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, name.len);
    var len: usize = 0;
    var prev_hyphen = false;

    for (name) |c| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (std.ascii.isAlphanumeric(lower)) {
            buf[len] = lower;
            len += 1;
            prev_hyphen = false;
        } else if (!prev_hyphen and len > 0) {
            buf[len] = '-';
            len += 1;
            prev_hyphen = true;
        }
    }

    if (len > 0 and buf[len - 1] == '-') len -= 1;
    if (len == 0) {
        allocator.free(buf);
        return try allocator.dupe(u8, "term");
    }

    return try allocator.realloc(buf, len);
}

// =============================================================================
// Tests
// =============================================================================

const schema_sql = @embedFile("tools/schema.sql");

fn initTestDb() !Db {
    var db = try Db.init(std.testing.allocator, ":memory:");
    try db.exec(schema_sql);
    return db;
}

test "parseFocalPointString: valid focal point" {
    const fp = parseFocalPointString("{\"alt_text\":\"test\",\"focal_point\":\"34,25\"}");
    try std.testing.expect(fp != null);
    try std.testing.expectEqual(@as(u8, 34), fp.?.x);
    try std.testing.expectEqual(@as(u8, 25), fp.?.y);
}

test "parseFocalPointString: missing focal point" {
    try std.testing.expect(parseFocalPointString("{\"alt_text\":\"test\"}") == null);
    try std.testing.expect(parseFocalPointString("{}") == null);
}

test "parseFocalPointString: invalid values" {
    try std.testing.expect(parseFocalPointString("{\"focal_point\":\"abc\"}") == null);
    try std.testing.expect(parseFocalPointString("{\"focal_point\":\"101,50\"}") == null);
}

test "generateMediaId produces valid IDs" {
    const id = try generateMediaId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expect(std.mem.startsWith(u8, id, "m_"));
    try std.testing.expect(id.len == 18);
}

test "generateMediaId produces unique IDs" {
    const id1 = try generateMediaId(std.testing.allocator);
    defer std.testing.allocator.free(id1);
    const id2 = try generateMediaId(std.testing.allocator);
    defer std.testing.allocator.free(id2);

    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}

test "createMedia and getMedia round-trip" {
    var db = try initTestDb();
    defer db.deinit();

    const record = try createMedia(std.testing.allocator, &db, .{
        .filename = "photo.jpg",
        .mime_type = "image/jpeg",
        .size = 1024,
        .width = 800,
        .height = 600,
        .storage_key = "2026/02/photo-abc123.jpg",
        .hash = "abcdef1234567890",
    });
    defer std.testing.allocator.free(record.id);
    defer std.testing.allocator.free(record.filename);
    defer std.testing.allocator.free(record.mime_type);
    defer std.testing.allocator.free(record.storage_key);
    defer std.testing.allocator.free(record.visibility);
    defer if (record.hash) |h| std.testing.allocator.free(h);

    try std.testing.expect(std.mem.startsWith(u8, record.id, "m_"));
    try std.testing.expectEqualStrings("photo.jpg", record.filename);
    try std.testing.expectEqualStrings("image/jpeg", record.mime_type);
    try std.testing.expectEqual(@as(i64, 1024), record.size);
    try std.testing.expectEqual(@as(?i64, 800), record.width);
    try std.testing.expectEqual(@as(?i64, 600), record.height);
    try std.testing.expectEqualStrings("public", record.visibility);

    // Retrieve by ID
    const retrieved = try getMedia(std.testing.allocator, &db, record.id) orelse {
        return error.StepFailed;
    };
    defer std.testing.allocator.free(retrieved.id);
    defer std.testing.allocator.free(retrieved.filename);
    defer std.testing.allocator.free(retrieved.mime_type);
    defer std.testing.allocator.free(retrieved.storage_key);
    defer std.testing.allocator.free(retrieved.visibility);
    defer if (retrieved.hash) |h| std.testing.allocator.free(h);

    try std.testing.expectEqualStrings(record.id, retrieved.id);
    try std.testing.expectEqualStrings("photo.jpg", retrieved.filename);
}

test "deleteMedia removes record" {
    var db = try initTestDb();
    defer db.deinit();

    const record = try createMedia(std.testing.allocator, &db, .{
        .filename = "delete-me.jpg",
        .mime_type = "image/jpeg",
        .size = 512,
        .storage_key = "2026/02/delete-me.jpg",
    });
    defer std.testing.allocator.free(record.id);
    defer std.testing.allocator.free(record.filename);
    defer std.testing.allocator.free(record.mime_type);
    defer std.testing.allocator.free(record.storage_key);
    defer std.testing.allocator.free(record.visibility);

    try deleteMedia(&db, record.id);

    const deleted = try getMedia(std.testing.allocator, &db, record.id);
    try std.testing.expect(deleted == null);
}

test "listMedia returns all records" {
    var db = try initTestDb();
    defer db.deinit();

    // Create two media records
    const r1 = try createMedia(std.testing.allocator, &db, .{
        .filename = "a.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/a.jpg",
    });
    defer std.testing.allocator.free(r1.id);
    defer std.testing.allocator.free(r1.filename);
    defer std.testing.allocator.free(r1.mime_type);
    defer std.testing.allocator.free(r1.storage_key);
    defer std.testing.allocator.free(r1.visibility);

    const r2 = try createMedia(std.testing.allocator, &db, .{
        .filename = "b.png",
        .mime_type = "image/png",
        .size = 200,
        .storage_key = "2026/02/b.png",
    });
    defer std.testing.allocator.free(r2.id);
    defer std.testing.allocator.free(r2.filename);
    defer std.testing.allocator.free(r2.mime_type);
    defer std.testing.allocator.free(r2.storage_key);
    defer std.testing.allocator.free(r2.visibility);

    const all = try listMedia(std.testing.allocator, &db, .{});
    defer {
        for (all) |item| {
            std.testing.allocator.free(item.id);
            std.testing.allocator.free(item.filename);
            std.testing.allocator.free(item.mime_type);
            std.testing.allocator.free(item.storage_key);
            std.testing.allocator.free(item.visibility);
            if (item.hash) |h| std.testing.allocator.free(h);
        }
        std.testing.allocator.free(all);
    }

    try std.testing.expectEqual(@as(usize, 2), all.len);
}

test "listMedia filters by visibility" {
    var db = try initTestDb();
    defer db.deinit();

    _ = try createMedia(std.testing.allocator, &db, .{
        .filename = "public.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/public.jpg",
        .visibility = .public,
    });

    _ = try createMedia(std.testing.allocator, &db, .{
        .filename = "private.pdf",
        .mime_type = "application/pdf",
        .size = 200,
        .storage_key = "2026/02/private.pdf",
        .visibility = .private,
    });

    const public_only = try listMedia(std.testing.allocator, &db, .{ .visibility = "public" });
    defer {
        for (public_only) |item| {
            std.testing.allocator.free(item.id);
            std.testing.allocator.free(item.filename);
            std.testing.allocator.free(item.mime_type);
            std.testing.allocator.free(item.storage_key);
            std.testing.allocator.free(item.visibility);
            if (item.hash) |h| std.testing.allocator.free(h);
        }
        std.testing.allocator.free(public_only);
    }

    try std.testing.expectEqual(@as(usize, 1), public_only.len);
    try std.testing.expectEqualStrings("public.jpg", public_only[0].filename);
}

test "countMedia returns correct count" {
    var db = try initTestDb();
    defer db.deinit();

    _ = try createMedia(std.testing.allocator, &db, .{
        .filename = "a.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/a.jpg",
    });
    _ = try createMedia(std.testing.allocator, &db, .{
        .filename = "b.jpg",
        .mime_type = "image/jpeg",
        .size = 200,
        .storage_key = "2026/02/b.jpg",
    });

    const total = try countMedia(&db, .{});
    try std.testing.expectEqual(@as(u32, 2), total);
}

test "syncMediaMeta writes credit to meta table" {
    var db = try initTestDb();
    defer db.deinit();

    const record = try createMedia(std.testing.allocator, &db, .{
        .filename = "credited.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/credited.jpg",
        .data = .{ .credit = "John Doe" },
    });
    defer std.testing.allocator.free(record.id);
    defer std.testing.allocator.free(record.filename);
    defer std.testing.allocator.free(record.mime_type);
    defer std.testing.allocator.free(record.storage_key);
    defer std.testing.allocator.free(record.visibility);

    // Verify meta was written
    var stmt = try db.prepare("SELECT value_text FROM media_meta WHERE media_id = ?1 AND key = 'credit'");
    defer stmt.deinit();
    try stmt.bindText(1, record.id);
    const has_row = try stmt.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqualStrings("John Doe", stmt.columnText(0).?);
}

test "syncMediaTerms writes term associations" {
    var db = try initTestDb();
    defer db.deinit();

    // Create a taxonomy and term
    try db.exec("INSERT INTO taxonomies (id, slug, name) VALUES ('tax_1', 'media-folders', 'Media Folders')");
    try db.exec("INSERT INTO terms (id, taxonomy_id, slug, name) VALUES ('t_1', 'tax_1', 'photos', 'Photos')");

    const record = try createMedia(std.testing.allocator, &db, .{
        .filename = "tagged.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/tagged.jpg",
    });
    defer std.testing.allocator.free(record.id);
    defer std.testing.allocator.free(record.filename);
    defer std.testing.allocator.free(record.mime_type);
    defer std.testing.allocator.free(record.storage_key);
    defer std.testing.allocator.free(record.visibility);

    try syncMediaTerms(&db, record.id, &.{"t_1"});

    // Verify term was written
    var stmt = try db.prepare("SELECT term_id FROM media_terms WHERE media_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, record.id);
    const has_row = try stmt.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqualStrings("t_1", stmt.columnText(0).?);
}

test "listMedia with MetaFilter" {
    var db = try initTestDb();
    defer db.deinit();

    // Create media with different credits
    _ = try createMedia(std.testing.allocator, &db, .{
        .filename = "john.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/john.jpg",
        .data = .{ .credit = "John Doe" },
    });

    _ = try createMedia(std.testing.allocator, &db, .{
        .filename = "jane.jpg",
        .mime_type = "image/jpeg",
        .size = 200,
        .storage_key = "2026/02/jane.jpg",
        .data = .{ .credit = "Jane Smith" },
    });

    // Filter by credit
    const results = try listMedia(std.testing.allocator, &db, .{
        .meta_filters = &.{
            .{ .key = "credit", .op = .eq, .value = .{ .text = "John Doe" } },
        },
    });
    defer {
        for (results) |item| {
            std.testing.allocator.free(item.id);
            std.testing.allocator.free(item.filename);
            std.testing.allocator.free(item.mime_type);
            std.testing.allocator.free(item.storage_key);
            std.testing.allocator.free(item.visibility);
            if (item.hash) |h| std.testing.allocator.free(h);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("john.jpg", results[0].filename);
}

test "Visibility re-export from storage" {
    try std.testing.expectEqualStrings("public", Visibility.public.toString());
    try std.testing.expectEqualStrings("private", Visibility.private.toString());
}

test "slugify: basic name" {
    const slug = try slugify(std.testing.allocator, "My Folder");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("my-folder", slug);
}

test "slugify: special chars" {
    const slug = try slugify(std.testing.allocator, "Photo & Videos (2026)");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("photo-videos-2026", slug);
}

test "createTerm and listTerms" {
    var db = try initTestDb();
    defer db.deinit();

    const term = try createTerm(std.testing.allocator, &db, tax_media_folders, "Photos", null);
    defer std.testing.allocator.free(term.id);
    defer std.testing.allocator.free(term.taxonomy_id);
    defer std.testing.allocator.free(term.slug);
    defer std.testing.allocator.free(term.name);
    defer std.testing.allocator.free(term.description);

    try std.testing.expectEqualStrings("Photos", term.name);
    try std.testing.expectEqualStrings("photos", term.slug);

    const terms = try listTerms(std.testing.allocator, &db, tax_media_folders);
    defer {
        for (terms) |t| {
            std.testing.allocator.free(t.id);
            std.testing.allocator.free(t.taxonomy_id);
            std.testing.allocator.free(t.slug);
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.description);
            if (t.parent_id) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(terms);
    }

    try std.testing.expectEqual(@as(usize, 1), terms.len);
    try std.testing.expectEqualStrings("Photos", terms[0].name);
}

test "renameTerm" {
    var db = try initTestDb();
    defer db.deinit();

    const term = try createTerm(std.testing.allocator, &db, tax_media_tags, "Old Name", null);
    defer std.testing.allocator.free(term.id);
    defer std.testing.allocator.free(term.taxonomy_id);
    defer std.testing.allocator.free(term.slug);
    defer std.testing.allocator.free(term.name);
    defer std.testing.allocator.free(term.description);

    try renameTerm(&db, term.id, "New Name");

    const terms = try listTerms(std.testing.allocator, &db, tax_media_tags);
    defer {
        for (terms) |t| {
            std.testing.allocator.free(t.id);
            std.testing.allocator.free(t.taxonomy_id);
            std.testing.allocator.free(t.slug);
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.description);
            if (t.parent_id) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(terms);
    }

    try std.testing.expectEqualStrings("New Name", terms[0].name);
}

test "deleteTerm removes term and unparents children" {
    var db = try initTestDb();
    defer db.deinit();

    const parent = try createTerm(std.testing.allocator, &db, tax_media_folders, "Parent", null);
    defer std.testing.allocator.free(parent.id);
    defer std.testing.allocator.free(parent.taxonomy_id);
    defer std.testing.allocator.free(parent.slug);
    defer std.testing.allocator.free(parent.name);
    defer std.testing.allocator.free(parent.description);

    const child = try createTerm(std.testing.allocator, &db, tax_media_folders, "Child", parent.id);
    defer std.testing.allocator.free(child.id);
    defer std.testing.allocator.free(child.taxonomy_id);
    defer std.testing.allocator.free(child.slug);
    defer std.testing.allocator.free(child.name);
    defer std.testing.allocator.free(child.description);
    defer if (child.parent_id) |p| std.testing.allocator.free(p);

    try deleteTerm(&db, parent.id);

    const terms = try listTerms(std.testing.allocator, &db, tax_media_folders);
    defer {
        for (terms) |t| {
            std.testing.allocator.free(t.id);
            std.testing.allocator.free(t.taxonomy_id);
            std.testing.allocator.free(t.slug);
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.description);
            if (t.parent_id) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(terms);
    }

    // Only child remains with null parent
    try std.testing.expectEqual(@as(usize, 1), terms.len);
    try std.testing.expect(terms[0].parent_id == null);
}

test "getMediaTermIds returns assigned terms" {
    var db = try initTestDb();
    defer db.deinit();

    const record = try createMedia(std.testing.allocator, &db, .{
        .filename = "photo.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/photo.jpg",
    });
    defer std.testing.allocator.free(record.id);
    defer std.testing.allocator.free(record.filename);
    defer std.testing.allocator.free(record.mime_type);
    defer std.testing.allocator.free(record.storage_key);
    defer std.testing.allocator.free(record.visibility);

    const folder = try createTerm(std.testing.allocator, &db, tax_media_folders, "Folder", null);
    defer std.testing.allocator.free(folder.id);
    defer std.testing.allocator.free(folder.taxonomy_id);
    defer std.testing.allocator.free(folder.slug);
    defer std.testing.allocator.free(folder.name);
    defer std.testing.allocator.free(folder.description);

    try syncMediaTerms(&db, record.id, &.{folder.id});

    const term_ids = try getMediaTermIds(std.testing.allocator, &db, record.id, tax_media_folders);
    defer {
        for (term_ids) |tid| std.testing.allocator.free(tid);
        std.testing.allocator.free(term_ids);
    }

    try std.testing.expectEqual(@as(usize, 1), term_ids.len);
    try std.testing.expectEqualStrings(folder.id, term_ids[0]);
}

test "mediaExistsByStorageKey" {
    var db = try initTestDb();
    defer db.deinit();

    _ = try createMedia(std.testing.allocator, &db, .{
        .filename = "exists.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/exists.jpg",
    });

    try std.testing.expect(try mediaExistsByStorageKey(&db, "2026/02/exists.jpg"));
    try std.testing.expect(!try mediaExistsByStorageKey(&db, "2026/02/missing.jpg"));
}

test "getDescendantFolderIds returns folder and all descendants" {
    var db = try initTestDb();
    defer db.deinit();

    const parent = try createTerm(std.testing.allocator, &db, tax_media_folders, "Parent", null);
    defer std.testing.allocator.free(parent.id);
    defer std.testing.allocator.free(parent.taxonomy_id);
    defer std.testing.allocator.free(parent.slug);
    defer std.testing.allocator.free(parent.name);
    defer std.testing.allocator.free(parent.description);

    const child = try createTerm(std.testing.allocator, &db, tax_media_folders, "Child", parent.id);
    defer std.testing.allocator.free(child.id);
    defer std.testing.allocator.free(child.taxonomy_id);
    defer std.testing.allocator.free(child.slug);
    defer std.testing.allocator.free(child.name);
    defer std.testing.allocator.free(child.description);
    defer if (child.parent_id) |p| std.testing.allocator.free(p);

    const grandchild = try createTerm(std.testing.allocator, &db, tax_media_folders, "Grandchild", child.id);
    defer std.testing.allocator.free(grandchild.id);
    defer std.testing.allocator.free(grandchild.taxonomy_id);
    defer std.testing.allocator.free(grandchild.slug);
    defer std.testing.allocator.free(grandchild.name);
    defer std.testing.allocator.free(grandchild.description);
    defer if (grandchild.parent_id) |p| std.testing.allocator.free(p);

    // From parent: should get parent + child + grandchild
    const ids = try getDescendantFolderIds(std.testing.allocator, &db, parent.id);
    defer {
        for (ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 3), ids.len);

    // From child: should get child + grandchild
    const child_ids = try getDescendantFolderIds(std.testing.allocator, &db, child.id);
    defer {
        for (child_ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(child_ids);
    }
    try std.testing.expectEqual(@as(usize, 2), child_ids.len);

    // From grandchild: just itself
    const gc_ids = try getDescendantFolderIds(std.testing.allocator, &db, grandchild.id);
    defer {
        for (gc_ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(gc_ids);
    }
    try std.testing.expectEqual(@as(usize, 1), gc_ids.len);
}

test "countMediaInFolderRecursive counts across descendants" {
    var db = try initTestDb();
    defer db.deinit();

    const parent = try createTerm(std.testing.allocator, &db, tax_media_folders, "Parent", null);
    defer std.testing.allocator.free(parent.id);
    defer std.testing.allocator.free(parent.taxonomy_id);
    defer std.testing.allocator.free(parent.slug);
    defer std.testing.allocator.free(parent.name);
    defer std.testing.allocator.free(parent.description);

    const child = try createTerm(std.testing.allocator, &db, tax_media_folders, "Child", parent.id);
    defer std.testing.allocator.free(child.id);
    defer std.testing.allocator.free(child.taxonomy_id);
    defer std.testing.allocator.free(child.slug);
    defer std.testing.allocator.free(child.name);
    defer std.testing.allocator.free(child.description);
    defer if (child.parent_id) |p| std.testing.allocator.free(p);

    // Media in parent
    const m1 = try createMedia(std.testing.allocator, &db, .{
        .filename = "in-parent.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/in-parent.jpg",
    });
    defer std.testing.allocator.free(m1.id);
    defer std.testing.allocator.free(m1.filename);
    defer std.testing.allocator.free(m1.mime_type);
    defer std.testing.allocator.free(m1.storage_key);
    defer std.testing.allocator.free(m1.visibility);
    try syncMediaTerms(&db, m1.id, &.{parent.id});

    // Media in child
    const m2 = try createMedia(std.testing.allocator, &db, .{
        .filename = "in-child.jpg",
        .mime_type = "image/jpeg",
        .size = 200,
        .storage_key = "2026/02/in-child.jpg",
    });
    defer std.testing.allocator.free(m2.id);
    defer std.testing.allocator.free(m2.filename);
    defer std.testing.allocator.free(m2.mime_type);
    defer std.testing.allocator.free(m2.storage_key);
    defer std.testing.allocator.free(m2.visibility);
    try syncMediaTerms(&db, m2.id, &.{child.id});

    // Parent recursive count: 2 (parent + child)
    const parent_count = try countMediaInFolderRecursive(&db, parent.id);
    try std.testing.expectEqual(@as(u32, 2), parent_count);

    // Child recursive count: 1 (just child)
    const child_count = try countMediaInFolderRecursive(&db, child.id);
    try std.testing.expectEqual(@as(u32, 1), child_count);

    // Non-recursive (direct) count for parent should still be 1
    const direct_count = try countMediaInTerm(&db, parent.id);
    try std.testing.expectEqual(@as(u32, 1), direct_count);
}

test "listMediaByFolderAndTags with folder descendants and tags" {
    var db = try initTestDb();
    defer db.deinit();

    // Create folder hierarchy: parent > child
    const parent = try createTerm(std.testing.allocator, &db, tax_media_folders, "Parent", null);
    defer std.testing.allocator.free(parent.id);
    defer std.testing.allocator.free(parent.taxonomy_id);
    defer std.testing.allocator.free(parent.slug);
    defer std.testing.allocator.free(parent.name);
    defer std.testing.allocator.free(parent.description);

    const child = try createTerm(std.testing.allocator, &db, tax_media_folders, "Child", parent.id);
    defer std.testing.allocator.free(child.id);
    defer std.testing.allocator.free(child.taxonomy_id);
    defer std.testing.allocator.free(child.slug);
    defer std.testing.allocator.free(child.name);
    defer std.testing.allocator.free(child.description);
    defer if (child.parent_id) |p| std.testing.allocator.free(p);

    // Create a tag
    const tag = try createTerm(std.testing.allocator, &db, tax_media_tags, "Nature", null);
    defer std.testing.allocator.free(tag.id);
    defer std.testing.allocator.free(tag.taxonomy_id);
    defer std.testing.allocator.free(tag.slug);
    defer std.testing.allocator.free(tag.name);
    defer std.testing.allocator.free(tag.description);

    // m1: in parent folder, tagged Nature
    const m1 = try createMedia(std.testing.allocator, &db, .{
        .filename = "parent-tagged.jpg",
        .mime_type = "image/jpeg",
        .size = 100,
        .storage_key = "2026/02/parent-tagged.jpg",
    });
    defer std.testing.allocator.free(m1.id);
    defer std.testing.allocator.free(m1.filename);
    defer std.testing.allocator.free(m1.mime_type);
    defer std.testing.allocator.free(m1.storage_key);
    defer std.testing.allocator.free(m1.visibility);
    try syncMediaTerms(&db, m1.id, &.{ parent.id, tag.id });

    // m2: in child folder, not tagged
    const m2 = try createMedia(std.testing.allocator, &db, .{
        .filename = "child-untagged.jpg",
        .mime_type = "image/jpeg",
        .size = 200,
        .storage_key = "2026/02/child-untagged.jpg",
    });
    defer std.testing.allocator.free(m2.id);
    defer std.testing.allocator.free(m2.filename);
    defer std.testing.allocator.free(m2.mime_type);
    defer std.testing.allocator.free(m2.storage_key);
    defer std.testing.allocator.free(m2.visibility);
    try syncMediaTerms(&db, m2.id, &.{child.id});

    // Folders only (both parent + child), no tags → should get 2 results
    const folder_only = try listMediaByFolderAndTags(std.testing.allocator, &db, &.{ parent.id, child.id }, &.{}, .{ .limit = 50 });
    defer {
        for (folder_only) |item| {
            std.testing.allocator.free(item.id);
            std.testing.allocator.free(item.filename);
            std.testing.allocator.free(item.mime_type);
            std.testing.allocator.free(item.storage_key);
            std.testing.allocator.free(item.visibility);
            if (item.hash) |h| std.testing.allocator.free(h);
        }
        std.testing.allocator.free(folder_only);
    }
    try std.testing.expectEqual(@as(usize, 2), folder_only.len);

    // Folders + tag → only m1 (in parent, tagged Nature)
    const folder_and_tag = try listMediaByFolderAndTags(std.testing.allocator, &db, &.{ parent.id, child.id }, &.{tag.id}, .{ .limit = 50 });
    defer {
        for (folder_and_tag) |item| {
            std.testing.allocator.free(item.id);
            std.testing.allocator.free(item.filename);
            std.testing.allocator.free(item.mime_type);
            std.testing.allocator.free(item.storage_key);
            std.testing.allocator.free(item.visibility);
            if (item.hash) |h| std.testing.allocator.free(h);
        }
        std.testing.allocator.free(folder_and_tag);
    }
    try std.testing.expectEqual(@as(usize, 1), folder_and_tag.len);
    try std.testing.expectEqualStrings("parent-tagged.jpg", folder_and_tag[0].filename);
}
