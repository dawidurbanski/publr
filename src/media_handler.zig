//! Media Serve Handler & Access Control
//!
//! Handles GET /media/* requests. Uses companion file logic: a zero-byte file
//! at the public path signals the real file is in .private/ and requires an
//! access check before serving.
//!
//! Supports on-demand image resize (?w=N) and automatic WebP conversion
//! via Accept header negotiation. Processed results are cached on disk.

const std = @import("std");
const storage = @import("storage");
const auth_middleware = @import("auth_middleware");
const Context = @import("middleware").Context;
const image = @import("image");

/// Access check function type.
/// Called when a companion file (private media) is detected.
/// Receives the storage key and optional authenticated user ID.
/// Returns true if access should be granted.
pub const AccessCheckFn = *const fn (storage_key: []const u8, user_id: ?[]const u8) bool;

// Module-level state
var access_check: AccessCheckFn = defaultAccessCheck;

/// Override the access check function (for plugins).
pub fn setAccessCheck(check_fn: AccessCheckFn) void {
    access_check = check_fn;
}

/// Default access check: private files require an authenticated user.
pub fn defaultAccessCheck(_: []const u8, user_id: ?[]const u8) bool {
    return user_id != null;
}

/// Validate that a URL path has no dot-prefixed segments.
/// Blocks `.private/`, `.cache/`, `..`, `.hidden`, etc.
pub fn validatePath(path: []const u8) bool {
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |segment| {
        if (segment.len > 0 and segment[0] == '.') return false;
    }
    return true;
}

// Cache header values
const public_cache_header = "Cache-Control: public, max-age=31536000, immutable";
const private_cache_header = "Cache-Control: private, no-store";

/// Handle GET /media/* requests.
pub fn handleMedia(ctx: *Context) !void {
    const media_path = ctx.wildcard orelse return notFound(ctx);

    // Path security: reject dot-prefixed segments
    if (!validatePath(media_path)) return notFound(ctx);

    // Build filesystem path for public location
    const public_path = storage.buildPath(ctx.allocator, media_path, .public) catch
        return serverError(ctx);
    defer ctx.allocator.free(public_path);

    // Try to open the file at the public path
    const file = std.fs.cwd().openFile(public_path, .{}) catch
        return notFound(ctx);

    // fstat to check size
    const stat = file.stat() catch {
        file.close();
        return serverError(ctx);
    };

    const mime_type = getMimeType(media_path);

    if (stat.size > 0) {
        // Public file — check if image processing is needed
        const img_params = parseImageParams(ctx);
        if (img_params != null and image.isProcessableImage(mime_type)) {
            file.close();
            serveProcessed(ctx, media_path, mime_type, .public, img_params.?, public_cache_header) catch
                return serverError(ctx);
        } else {
            defer file.close();
            serveFileStream(ctx, file, stat.size, mime_type, public_cache_header) catch
                return serverError(ctx);
        }
    } else {
        // Zero-byte companion — close it, check access, serve from .private/
        file.close();
        servePrivate(ctx, media_path, mime_type) catch
            return serverError(ctx);
    }
}

/// Parse image processing parameters from query string and Accept header.
/// Returns null if no processing is needed.
fn parseImageParams(ctx: *Context) ?image.ImageParams {
    const width = parseWidthParam(ctx.query);
    const accept = ctx.getRequestHeader("Accept");
    const mime_type = getMimeType(ctx.wildcard orelse return null);

    if (!image.isProcessableImage(mime_type)) return null;

    const output_format = image.negotiateFormat(accept, mime_type);

    // Need processing if resize requested or format changes
    const needs_resize = width != null;
    const needs_conversion = output_format != sourceFormat(mime_type);

    if (!needs_resize and !needs_conversion) return null;

    return .{
        .width = width,
        .format = output_format,
    };
}

fn sourceFormat(mime_type: []const u8) image.ImageFormat {
    if (std.mem.eql(u8, mime_type, "image/png")) return .png;
    return .jpeg;
}

