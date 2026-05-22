//! GET /admin/editors/<id>/<asset> — serves static assets declared by an
//! editor in the registry (see `src/editors.zig`). 404s on unknown id or
//! unknown asset name. Mirrors the caching policy of `/static/*`
//! (immutable, max-age=31536000, ETag, 304 on `If-None-Match`).

const std = @import("std");
// Import Context from middleware (not router) so the handler is reachable
// from both the native http.zig graph and the wasm/main.zig graph — wasm
// doesn't ship the `router` module, only `wasm_router`.
const Context = @import("middleware").Context;
const editors = @import("editors");

/// ETag length: '"' + 16 hex chars + '"'
const ETAG_LEN = 18;

fn computeEtag(content: []const u8) [ETAG_LEN]u8 {
    const hash = std.hash.Fnv1a_64.hash(content);
    const hex_chars = "0123456789abcdef";
    var buf: [ETAG_LEN]u8 = undefined;
    buf[0] = '"';
    var h = hash;
    for (0..16) |i| {
        buf[16 - i] = hex_chars[@as(usize, @intCast(h & 0xf))];
        h >>= 4;
    }
    buf[17] = '"';
    return buf;
}

fn etagMatches(client_etag: []const u8, server_etag: []const u8) bool {
    const trimmed = std.mem.trim(u8, client_etag, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;
    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |part| {
        var tag = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, tag, "W/")) tag = tag[2..];
        if (std.mem.eql(u8, tag, server_etag)) return true;
    }
    return false;
}

fn notFound(ctx: *Context) void {
    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
}

pub fn handleEditorAsset(ctx: *Context) !void {
    const path = ctx.wildcard orelse return notFound(ctx);

    // path looks like "<editor_id>/<asset_name>" — split on the first '/'.
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return notFound(ctx);
    const editor_id = path[0..slash];
    const asset_name = path[slash + 1 ..];
    if (editor_id.len == 0 or asset_name.len == 0) return notFound(ctx);

    const editor = editors.get(editor_id) orelse return notFound(ctx);

    for (editor.assets) |asset| {
        if (!std.mem.eql(u8, asset.name, asset_name)) continue;

        const etag = computeEtag(asset.content);
        if (ctx.getRequestHeader("If-None-Match")) |client_etag| {
            if (etagMatches(client_etag, &etag)) {
                ctx.response.setStatus("304 Not Modified");
                // setHeaderOwned copies into the response's header buffer.
                // Required: `etag` is a stack-local [18]u8, gone the moment
                // this handler returns. setHeader stores the slice ref
                // verbatim, so a non-owned pointer becomes dangling by the
                // time the router writes the response.
                ctx.response.setHeaderOwned("ETag", &etag);
                return;
            }
        }
        ctx.response.setContentType(asset.content_type);
        ctx.response.setBody(asset.content);
        ctx.response.setHeaderOwned("ETag", &etag);
        ctx.response.setHeader("Cache-Control", "public, max-age=31536000, immutable");
        return;
    }

    notFound(ctx);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "computeEtag is deterministic and 18 bytes" {
    const a = computeEtag("abc");
    const b = computeEtag("abc");
    try std.testing.expectEqualStrings(&a, &b);
    try std.testing.expect(a.len == 18);
    try std.testing.expect(a[0] == '"' and a[17] == '"');
}

test "computeEtag differs for different content" {
    const a = computeEtag("aaa");
    const b = computeEtag("bbb");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "etagMatches handles exact, wildcard, weak, list" {
    const server = "\"abc\"";
    try std.testing.expect(etagMatches("\"abc\"", server));
    try std.testing.expect(etagMatches("*", server));
    try std.testing.expect(etagMatches("W/\"abc\"", server));
    try std.testing.expect(etagMatches("\"x\", \"abc\"", server));
    try std.testing.expect(!etagMatches("\"xyz\"", server));
}
