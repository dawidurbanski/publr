//! Media Serve Handler & Access Control
//!
//! Handles GET /media/* requests. Uses companion file logic: a zero-byte file
//! at the public path signals the real file is in .private/ and requires an
//! access check before serving.

const std = @import("std");
const storage = @import("storage");
const auth_middleware = @import("auth_middleware");
const Context = @import("middleware").Context;

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
        // Public file — serve directly with public cache headers
        defer file.close();
        serveFileStream(ctx, file, stat.size, mime_type, public_cache_header) catch
            return serverError(ctx);
    } else {
        // Zero-byte companion — close it, check access, serve from .private/
        file.close();
        servePrivate(ctx, media_path, mime_type) catch
            return serverError(ctx);
    }
}

/// Serve a private file after verifying access.
fn servePrivate(ctx: *Context, media_path: []const u8, mime_type: []const u8) !void {
    const user_id = auth_middleware.getUserId(ctx);
    if (!access_check(media_path, user_id)) return notFound(ctx);

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

fn getMimeType(path: []const u8) []const u8 {
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