fn parseWidthParam(query: ?[]const u8) ?u32 {
    const q = query orelse return null;
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "w=")) {
            return std.fmt.parseInt(u32, pair[2..], 10) catch null;
        }
    }
    return null;
}

/// Serve a private file after verifying access.
fn servePrivate(ctx: *Context, media_path: []const u8, mime_type: []const u8) !void {
    const user_id = auth_middleware.getUserId(ctx);
    if (!access_check(media_path, user_id)) return notFound(ctx);

    // Check if image processing is needed
    const img_params = parseImageParams(ctx);
    if (img_params != null and image.isProcessableImage(mime_type)) {
        return serveProcessed(ctx, media_path, mime_type, .private, img_params.?, private_cache_header);
    }

    // Build path to real file in .private/
    const private_path = try storage.buildPath(ctx.allocator, media_path, .private);
    defer ctx.allocator.free(private_path);

    const file = std.fs.cwd().openFile(private_path, .{}) catch
        return notFound(ctx);
    defer file.close();

    const stat = try file.stat();
    try serveFileStream(ctx, file, stat.size, mime_type, private_cache_header);
}

// =============================================================================
// Image Processing + Cache
// =============================================================================

/// Serve a processed (resized/converted) image, using filesystem cache.
fn serveProcessed(
    ctx: *Context,
    media_path: []const u8,
    mime_type: []const u8,
    visibility: storage.Visibility,
    params: image.ImageParams,
    cache_header: []const u8,
) !void {
    const output_format = params.format orelse sourceFormat(mime_type);

    // Build cache suffix and path
    const suffix = try image.cacheSuffix(ctx.allocator, params, output_format, mime_type);
    defer ctx.allocator.free(suffix);

    const cache_path = try buildCachePathFull(ctx.allocator, media_path, visibility, suffix, output_format, mime_type);
    defer ctx.allocator.free(cache_path);

    // Try serving from cache
    if (serveCached(ctx, cache_path, output_format.mimeType(), cache_header)) return;

    // Cache miss — read source, process, write cache, serve
    const source_path = switch (visibility) {
        .public => try storage.buildPath(ctx.allocator, media_path, .public),
        .private => try storage.buildPath(ctx.allocator, media_path, .private),
    };
    defer ctx.allocator.free(source_path);

    const source_data = std.fs.cwd().readFileAlloc(ctx.allocator, source_path, 10 * 1024 * 1024) catch
        return notFound(ctx);
    defer ctx.allocator.free(source_data);

    var result = image.processImage(ctx.allocator, source_data, params) catch
        return serverError(ctx);
    defer result.deinit(ctx.allocator);

    // Write cache file (best-effort)
    writeCacheFile(cache_path, result.data);

    // Serve from memory
    serveBytes(ctx, result.data, result.format.mimeType(), cache_header) catch
        return serverError(ctx);
}

/// Build the full cache filesystem path, handling format conversion.
/// When converting formats (e.g. jpg→webp), the cache file gets the new extension.
fn buildCachePathFull(
    allocator: std.mem.Allocator,
    media_path: []const u8,
    visibility: storage.Visibility,
    suffix: []const u8,
    output_format: image.ImageFormat,
    source_mime: []const u8,
) ![]const u8 {
    const is_conversion = switch (output_format) {
        .webp => true,
        .png => !std.mem.eql(u8, source_mime, "image/png"),
        .jpeg => !std.mem.eql(u8, source_mime, "image/jpeg"),
    };

    if (is_conversion) {
        // For format conversions, replace the extension in the cache path.
        // e.g., photo-abc.jpg with suffix "_w300.webp" → photo-abc_w300.webp
        const dir = std.fs.path.dirname(media_path) orelse "";
        const basename = std.fs.path.basename(media_path);
        const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
        const stem = basename[0..dot_idx];

        const cache_base = switch (visibility) {
            .public => storage.media_dir ++ "/.cache",
            .private => storage.media_dir ++ "/.private/.cache",
        };

        if (dir.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/{s}/{s}{s}", .{ cache_base, dir, stem, suffix });
        } else {
            return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ cache_base, stem, suffix });
        }
    } else {
        // Same format — use standard cache path builder
        return storage.buildCachePath(allocator, media_path, visibility, suffix);
    }
}

