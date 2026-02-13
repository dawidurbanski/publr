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
const id_gen = @import("id_gen");

const Allocator = std.mem.Allocator;

pub const Visibility = storage.Visibility;
pub const StorageBackend = storage.StorageBackend;
pub const ImageParams = storage.ImageParams;

// =========================================================================
// Re-exports for backward compatibility
// =========================================================================
pub const taxonomy = @import("taxonomy");
pub const media_query = @import("media_query");

// Taxonomy re-exports
pub const TermRecord = taxonomy.TermRecord;
pub const tax_media_folders = taxonomy.tax_media_folders;
pub const tax_media_tags = taxonomy.tax_media_tags;
pub const generateTermId = taxonomy.generateTermId;
pub const createTerm = taxonomy.createTerm;
pub const listTerms = taxonomy.listTerms;
pub const renameTerm = taxonomy.renameTerm;
pub const deleteTerm = taxonomy.deleteTerm;
pub const moveTermParent = taxonomy.moveTermParent;
pub const deleteTermWithReparent = taxonomy.deleteTermWithReparent;
pub const termExists = taxonomy.termExists;
pub const getDescendantFolderIds = taxonomy.getDescendantFolderIds;
pub const syncMediaTerms = taxonomy.syncMediaTerms;
pub const addTermToMedia = taxonomy.addTermToMedia;
pub const removeTermFromMedia = taxonomy.removeTermFromMedia;
pub const replaceMediaFolder = taxonomy.replaceMediaFolder;
pub const getMediaTermIds = taxonomy.getMediaTermIds;
pub const getMediaTermNames = taxonomy.getMediaTermNames;
pub const countMediaInTerm = taxonomy.countMediaInTerm;
pub const countMediaInFolderRecursive = taxonomy.countMediaInFolderRecursive;

// Media query re-exports
pub const listMedia = media_query.listMedia;
pub const listMediaByFolderAndTags = media_query.listMediaByFolderAndTags;
pub const listMediaByTerm = media_query.listMediaByTerm;
pub const listMediaByTerms = media_query.listMediaByTerms;
pub const listUnsortedMedia = media_query.listUnsortedMedia;
pub const listUnreviewedMedia = media_query.listUnreviewedMedia;
pub const countMedia = media_query.countMedia;
pub const countUnreviewedMedia = media_query.countUnreviewedMedia;
pub const countUnsortedMedia = media_query.countUnsortedMedia;
pub const countTagInContext = media_query.countTagInContext;
pub const countFolderInContext = media_query.countFolderInContext;
pub const countAllInContext = media_query.countAllInContext;
pub const countUnsortedInContext = media_query.countUnsortedInContext;
pub const DatePeriod = media_query.DatePeriod;
pub const getDistinctDatePeriods = media_query.getDistinctDatePeriods;
pub const getDistinctYears = media_query.getDistinctYears;
pub const getMonthsForYear = media_query.getMonthsForYear;

// =========================================================================
// Core Types
// =========================================================================

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
pub const generateMediaId = id_gen.generateMediaId;

// =========================================================================
// CRUD Operations
// =========================================================================

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
        // Log but don't fail -- DB record should still be cleaned up
        std.debug.print("Warning: failed to delete storage for {s}: {}\n", .{ media_id, err });
    };

    // Delete DB record (cascades to media_meta and media_terms)
    try deleteMedia(db, media_id);
}

// =========================================================================
// Sync Helpers
// =========================================================================

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

/// Check if a media record exists with a given storage key
pub fn mediaExistsByStorageKey(db: *Db, storage_key: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM media WHERE storage_key = ?1 LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, storage_key);
    return try stmt.step();
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

// =========================================================================
// Shared Helpers
// =========================================================================

/// Parse a media record from a database row. Public so media_query can use it.
pub fn parseMediaRow(allocator: Allocator, stmt: *Statement) !MediaRecord {
    const id = try allocator.dupe(u8, stmt.columnText(0) orelse "");
    const filename = try allocator.dupe(u8, stmt.columnText(1) orelse "");
    const mime_type = try allocator.dupe(u8, stmt.columnText(2) orelse "");
    const size = stmt.columnInt(3);
    const width: ?i64 = if (stmt.columnIsNull(4)) null else stmt.columnInt(4);
    const height: ?i64 = if (stmt.columnIsNull(5)) null else stmt.columnInt(5);
    const storage_key = try allocator.dupe(u8, stmt.columnText(6) orelse "");
    const visibility = try allocator.dupe(u8, stmt.columnText(7) orelse "public");
    const hash: ?[]const u8 = if (stmt.columnText(8)) |h| try allocator.dupe(u8, h) else null;
    const data_json = try allocator.dupe(u8, stmt.columnText(9) orelse "{}");
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

/// Simple slugify: lowercase, replace non-alphanumeric with hyphens
pub fn slugify(allocator: Allocator, name: []const u8) ![]u8 {
    return taxonomy.slugify(allocator, name);
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

    // Folders only (both parent + child), no tags -> should get 2 results
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

    // Folders + tag -> only m1 (in parent, tagged Nature)
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
