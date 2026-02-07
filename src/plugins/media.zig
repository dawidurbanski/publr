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
const media_sync = @import("media_sync");
const storage = @import("storage");
const auth_middleware = @import("auth_middleware");
const media_handler = @import("media_handler");
const registry = @import("registry");
const db_mod = @import("db");
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
    app.postAt("/sync", handleSync);
    app.postAt("/folders", handleCreateFolder);
    app.postAt("/folders/delete", handleDeleteFolder);
    app.postAt("/folders/rename", handleRenameFolder);
    app.postAt("/tags", handleCreateTag);
    app.postAt("/tags/delete", handleDeleteTag);
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

    // Parse query params
    const view_mode = parseQueryParam(ctx.query, "view") orelse "grid";
    const folder_filter = parseQueryParam(ctx.query, "folder");
    const tag_filter = parseQueryParam(ctx.query, "tag");
    const show_unreviewed = parseQueryParam(ctx.query, "unreviewed") != null;

    // Fetch media based on filter
    const entries = blk: {
        if (show_unreviewed) {
            break :blk media.listUnreviewedMedia(ctx.allocator, db, .{
                .limit = 50,
                .order_by = "created_at",
                .order_dir = .desc,
            }) catch &[_]media.MediaRecord{};
        } else if (folder_filter) |fid| {
            break :blk media.listMediaByTerm(ctx.allocator, db, fid, .{
                .limit = 50,
                .order_by = "created_at",
                .order_dir = .desc,
            }) catch &[_]media.MediaRecord{};
        } else if (tag_filter) |tid| {
            break :blk media.listMediaByTerm(ctx.allocator, db, tid, .{
                .limit = 50,
                .order_by = "created_at",
                .order_dir = .desc,
            }) catch &[_]media.MediaRecord{};
        } else {
            break :blk media.listMedia(ctx.allocator, db, .{
                .limit = 50,
                .order_by = "created_at",
                .order_dir = .desc,
            }) catch &[_]media.MediaRecord{};
        }
    };

    // Get total count
    const total_count = media.countMedia(db, .{}) catch 0;
    const unreviewed_count = media.countUnreviewedMedia(db) catch 0;

    // Fetch folders and tags for sidebar
    const folders = media.listTerms(ctx.allocator, db, media.tax_media_folders) catch &[_]media.TermRecord{};
    const tags = media.listTerms(ctx.allocator, db, media.tax_media_tags) catch &[_]media.TermRecord{};

    // Convert folders to view format
    const folder_items = ctx.allocator.alloc(FolderItem, folders.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (folders, 0..) |f, i| {
        const count = media.countMediaInTerm(db, f.id) catch 0;
        folder_items[i] = .{
            .id = f.id,
            .name = f.name,
            .parent_id = f.parent_id orelse "",
            .count = count,
            .is_active = if (folder_filter) |fid| std.mem.eql(u8, fid, f.id) else false,
            .url = std.fmt.allocPrint(ctx.allocator, "?folder={s}", .{f.id}) catch "?folder=",
        };
    }

    // Convert tags to view format
    const tag_items = ctx.allocator.alloc(TagItem, tags.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (tags, 0..) |t, i| {
        const count = media.countMediaInTerm(db, t.id) catch 0;
        tag_items[i] = .{
            .id = t.id,
            .name = t.name,
            .count = count,
            .is_active = if (tag_filter) |tid| std.mem.eql(u8, tid, t.id) else false,
            .url = std.fmt.allocPrint(ctx.allocator, "?tag={s}", .{t.id}) catch "?tag=",
        };
    }

    // Convert media to view format
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
        .folders = folder_items,
        .tags = tag_items,
        .active_folder = folder_filter orelse "",
        .active_tag = tag_filter orelse "",
        .show_unreviewed = show_unreviewed,
        .unreviewed_count = unreviewed_count,
        .view_grid_url = "?view=grid",
        .view_list_url = "?view=list",
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

    // Get folders and tags for this media item
    const all_folders = media.listTerms(ctx.allocator, db, media.tax_media_folders) catch &[_]media.TermRecord{};
    const assigned_folder_ids = media.getMediaTermIds(ctx.allocator, db, media_id, media.tax_media_folders) catch &[_][]const u8{};
    const assigned_tag_ids = media.getMediaTermIds(ctx.allocator, db, media_id, media.tax_media_tags) catch &[_][]const u8{};
    const assigned_tag_names = media.getMediaTermNames(ctx.allocator, db, media_id, media.tax_media_tags) catch &[_][]const u8{};

    // Convert to view format
    const folder_options = ctx.allocator.alloc(FolderOption, all_folders.len) catch {
        redirect(ctx, "/admin/media");
        return;
    };
    for (all_folders, 0..) |f, i| {
        folder_options[i] = .{
            .id = f.id,
            .name = f.name,
            .is_selected = isTermSelected(f.id, assigned_folder_ids),
        };
    }

    // Build comma-separated list of selected folder IDs
    var selected_folder_ids: []const u8 = "";
    if (assigned_folder_ids.len > 0) {
        var buf: std.ArrayList(u8) = .{};
        for (assigned_folder_ids, 0..) |fid, i| {
            if (i > 0) buf.appendSlice(ctx.allocator, ",") catch {};
            buf.appendSlice(ctx.allocator, fid) catch {};
        }
        selected_folder_ids = buf.toOwnedSlice(ctx.allocator) catch "";
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
        .folders = folder_options,
        .tags_display = tag_display,
        .assigned_tag_ids = assigned_tag_ids,
        .selected_folder_ids = selected_folder_ids,
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

    // Update folder assignments (comma-separated in hidden field)
    const folders_input = ctx.formValue("folders");
    // Update tag assignments from comma-separated tag names
    const tags_input = ctx.formValue("tags");

    // Build combined term_ids list
    var all_term_ids: std.ArrayListUnmanaged([]const u8) = .{};
    defer all_term_ids.deinit(ctx.allocator);

    // Add folder term IDs
    if (folders_input) |fids_str| {
        if (fids_str.len > 0) {
            var folder_iter = std.mem.splitScalar(u8, fids_str, ',');
            while (folder_iter.next()) |fid| {
                const trimmed = std.mem.trim(u8, fid, " ");
                if (trimmed.len > 0) {
                    all_term_ids.append(ctx.allocator, trimmed) catch {};
                }
            }
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
                const tag_id = findOrCreateTag(ctx.allocator, db, tag_name) catch continue;
                all_term_ids.append(ctx.allocator, tag_id) catch {};
            }
        }
    }

    // Sync all term associations
    media.syncMediaTerms(db, media_id, all_term_ids.items) catch |err| {
        std.debug.print("Error syncing terms: {}\n", .{err});
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
// Sync, Folder & Tag Handlers
// =============================================================================

fn handleSync(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    storage.initDirectories() catch {};

    const result = media_sync.syncFilesystem(ctx.allocator, db) catch |err| {
        std.debug.print("Sync error: {}\n", .{err});
        redirect(ctx, "/admin/media");
        return;
    };

    // Redirect with result summary in query string
    const url = std.fmt.allocPrint(ctx.allocator, "/admin/media?synced=1&new={d}&missing={d}", .{
        result.new_count,
        result.missing_count,
    }) catch "/admin/media";

    redirect(ctx, url);
}

fn handleCreateFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const name = ctx.formValue("folder_name") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    if (name.len == 0) {
        redirect(ctx, "/admin/media");
        return;
    }

    const parent_id = if (ctx.formValue("parent_id")) |pid| if (pid.len > 0) pid else null else null;

    _ = media.createTerm(ctx.allocator, db, media.tax_media_folders, name, parent_id) catch |err| {
        std.debug.print("Error creating folder: {}\n", .{err});
    };

    redirect(ctx, "/admin/media");
}

fn handleDeleteFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    media.deleteTerm(db, term_id) catch |err| {
        std.debug.print("Error deleting folder: {}\n", .{err});
    };

    redirect(ctx, "/admin/media");
}

fn handleRenameFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };
    const new_name = ctx.formValue("folder_name") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    media.renameTerm(db, term_id, new_name) catch |err| {
        std.debug.print("Error renaming folder: {}\n", .{err});
    };

    redirect(ctx, "/admin/media");
}