/// Try to serve a cached file. Returns true on hit, false on miss.
fn serveCached(ctx: *Context, cache_path: []const u8, mime_type: []const u8, cache_header: []const u8) bool {
    const file = std.fs.cwd().openFile(cache_path, .{}) catch return false;
    const stat = file.stat() catch {
        file.close();
        return false;
    };
    if (stat.size == 0) {
        file.close();
        return false;
    }

    serveFileStream(ctx, file, stat.size, mime_type, cache_header) catch {
        file.close();
        return false;
    };
    file.close();
    return true;
}

/// Write processed image data to cache (best-effort, never fails the request).
fn writeCacheFile(cache_path: []const u8, data: []const u8) void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(cache_path)) |dir| {
        std.fs.cwd().makePath(dir) catch return;
    }
    const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
    defer file.close();
    file.writeAll(data) catch {};
}

// =============================================================================
// File Streaming
// =============================================================================

/// Write HTTP headers and file body directly to the connection stream.
/// Bypasses the response buffer to avoid copying large files into memory.
fn serveFileStream(ctx: *Context, file: std.fs.File, size: u64, mime_type: []const u8, cache_header: []const u8) !void {
    const stream = ctx.stream orelse return error.NoStream;

    // Write HTTP response headers directly
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}\r\nConnection: close\r\n\r\n",
        .{ mime_type, size, cache_header },
    );
    _ = try stream.write(header);

    // Stream file content in chunks
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        _ = stream.write(buf[0..n]) catch break;
    }

    // Prevent router from sending duplicate response
    ctx.response.headers_sent = true;
}

/// Serve bytes from memory buffer directly to the connection stream.
fn serveBytes(ctx: *Context, data: []const u8, mime_type: []const u8, cache_header: []const u8) !void {
    const stream = ctx.stream orelse return error.NoStream;

    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}\r\nConnection: close\r\n\r\n",
        .{ mime_type, data.len, cache_header },
    );
    _ = try stream.write(header);
    _ = try stream.write(data);

    ctx.response.headers_sent = true;
}

// =============================================================================
// MIME Type Lookup
// =============================================================================

const mime_map = .{
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".png", "image/png" },
    .{ ".gif", "image/gif" },
    .{ ".webp", "image/webp" },
    .{ ".avif", "image/avif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".ico", "image/x-icon" },
    .{ ".pdf", "application/pdf" },
    .{ ".mp4", "video/mp4" },
    .{ ".webm", "video/webm" },
    .{ ".mp3", "audio/mpeg" },
    .{ ".ogg", "audio/ogg" },
    .{ ".wav", "audio/wav" },
    .{ ".txt", "text/plain" },
    .{ ".css", "text/css" },
    .{ ".js", "application/javascript" },
    .{ ".json", "application/json" },
    .{ ".xml", "application/xml" },
    .{ ".html", "text/html" },
};

pub fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return "application/octet-stream";

    inline for (mime_map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }

    return "application/octet-stream";
}

// =============================================================================
// Helpers
// =============================================================================

fn notFound(ctx: *Context) void {
    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
}

fn serverError(ctx: *Context) void {
    ctx.response.setStatus("500 Internal Server Error");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Internal Server Error");
}

// =============================================================================
// Tests
// =============================================================================

test "validatePath: rejects dot-prefixed segments" {
    try std.testing.expect(!validatePath(".private/file.jpg"));
    try std.testing.expect(!validatePath(".."));
    try std.testing.expect(!validatePath("."));
    try std.testing.expect(!validatePath(".cache/2026/02/photo.webp"));
    try std.testing.expect(!validatePath("2026/.hidden/file.jpg"));
    try std.testing.expect(!validatePath("2026/02/.secret"));
    try std.testing.expect(!validatePath(".private/2026/02/report.pdf"));
}

