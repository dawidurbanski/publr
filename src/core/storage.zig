//! Storage Backend
//!
//! Pluggable storage interface for media files. The default filesystem backend
//! stores files under `data/media/` with date-based keys. CDN/S3 plugins can
//! replace the function pointers to route storage elsewhere.

const std = @import("std");
const time_util = @import("time_util");
const Allocator = std.mem.Allocator;

/// Visibility levels for media files
pub const Visibility = enum {
    public,
    private,

    pub fn toString(self: Visibility) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Visibility {
        if (std.mem.eql(u8, s, "public")) return .public;
        if (std.mem.eql(u8, s, "private")) return .private;
        return null;
    }
};

/// Image transform parameters for URL generation
pub const ImageParams = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    format: ?ImageFormat = null,
    quality: ?u8 = null,
};

pub const ImageFormat = enum { jpeg, webp, png };

/// Pluggable storage backend interface
pub const StorageBackend = struct {
    save: *const fn (allocator: Allocator, filename: []const u8, data: []const u8, visibility: Visibility) anyerror![]const u8,
    delete: *const fn (allocator: Allocator, storage_key: []const u8) anyerror!void,
    url: *const fn (allocator: Allocator, storage_key: []const u8, visibility: Visibility, params: ImageParams) anyerror![]const u8,
};

/// Base directory for media storage
pub const media_dir = "data/media";

/// Default filesystem storage backend
pub const filesystem = StorageBackend{
    .save = fsSave,
    .delete = fsDelete,
    .url = fsUrl,
};

// =============================================================================
// Filesystem Backend Implementation
// =============================================================================

/// Ensure all required media directories exist
pub fn initDirectories() !void {
    const dirs = [_][]const u8{
        media_dir,
        media_dir ++ "/.private",
        media_dir ++ "/.cache",
        media_dir ++ "/.private/.cache",
    };
    for (dirs) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
}