fn handleCreateTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const name = ctx.formValue("tag_name") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    if (name.len == 0) {
        redirect(ctx, "/admin/media");
        return;
    }

    _ = media.createTerm(ctx.allocator, db, media.tax_media_tags, name, null) catch |err| {
        std.debug.print("Error creating tag: {}\n", .{err});
    };

    redirect(ctx, "/admin/media");
}

fn handleDeleteTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    media.deleteTerm(db, term_id) catch |err| {
        std.debug.print("Error deleting tag: {}\n", .{err});
    };

    redirect(ctx, "/admin/media");
}

/// Find a tag by name or create it
fn findOrCreateTag(allocator: std.mem.Allocator, db: *db_mod.Db, name: []const u8) ![]const u8 {
    // Check if tag exists
    var stmt = try db.prepare(
        "SELECT id FROM terms WHERE taxonomy_id = ?1 AND name = ?2 LIMIT 1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media.tax_media_tags);
    try stmt.bindText(2, name);

    if (try stmt.step()) {
        return try allocator.dupe(u8, stmt.columnText(0) orelse return error.StepFailed);
    }

    // Create new tag
    const term = try media.createTerm(allocator, db, media.tax_media_tags, name, null);
    return term.id;
}

fn isTermSelected(term_id: []const u8, assigned_ids: []const []const u8) bool {
    for (assigned_ids) |aid| {
        if (std.mem.eql(u8, term_id, aid)) return true;
    }
    return false;
}

// =============================================================================
// Helpers
// =============================================================================

const FolderItem = struct {
    id: []const u8,
    name: []const u8,
    parent_id: []const u8,
    count: u32,
    is_active: bool,
    url: []const u8,
};

const TagItem = struct {
    id: []const u8,
    name: []const u8,
    count: u32,
    is_active: bool,
    url: []const u8,
};

const FolderOption = struct {
    id: []const u8,
    name: []const u8,
    is_selected: bool,
};

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
