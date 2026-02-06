const std = @import("std");
const Context = @import("router").Context;

/// MIME type mappings for common file extensions
const mime_types = .{
    .{ ".css", "text/css" },
    .{ ".js", "application/javascript" },
    .{ ".html", "text/html" },
    .{ ".json", "application/json" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".ico", "image/x-icon" },
    .{ ".woff", "font/woff" },
    .{ ".woff2", "font/woff2" },
    .{ ".txt", "text/plain" },
    .{ ".xml", "application/xml" },
};

/// Get MIME type for a file path based on extension
pub fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return "application/octet-stream";

    inline for (mime_types) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) {
            return entry[1];
        }
    }

    return "application/octet-stream";
}

/// ETag length: "\"" + 16 hex chars + "\""
const ETAG_LEN = 18;

/// Generate ETag from content at compile time using FNV-1a hash
/// Returns a fixed-size array that can be embedded in structs
pub fn compileTimeETag(comptime content: []const u8) [ETAG_LEN]u8 {
    @setEvalBranchQuota(content.len * 10 + 1000);
    const hash = std.hash.Fnv1a_64.hash(content);
    const hex_chars = "0123456789abcdef";
    var buf: [ETAG_LEN]u8 = undefined;
    buf[0] = '"';
    var h = hash;
    // Write hex digits in reverse order to positions 1-16
    for (0..16) |i| {
        buf[16 - i] = hex_chars[@as(usize, @intCast(h & 0xf))];
        h >>= 4;
    }
    buf[17] = '"';
    return buf;
}

/// Embedded asset with precomputed metadata
pub fn Asset(comptime path: []const u8, comptime content: []const u8) type {
    return struct {
        pub const data = content;
        pub const mime_type = getMimeType(path);
        pub const etag: [ETAG_LEN]u8 = compileTimeETag(content);

        /// Serve this asset, handling If-None-Match for caching
        pub fn serve(ctx: *Context, if_none_match: ?[]const u8) void {
            // Check if client has cached version
            if (if_none_match) |client_etag| {
                if (etagMatches(client_etag, &etag)) {
                    ctx.response.setStatus("304 Not Modified");
                    ctx.response.setHeader("ETag", &etag);
                    return;
                }
            }

            // Serve full response with caching headers
            ctx.response.setContentType(mime_type);
            ctx.response.setBody(data);
            ctx.response.setHeader("ETag", &etag);
            ctx.response.setHeader("Cache-Control", "public, max-age=31536000, immutable");
        }
    };
}

/// Check if client ETag matches server ETag
/// Handles both strong and weak ETags, and comma-separated lists
fn etagMatches(client_etag: []const u8, server_etag: []const u8) bool {
    // Handle "*" which matches any ETag
    const trimmed = std.mem.trim(u8, client_etag, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;

    // Check for comma-separated list of ETags
    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |part| {
        var tag = std.mem.trim(u8, part, " \t");

        // Strip weak validator prefix if present
        if (std.mem.startsWith(u8, tag, "W/")) {
            tag = tag[2..];
        }

        if (std.mem.eql(u8, tag, server_etag)) return true;
    }

    return false;
}

// Tests
test "getMimeType common extensions" {
    try std.testing.expectEqualStrings("text/css", getMimeType("style.css"));
    try std.testing.expectEqualStrings("text/css", getMimeType("/static/admin.css"));
    try std.testing.expectEqualStrings("application/javascript", getMimeType("app.js"));
    try std.testing.expectEqualStrings("text/html", getMimeType("index.html"));
    try std.testing.expectEqualStrings("application/json", getMimeType("data.json"));
    try std.testing.expectEqualStrings("image/png", getMimeType("logo.png"));
    try std.testing.expectEqualStrings("image/jpeg", getMimeType("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", getMimeType("photo.jpeg"));
    try std.testing.expectEqualStrings("image/gif", getMimeType("anim.gif"));
    try std.testing.expectEqualStrings("image/svg+xml", getMimeType("icon.svg"));
    try std.testing.expectEqualStrings("image/x-icon", getMimeType("favicon.ico"));
    try std.testing.expectEqualStrings("font/woff", getMimeType("font.woff"));
    try std.testing.expectEqualStrings("font/woff2", getMimeType("font.woff2"));
}

test "getMimeType unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("file.unknown"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("noextension"));
}

test "compileTimeETag generates valid format" {
    const etag = compileTimeETag("test content");
    try std.testing.expect(etag.len == 18);
    try std.testing.expect(etag[0] == '"');
    try std.testing.expect(etag[17] == '"');
}

test "compileTimeETag is deterministic" {
    const etag1 = compileTimeETag("hello world");
    const etag2 = compileTimeETag("hello world");
    try std.testing.expectEqualStrings(&etag1, &etag2);
}

test "compileTimeETag differs for different content" {
    const etag1 = compileTimeETag("content a");
    const etag2 = compileTimeETag("content b");
    try std.testing.expect(!std.mem.eql(u8, &etag1, &etag2));
}

test "etagMatches exact match" {
    try std.testing.expect(etagMatches("\"abc123\"", "\"abc123\""));
    try std.testing.expect(!etagMatches("\"abc123\"", "\"xyz789\""));
}

test "etagMatches wildcard" {
    try std.testing.expect(etagMatches("*", "\"anything\""));
    try std.testing.expect(etagMatches(" * ", "\"anything\""));
}

test "etagMatches weak validator" {
    try std.testing.expect(etagMatches("W/\"abc123\"", "\"abc123\""));
}

test "etagMatches comma-separated list" {
    try std.testing.expect(etagMatches("\"first\", \"second\", \"third\"", "\"second\""));
    try std.testing.expect(!etagMatches("\"first\", \"second\"", "\"third\""));
}

test "Asset creates correct metadata" {
    const TestAsset = Asset("test.css", "body { color: red; }");
    try std.testing.expectEqualStrings("text/css", TestAsset.mime_type);
    try std.testing.expect(TestAsset.etag.len == 18);
    try std.testing.expectEqualStrings("body { color: red; }", TestAsset.data);
}
