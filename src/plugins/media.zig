//! Media plugin — file management pages
//!
//! Provides the media library UI at /admin/media with list, upload,
//! edit, and delete functionality. Uses the media CRUD API for
//! database operations and storage backend for file management.

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const csrf = @import("csrf");
const media = @import("media");
const storage = @import("storage");
const auth_middleware = @import("auth_middleware");
const media_handler = @import("media_handler");
const registry = @import("registry");
const zsx_admin_media_list = @import("zsx_admin_media_list");
const zsx_admin_media_edit = @import("zsx_admin_media_edit");

/// Media list page (shows in nav at position 25, between Posts and Users)
pub const page = admin.registerPage(.{
    .id = "media",
    .title = "Media",
    .path = "/media",
    .icon = icons.image,
    .position = 25,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleList);
    app.get("/:id", handleEdit);
    app.post(handleUpload);
    app.postAt("/:id", handleUpdate);
    app.postAt("/:id/delete", handleDelete);
    app.postAt("/:id/toggle-visibility", handleToggleVisibility);

    // Wire up focal point DB fallback for image cropping
    media_handler.setFocalPointLookup(lookupFocalPoint);
}

/// Look up focal point from DB by storage key (fallback when fp= param absent).
fn lookupFocalPoint(storage_key: []const u8) ?media_handler.FocalPoint {
    const db = if (auth_middleware.auth) |a| a.db else return null;
    const fp = media.getFocalPoint(db, storage_key) orelse return null;
    return .{ .x = fp.x, .y = fp.y };
}

// =============================================================================
// Handlers
// =============================================================================

fn handleList(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);

    // Parse view mode from query string (default: grid)
    const view_mode = parseQueryParam(ctx.query, "view") orelse "grid";

    // Fetch media from database
    const entries = media.listMedia(ctx.allocator, db, .{
        .limit = 50,
        .order_by = "created_at",
        .order_dir = .desc,
    }) catch |err| {
        std.debug.print("Error listing media: {}\n", .{err});
        const content = tpl.render(zsx_admin_media_list.List, .{.{
            .has_media = false,
            .media = &[_]MediaListItem{},
            .csrf_token = csrf_token,
            .view_mode = view_mode,
            .total_count = 0,
        }});
        ctx.html(registry.renderPage(page, ctx, content, ""));
        return;
    };

    // Get total count
    const total_count = media.countMedia(db, .{}) catch 0;

    // Convert to view format
    var items = ctx.allocator.alloc(MediaListItem, entries.len) catch {
        ctx.html("Error allocating memory");
        return;
    };

    for (entries, 0..) |entry, i| {
        const is_image = std.mem.startsWith(u8, entry.mime_type, "image/");
        const is_private = std.mem.eql(u8, entry.visibility, "private");

        items[i] = .{
            .id = entry.id,
            .filename = entry.filename,
            .mime_type = entry.mime_type,
            .size_display = formatSize(ctx.allocator, entry.size) catch "?",
            .visibility = entry.visibility,
            .edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}", .{entry.id}) catch "/admin/media",
            .delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}/delete", .{entry.id}) catch "/admin/media",
            .thumb_url = if (is_image) std.fmt.allocPrint(ctx.allocator, "/media/{s}?w=200", .{entry.storage_key}) catch "" else "",
            .is_image = is_image,
            .is_private = is_private,
        };
    }

    const content = tpl.render(zsx_admin_media_list.List, .{.{
        .has_media = items.len > 0,
        .media = items,
        .csrf_token = csrf_token,
        .view_mode = view_mode,
        .total_count = total_count,
    }});

    ctx.html(registry.renderPage(page, ctx, content, ""));
}

