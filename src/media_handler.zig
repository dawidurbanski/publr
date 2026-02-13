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

/// Focal point coordinates (0-100 percentages)
pub const FocalPoint = struct { x: u8, y: u8 };

/// Focal point lookup function type.
/// Called when both w and h are specified to get the stored focal point.
/// Returns x,y percentages (0-100) or null if not available.
pub const FocalPointFn = *const fn (storage_key: []const u8) ?FocalPoint;

// Module-level state
var access_check: AccessCheckFn = defaultAccessCheck;
var focal_point_fn: ?FocalPointFn = null;

/// Set the focal point lookup function (for plugins).
pub fn setFocalPointLookup(f: FocalPointFn) void {
    focal_point_fn = f;
}

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
    const media_path = percentDecodePath(ctx.allocator, ctx.wildcard orelse return notFound(ctx));

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
    const width = parseDimensionParam(ctx.query, "w=");
    const height = parseDimensionParam(ctx.query, "h=");
    const accept = ctx.getRequestHeader("Accept");
    const media_path = ctx.wildcard orelse return null;
    const mime_type = getMimeType(media_path);

    if (!image.isProcessableImage(mime_type)) return null;

    const output_format = image.negotiateFormat(accept, mime_type);

    // Need processing if resize requested or format changes
    const needs_resize = width != null or height != null;
    const needs_conversion = output_format != sourceFormat(mime_type);

    if (!needs_resize and !needs_conversion) return null;

    // Parse fit mode and quality
    const fit = parseFitParam(ctx.query);
    const quality = parseQualityParam(ctx.query);

    // Focal point: explicit fp= param takes priority, then DB fallback
    var focal_x: u8 = 50;
    var focal_y: u8 = 50;
    if (width != null and height != null) {
        if (parseFocalPointParam(ctx.query)) |fp| {
            focal_x = fp.x;
            focal_y = fp.y;
        } else if (focal_point_fn) |lookup| {
            if (lookup(media_path)) |fp| {
                focal_x = fp.x;
                focal_y = fp.y;
            }
        }
    }

    return .{
        .width = width,
        .height = height,
        .focal_x = focal_x,
        .focal_y = focal_y,
        .fit = fit,
        .format = output_format,
        .quality = quality,
    };
}

fn sourceFormat(mime_type: []const u8) image.ImageFormat {
    if (std.mem.eql(u8, mime_type, "image/png")) return .png;
    return .jpeg;
}

fn parseDimensionParam(query: ?[]const u8, prefix: []const u8) ?u32 {
    const q = query orelse return null;
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.startsWith(u8, pair, prefix)) {
            return std.fmt.parseInt(u32, pair[prefix.len..], 10) catch null;
        }
    }
    return null;
}

/// Parse focal point from query string: fp=X,Y where X,Y are 0-100.
fn parseFocalPointParam(query: ?[]const u8) ?FocalPoint {
    const q = query orelse return null;
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "fp=")) {
            const val = pair[3..];
            const comma = std.mem.indexOfScalar(u8, val, ',') orelse return null;
            const x = std.fmt.parseInt(u8, val[0..comma], 10) catch return null;
            const y = std.fmt.parseInt(u8, val[comma + 1 ..], 10) catch return null;
            if (x > 100 or y > 100) return null;
            return .{ .x = x, .y = y };
        }
    }
    return null;
}

/// Parse fit mode from query string: fit=cover (default is crop).
fn parseFitParam(query: ?[]const u8) image.FitMode {
    const q = query orelse return .crop;
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "fit=")) {
            const val = pair[4..];
            if (std.mem.eql(u8, val, "cover")) return .cover;
        }
    }
    return .crop;
}

/// Parse quality from query string: q=N where N is 1-100 (default 90).
fn parseQualityParam(query: ?[]const u8) u8 {
    const q = query orelse return 90;
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "q=")) {
            const val = std.fmt.parseInt(u8, pair[2..], 10) catch return 90;
            if (val >= 1 and val <= 100) return val;
        }
    }
    return 90;
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

pub const getMimeType = @import("mime").fromPath;

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

const percentDecodePath = @import("url").pathDecode;

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

test "parseDimensionParam: extracts width" {
    try std.testing.expectEqual(@as(?u32, 300), parseDimensionParam("w=300", "w="));
    try std.testing.expectEqual(@as(?u32, 600), parseDimensionParam("w=600&fmt=webp", "w="));
    try std.testing.expectEqual(@as(?u32, 150), parseDimensionParam("quality=80&w=150", "w="));
}

test "parseDimensionParam: extracts height" {
    try std.testing.expectEqual(@as(?u32, 200), parseDimensionParam("h=200", "h="));
    try std.testing.expectEqual(@as(?u32, 400), parseDimensionParam("w=300&h=400", "h="));
}

test "parseDimensionParam: returns null for invalid or missing" {
    try std.testing.expect(parseDimensionParam(null, "w=") == null);
    try std.testing.expect(parseDimensionParam("fmt=webp", "w=") == null);
    try std.testing.expect(parseDimensionParam("w=abc", "w=") == null);
    try std.testing.expect(parseDimensionParam("", "w=") == null);
}

test "parseFocalPointParam: extracts focal point" {
    const fp1 = parseFocalPointParam("w=80&h=80&fp=34,25");
    try std.testing.expect(fp1 != null);
    try std.testing.expectEqual(@as(u8, 34), fp1.?.x);
    try std.testing.expectEqual(@as(u8, 25), fp1.?.y);

    const fp2 = parseFocalPointParam("fp=0,100&w=80");
    try std.testing.expect(fp2 != null);
    try std.testing.expectEqual(@as(u8, 0), fp2.?.x);
    try std.testing.expectEqual(@as(u8, 100), fp2.?.y);
}

test "parseFocalPointParam: returns null for invalid" {
    try std.testing.expect(parseFocalPointParam(null) == null);
    try std.testing.expect(parseFocalPointParam("w=80&h=80") == null);
    try std.testing.expect(parseFocalPointParam("fp=abc") == null);
    try std.testing.expect(parseFocalPointParam("fp=50") == null);
    try std.testing.expect(parseFocalPointParam("fp=101,50") == null);
    try std.testing.expect(parseFocalPointParam("fp=50,101") == null);
}

test "parseFitParam: defaults to crop" {
    try std.testing.expectEqual(image.FitMode.crop, parseFitParam(null));
    try std.testing.expectEqual(image.FitMode.crop, parseFitParam("w=80&h=80"));
    try std.testing.expectEqual(image.FitMode.crop, parseFitParam("fit=invalid"));
}

test "parseFitParam: parses cover" {
    try std.testing.expectEqual(image.FitMode.cover, parseFitParam("w=80&h=80&fit=cover"));
    try std.testing.expectEqual(image.FitMode.cover, parseFitParam("fit=cover"));
}

test "parseQualityParam: defaults to 90" {
    try std.testing.expectEqual(@as(u8, 90), parseQualityParam(null));
    try std.testing.expectEqual(@as(u8, 90), parseQualityParam("w=80"));
    try std.testing.expectEqual(@as(u8, 90), parseQualityParam("q=0"));
    try std.testing.expectEqual(@as(u8, 90), parseQualityParam("q=abc"));
}

test "parseQualityParam: parses valid values" {
    try std.testing.expectEqual(@as(u8, 80), parseQualityParam("q=80"));
    try std.testing.expectEqual(@as(u8, 100), parseQualityParam("w=200&q=100"));
    try std.testing.expectEqual(@as(u8, 1), parseQualityParam("q=1&w=80"));
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
