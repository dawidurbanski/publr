//! API handlers — picker list, picker thumb, sync, scan.

const std = @import("std");
const Context = @import("middleware").Context;
const media = @import("media");
const storage = @import("storage");
const auth_middleware = @import("auth_middleware");

const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32;

// Conditional imports: media_sync uses filesystem APIs
const media_sync = if (is_wasm) struct {} else @import("media_sync");

const h = @import("helpers.zig");

/// JSON endpoint for image picker modal - lists media items for selection
pub fn handlePickerList(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"items\":[],\"folders\":[],\"tags\":[]}");
        return;
    };

    // Parse filters
    const raw_search = h.parseQueryParam(ctx.query, "search");
    const search_term: ?[]const u8 = if (raw_search) |s| if (s.len > 0) h.percentDecode(ctx.allocator, s) else null else null;
    const search_pattern: ?[]const u8 = if (search_term) |s| std.fmt.allocPrint(ctx.allocator, "%{s}%", .{s}) catch null else null;
    const folder_filter = h.parseQueryParam(ctx.query, "folder");
    const active_tag_ids = h.parseQueryParamAll(ctx.allocator, ctx.query, "tag");

    // Parse accept filter (e.g., "image/*" or "image/*,image/svg+xml")
    const raw_accept = h.parseQueryParam(ctx.query, "accept");
    const accept_filter: ?[]const u8 = if (raw_accept) |a| if (a.len > 0) h.percentDecode(ctx.allocator, a) else null else null;

    // Database-level mime type filtering via mime_patterns
    const list_opts: media.MediaListOptions = .{
        .limit = 50, // Only fetch what we display
        .offset = 0,
        .order_by = "created_at",
        .order_dir = .desc,
        .search = search_pattern,
        .mime_patterns = accept_filter,
    };

    // Fetch media matching folder/tag/search/mime filters at database level
    const entries = blk: {
        if (folder_filter) |fid| {
            if (std.mem.eql(u8, fid, "default")) {
                break :blk media.listUnsortedMedia(ctx.allocator, db, media.tax_media_folders, list_opts) catch &[_]media.MediaRecord{};
            } else {
                const folder_ids = media.getDescendantFolderIds(ctx.allocator, db, fid) catch &[_][]const u8{};
                break :blk media.listMediaByFolderAndTags(ctx.allocator, db, folder_ids, active_tag_ids, list_opts) catch &[_]media.MediaRecord{};
            }
        } else if (active_tag_ids.len > 0) {
            break :blk media.listMediaByTerms(ctx.allocator, db, active_tag_ids, list_opts) catch &[_]media.MediaRecord{};
        } else {
            break :blk media.listMedia(ctx.allocator, db, list_opts) catch &[_]media.MediaRecord{};
        }
    };

    // Fetch folders and tags for sidebar
    const folders = media.listTerms(ctx.allocator, db, media.tax_media_folders) catch &[_]media.TermRecord{};
    const tags = media.listTerms(ctx.allocator, db, media.tax_media_tags) catch &[_]media.TermRecord{};

    // Build JSON response using ArrayListUnmanaged
    var json: std.ArrayListUnmanaged(u8) = .{};
    var writer = json.writer(ctx.allocator);

    // Start JSON object
    writer.writeAll("{") catch {};

    // Items array (limited to 50 for display)
    writer.writeAll("\"items\":[") catch {};
    const display_limit: usize = @min(entries.len, 50);
    for (entries[0..display_limit], 0..) |entry, i| {
        if (i > 0) writer.writeAll(",") catch {};

        const is_image = std.mem.startsWith(u8, entry.mime_type, "image/");
        const alt_text = entry.data.alt_text orelse "";
        const thumb_url = if (is_image)
            std.fmt.allocPrint(ctx.allocator, "/media/{s}?w=150", .{entry.storage_key}) catch ""
        else
            "";

        writer.print(
            \\{{"id":"{s}","filename":"{s}","mime_type":"{s}","is_image":{s},"thumb_url":"{s}","alt_text":"{s}"}}
        , .{
            entry.id,
            entry.filename,
            entry.mime_type,
            if (is_image) "true" else "false",
            thumb_url,
            alt_text,
        }) catch {};
    }
    writer.writeAll("],") catch {};

    // Folders array with counts (filtered at database level with mime_patterns)
    writer.writeAll("\"folders\":[") catch {};
    const unsorted_count = media.countUnsortedInContext(ctx.allocator, db, media.tax_media_folders, active_tag_ids, search_pattern, null, null, accept_filter) catch 0;
    writer.print("{{\"id\":\"default\",\"name\":\"Default\",\"parent_id\":\"\",\"count\":{d}}}", .{unsorted_count}) catch {};
    for (folders) |folder| {
        writer.writeAll(",") catch {};
        const count = media.countFolderInContext(ctx.allocator, db, folder.id, active_tag_ids, search_pattern, null, null, accept_filter) catch 0;
        writer.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"parent_id\":\"{s}\",\"count\":{d}}}", .{
            folder.id,
            folder.name,
            folder.parent_id orelse "",
            count,
        }) catch {};
    }
    writer.writeAll("],") catch {};

    // Tags array with counts (filtered at database level with mime_patterns)
    writer.writeAll("\"tags\":[") catch {};
    for (tags, 0..) |tag, i| {
        if (i > 0) writer.writeAll(",") catch {};
        const count = media.countTagInContext(ctx.allocator, db, tag.id, folder_filter, active_tag_ids, search_pattern, null, null, accept_filter) catch 0;
        writer.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"count\":{d}}}", .{
            tag.id,
            tag.name,
            count,
        }) catch {};
    }
    writer.writeAll("],") catch {};

    // Active filters for state
    writer.print("\"active_folder\":\"{s}\",", .{folder_filter orelse ""}) catch {};
    writer.writeAll("\"active_tags\":[") catch {};
    for (active_tag_ids, 0..) |tid, i| {
        if (i > 0) writer.writeAll(",") catch {};
        writer.print("\"{s}\"", .{tid}) catch {};
    }
    writer.writeAll("]") catch {};

    writer.writeAll("}") catch {};

    ctx.response.setHeader("Content-Type", "application/json");
    ctx.response.setBody(json.items);
}

