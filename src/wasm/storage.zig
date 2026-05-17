//! WASM Storage Backend — SQLite Blob Storage
//!
//! Implements storage.StorageBackend using a `media_files` SQLite table
//! for storing media file bytes as BLOBs. The database is already persisted
//! to OPFS via cms_export_db/saveToOPFS, so media files persist automatically.

const std = @import("std");
const db_mod = @import("db");
const storage = @import("storage");
const Allocator = std.mem.Allocator;

var global_db: *db_mod.Db = undefined;

/// Initialize the WASM storage backend. Creates the media_files table.
pub fn init(database: *db_mod.Db) void {
    global_db = database;
    database.exec(
        \\CREATE TABLE IF NOT EXISTS media_files (
        \\    storage_key TEXT PRIMARY KEY,
        \\    data BLOB NOT NULL,
        \\    visibility TEXT NOT NULL DEFAULT 'public'
        \\)
    ) catch {};
}

/// StorageBackend instance for WASM
pub const backend = storage.StorageBackend{
    .save = wasmSave,
    .delete = wasmDelete,
    .url = wasmUrl,
};

fn wasmSave(allocator: Allocator, filename: []const u8, data: []const u8, visibility: storage.Visibility) anyerror![]const u8 {
    const key = try storage.generateStorageKey(allocator, filename);
    errdefer allocator.free(key);

    var stmt = try global_db.prepare(
        "INSERT INTO media_files (storage_key, data, visibility) VALUES (?1, ?2, ?3)",
    );
    defer stmt.deinit();
    try stmt.bindText(1, key);
    try stmt.bindBlob(2, data);
    try stmt.bindText(3, visibility.toString());
    _ = try stmt.step();

    return key;
}

fn wasmDelete(_: Allocator, storage_key: []const u8) anyerror!void {
    var stmt = try global_db.prepare("DELETE FROM media_files WHERE storage_key = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, storage_key);
    _ = try stmt.step();
}

fn wasmUrl(allocator: Allocator, storage_key: []const u8, visibility: storage.Visibility, params: storage.ImageParams) anyerror![]const u8 {
    // Reuse the same URL format as filesystem backend
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "/media/");
    try buf.appendSlice(allocator, storage_key);

    var has_param = false;
    if (params.width) |w| {
        try buf.append(allocator, '?');
        try std.fmt.format(buf.writer(allocator), "w={}", .{w});
        has_param = true;
    }
    if (params.height) |h| {
        try buf.append(allocator, if (has_param) '&' else '?');
        try std.fmt.format(buf.writer(allocator), "h={}", .{h});
        has_param = true;
    }
    if (params.format) |f| {
        try buf.append(allocator, if (has_param) '&' else '?');
        try std.fmt.format(buf.writer(allocator), "fmt={s}", .{@tagName(f)});
    }

    _ = visibility;
    return buf.toOwnedSlice(allocator);
}

/// Read file data from the media_files table. Caller owns the returned slice.
pub fn readBlob(allocator: Allocator, storage_key: []const u8) ![]const u8 {
    var stmt = try global_db.prepare("SELECT data FROM media_files WHERE storage_key = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, storage_key);

    if (try stmt.step()) {
        const blob = stmt.columnBlob(0) orelse return error.NotFound;
        return try allocator.dupe(u8, blob);
    }
    return error.NotFound;
}

/// Read the visibility of a stored file.
pub fn readVisibility(allocator: Allocator, storage_key: []const u8) ![]const u8 {
    var stmt = try global_db.prepare("SELECT visibility FROM media_files WHERE storage_key = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, storage_key);

    if (try stmt.step()) {
        const vis = stmt.columnText(0) orelse return error.NotFound;
        return try allocator.dupe(u8, vis);
    }
    return error.NotFound;
}

/// Update visibility for a storage key.
pub fn updateVisibility(storage_key: []const u8, new_vis: storage.Visibility) !void {
    var stmt = try global_db.prepare("UPDATE media_files SET visibility = ?2 WHERE storage_key = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, storage_key);
    try stmt.bindText(2, new_vis.toString());
    _ = try stmt.step();
}
