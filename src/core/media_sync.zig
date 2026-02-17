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
const svg_sanitize = @import("svg_sanitize");

const Allocator = std.mem.Allocator;

pub const SyncResult = struct {
    new_count: u32 = 0,
    missing_count: u32 = 0,
    skipped_count: u32 = 0,
    error_count: u32 = 0,
};

const ScanConfig = struct {
    folder: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

/// Read and parse a `.publr-sync` JSON file from a directory.
/// Returns null if the file doesn't exist or can't be parsed.
fn parseScanConfig(allocator: Allocator, dir_path: []const u8) ?ScanConfig {
    const scan_path = std.fmt.allocPrint(allocator, "{s}/.publr-sync", .{dir_path}) catch return null;
    defer allocator.free(scan_path);
    const file = std.fs.cwd().openFile(scan_path, .{}) catch return null;
    defer file.close();
    const data = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(ScanConfig, allocator, data, .{ .ignore_unknown_fields = true }) catch return null;
    // Dupe the parsed strings so they survive after parsed.deinit()
    const folder = if (parsed.value.folder) |f| (allocator.dupe(u8, f) catch null) else null;
    var tags_list: std.ArrayListUnmanaged([]const u8) = .{};
    for (parsed.value.tags) |t| {
        const duped = allocator.dupe(u8, t) catch continue;
        tags_list.append(allocator, duped) catch {
            allocator.free(duped);
            continue;
        };
    }
    parsed.deinit();
    return .{
        .folder = folder,
        .tags = tags_list.toOwnedSlice(allocator) catch &.{},
    };
}

/// Validate a ScanConfig against the database, filtering out IDs that don't exist.
fn validateScanConfig(allocator: Allocator, db: *Db, config: ScanConfig) ScanConfig {
    const valid_folder = if (config.folder) |fid|
        if (media.termExists(db, fid)) fid else blk: {
            std.debug.print(".publr-sync: folder '{s}' not found, skipping\n", .{fid});
            break :blk null;
        }
    else
        null;

    var valid_tags: std.ArrayListUnmanaged([]const u8) = .{};
    for (config.tags) |tid| {
        if (media.termExists(db, tid)) {
            valid_tags.append(allocator, tid) catch {};
        } else {
            std.debug.print(".publr-sync: tag '{s}' not found, skipping\n", .{tid});
        }
    }

    return .{
        .folder = valid_folder,
        .tags = valid_tags.toOwnedSlice(allocator) catch &.{},
    };
}

/// Run filesystem sync: walk media directories, compare with DB
pub fn syncFilesystem(allocator: Allocator, db: *Db) !SyncResult {
    var result = SyncResult{};

    // Phase 1: Walk public directory, find new files
    walkDirectory(allocator, db, storage.media_dir, "", .public, &result, null) catch |err| {
        std.debug.print("Error walking public media dir: {}\n", .{err});
    };

    // Phase 2: Walk private directory, find new files
    walkDirectory(allocator, db, storage.media_dir ++ "/.private", "", .private, &result, null) catch |err| {
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
    inherited_config: ?ScanConfig,
) !void {
    const full_path = if (relative_prefix.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, relative_prefix })
    else
        try allocator.dupe(u8, base_dir);
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Check for .publr-sync in this directory
    const local_config = parseScanConfig(allocator, full_path);
    const effective_config = if (local_config) |lc|
        validateScanConfig(allocator, db, lc)
    else
        inherited_config;

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

            walkDirectory(allocator, db, base_dir, sub_prefix, visibility, result, effective_config) catch |err| {
                std.debug.print("Error walking {s}: {}\n", .{ sub_prefix, err });
                result.error_count += 1;
            };
            continue;
        }

        if (entry.kind != .file) continue;

        // Skip .publr-sync manifest files
        if (std.mem.eql(u8, entry.name, ".publr-sync")) continue;

        // Skip files with disallowed extensions (.DS_Store, etc.)
        if (!storage.isAllowedExtension(entry.name)) {
            result.skipped_count += 1;
            continue;
        }

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
        syncNewFile(allocator, db, base_dir, storage_key, visibility, result, effective_config) catch |err| {
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
    scan_config: ?ScanConfig,
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

    // Read file data
    const raw_data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(raw_data);

    // Sanitize SVG files and write back to disk
    const data = if (std.mem.eql(u8, mime_type, "image/svg+xml")) blk: {
        const sanitized = svg_sanitize.sanitize(allocator, raw_data) catch {
            result.error_count += 1;
            return;
        };

        // Overwrite file with sanitized content
        const write_file = std.fs.cwd().openFile(file_path, .{ .mode = .write_only }) catch {
            allocator.free(sanitized);
            result.error_count += 1;
            return;
        };
        defer write_file.close();
        write_file.writeAll(sanitized) catch {
            allocator.free(sanitized);
            result.error_count += 1;
            return;
        };
        write_file.setEndPos(sanitized.len) catch {};

        break :blk sanitized;
    } else raw_data;
    defer if (std.mem.eql(u8, mime_type, "image/svg+xml")) allocator.free(data);

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
    defer {
        allocator.free(record.id);
        allocator.free(record.filename);
        allocator.free(record.mime_type);
        allocator.free(record.storage_key);
        allocator.free(record.visibility);
        if (record.hash) |h| allocator.free(h);
    }

    // Assign folder/tags from .publr-sync config
    if (scan_config) |config| {
        var term_ids: std.ArrayListUnmanaged([]const u8) = .{};
        defer term_ids.deinit(allocator);
        if (config.folder) |fid| term_ids.append(allocator, fid) catch {};
        for (config.tags) |tid| term_ids.append(allocator, tid) catch {};
        if (term_ids.items.len > 0) {
            media.syncMediaTerms(db, record.id, term_ids.items) catch |err| {
                std.debug.print("Error assigning terms to {s}: {}\n", .{ storage_key, err });
            };
        }
    }

    // Mark as synced (unreviewed)
    var stmt = try db.prepare("UPDATE media SET data = json_set(data, '$.synced', 1) WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, record.id);
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

pub const mimeFromExtension = @import("mime").fromPath;

/// Count new files on disk without syncing.
/// Walks directories like syncFilesystem but only counts files not in the DB.
/// No file reads, no hash computation, no DB inserts.
pub fn countNewFilesOnDisk(allocator: Allocator, db: *Db) !u32 {
    // Load all existing storage keys into a hash set for O(1) lookups
    var known_keys = std.StringHashMap(void).init(allocator);
    defer known_keys.deinit();

    {
        var stmt = try db.prepare("SELECT storage_key FROM media");
        defer stmt.deinit();
        while (try stmt.step()) {
            const key = stmt.columnText(0) orelse continue;
            const duped = try allocator.dupe(u8, key);
            try known_keys.put(duped, {});
        }
    }
    defer {
        var it = known_keys.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
    }

    var count: u32 = 0;
    countNewInDir(allocator, &known_keys, storage.media_dir, "", .public, &count) catch {};
    countNewInDir(allocator, &known_keys, storage.media_dir ++ "/.private", "", .private, &count) catch {};
    return count;
}

/// Recursively walk a directory counting files not in known_keys
fn countNewInDir(
    allocator: Allocator,
    known_keys: *std.StringHashMap(void),
    base_dir: []const u8,
    relative_prefix: []const u8,
    visibility: storage.Visibility,
    count: *u32,
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
        if (entry.kind == .directory) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            const sub_prefix = if (relative_prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_prefix, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            defer allocator.free(sub_prefix);
            countNewInDir(allocator, known_keys, base_dir, sub_prefix, visibility, count) catch {};
            continue;
        }

        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".publr-sync")) continue;
        if (!storage.isAllowedExtension(entry.name)) continue;

        // Build storage key
        const storage_key = if (relative_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(storage_key);

        // Skip zero-byte companions in public dir
        if (visibility == .public) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_path, entry.name });
            defer allocator.free(file_path);
            const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;
            if (stat.size == 0) continue;
        }

        if (!known_keys.contains(storage_key)) {
            count.* += 1;
        }
    }
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


test "media_sync: public API coverage" {
    _ = syncFilesystem;
    _ = countNewFilesOnDisk;
}
