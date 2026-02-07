//! Filesystem Sync
//!
//! Walks data/media/ recursively, compares against the database, and
//! creates records for new files or flags missing ones. Skips .cache/
//! directories and zero-byte companion files in the public directory.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const media = @import("media");
const storage = @import("storage");

const Allocator = std.mem.Allocator;

pub const SyncResult = struct {
    new_count: u32 = 0,
    missing_count: u32 = 0,
    skipped_count: u32 = 0,
    error_count: u32 = 0,
};

/// Run filesystem sync: walk media directories, compare with DB
pub fn syncFilesystem(allocator: Allocator, db: *Db) !SyncResult {
    var result = SyncResult{};

    // Phase 1: Walk public directory, find new files
    walkDirectory(allocator, db, storage.media_dir, "", .public, &result) catch |err| {
        std.debug.print("Error walking public media dir: {}\n", .{err});
    };

    // Phase 2: Walk private directory, find new files
    walkDirectory(allocator, db, storage.media_dir ++ "/.private", "", .private, &result) catch |err| {
        std.debug.print("Error walking private media dir: {}\n", .{err});
    };

    // Phase 3: Find DB records with no corresponding file on disk
    result.missing_count = try flagMissingFiles(allocator, db);

    return result;
}

/// Recursively walk a directory and sync files
fn walkDirectory(
    allocator: Allocator,
    db: *Db,
    base_dir: []const u8,
    relative_prefix: []const u8,
    visibility: storage.Visibility,
    result: *SyncResult,
) !void {
    const full_path = if (relative_prefix.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, relative_prefix })
    else
        try allocator.dupe(u8, base_dir);
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip .cache directories
        if (entry.kind == .directory) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;

            // Recurse into subdirectory
            const sub_prefix = if (relative_prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_prefix, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            defer allocator.free(sub_prefix);

            walkDirectory(allocator, db, base_dir, sub_prefix, visibility, result) catch |err| {
                std.debug.print("Error walking {s}: {}\n", .{ sub_prefix, err });
                result.error_count += 1;
            };
            continue;
        }

        if (entry.kind != .file) continue;

        // Build storage key from relative path
        const storage_key = if (relative_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(storage_key);

        // For public files: skip zero-byte companions
        if (visibility == .public) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_path, entry.name });
            defer allocator.free(file_path);

            const file = std.fs.cwd().openFile(file_path, .{}) catch {
                result.skipped_count += 1;
                continue;
            };
            defer file.close();

            const stat = file.stat() catch {
                result.skipped_count += 1;
                continue;
            };

            if (stat.size == 0) {
                result.skipped_count += 1;
                continue;
            }
        }

        // Check if media record already exists
        const exists = media.mediaExistsByStorageKey(db, storage_key) catch {
            result.error_count += 1;
            continue;
        };

        if (exists) continue;

        // New file — create record
        syncNewFile(allocator, db, base_dir, storage_key, visibility, result) catch |err| {
            std.debug.print("Error syncing {s}: {}\n", .{ storage_key, err });
            result.error_count += 1;
        };
    }
}

/// Create a media record for a newly discovered file
fn syncNewFile(
    allocator: Allocator,
    db: *Db,
    base_dir: []const u8,
    storage_key: []const u8,
    visibility: storage.Visibility,
    result: *SyncResult,
) !void {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, storage_key });
    defer allocator.free(file_path);

    // Read file for hash computation
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: i64 = @intCast(stat.size);

    // Extract filename from storage key
    const filename = std.fs.path.basename(storage_key);

    // Detect mime type from extension
    const mime_type = mimeFromExtension(filename);

    // Compute hash
    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(data);

    const hash = try storage.computeHash(allocator, data);

    // Detect image dimensions (if image)
    var width: ?i64 = null;
    var height: ?i64 = null;
    if (std.mem.startsWith(u8, mime_type, "image/")) {
        const dims = detectImageDimensions(data);
        width = dims.width;
        height = dims.height;
    }

    // Create media record
    const record = try media.createMedia(allocator, db, .{
        .filename = filename,
        .mime_type = mime_type,
        .size = size,
        .width = width,
        .height = height,
        .storage_key = storage_key,
        .visibility = visibility,
        .hash = hash,
    });

    // Free the record fields we don't need
    allocator.free(record.id);
    allocator.free(record.filename);
    allocator.free(record.mime_type);
    allocator.free(record.storage_key);
    allocator.free(record.visibility);
    if (record.hash) |h| allocator.free(h);

    // Mark as synced (unreviewed) — use the allocated ID before freeing
    // Actually we already freed record.id, so re-query by storage key
    // Instead, mark before freeing:
    // We need the ID, so let's restructure:
    // Actually the record is returned with the id, let's just mark after create
    // The issue is we already freed record.id. Let's restructure.

    // Re-fetch is simpler — the record was just created
    var stmt = try db.prepare("UPDATE media SET data = json_set(data, '$.synced', 1) WHERE storage_key = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, storage_key);
    _ = try stmt.step();

    result.new_count += 1;
}