/// Returns a thumbnail for a specific media item by ID (for image picker preview)
pub fn handlePickerThumb(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const media_id = ctx.param("id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Media not found");
        return;
    };

    const record = media.getMedia(ctx.allocator, db, media_id) catch {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Media not found");
        return;
    } orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Media not found");
        return;
    };

    // Redirect to the actual media URL with resize parameter
    const is_image = std.mem.startsWith(u8, record.mime_type, "image/");
    const url = if (is_image)
        std.fmt.allocPrint(ctx.allocator, "/media/{s}?w=300", .{record.storage_key}) catch "/admin/media"
    else
        std.fmt.allocPrint(ctx.allocator, "/media/{s}", .{record.storage_key}) catch "/admin/media";

    h.redirect(ctx, url);
}

pub fn handleSync(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    storage.initDirectories() catch {};

    const result = media_sync.syncFilesystem(ctx.allocator, db) catch |err| {
        std.debug.print("Sync error: {}\n", .{err});
        h.redirect(ctx, "/admin/media");
        return;
    };

    // Redirect with result summary in query string
    const url = std.fmt.allocPrint(ctx.allocator, "/admin/media?synced=1&new={d}&missing={d}", .{
        result.new_count,
        result.missing_count,
    }) catch "/admin/media";

    h.redirect(ctx, url);
}

pub fn handleScan(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    storage.initDirectories() catch {};

    const count = media_sync.countNewFilesOnDisk(ctx.allocator, db) catch |err| {
        std.debug.print("Scan error: {}\n", .{err});
        h.redirect(ctx, "/admin/media");
        return;
    };

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/media?scan_result={d}", .{count}) catch "/admin/media";
    h.redirect(ctx, url);
}

test "admin media api: unauthenticated branches" {
    var picker = Context.init(std.heap.page_allocator, .GET, "/admin/media/picker/list");
    defer picker.deinit();
    try handlePickerList(&picker);
    try std.testing.expect(std.mem.indexOf(u8, picker.response.body, "\"items\":[]") != null);

    var thumb = Context.init(std.heap.page_allocator, .GET, "/admin/media/picker/thumb");
    defer thumb.deinit();
    try handlePickerThumb(&thumb);
    try std.testing.expectEqualStrings("303 See Other", thumb.response.status);

    var sync_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/sync");
    defer sync_ctx.deinit();
    try handleSync(&sync_ctx);
    try std.testing.expectEqualStrings("303 See Other", sync_ctx.response.status);

    var scan_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/scan");
    defer scan_ctx.deinit();
    try handleScan(&scan_ctx);
    try std.testing.expectEqualStrings("303 See Other", scan_ctx.response.status);
}

test "admin media api: public API coverage" {
    _ = handlePickerList;
    _ = handlePickerThumb;
    _ = handleSync;
    _ = handleScan;
}