fn handleEdit(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);
    const media_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    const record = media.getMedia(ctx.allocator, db, media_id) catch {
        redirect(ctx, "/admin/media");
        return;
    } orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    const is_image = std.mem.startsWith(u8, record.mime_type, "image/");
    const is_private = std.mem.eql(u8, record.visibility, "private");

    const dimensions = if (record.width != null and record.height != null)
        std.fmt.allocPrint(ctx.allocator, "{d} x {d}", .{ record.width.?, record.height.? }) catch ""
    else
        "";

    const content = tpl.render(zsx_admin_media_edit.Edit, .{.{
        .media = .{
            .id = record.id,
            .filename = record.filename,
            .mime_type = record.mime_type,
            .size_display = formatSize(ctx.allocator, record.size) catch "?",
            .dimensions = dimensions,
            .visibility = record.visibility,
            .is_image = is_image,
            .is_private = is_private,
            .preview_url = if (is_image) std.fmt.allocPrint(ctx.allocator, "/media/{s}?w=600", .{record.storage_key}) catch "" else "",
            .media_url = std.fmt.allocPrint(ctx.allocator, "/media/{s}", .{record.storage_key}) catch "",
            .alt_text = record.data.alt_text orelse "",
            .caption = record.data.caption orelse "",
            .credit = record.data.credit orelse "",
            .focal_point = record.data.focal_point orelse "",
            .created_at = std.fmt.allocPrint(ctx.allocator, "{d}", .{record.created_at}) catch "?",
        },
        .csrf_token = csrf_token,
        .action = std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}", .{media_id}) catch "/admin/media",
        .delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}/delete", .{media_id}) catch "/admin/media",
        .toggle_url = std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}/toggle-visibility", .{media_id}) catch "/admin/media",
    }});

    ctx.html(registry.renderPage(page, ctx, content, ""));
}

fn handleUpload(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const body_content = ctx.body orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    // Get Content-Type header to extract boundary
    const content_type = ctx.getRequestHeader("Content-Type") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    // Parse multipart boundary
    const boundary = parseMultipartBoundary(content_type) orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    // Parse file from multipart form data
    const file_data = parseMultipartFile(body_content, boundary) orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    // Detect image dimensions if applicable
    const width: ?i64 = null;
    const height: ?i64 = null;
    if (std.mem.startsWith(u8, file_data.content_type, "image/")) {
        // Image dimension detection would go here — requires stb_image
        // For now, leave as null; dimensions are optional
    }

    // Upload: validate, store, create DB record
    _ = media.uploadMedia(ctx.allocator, db, storage.filesystem, .{
        .filename = file_data.filename,
        .mime_type = file_data.content_type,
        .data = file_data.data,
        .width = width,
        .height = height,
    }) catch |err| {
        std.debug.print("Upload error: {}\n", .{err});
        redirect(ctx, "/admin/media");
        return;
    };

    redirect(ctx, "/admin/media");
}

fn handleUpdate(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const media_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    // Parse form data
    const alt_text = ctx.formValue("alt_text");
    const caption = ctx.formValue("caption");
    const credit = ctx.formValue("credit");
    const focal_point = ctx.formValue("focal_point");

    const new_fp = if (focal_point) |v| if (v.len > 0) v else null else null;

    // Check if focal point changed — if so, invalidate resized cache
    if (new_fp != null) {
        if (media.getMedia(ctx.allocator, db, media_id) catch null) |record| {
            const old_fp = record.data.focal_point orelse "";
            if (!std.mem.eql(u8, old_fp, new_fp.?)) {
                storage.deleteResizedDerivatives(ctx.allocator, record.storage_key) catch |err| {
                    std.debug.print("Error invalidating cache: {}\n", .{err});
                };
            }
        }
    }

    const schema = @import("schema_media");

    _ = media.updateMedia(ctx.allocator, db, media_id, schema.Media.Data{
        .alt_text = if (alt_text) |v| if (v.len > 0) v else null else null,
        .caption = if (caption) |v| if (v.len > 0) v else null else null,
        .credit = if (credit) |v| if (v.len > 0) v else null else null,
        .focal_point = new_fp,
    }) catch |err| {
        std.debug.print("Error updating media: {}\n", .{err});
    };

    redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}", .{media_id}) catch "/admin/media");
}

fn handleDelete(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const media_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    media.fullDeleteMedia(ctx.allocator, db, storage.filesystem, media_id) catch |err| {
        std.debug.print("Error deleting media: {}\n", .{err});
    };

    redirect(ctx, "/admin/media");
}

fn handleToggleVisibility(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const media_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    media.toggleMediaVisibility(ctx.allocator, db, media_id) catch |err| {
        std.debug.print("Error toggling visibility: {}\n", .{err});
    };

    redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}", .{media_id}) catch "/admin/media");
}

// =============================================================================
// Helpers
// =============================================================================

const MediaListItem = struct {
    id: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    size_display: []const u8,
    visibility: []const u8,
    edit_url: []const u8,
    delete_url: []const u8,
    thumb_url: []const u8,
    is_image: bool,
    is_private: bool,
};

