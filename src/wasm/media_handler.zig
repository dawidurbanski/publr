//! WASM Media Handler — Serve media from SQLite blobs
//!
//! Handles GET /media/* in the WASM build. Reads file data from the
//! media_files table, checks visibility, determines MIME type, and
//! optionally processes images (resize/convert) before serving.

const std = @import("std");
const Context = @import("middleware").Context;
const wasm_storage = @import("wasm_storage");
const auth_middleware = @import("auth_middleware");
const media_handler = @import("media_handler");
const image = @import("image");
const storage = @import("storage");

/// Handle GET /media/* — serve file from SQLite blob storage
pub fn handleMedia(ctx: *Context) !void {
    const media_path = ctx.wildcard orelse return notFound(ctx);

    // Path security: reject dot-prefixed segments
    if (!media_handler.validatePath(media_path)) return notFound(ctx);

    // Read file data from SQLite
    const data = wasm_storage.readBlob(ctx.allocator, media_path) catch
        return notFound(ctx);
    defer ctx.allocator.free(data);

    // Check visibility — private files require auth
    const vis_str = wasm_storage.readVisibility(ctx.allocator, media_path) catch "public";
    defer ctx.allocator.free(vis_str);

    if (std.mem.eql(u8, vis_str, "private")) {
        const user_id = auth_middleware.getUserId(ctx);
        if (user_id == null) return notFound(ctx);
    }

    // Determine MIME type from extension
    const mime_type = media_handler.getMimeType(media_path);

    // Check if image processing is needed
    const img_params = parseImageParams(ctx, mime_type);
    if (img_params != null and image.isProcessableImage(mime_type)) {
        var result = image.processImage(ctx.allocator, data, img_params.?) catch
            return serveRaw(ctx, data, mime_type);
        defer result.deinit(ctx.allocator);

        ctx.response.setContentType(result.format.mimeType());
        ctx.response.setBody(result.data);
        return;
    }

    serveRaw(ctx, data, mime_type);
}

fn serveRaw(ctx: *Context, data: []const u8, mime_type: []const u8) void {
    ctx.response.setContentType(mime_type);
    ctx.response.setBody(data);
}

/// Parse image processing params from query string
fn parseImageParams(ctx: *Context, mime_type: []const u8) ?image.ImageParams {
    if (!image.isProcessableImage(mime_type)) return null;

    const width = parseDimensionParam(ctx.query, "w=");
    const height = parseDimensionParam(ctx.query, "h=");

    // No Accept header negotiation in WASM (browser handles format natively)
    const needs_resize = width != null or height != null;
    if (!needs_resize) return null;

    return .{
        .width = width,
        .height = height,
        .focal_x = 50,
        .focal_y = 50,
        .fit = .crop,
        .format = null, // Keep source format
        .quality = 90,
    };
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

fn notFound(ctx: *Context) void {
    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
}
