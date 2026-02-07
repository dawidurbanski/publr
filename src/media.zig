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

/// List media with optional filtering
pub fn listMedia(
    allocator: Allocator,
    db: *Db,
    opts: MediaListOptions,
) ![]MediaRecord {
    return cms.listWithMeta(MediaRecord, allocator, db, .{
        .table = "media",
        .id_column = "id",
        .meta_table = "media_meta",
        .meta_fk = "media_id",
        .select_cols = "id, filename, mime_type, size, width, height, storage_key, visibility, hash, data, created_at, updated_at",
        .visibility = opts.visibility,
        .mime_type = opts.mime_type,
        .limit = opts.limit,
        .offset = opts.offset,
        .order_by = opts.order_by,
        .order_dir = opts.order_dir,
        .meta_filters = opts.meta_filters,
        .parse_row = parseMediaRowFn,
    });
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
    // Validate size
    const max_size = input.max_size orelse storage.default_max_size;
    if (!storage.validateSize(input.data.len, max_size)) {
        return error.FileTooLarge;
    }

    // Validate mime type
    if (!storage.validateMimeType(input.mime_type)) {
        return error.InvalidMimeType;
    }

    // Compute SHA-256 hash
    const hash = try storage.computeHash(allocator, input.data);

    // Save to storage backend
    const storage_key = try backend.save(allocator, input.filename, input.data, input.visibility);

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
}) !u32 {
    if (opts.visibility != null and opts.mime_type != null) {
        var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE visibility = ?1 AND mime_type = ?2");
        defer stmt.deinit();
        try stmt.bindText(1, opts.visibility.?);
        try stmt.bindText(2, opts.mime_type.?);
        _ = try stmt.step();
        return @intCast(stmt.columnInt(0));
    } else if (opts.visibility != null) {
        var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE visibility = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, opts.visibility.?);
        _ = try stmt.step();
        return @intCast(stmt.columnInt(0));
    } else if (opts.mime_type != null) {
        var stmt = try db.prepare("SELECT COUNT(*) FROM media WHERE mime_type = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, opts.mime_type.?);
        _ = try stmt.step();
        return @intCast(stmt.columnInt(0));
    } else {
        var stmt = try db.prepare("SELECT COUNT(*) FROM media");
        defer stmt.deinit();
        _ = try stmt.step();
        return @intCast(stmt.columnInt(0));
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