fn redirect(ctx: *Context, location: []const u8) void {
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", location);
    ctx.response.setBody("");
}

fn formatSize(allocator: std.mem.Allocator, size: i64) ![]const u8 {
    const s: u64 = @intCast(if (size < 0) 0 else size);
    if (s < 1024) {
        return std.fmt.allocPrint(allocator, "{d} B", .{s});
    } else if (s < 1024 * 1024) {
        return std.fmt.allocPrint(allocator, "{d} KB", .{s / 1024});
    } else {
        return std.fmt.allocPrint(allocator, "{d}.{d} MB", .{ s / (1024 * 1024), (s % (1024 * 1024)) * 10 / (1024 * 1024) });
    }
}

fn parseQueryParam(query: ?[]const u8, name: []const u8) ?[]const u8 {
    const q = query orelse return null;
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq_pos| {
            if (std.mem.eql(u8, pair[0..eq_pos], name)) {
                return pair[eq_pos + 1 ..];
            }
        }
    }
    return null;
}

/// Parse multipart boundary from Content-Type header
fn parseMultipartBoundary(content_type: []const u8) ?[]const u8 {
    const marker = "boundary=";
    const idx = std.mem.indexOf(u8, content_type, marker) orelse return null;
    return content_type[idx + marker.len ..];
}

/// Parsed file from multipart form data
const MultipartFile = struct {
    filename: []const u8,
    content_type: []const u8,
    data: []const u8,
};

/// Parse a file field from multipart form data
fn parseMultipartFile(body: []const u8, boundary: []const u8) ?MultipartFile {
    // Multipart format: --boundary\r\nHeaders\r\n\r\nData\r\n--boundary--
    // Iterate parts to find one with a filename

    // Build delimiter: "\r\n--" + boundary
    var delim_buf: [256]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "\r\n--{s}", .{boundary}) catch return null;

    // Find first part boundary (starts with --boundary\r\n)
    var start_marker_buf: [256]u8 = undefined;
    const start_marker = std.fmt.bufPrint(&start_marker_buf, "--{s}\r\n", .{boundary}) catch return null;

    var pos = std.mem.indexOf(u8, body, start_marker) orelse return null;
    pos += start_marker.len;

    // Iterate through parts
    while (pos < body.len) {
        // Find end of headers (blank line)
        const headers_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse return null;
        const headers = body[pos .. pos + headers_end];
        const data_start = pos + headers_end + 4;

        // Find end of this part's data
        const data_end_rel = std.mem.indexOf(u8, body[data_start..], delim) orelse body.len - data_start;

        // Check if this part has a filename (file field, not text field)
        if (std.mem.indexOf(u8, headers, "filename=\"")) |_| {
            var filename: []const u8 = "upload";
            var content_type_val: []const u8 = "application/octet-stream";

            // Parse headers for filename and content type
            var hdr_iter = std.mem.splitSequence(u8, headers, "\r\n");
            while (hdr_iter.next()) |header_line| {
                if (std.ascii.startsWithIgnoreCase(header_line, "Content-Disposition:")) {
                    if (std.mem.indexOf(u8, header_line, "filename=\"")) |fn_start| {
                        const name_start = fn_start + "filename=\"".len;
                        if (std.mem.indexOfPos(u8, header_line, name_start, "\"")) |name_end| {
                            filename = header_line[name_start..name_end];
                        }
                    }
                } else if (std.ascii.startsWithIgnoreCase(header_line, "Content-Type:")) {
                    const ct = std.mem.trimLeft(u8, header_line["Content-Type:".len..], " ");
                    if (ct.len > 0) content_type_val = ct;
                }
            }

            // Skip empty file fields (user clicked upload without selecting a file)
            if (filename.len == 0 or data_end_rel == 0) {
                // Fall through to advance to next part
            } else {
                return .{
                    .filename = filename,
                    .content_type = content_type_val,
                    .data = body[data_start .. data_start + data_end_rel],
                };
            }
        }

        // Advance past this part's data + delimiter to next part's headers
        const next_part = data_start + data_end_rel + delim.len;
        // Skip the \r\n after the delimiter to get to the next part's headers
        if (next_part + 2 <= body.len and body[next_part] == '\r' and body[next_part + 1] == '\n') {
            pos = next_part + 2;
        } else {
            break; // End of multipart (--boundary--)
        }
    }

    return null;
}
