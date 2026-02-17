//! Media CRUD handlers — edit, upload, update, delete, toggle visibility.

const std = @import("std");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const csrf = @import("csrf");
const media = @import("media");
const storage = @import("storage");
const auth_middleware = @import("auth_middleware");
const registry = @import("registry");
const db_mod = @import("db");
const views = @import("views");
const multipart = @import("multipart");

const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32;

const h = @import("helpers.zig");

pub fn handleEdit(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);
    const media_id = ctx.param("id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const record = media.getMedia(ctx.allocator, db, media_id) catch {
        h.redirect(ctx, "/admin/media");
        return;
    } orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const is_image = std.mem.startsWith(u8, record.mime_type, "image/");
    const is_private = std.mem.eql(u8, record.visibility, "private");

    const dimensions = if (record.width != null and record.height != null)
        std.fmt.allocPrint(ctx.allocator, "{d} x {d}", .{ record.width.?, record.height.? }) catch ""
    else
        "";

    // Get folders and tags for this media item
    const all_folders = media.listTerms(ctx.allocator, db, media.tax_media_folders) catch &[_]media.TermRecord{};
    const assigned_folder_ids = media.getMediaTermIds(ctx.allocator, db, media_id, media.tax_media_folders) catch &[_][]const u8{};
    const assigned_tag_ids = media.getMediaTermIds(ctx.allocator, db, media_id, media.tax_media_tags) catch &[_][]const u8{};
    const assigned_tag_names = media.getMediaTermNames(ctx.allocator, db, media_id, media.tax_media_tags) catch &[_][]const u8{};

    // Single folder assignment: get current folder ID (first one, or empty)
    const current_folder_id: []const u8 = if (assigned_folder_ids.len > 0) assigned_folder_ids[0] else "";

    // Build tree-ordered folder list (reuse sidebar tree builder)
    const tree_items = h.buildFolderTree(ctx.allocator, all_folders, db, null, "", &[_][]const u8{}, null, null, null, null) catch {
        h.redirect(ctx, "/admin/media");
        return;
    };
    const folder_options = ctx.allocator.alloc(h.FolderOption, tree_items.len) catch {
        h.redirect(ctx, "/admin/media");
        return;
    };
    for (tree_items, 0..) |f, i| {
        folder_options[i] = .{
            .id = f.id,
            .name = f.name,
            .depth = f.depth,
            .is_selected = std.mem.eql(u8, f.id, current_folder_id),
        };
    }

    // Build tag options with selection state
    const all_tags_records = media.listTerms(ctx.allocator, db, media.tax_media_tags) catch &[_]media.TermRecord{};
    const tag_options = ctx.allocator.alloc(h.TagOption, all_tags_records.len) catch {
        h.redirect(ctx, "/admin/media");
        return;
    };
    for (all_tags_records, 0..) |t, i| {
        tag_options[i] = .{
            .id = t.id,
            .name = t.name,
            .is_selected = h.isTermSelected(t.id, assigned_tag_ids),
        };
    }

    // Join tag names with comma for display
    var tag_display: []const u8 = "";
    if (assigned_tag_names.len > 0) {
        var buf: std.ArrayList(u8) = .{};
        for (assigned_tag_names, 0..) |name, i| {
            if (i > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
            buf.appendSlice(ctx.allocator, name) catch {};
        }
        tag_display = buf.toOwnedSlice(ctx.allocator) catch "";
    }

    const page_reg = @import("main.zig").page;

    const content = tpl.render(views.admin.media.edit.Edit, .{.{
        .media = .{
            .id = record.id,
            .filename = record.filename,
            .mime_type = record.mime_type,
            .size_display = h.formatSize(ctx.allocator, record.size) catch "?",
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
        .folders = folder_options,
        .all_tags = tag_options,
        .tags_display = tag_display,
        .current_folder_id = current_folder_id,
    }});

    ctx.html(registry.renderPage(page_reg, ctx, content));
}

pub fn handleUpload(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const body_content = ctx.body orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    // Get Content-Type header to extract boundary
    const content_type = ctx.getRequestHeader("Content-Type") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    // Parse multipart boundary
    const boundary = multipart.parseMultipartBoundary(content_type) orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    // Parse file from multipart form data
    const file_data = multipart.parseMultipartFile(ctx.allocator, body_content, boundary) orelse {
        h.redirect(ctx, "/admin/media");
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
    const record = media.uploadMedia(ctx.allocator, db, h.getBackend(), .{
        .filename = file_data.filename,
        .mime_type = file_data.content_type,
        .data = file_data.data,
        .width = width,
        .height = height,
    }) catch |err| {
        std.debug.print("Upload error: {}\n", .{err});
        h.redirect(ctx, "/admin/media");
        return;
    };

    // Assign to folder if specified
    const folder_id = multipart.parseMultipartField(ctx.allocator, body_content, boundary, "folder_id");
    if (folder_id) |fid| {
        if (fid.len > 0) {
            media.addTermToMedia(db, record.id, fid) catch {};
        }
    }

    h.redirect(ctx, "/admin/media");
}

pub fn handleUpdate(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const media_id = ctx.param("id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    // Parse form data
    const alt_text = ctx.formValue("alt_text");
    const caption = ctx.formValue("caption");
    const credit = ctx.formValue("credit");
    const focal_point = ctx.formValue("focal_point");

    const new_fp = if (focal_point) |v| if (v.len > 0) v else null else null;

    // Check if focal point changed — if so, invalidate resized cache
    if (!is_wasm) {
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

    // Update folder assignment (single folder — filesystem model)
    const folder_input = ctx.formValue("folder");
    // Update tag assignments from comma-separated tag names
    const tags_input = ctx.formValue("tags");

    // Build combined term_ids list
    var all_term_ids: std.ArrayListUnmanaged([]const u8) = .{};
    defer all_term_ids.deinit(ctx.allocator);

    // Add single folder term ID (if selected)
    if (folder_input) |fid| {
        const trimmed = std.mem.trim(u8, fid, " ");
        if (trimmed.len > 0) {
            all_term_ids.append(ctx.allocator, trimmed) catch {};
        }
    }

    // Resolve tag names to IDs (create if needed)
    if (tags_input) |tags_str| {
        if (tags_str.len > 0) {
            var tag_iter = std.mem.splitScalar(u8, tags_str, ',');
            while (tag_iter.next()) |raw_tag| {
                const tag_name = std.mem.trim(u8, raw_tag, " ");
                if (tag_name.len == 0) continue;

                // Find existing tag or create new one
                const tag_id = h.findOrCreateTag(ctx.allocator, db, tag_name) catch continue;
                all_term_ids.append(ctx.allocator, tag_id) catch {};
            }
        }
    }

    // Sync all term associations
    media.syncMediaTerms(db, media_id, all_term_ids.items) catch |err| {
        std.debug.print("Error syncing terms: {}\n", .{err});
    };

    h.redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}", .{media_id}) catch "/admin/media");
}

pub fn handleDelete(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const media_id = ctx.param("id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    media.fullDeleteMedia(ctx.allocator, db, h.getBackend(), media_id) catch |err| {
        std.debug.print("Error deleting media: {}\n", .{err});
    };

    h.redirect(ctx, "/admin/media");
}

pub fn handleToggleVisibility(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const media_id = ctx.param("id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    media.toggleMediaVisibility(ctx.allocator, db, media_id) catch |err| {
        std.debug.print("Error toggling visibility: {}\n", .{err});
    };

    h.redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}", .{media_id}) catch "/admin/media");
}

test "admin media crud: unauthenticated branches" {
    var edit_ctx = Context.init(std.heap.page_allocator, .GET, "/admin/media/1");
    defer edit_ctx.deinit();
    try handleEdit(&edit_ctx);
    try std.testing.expectEqualStrings("303 See Other", edit_ctx.response.status);

    var upload_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/upload");
    defer upload_ctx.deinit();
    try handleUpload(&upload_ctx);
    try std.testing.expectEqualStrings("303 See Other", upload_ctx.response.status);

    var update_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/1");
    defer update_ctx.deinit();
    try handleUpdate(&update_ctx);
    try std.testing.expectEqualStrings("303 See Other", update_ctx.response.status);

    var delete_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/1/delete");
    defer delete_ctx.deinit();
    try handleDelete(&delete_ctx);
    try std.testing.expectEqualStrings("303 See Other", delete_ctx.response.status);

    var toggle_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/1/toggle");
    defer toggle_ctx.deinit();
    try handleToggleVisibility(&toggle_ctx);
    try std.testing.expectEqualStrings("303 See Other", toggle_ctx.response.status);
}

test "admin media crud: public API coverage" {
    _ = handleEdit;
    _ = handleUpload;
    _ = handleUpdate;
    _ = handleDelete;
    _ = handleToggleVisibility;
}