test "validatePath: rejects path traversal" {
    try std.testing.expect(!validatePath("2026/02/../../etc/passwd"));
    try std.testing.expect(!validatePath("../../../etc/passwd"));
    try std.testing.expect(!validatePath("2026/../.private/file.pdf"));
}

test "validatePath: accepts valid paths" {
    try std.testing.expect(validatePath("2026/02/photo-abc123.jpg"));
    try std.testing.expect(validatePath("photo.jpg"));
    try std.testing.expect(validatePath("2026/02/my.file.name.jpg"));
    try std.testing.expect(validatePath("a/b/c/d.txt"));
    try std.testing.expect(validatePath("file-with-dashes.pdf"));
}

test "validatePath: dots in filenames are OK" {
    try std.testing.expect(validatePath("2026/02/photo.thumb.jpg"));
    try std.testing.expect(validatePath("report.2026.pdf"));
    try std.testing.expect(validatePath("file.name.with.dots.png"));
}

test "defaultAccessCheck: denies unauthenticated" {
    try std.testing.expect(!defaultAccessCheck("any/key", null));
}

test "defaultAccessCheck: allows authenticated" {
    try std.testing.expect(defaultAccessCheck("any/key", "user_123"));
}

test "getMimeType: common image types" {
    try std.testing.expectEqualStrings("image/jpeg", getMimeType("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", getMimeType("2026/02/photo-abc.jpeg"));
    try std.testing.expectEqualStrings("image/png", getMimeType("logo.png"));
    try std.testing.expectEqualStrings("image/webp", getMimeType("photo.webp"));
    try std.testing.expectEqualStrings("image/gif", getMimeType("anim.gif"));
    try std.testing.expectEqualStrings("image/svg+xml", getMimeType("icon.svg"));
}

test "getMimeType: document and media types" {
    try std.testing.expectEqualStrings("application/pdf", getMimeType("report.pdf"));
    try std.testing.expectEqualStrings("video/mp4", getMimeType("video.mp4"));
    try std.testing.expectEqualStrings("audio/mpeg", getMimeType("song.mp3"));
}

test "getMimeType: unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("file.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("noextension"));
}

test "parseWidthParam: extracts width" {
    try std.testing.expectEqual(@as(?u32, 300), parseWidthParam("w=300"));
    try std.testing.expectEqual(@as(?u32, 600), parseWidthParam("w=600&fmt=webp"));
    try std.testing.expectEqual(@as(?u32, 150), parseWidthParam("quality=80&w=150"));
}

test "parseWidthParam: returns null for invalid or missing" {
    try std.testing.expect(parseWidthParam(null) == null);
    try std.testing.expect(parseWidthParam("fmt=webp") == null);
    try std.testing.expect(parseWidthParam("w=abc") == null);
    try std.testing.expect(parseWidthParam("") == null);
}

test "buildCachePathFull: same format uses standard path" {
    const path = try buildCachePathFull(
        std.testing.allocator,
        "2026/02/photo-abc.jpg",
        .public,
        "_w300",
        .jpeg,
        "image/jpeg",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/.cache/2026/02/photo-abc_w300.jpg", path);
}

test "buildCachePathFull: webp conversion replaces extension" {
    const path = try buildCachePathFull(
        std.testing.allocator,
        "2026/02/photo-abc.jpg",
        .public,
        "_w300.webp",
        .webp,
        "image/jpeg",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/.cache/2026/02/photo-abc_w300.webp", path);
}

test "buildCachePathFull: webp-only conversion (no resize)" {
    const path = try buildCachePathFull(
        std.testing.allocator,
        "2026/02/photo-abc.jpg",
        .public,
        ".webp",
        .webp,
        "image/jpeg",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/.cache/2026/02/photo-abc.webp", path);
}

test "buildCachePathFull: private webp conversion" {
    const path = try buildCachePathFull(
        std.testing.allocator,
        "2026/02/doc-xyz.png",
        .private,
        "_w600.webp",
        .webp,
        "image/png",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("data/media/.private/.cache/2026/02/doc-xyz_w600.webp", path);
}