/// Find DB records whose files are missing from disk
fn flagMissingFiles(allocator: Allocator, db: *Db) !u32 {
    var stmt = try db.prepare(
        "SELECT id, storage_key, visibility FROM media WHERE json_extract(data, '$.synced_missing') IS NULL OR json_extract(data, '$.synced_missing') != 1",
    );
    defer stmt.deinit();

    var missing_count: u32 = 0;

    while (try stmt.step()) {
        const id = stmt.columnText(0) orelse continue;
        const sk = stmt.columnText(1) orelse continue;
        const vis_str = stmt.columnText(2) orelse "public";

        const vis = storage.Visibility.fromString(vis_str) orelse .public;
        const path = try storage.buildPath(allocator, sk, vis);
        defer allocator.free(path);

        const file_exists = blk: {
            std.fs.cwd().access(path, .{}) catch break :blk false;
            break :blk true;
        };

        if (!file_exists) {
            media.flagMediaMissing(db, id) catch {};
            missing_count += 1;
        }
    }

    return missing_count;
}

/// Detect mime type from file extension
pub fn mimeFromExtension(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    if (ext.len == 0) return "application/octet-stream";

    // Lowercase comparison
    if (eqlCaseInsensitive(ext, ".jpg") or eqlCaseInsensitive(ext, ".jpeg")) return "image/jpeg";
    if (eqlCaseInsensitive(ext, ".png")) return "image/png";
    if (eqlCaseInsensitive(ext, ".gif")) return "image/gif";
    if (eqlCaseInsensitive(ext, ".webp")) return "image/webp";
    if (eqlCaseInsensitive(ext, ".svg")) return "image/svg+xml";
    if (eqlCaseInsensitive(ext, ".bmp")) return "image/bmp";
    if (eqlCaseInsensitive(ext, ".ico")) return "image/x-icon";
    if (eqlCaseInsensitive(ext, ".pdf")) return "application/pdf";
    if (eqlCaseInsensitive(ext, ".mp4")) return "video/mp4";
    if (eqlCaseInsensitive(ext, ".webm")) return "video/webm";
    if (eqlCaseInsensitive(ext, ".mp3")) return "audio/mpeg";
    if (eqlCaseInsensitive(ext, ".wav")) return "audio/wav";
    if (eqlCaseInsensitive(ext, ".ogg")) return "audio/ogg";
    if (eqlCaseInsensitive(ext, ".txt")) return "text/plain";
    if (eqlCaseInsensitive(ext, ".css")) return "text/css";
    if (eqlCaseInsensitive(ext, ".html")) return "text/html";

    return "application/octet-stream";
}

fn eqlCaseInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

/// Detect image dimensions from raw data using stb_image
fn detectImageDimensions(data: []const u8) struct { width: ?i64, height: ?i64 } {
    const c = @cImport({
        @cInclude("stb_image.h");
    });

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;

    const ok = c.stbi_info_from_memory(data.ptr, @intCast(data.len), &w, &h, &channels);
    if (ok == 0) return .{ .width = null, .height = null };

    return .{ .width = @intCast(w), .height = @intCast(h) };
}

// =============================================================================
// Tests
// =============================================================================

test "mimeFromExtension: common types" {
    try std.testing.expectEqualStrings("image/jpeg", mimeFromExtension("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", mimeFromExtension("photo.JPEG"));
    try std.testing.expectEqualStrings("image/png", mimeFromExtension("screenshot.png"));
    try std.testing.expectEqualStrings("image/webp", mimeFromExtension("image.webp"));
    try std.testing.expectEqualStrings("application/pdf", mimeFromExtension("doc.pdf"));
    try std.testing.expectEqualStrings("video/mp4", mimeFromExtension("video.mp4"));
    try std.testing.expectEqualStrings("audio/mpeg", mimeFromExtension("song.mp3"));
}

test "mimeFromExtension: unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", mimeFromExtension("data.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFromExtension("noext"));
}

test "eqlCaseInsensitive" {
    try std.testing.expect(eqlCaseInsensitive(".JPG", ".jpg"));
    try std.testing.expect(eqlCaseInsensitive(".Png", ".png"));
    try std.testing.expect(!eqlCaseInsensitive(".jpg", ".png"));
}