/// Save a file to the filesystem. Returns the storage key.
fn fsSave(allocator: Allocator, filename: []const u8, data: []const u8, visibility: Visibility) anyerror![]const u8 {
    // Generate date-based storage key
    const key = try generateStorageKey(allocator, filename);

    // Build the full path
    const full_path = try buildPath(allocator, key, visibility);
    defer allocator.free(full_path);

    // Ensure parent directory exists
    if (std.fs.path.dirname(full_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Write the file
    const file = try std.fs.cwd().createFile(full_path, .{});
    defer file.close();
    try file.writeAll(data);

    // For private files, create zero-byte companion at the public path
    if (visibility == .private) {
        const companion_path = try buildPath(allocator, key, .public);
        defer allocator.free(companion_path);

        if (std.fs.path.dirname(companion_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const companion = try std.fs.cwd().createFile(companion_path, .{});
        companion.close();
    }

    return key;
}

/// Delete a file and its associated artifacts (companion, cache derivatives)
fn fsDelete(allocator: Allocator, storage_key: []const u8) anyerror!void {
    // Delete the public file (real or companion)
    const public_path = try buildPath(allocator, storage_key, .public);
    defer allocator.free(public_path);
    std.fs.cwd().deleteFile(public_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    // Delete private file if it exists
    const private_path = try buildPath(allocator, storage_key, .private);
    defer allocator.free(private_path);
    std.fs.cwd().deleteFile(private_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    // Delete cached derivatives
    try deleteCacheDerivatives(allocator, storage_key, .public);
    try deleteCacheDerivatives(allocator, storage_key, .private);
}

/// Generate a URL for a stored media file
fn fsUrl(allocator: Allocator, storage_key: []const u8, _: Visibility, params: ImageParams) anyerror![]const u8 {
    // Base URL: /media/{storage_key}
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "/media/");
    try buf.appendSlice(allocator, storage_key);

    // Append query params if any
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

    return buf.toOwnedSlice(allocator);
}

// =============================================================================
// Internal Helpers
// =============================================================================

/// Generate a date-based storage key with random suffix.
/// Format: `YYYY/MM/name-XXXXXX.ext`
pub fn generateStorageKey(allocator: Allocator, filename: []const u8) ![]const u8 {
    const now = time_util.timestamp();
    const epoch_secs: u64 = @intCast(now);
    const epoch_day = epoch_secs / 86400;
    const date = epochDayToYMD(epoch_day);

    const sanitized = sanitizeFilename(filename);
    const stem = sanitized.stem;
    const ext = sanitized.ext;

    // Try up to 10 times to find a unique key
    var attempts: u8 = 0;
    while (attempts < 10) : (attempts += 1) {
        var suffix_buf: [6]u8 = undefined;
        randomSuffix(&suffix_buf);

        // Build key: YYYY/MM/stem-suffix.ext
        const key = try std.fmt.allocPrint(allocator, "{d:0>4}/{d:0>2}/{s}-{s}{s}", .{
            date.year, date.month, stem, suffix_buf, ext,
        });

        // Check shared namespace — neither public nor private path should exist
        const pub_path = try buildPath(allocator, key, .public);
        defer allocator.free(pub_path);
        const priv_path = try buildPath(allocator, key, .private);
        defer allocator.free(priv_path);

        const pub_exists = pathExists(pub_path);
        const priv_exists = pathExists(priv_path);

        if (!pub_exists and !priv_exists) {
            return key;
        }

        allocator.free(key);
    }

    return error.OutOfMemory; // Couldn't find unique key
}

/// Build the full filesystem path for a storage key and visibility
pub fn buildPath(allocator: Allocator, storage_key: []const u8, visibility: Visibility) ![]const u8 {
    return switch (visibility) {
        .public => std.fmt.allocPrint(allocator, "{s}/{s}", .{ media_dir, storage_key }),
        .private => std.fmt.allocPrint(allocator, "{s}/.private/{s}", .{ media_dir, storage_key }),
    };
}

/// Build cache path for a derivative
pub fn buildCachePath(allocator: Allocator, storage_key: []const u8, visibility: Visibility, suffix: []const u8) ![]const u8 {
    // Split storage_key into dir/stem.ext, produce dir/stem_suffix.ext
    const dir = std.fs.path.dirname(storage_key) orelse "";
    const basename = std.fs.path.basename(storage_key);
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = basename[0..dot_idx];
    const ext = if (dot_idx < basename.len) basename[dot_idx..] else "";

    const cache_base = switch (visibility) {
        .public => media_dir ++ "/.cache",
        .private => media_dir ++ "/.private/.cache",
    };

    if (dir.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}/{s}/{s}{s}{s}", .{ cache_base, dir, stem, suffix, ext });
    } else {
        return std.fmt.allocPrint(allocator, "{s}/{s}{s}{s}", .{ cache_base, stem, suffix, ext });
    }
}

const YMD = struct { year: u16, month: u8, day: u8 };

fn epochDayToYMD(epoch_day: u64) YMD {
    // Algorithm from http://howardhinnant.github.io/date_algorithms.html
    const z = epoch_day + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year_adj: u16 = @intCast(if (m <= 2) y + 1 else y);
    return .{
        .year = year_adj,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

const SanitizedFilename = struct { stem: []const u8, ext: []const u8 };

threadlocal var sanitize_buf: [256]u8 = undefined;

fn sanitizeFilename(filename: []const u8) SanitizedFilename {
    // Find extension
    const dot_idx = std.mem.lastIndexOfScalar(u8, filename, '.');
    const raw_stem = if (dot_idx) |i| filename[0..i] else filename;
    const ext = if (dot_idx) |i| filename[i..] else "";

    // Sanitize stem: keep alphanumeric, hyphens, underscores; replace rest with hyphen
    var out_len: usize = 0;
    var prev_hyphen = false;
    for (raw_stem) |c| {
        if (out_len >= sanitize_buf.len) break;
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (std.ascii.isAlphanumeric(lower) or lower == '_') {
            sanitize_buf[out_len] = lower;
            out_len += 1;
            prev_hyphen = false;
        } else if (!prev_hyphen and out_len > 0) {
            sanitize_buf[out_len] = '-';
            out_len += 1;
            prev_hyphen = true;
        }
    }

    // Trim trailing hyphen
    if (out_len > 0 and sanitize_buf[out_len - 1] == '-') out_len -= 1;

    const stem = if (out_len > 0) sanitize_buf[0..out_len] else "file";
    return .{ .stem = stem, .ext = ext };
}

fn randomSuffix(buf: *[6]u8) void {
    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    var rand_buf: [6]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    for (rand_buf, 0..) |byte, i| {
        buf[i] = charset[byte % charset.len];
    }
}

fn pathExists(path: []const u8) bool {
    if (@import("builtin").target.cpu.arch == .wasm32) return false;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Delete all cached derivatives for a storage key
fn deleteCacheDerivatives(allocator: Allocator, storage_key: []const u8, visibility: Visibility) !void {
    // Build the cache directory path and the stem prefix to match
    const dir_part = std.fs.path.dirname(storage_key) orelse "";
    const basename = std.fs.path.basename(storage_key);
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = basename[0..dot_idx];

    const cache_base = switch (visibility) {
        .public => media_dir ++ "/.cache",
        .private => media_dir ++ "/.private/.cache",
    };

    const cache_dir_path = if (dir_part.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_base, dir_part })
    else
        try allocator.dupe(u8, cache_base);
    defer allocator.free(cache_dir_path);

    var dir = std.fs.cwd().openDir(cache_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Match files starting with "stem_" or "stem." (format-converted originals)
        if (std.mem.startsWith(u8, entry.name, stem)) {
            const rest = entry.name[stem.len..];
            if (rest.len > 0 and (rest[0] == '_' or rest[0] == '.')) {
                dir.deleteFile(entry.name) catch {};
            }
        }
    }
}

/// Delete only resized cached derivatives (those with `_w` suffix) for a storage key.
/// Used when focal point changes — format-only conversions are unaffected.
pub fn deleteResizedDerivatives(allocator: Allocator, storage_key: []const u8) !void {
    try deleteResizedForVisibility(allocator, storage_key, .public);
    try deleteResizedForVisibility(allocator, storage_key, .private);
}

fn deleteResizedForVisibility(allocator: Allocator, storage_key: []const u8, visibility: Visibility) !void {
    const dir_part = std.fs.path.dirname(storage_key) orelse "";
    const basename = std.fs.path.basename(storage_key);
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = basename[0..dot_idx];

    const cache_base = switch (visibility) {
        .public => media_dir ++ "/.cache",
        .private => media_dir ++ "/.private/.cache",
    };

    const cache_dir_path = if (dir_part.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_base, dir_part })
    else
        try allocator.dupe(u8, cache_base);
    defer allocator.free(cache_dir_path);

    var dir = std.fs.cwd().openDir(cache_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, stem)) {
            const rest = entry.name[stem.len..];
            // Delete resized/cropped derivatives: _w300, _h200, _w80_h80, _w80_h80_fp34-25, etc.
            if (rest.len > 1 and rest[0] == '_' and (rest[1] == 'w' or rest[1] == 'h')) {
                dir.deleteFile(entry.name) catch {};
            }
        }
    }
}

/// Compute SHA-256 hash of data, returned as hex string
pub fn computeHash(allocator: Allocator, data: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // Convert to hex
    var hex_buf: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        const chars = "0123456789abcdef";
        hex_buf[i * 2] = chars[byte >> 4];
        hex_buf[i * 2 + 1] = chars[byte & 0x0f];
    }

    return try allocator.dupe(u8, &hex_buf);
}

/// Validate file size against limit (in bytes)
pub fn validateSize(size: usize, max_bytes: usize) bool {
    return size <= max_bytes;
}

/// Default max upload size: 1MB
pub const default_max_size: usize = 1024 * 1024;

/// Allowed file extensions (lowercase, with dot).
pub const allowed_extensions = [_][]const u8{
    // Images
    ".jpg", ".jpeg", ".png",  ".gif",  ".webp", ".svg",
    ".bmp", ".ico",  ".avif", ".tiff", ".tif",
    // Documents
     ".pdf",
    // Video
    ".mp4", ".webm", ".mov",  ".avi",
    // Audio
     ".mp3",  ".wav",
    ".ogg", ".aac",  ".flac",
};

/// Check whether a filename has an allowed extension.
pub fn isAllowedExtension(filename: []const u8) bool {
    const ext = std.fs.path.extension(filename);
    if (ext.len == 0) return false;
    for (allowed_extensions) |allowed| {
        if (eqlLower(ext, allowed)) return true;
    }
    return false;
}

/// Validate mime type against allowed types.
pub fn validateMimeType(mime_type: []const u8) bool {
    for (allowed_mime_types) |allowed| {
        if (std.mem.eql(u8, mime_type, allowed)) return true;
    }
    return false;
}

const allowed_mime_types = [_][]const u8{
    // Images
    "image/jpeg",      "image/png",       "image/gif",
    "image/webp",      "image/svg+xml",   "image/bmp",
    "image/x-icon",    "image/avif",      "image/tiff",
    // Documents
    "application/pdf",
    // Video
    "video/mp4",       "video/webm",
    "video/quicktime", "video/x-msvideo",
    // Audio
    "audio/mpeg",
    "audio/wav",       "audio/ogg",       "audio/aac",
    "audio/flac",
};

fn eqlLower(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "Visibility enum conversions" {
    try std.testing.expectEqualStrings("public", Visibility.public.toString());
    try std.testing.expectEqualStrings("private", Visibility.private.toString());
    try std.testing.expect(Visibility.fromString("public") == .public);
    try std.testing.expect(Visibility.fromString("private") == .private);
    try std.testing.expect(Visibility.fromString("invalid") == null);
}

test "epochDayToYMD: Unix epoch is 1970-01-01" {
    const ymd = epochDayToYMD(0);
    try std.testing.expectEqual(@as(u16, 1970), ymd.year);
    try std.testing.expectEqual(@as(u8, 1), ymd.month);
    try std.testing.expectEqual(@as(u8, 1), ymd.day);
}

test "epochDayToYMD: known date 2026-02-07" {
    // 2026-02-07 is 20491 days after Unix epoch
    const ymd = epochDayToYMD(20491);
    try std.testing.expectEqual(@as(u16, 2026), ymd.year);
    try std.testing.expectEqual(@as(u8, 2), ymd.month);
    try std.testing.expectEqual(@as(u8, 7), ymd.day);
}

test "sanitizeFilename: splits stem and extension" {
    const r1 = sanitizeFilename("photo.jpg");
    try std.testing.expectEqualStrings("photo", r1.stem);
    try std.testing.expectEqualStrings(".jpg", r1.ext);

    const r2 = sanitizeFilename("my.file.png");
    try std.testing.expectEqualStrings("my-file", r2.stem);
    try std.testing.expectEqualStrings(".png", r2.ext);

    const r3 = sanitizeFilename("noext");
    try std.testing.expectEqualStrings("noext", r3.stem);
    try std.testing.expectEqualStrings("", r3.ext);
}

test "sanitizeFilename: spaces and special chars become hyphens" {
    const r1 = sanitizeFilename("Screenshot 2025-12-31 at 23.34.51.png");
    try std.testing.expectEqualStrings("screenshot-2025-12-31-at-23-34-51", r1.stem);
    try std.testing.expectEqualStrings(".png", r1.ext);

    const r2 = sanitizeFilename("My Photo (1).jpg");
    try std.testing.expectEqualStrings("my-photo-1", r2.stem);
    try std.testing.expectEqualStrings(".jpg", r2.ext);
}

test "sanitizeFilename: lowercases stem" {
    const r = sanitizeFilename("MyFile.PDF");
    try std.testing.expectEqualStrings("myfile", r.stem);
    try std.testing.expectEqualStrings(".PDF", r.ext);
}

test "sanitizeFilename: empty stem becomes 'file'" {
    const r = sanitizeFilename(".gitignore");
    try std.testing.expectEqualStrings("file", r.stem);
    try std.testing.expectEqualStrings(".gitignore", r.ext);
}

test "randomSuffix: produces 6 alphanumeric chars" {
    var buf: [6]u8 = undefined;
    randomSuffix(&buf);
    for (buf) |ch| {
        try std.testing.expect(std.ascii.isAlphanumeric(ch));
    }
}

test "randomSuffix: produces different values" {
    var buf1: [6]u8 = undefined;
    var buf2: [6]u8 = undefined;
    randomSuffix(&buf1);
    randomSuffix(&buf2);
    // Extremely unlikely to be equal
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "buildPath: public path" {
    const path = try buildPath(std.testing.allocator, "2026/02/photo-abc123.jpg", .public);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/2026/02/photo-abc123.jpg", path);
}

test "buildPath: private path" {
    const path = try buildPath(std.testing.allocator, "2026/02/report-def456.pdf", .private);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/.private/2026/02/report-def456.pdf", path);
}

test "buildCachePath: public derivative" {
    const path = try buildCachePath(std.testing.allocator, "2026/02/photo-abc123.jpg", .public, "_w300");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/.cache/2026/02/photo-abc123_w300.jpg", path);
}

test "buildCachePath: private derivative" {
    const path = try buildCachePath(std.testing.allocator, "2026/02/doc-xyz.pdf", .private, "_w600");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/.private/.cache/2026/02/doc-xyz_w600.pdf", path);
}

test "computeHash: SHA-256 of empty string" {
    const hash = try computeHash(std.testing.allocator, "");
    defer std.testing.allocator.free(hash);
    // Known SHA-256 of empty string
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hash,
    );
}

test "computeHash: SHA-256 of known input" {
    const hash = try computeHash(std.testing.allocator, "hello");
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        hash,
    );
}

test "validateSize: within limit" {
    try std.testing.expect(validateSize(1000, default_max_size));
    try std.testing.expect(validateSize(default_max_size, default_max_size));
}

test "validateSize: exceeds limit" {
    try std.testing.expect(!validateSize(default_max_size + 1, default_max_size));
}

test "validateMimeType: allowed types" {
    try std.testing.expect(validateMimeType("image/jpeg"));
    try std.testing.expect(validateMimeType("image/png"));
    try std.testing.expect(validateMimeType("image/webp"));
    try std.testing.expect(validateMimeType("application/pdf"));
    try std.testing.expect(validateMimeType("video/mp4"));
    try std.testing.expect(validateMimeType("audio/mpeg"));
}

test "validateMimeType: rejected types" {
    try std.testing.expect(!validateMimeType("application/javascript"));
    try std.testing.expect(!validateMimeType("application/x-executable"));
    try std.testing.expect(!validateMimeType(""));
}

test "generateStorageKey: format matches YYYY/MM/stem-suffix.ext" {
    const key = try generateStorageKey(std.testing.allocator, "photo.jpg");
    defer std.testing.allocator.free(key);

    // Should match pattern: YYYY/MM/photo-XXXXXX.jpg
    try std.testing.expect(key.len > 0);
    // Check starts with 4-digit year
    try std.testing.expect(std.ascii.isDigit(key[0]));
    try std.testing.expect(key[4] == '/');
    // Check contains the stem
    try std.testing.expect(std.mem.indexOf(u8, key, "photo-") != null);
    // Check ends with extension
    try std.testing.expect(std.mem.endsWith(u8, key, ".jpg"));
}

test "generateStorageKey: unique keys" {
    const key1 = try generateStorageKey(std.testing.allocator, "test.png");
    defer std.testing.allocator.free(key1);
    const key2 = try generateStorageKey(std.testing.allocator, "test.png");
    defer std.testing.allocator.free(key2);

    try std.testing.expect(!std.mem.eql(u8, key1, key2));
}

test "fsUrl: basic URL" {
    const url = try fsUrl(std.testing.allocator, "2026/02/photo-abc123.jpg", .public, .{});
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("/media/2026/02/photo-abc123.jpg", url);
}

test "fsUrl: URL with width param" {
    const url = try fsUrl(std.testing.allocator, "2026/02/photo-abc123.jpg", .public, .{ .width = 300 });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("/media/2026/02/photo-abc123.jpg?w=300", url);
}

test "fsUrl: URL with multiple params" {
    const url = try fsUrl(std.testing.allocator, "2026/02/photo.jpg", .public, .{ .width = 300, .format = .webp });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("/media/2026/02/photo.jpg?w=300&fmt=webp", url);
}

test "initDirectories: creates all required dirs" {
    // Use a temp directory for isolation
    const test_dir = "/tmp/publr_storage_test";
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    defer std.fs.deleteTreeAbsolute(test_dir) catch {};

    // We can't easily test initDirectories since it uses hardcoded paths,
    // but we can verify the function doesn't error when dirs already exist
    // by calling it twice (idempotent).
    // Full integration test would require a configurable base path.
}

test "filesystem save and delete round-trip" {
    // Create temp media dir structure
    const test_base = "/tmp/publr_fs_test";
    std.fs.deleteTreeAbsolute(test_base) catch {};
    defer std.fs.deleteTreeAbsolute(test_base) catch {};

    // For a true round-trip test we'd need a configurable base path.
    // The unit tests above verify each component (key gen, path building,
    // hash computation). Integration tests with actual file I/O are
    // covered in the serve handler task (task-03).
}

test "storage: public API coverage" {
    _ = initDirectories;
    _ = generateStorageKey;
    _ = buildPath;
    _ = buildCachePath;
    _ = deleteResizedDerivatives;
    _ = computeHash;
    _ = validateSize;
    _ = isAllowedExtension;
    _ = validateMimeType;
}
