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
const registry = @import("registry");
const db_mod = @import("db");
const zsx_admin_media_list = @import("zsx_admin_media_list");
const zsx_admin_media_edit = @import("zsx_admin_media_edit");

const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32;

// Conditional imports: media_sync and media_handler use filesystem APIs
const media_sync = if (is_wasm) struct {} else @import("media_sync");
const media_handler = if (is_wasm) struct {
    pub const FocalPoint = struct { x: u8, y: u8 };
    pub const FocalPointFn = *const fn ([]const u8) ?FocalPoint;
    pub fn setFocalPointLookup(_: FocalPointFn) void {}
} else @import("media_handler");

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
    app.get("/picker/list", handlePickerList);
    app.get("/picker/thumb/:id", handlePickerThumb);
    app.post(handleUpload);
    if (!is_wasm) {
        app.postAt("/sync", handleSync);
        app.postAt("/scan", handleScan);
    }
    app.postAt("/folders", handleCreateFolder);
    app.postAt("/folders/delete", handleDeleteFolder);
    app.postAt("/folders/rename", handleRenameFolder);
    app.postAt("/folders/move", handleMoveFolder);
    app.postAt("/tags", handleCreateTag);
    app.postAt("/tags/delete", handleDeleteTag);
    app.postAt("/bulk/delete", handleBulkDelete);
    app.postAt("/bulk/add-tag", handleBulkAddTag);
    app.postAt("/bulk/remove-tag", handleBulkRemoveTag);
    app.postAt("/bulk/move-folder", handleBulkMoveFolder);
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
    const active_tag_ids = parseQueryParamAll(ctx.allocator, ctx.query, "tag");
    const show_unreviewed = parseQueryParam(ctx.query, "unreviewed") != null;
    const raw_search = parseQueryParam(ctx.query, "search");
    const search_term: ?[]const u8 = if (raw_search) |s| if (s.len > 0) percentDecode(ctx.allocator, s) else null else null;
    const search_pattern: ?[]const u8 = if (search_term) |s| std.fmt.allocPrint(ctx.allocator, "%{s}%", .{s}) catch null else null;

    // Parse date filters
    const year_filter: ?u16 = parseIntParam(ctx.query, "year", u16);
    const month_filter: ?u8 = parseIntParam(ctx.query, "month", u8);

    // Parse scan result (from handleScan redirect)
    const scan_result: ?u32 = parseIntParam(ctx.query, "scan_result", u32);

    // Pagination
    const items_per_page: u32 = 25;
    const current_page: u32 = @max(1, parseIntParam(ctx.query, "page", u32) orelse 1);
    const offset: u32 = (current_page - 1) * items_per_page;

    // Fetch media based on combined filters
    const list_opts: media.MediaListOptions = .{
        .limit = items_per_page,
        .offset = offset,
        .order_by = "created_at",
        .order_dir = .desc,
        .search = search_pattern,
        .year = year_filter,
        .month = month_filter,
    };

    const entries = blk: {
        if (show_unreviewed) {
            break :blk media.listUnreviewedMedia(ctx.allocator, db, list_opts) catch &[_]media.MediaRecord{};
        }

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

    // Get counts
    const total_count = media.countMedia(db, .{ .search = search_pattern }) catch 0;
    const unsorted_count = media.countUnsortedInContext(ctx.allocator, db, media.tax_media_folders, active_tag_ids, search_pattern, year_filter, month_filter) catch total_count;
    const unreviewed_count = media.countUnreviewedMedia(ctx.allocator, db, search_pattern, year_filter, month_filter) catch 0;

    // Compute filtered count for pagination (matches the list query dispatch)
    const filtered_count: u32 = blk: {
        if (show_unreviewed) break :blk unreviewed_count;
        if (folder_filter) |fid| {
            if (std.mem.eql(u8, fid, "default")) {
                break :blk unsorted_count;
            } else {
                break :blk media.countFolderInContext(ctx.allocator, db, fid, active_tag_ids, search_pattern, year_filter, month_filter) catch 0;
            }
        } else if (active_tag_ids.len > 0) {
            break :blk media.countAllInContext(ctx.allocator, db, active_tag_ids, search_pattern, year_filter, month_filter) catch 0;
        } else {
            break :blk total_count;
        }
    };

    const total_pages: u32 = if (filtered_count == 0) 1 else (filtered_count + items_per_page - 1) / items_per_page;

    // Fetch folders and tags for sidebar
    const folders = media.listTerms(ctx.allocator, db, media.tax_media_folders) catch &[_]media.TermRecord{};
    const tags = media.listTerms(ctx.allocator, db, media.tax_media_tags) catch &[_]media.TermRecord{};

    // Fetch date periods for sidebar selects
    const raw_years = media.getDistinctYears(ctx.allocator, db) catch &[_]u16{};
    const year_options: []const YearOption = blk: {
        const opts = ctx.allocator.alloc(YearOption, raw_years.len) catch break :blk &[_]YearOption{};
        for (raw_years, 0..) |yr, i| {
            opts[i] = .{
                .value = std.fmt.allocPrint(ctx.allocator, "{d}", .{yr}) catch "",
                .label = std.fmt.allocPrint(ctx.allocator, "{d}", .{yr}) catch "",
                .is_selected = if (year_filter) |ay| ay == yr else false,
            };
        }
        break :blk opts;
    };
    const raw_months: []const u8 = if (year_filter) |y|
        (media.getMonthsForYear(ctx.allocator, db, y) catch &[_]u8{})
    else
        &[_]u8{};
    const month_options: []const MonthOption = blk: {
        const opts = ctx.allocator.alloc(MonthOption, raw_months.len) catch break :blk &[_]MonthOption{};
        for (raw_months, 0..) |mo, i| {
            opts[i] = .{
                .value = std.fmt.allocPrint(ctx.allocator, "{d}", .{mo}) catch "",
                .label = monthName(mo),
                .is_selected = if (month_filter) |am| am == mo else false,
            };
        }
        break :blk opts;
    };

    // Build folder tree
    const folder_items = buildFolderTree(ctx.allocator, folders, db, folder_filter, view_mode, active_tag_ids, search_pattern, search_term, year_filter, month_filter) catch {
        ctx.html("Error building folder tree");
        return;
    };

    // Convert tags to view format
    const tag_items = ctx.allocator.alloc(TagItem, tags.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (tags, 0..) |t, i| {
        const is_active = isIdInList(t.id, active_tag_ids);
        const other_tags = removeFromList(ctx.allocator, active_tag_ids, t.id);
        const count = media.countTagInContext(ctx.allocator, db, t.id, folder_filter, other_tags, search_pattern, year_filter, month_filter) catch 0;
        tag_items[i] = .{
            .id = t.id,
            .name = t.name,
            .count = count,
            .is_active = is_active,
            .is_disabled = count == 0 and !is_active,
            .url = if (is_active)
                buildMediaUrl(ctx.allocator, view_mode, folder_filter, other_tags, false, search_term, year_filter, month_filter)
            else
                buildMediaUrl(ctx.allocator, view_mode, folder_filter, appendToList(ctx.allocator, active_tag_ids, t.id), false, search_term, year_filter, month_filter),
        };
    }

    // Build active tag refinements
    const active_tags = ctx.allocator.alloc(ActiveTag, active_tag_ids.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (active_tag_ids, 0..) |tid, i| {
        active_tags[i] = .{
            .id = tid,
            .name = findTagName(tags, tid),
            .remove_url = buildMediaUrl(ctx.allocator, view_mode, folder_filter, removeFromList(ctx.allocator, active_tag_ids, tid), false, search_term, year_filter, month_filter),
        };
    }

    const active_folder_name: []const u8 = if (folder_filter) |fid|
        (if (std.mem.eql(u8, fid, "default")) "Default" else findFolderName(folders, fid))
    else
        "";

    const breadcrumbs = buildBreadcrumbs(ctx.allocator, folder_filter, folders, view_mode, active_tag_ids, search_term, year_filter, month_filter);

    // Build unified active_filters list (folder + tags + search + date)
    const date_filter_count: usize = (if (year_filter != null) @as(usize, 1) else @as(usize, 0));
    const filter_count = (if (folder_filter != null) @as(usize, 1) else @as(usize, 0)) + active_tag_ids.len + (if (search_term != null) @as(usize, 1) else @as(usize, 0)) + date_filter_count;
    const active_filters = ctx.allocator.alloc(ActiveFilter, filter_count) catch {
        ctx.html("Error allocating memory");
        return;
    };
    {
        var fi: usize = 0;
        if (folder_filter != null) {
            active_filters[fi] = .{
                .label = "Folder:",
                .value = active_folder_name,
                .remove_url = buildMediaUrl(ctx.allocator, view_mode, null, active_tag_ids, false, search_term, year_filter, month_filter),
            };
            fi += 1;
        }
        for (active_tags) |at| {
            active_filters[fi] = .{
                .label = "Tag:",
                .value = at.name,
                .remove_url = at.remove_url,
            };
            fi += 1;
        }
        if (search_term != null) {
            active_filters[fi] = .{
                .label = "Search:",
                .value = search_term.?,
                .remove_url = buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, false, null, year_filter, month_filter),
            };
            fi += 1;
        }
        if (year_filter != null) {
            const date_label = if (month_filter) |m|
                std.fmt.allocPrint(ctx.allocator, "{s} {d}", .{ monthName(m), year_filter.? }) catch "?"
            else
                std.fmt.allocPrint(ctx.allocator, "{d}", .{year_filter.?}) catch "?";
            active_filters[fi] = .{
                .label = "Date:",
                .value = date_label,
                .remove_url = buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, false, search_term, null, null),
            };
        }
    }

    // Build hidden params for the search form
    const year_param_count: usize = if (year_filter != null) 1 else 0;
    const month_param_count: usize = if (month_filter != null) 1 else 0;
    const view_param_count: usize = if (!std.mem.eql(u8, view_mode, "grid")) 1 else 0;
    const folder_param_count: usize = if (folder_filter != null) 1 else 0;
    const hidden_param_count = view_param_count + folder_param_count + active_tag_ids.len + year_param_count + month_param_count;
    const search_hidden_params = ctx.allocator.alloc(HiddenParam, hidden_param_count) catch {
        ctx.html("Error allocating memory");
        return;
    };
    {
        var pi: usize = 0;
        if (!std.mem.eql(u8, view_mode, "grid")) {
            search_hidden_params[pi] = .{ .name = "view", .value = view_mode };
            pi += 1;
        }
        if (folder_filter) |fid| {
            search_hidden_params[pi] = .{ .name = "folder", .value = fid };
            pi += 1;
        }
        for (active_tag_ids) |tid| {
            search_hidden_params[pi] = .{ .name = "tag", .value = tid };
            pi += 1;
        }
        if (year_filter) |y| {
            search_hidden_params[pi] = .{ .name = "year", .value = std.fmt.allocPrint(ctx.allocator, "{d}", .{y}) catch "" };
            pi += 1;
        }
        if (month_filter) |m| {
            search_hidden_params[pi] = .{ .name = "month", .value = std.fmt.allocPrint(ctx.allocator, "{d}", .{m}) catch "" };
            pi += 1;
        }
    }

    // Build hidden params for the date filter form (view + folder + tags + search, no year/month)
    const date_base_count = view_param_count + folder_param_count + active_tag_ids.len + (if (search_term != null) @as(usize, 1) else @as(usize, 0));
    const date_hidden_params = ctx.allocator.alloc(HiddenParam, date_base_count) catch {
        ctx.html("Error allocating memory");
        return;
    };
    {
        var di: usize = 0;
        if (!std.mem.eql(u8, view_mode, "grid")) {
            date_hidden_params[di] = .{ .name = "view", .value = view_mode };
            di += 1;
        }
        if (folder_filter) |fid| {
            date_hidden_params[di] = .{ .name = "folder", .value = fid };
            di += 1;
        }
        for (active_tag_ids) |tid| {
            date_hidden_params[di] = .{ .name = "tag", .value = tid };
            di += 1;
        }
        if (search_term) |s| {
            date_hidden_params[di] = .{ .name = "search", .value = s };
        }
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

    // Build pagination URLs
    const base_url = buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter);
    const page_urls = ctx.allocator.alloc(PageUrl, total_pages) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Out of memory");
        return;
    };
    for (page_urls, 0..) |*page_url, i| {
        const pg: u32 = @intCast(i + 1);
        const page_num_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{pg}) catch "?";
        page_url.* = .{
            .page_num = page_num_str,
            .url = buildPageUrl(ctx.allocator, base_url, pg),
            .is_current = pg == current_page,
        };
    }

    const content = tpl.render(zsx_admin_media_list.List, .{.{
        .has_media = items.len > 0,
        .media = items,
        .csrf_token = csrf_token,
        .view_mode = view_mode,
        .total_count = total_count,
        .filtered_count = filtered_count,
        .unsorted_count = unsorted_count,
        .folders = folder_items,
        .tags = tag_items,
        .active_folder = folder_filter orelse "",
        .active_folder_name = active_folder_name,
        .active_tags = active_tags,
        .show_unreviewed = show_unreviewed,
        .unreviewed_count = unreviewed_count,
        .view_grid_url = buildMediaUrl(ctx.allocator, "grid", folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter),
        .view_list_url = buildMediaUrl(ctx.allocator, "list", folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter),
        .unsorted_url = if (folder_filter != null and std.mem.eql(u8, folder_filter.?, "default"))
            buildMediaUrl(ctx.allocator, view_mode, null, active_tag_ids, false, search_term, year_filter, month_filter)
        else
            buildMediaUrl(ctx.allocator, view_mode, "default", active_tag_ids, false, search_term, year_filter, month_filter),
        .reset_url = buildMediaUrl(ctx.allocator, view_mode, null, &.{}, false, null, null, null),
        .unreviewed_url = buildMediaUrl(ctx.allocator, view_mode, null, &.{}, !show_unreviewed, search_term, year_filter, month_filter),
        .folder_remove_url = buildMediaUrl(ctx.allocator, view_mode, null, active_tag_ids, false, search_term, year_filter, month_filter),
        .search_term = search_term orelse "",
        .search_remove_url = buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, false, null, year_filter, month_filter),
        .active_filters = active_filters,
        .search_hidden_params = search_hidden_params,
        .date_hidden_params = date_hidden_params,
        .year_options = year_options,
        .month_options = month_options,
        .scan_result = scan_result,
        .current_page = current_page,
        .total_pages = total_pages,
        .page_urls = page_urls,
        .prev_page_url = if (current_page > 1) buildPageUrl(ctx.allocator, base_url, current_page - 1) else "",
        .next_page_url = if (current_page < total_pages) buildPageUrl(ctx.allocator, base_url, current_page + 1) else "",
        .items_per_page = items_per_page,
        .filtered_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{filtered_count}) catch "0",
        .items_per_page_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{items_per_page}) catch "25",
    }});

    const subtitle = tpl.render(zsx_admin_media_list.Breadcrumbs, .{.{
        .items = breadcrumbs,
    }});

    ctx.html(registry.renderPageWith(page, ctx, content, subtitle));
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

    // Single folder assignment: get current folder ID (first one, or empty)
    const current_folder_id: []const u8 = if (assigned_folder_ids.len > 0) assigned_folder_ids[0] else "";

    // Build tree-ordered folder list (reuse sidebar tree builder)
    const tree_items = buildFolderTree(ctx.allocator, all_folders, db, null, "", &[_][]const u8{}, null, null, null, null) catch {
        redirect(ctx, "/admin/media");
        return;
    };
    const folder_options = ctx.allocator.alloc(FolderOption, tree_items.len) catch {
        redirect(ctx, "/admin/media");
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
    const tag_options = ctx.allocator.alloc(TagOption, all_tags_records.len) catch {
        redirect(ctx, "/admin/media");
        return;
    };
    for (all_tags_records, 0..) |t, i| {
        tag_options[i] = .{
            .id = t.id,
            .name = t.name,
            .is_selected = isTermSelected(t.id, assigned_tag_ids),
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
        .all_tags = tag_options,
        .tags_display = tag_display,
        .current_folder_id = current_folder_id,
    }});

    ctx.html(registry.renderPage(page, ctx, content));
}

/// JSON endpoint for image picker modal - lists media items for selection
fn handlePickerList(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"items\":[]}");
        return;
    };

    const raw_search = parseQueryParam(ctx.query, "search");
    const search_term: ?[]const u8 = if (raw_search) |s| if (s.len > 0) percentDecode(ctx.allocator, s) else null else null;
    const search_pattern: ?[]const u8 = if (search_term) |s| std.fmt.allocPrint(ctx.allocator, "%{s}%", .{s}) catch null else null;

    const list_opts: media.MediaListOptions = .{
        .limit = 50,
        .offset = 0,
        .order_by = "created_at",
        .order_dir = .desc,
        .search = search_pattern,
    };

    const entries = media.listMedia(ctx.allocator, db, list_opts) catch &[_]media.MediaRecord{};

    // Build JSON response using ArrayListUnmanaged
    var json: std.ArrayListUnmanaged(u8) = .{};
    var writer = json.writer(ctx.allocator);

    writer.writeAll("{\"items\":[") catch {};
    for (entries, 0..) |entry, i| {
        if (i > 0) writer.writeAll(",") catch {};

        const is_image = std.mem.startsWith(u8, entry.mime_type, "image/");

        // Get alt_text from data struct
        const alt_text = entry.data.alt_text orelse "";

        // Build thumb URL
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
    writer.writeAll("]}") catch {};

    ctx.response.setHeader("Content-Type", "application/json");
    ctx.response.setBody(json.items);
}

/// Returns a thumbnail for a specific media item by ID (for image picker preview)
fn handlePickerThumb(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
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

    redirect(ctx, url);
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
    const record = media.uploadMedia(ctx.allocator, db, getBackend(), .{
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

    // Assign to folder if specified
    const folder_id = parseMultipartField(body_content, boundary, "folder_id");
    if (folder_id) |fid| {
        if (fid.len > 0) {
            media.addTermToMedia(db, record.id, fid) catch {};
        }
    }

    redirect(ctx, "/admin/media");
}

/// Get the appropriate storage backend for the current platform
fn getBackend() storage.StorageBackend {
    if (is_wasm) return @import("wasm_storage").backend;
    return storage.filesystem;
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

    media.fullDeleteMedia(ctx.allocator, db, getBackend(), media_id) catch |err| {
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

fn handleScan(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    storage.initDirectories() catch {};

    const count = media_sync.countNewFilesOnDisk(ctx.allocator, db) catch |err| {
        std.debug.print("Scan error: {}\n", .{err});
        redirect(ctx, "/admin/media");
        return;
    };

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/media?scan_result={d}", .{count}) catch "/admin/media";
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

    media.deleteTermWithReparent(db, term_id) catch |err| {
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

fn handleMoveFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };

    const parent_id = if (ctx.formValue("parent_id")) |pid| if (pid.len > 0) pid else null else null;

    // Validate: cannot move folder under itself
    if (parent_id) |pid| {
        if (std.mem.eql(u8, pid, term_id)) {
            redirect(ctx, "/admin/media");
            return;
        }

        // Validate: cannot create circular reference
        // Walk up from proposed parent to root; if we hit term_id, reject
        {
            var check_id: []const u8 = pid;
            while (true) {
                var anc_stmt = db.prepare(
                    "SELECT parent_id FROM terms WHERE id = ?1",
                ) catch break;
                defer anc_stmt.deinit();
                anc_stmt.bindText(1, check_id) catch break;
                if (!(anc_stmt.step() catch false)) break;
                const next_id = anc_stmt.columnText(0) orelse break;
                if (std.mem.eql(u8, next_id, term_id)) {
                    redirect(ctx, "/admin/media");
                    return;
                }
                check_id = ctx.allocator.dupe(u8, next_id) catch break;
            }
        }
    }

    media.moveTermParent(db, term_id, parent_id) catch |err| {
        std.debug.print("Error moving folder: {}\n", .{err});
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

// =============================================================================
// Bulk Action Handlers
// =============================================================================

fn handleBulkDelete(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.fullDeleteMedia(ctx.allocator, db, getBackend(), media_id) catch |err| {
            std.debug.print("Bulk delete error for {s}: {}\n", .{ media_id, err });
        };
    }

    redirect(ctx, "/admin/media");
}

fn handleBulkAddTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };
    if (term_id.len == 0) {
        redirect(ctx, "/admin/media");
        return;
    }

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.addTermToMedia(db, media_id, term_id) catch |err| {
            std.debug.print("Bulk add-tag error for {s}: {}\n", .{ media_id, err });
        };
    }

    redirect(ctx, "/admin/media");
}

fn handleBulkRemoveTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };
    if (term_id.len == 0) {
        redirect(ctx, "/admin/media");
        return;
    }

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.removeTermFromMedia(db, media_id, term_id) catch |err| {
            std.debug.print("Bulk remove-tag error for {s}: {}\n", .{ media_id, err });
        };
    }

    redirect(ctx, "/admin/media");
}

fn handleBulkMoveFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        redirect(ctx, "/admin/media");
        return;
    };
    if (term_id.len == 0) {
        redirect(ctx, "/admin/media");
        return;
    }

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.replaceMediaFolder(db, media_id, term_id) catch |err| {
            std.debug.print("Bulk move-folder error for {s}: {}\n", .{ media_id, err });
        };
    }

    redirect(ctx, "/admin/media");
}

/// Parse bulk IDs from form: either comma-separated "ids" field,
/// or if "select_all=1" re-query matching items with no limit.
fn parseBulkIds(ctx: *Context) []const []const u8 {
    const select_all = ctx.formValue("select_all");
    if (select_all != null and std.mem.eql(u8, select_all.?, "1")) {
        return resolveBulkSelectAll(ctx);
    }

    const ids_raw = ctx.formValue("ids") orelse return &[_][]const u8{};
    if (ids_raw.len == 0) return &[_][]const u8{};

    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var iter = std.mem.splitScalar(u8, ids_raw, ',');
    while (iter.next()) |id| {
        const trimmed = std.mem.trim(u8, id, " ");
        if (trimmed.len > 0) {
            list.append(ctx.allocator, trimmed) catch {};
        }
    }
    return list.toOwnedSlice(ctx.allocator) catch &[_][]const u8{};
}

/// Re-query all matching media IDs for "select all across pages"
fn resolveBulkSelectAll(ctx: *Context) []const []const u8 {
    const db = if (auth_middleware.auth) |a| a.db else return &[_][]const u8{};

    const folder_filter = ctx.formValue("filter_folder");
    const show_unreviewed = if (ctx.formValue("filter_unreviewed")) |v| std.mem.eql(u8, v, "1") else false;
    const raw_search = ctx.formValue("filter_search");
    const search_pattern: ?[]const u8 = if (raw_search) |s| if (s.len > 0) (std.fmt.allocPrint(ctx.allocator, "%{s}%", .{s}) catch null) else null else null;

    const year_filter: ?u16 = if (ctx.formValue("filter_year")) |v| std.fmt.parseInt(u16, v, 10) catch null else null;
    const month_filter: ?u8 = if (ctx.formValue("filter_month")) |v| std.fmt.parseInt(u8, v, 10) catch null else null;

    // Parse tag IDs from comma-separated filter_tags
    const raw_tags = ctx.formValue("filter_tags") orelse "";
    var tag_list: std.ArrayListUnmanaged([]const u8) = .{};
    if (raw_tags.len > 0) {
        var tag_iter = std.mem.splitScalar(u8, raw_tags, ',');
        while (tag_iter.next()) |tid| {
            const trimmed = std.mem.trim(u8, tid, " ");
            if (trimmed.len > 0) tag_list.append(ctx.allocator, trimmed) catch {};
        }
    }
    const active_tag_ids = tag_list.toOwnedSlice(ctx.allocator) catch &[_][]const u8{};

    const no_limit_opts: media.MediaListOptions = .{
        .limit = null,
        .offset = null,
        .order_by = "created_at",
        .order_dir = .desc,
        .search = search_pattern,
        .year = year_filter,
        .month = month_filter,
    };

    const entries = blk: {
        if (show_unreviewed) {
            break :blk media.listUnreviewedMedia(ctx.allocator, db, no_limit_opts) catch &[_]media.MediaRecord{};
        }
        if (folder_filter) |fid| {
            if (fid.len == 0) {
                break :blk media.listMedia(ctx.allocator, db, no_limit_opts) catch &[_]media.MediaRecord{};
            } else if (std.mem.eql(u8, fid, "default")) {
                break :blk media.listUnsortedMedia(ctx.allocator, db, media.tax_media_folders, no_limit_opts) catch &[_]media.MediaRecord{};
            } else {
                const folder_ids = media.getDescendantFolderIds(ctx.allocator, db, fid) catch &[_][]const u8{};
                break :blk media.listMediaByFolderAndTags(ctx.allocator, db, folder_ids, active_tag_ids, no_limit_opts) catch &[_]media.MediaRecord{};
            }
        } else if (active_tag_ids.len > 0) {
            break :blk media.listMediaByTerms(ctx.allocator, db, active_tag_ids, no_limit_opts) catch &[_]media.MediaRecord{};
        } else {
            break :blk media.listMedia(ctx.allocator, db, no_limit_opts) catch &[_]media.MediaRecord{};
        }
    };

    const result = ctx.allocator.alloc([]const u8, entries.len) catch return &[_][]const u8{};
    for (entries, 0..) |entry, i| {
        result[i] = entry.id;
    }
    return result;
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

const ActiveTag = struct {
    id: []const u8,
    name: []const u8,
    remove_url: []const u8,
};

const BreadcrumbItem = struct {
    name: []const u8,
    url: []const u8,
};

const ActiveFilter = struct {
    label: []const u8,
    value: []const u8,
    remove_url: []const u8,
};

const HiddenParam = struct {
    name: []const u8,
    value: []const u8,
};

const FolderItem = struct {
    id: []const u8,
    name: []const u8,
    parent_id: []const u8,
    count: u32,
    depth: u32,
    is_active: bool,
    is_disabled: bool,
    url: []const u8,
};

const TagItem = struct {
    id: []const u8,
    name: []const u8,
    count: u32,
    is_active: bool,
    is_disabled: bool,
    url: []const u8,
};

const YearOption = struct {
    value: []const u8,
    label: []const u8,
    is_selected: bool,
};

const MonthOption = struct {
    value: []const u8,
    label: []const u8,
    is_selected: bool,
};

const FolderOption = struct {
    id: []const u8,
    name: []const u8,
    depth: u32,
    is_selected: bool,
};

const TagOption = struct {
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

const PageUrl = struct {
    page_num: []const u8,
    url: []const u8,
    is_current: bool,
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

/// Parse all values for a query param key (e.g. ?tag=a&tag=b → ["a","b"])
fn parseQueryParamAll(allocator: std.mem.Allocator, query: ?[]const u8, name: []const u8) []const []const u8 {
    const q = query orelse return &[_][]const u8{};
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq_pos| {
            if (std.mem.eql(u8, pair[0..eq_pos], name)) {
                list.append(allocator, pair[eq_pos + 1 ..]) catch {};
            }
        }
    }
    return list.toOwnedSlice(allocator) catch &[_][]const u8{};
}

/// Build a media page URL preserving view, folder, tag[], unreviewed, search, year, and month params
fn buildMediaUrl(allocator: std.mem.Allocator, view: []const u8, folder: ?[]const u8, tags: []const []const u8, unreviewed: bool, search: ?[]const u8, year: ?u16, month: ?u8) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    buf.appendSlice(allocator, "/admin/media") catch return "/admin/media";

    var has_param = false;

    // View mode (only if not "grid" which is the default)
    if (!std.mem.eql(u8, view, "grid")) {
        buf.appendSlice(allocator, "?view=") catch {};
        buf.appendSlice(allocator, view) catch {};
        has_param = true;
    }

    // Folder filter
    if (folder) |fid| {
        buf.appendSlice(allocator, if (has_param) "&folder=" else "?folder=") catch {};
        buf.appendSlice(allocator, fid) catch {};
        has_param = true;
    }

    // Tag filters (repeated param: &tag=x&tag=y)
    for (tags) |tid| {
        buf.appendSlice(allocator, if (has_param) "&tag=" else "?tag=") catch {};
        buf.appendSlice(allocator, tid) catch {};
        has_param = true;
    }

    // Unreviewed
    if (unreviewed) {
        buf.appendSlice(allocator, if (has_param) "&unreviewed=1" else "?unreviewed=1") catch {};
        has_param = true;
    }

    // Search
    if (search) |s| {
        buf.appendSlice(allocator, if (has_param) "&search=" else "?search=") catch {};
        urlEncode(allocator, &buf, s);
        has_param = true;
    }

    // Year
    if (year) |y| {
        const yr_str = std.fmt.allocPrint(allocator, "{d}", .{y}) catch "";
        buf.appendSlice(allocator, if (has_param) "&year=" else "?year=") catch {};
        buf.appendSlice(allocator, yr_str) catch {};
        has_param = true;
    }

    // Month
    if (month) |m| {
        const mo_str = std.fmt.allocPrint(allocator, "{d}", .{m}) catch "";
        buf.appendSlice(allocator, if (has_param) "&month=" else "?month=") catch {};
        buf.appendSlice(allocator, mo_str) catch {};
        has_param = true;
    }

    return buf.toOwnedSlice(allocator) catch "/admin/media";
}

/// Build a page URL by appending &page=N to a base URL
fn buildPageUrl(allocator: std.mem.Allocator, base_url: []const u8, page_num: u32) []const u8 {
    if (page_num <= 1) return base_url;
    const sep: []const u8 = if (std.mem.indexOf(u8, base_url, "?") != null) "&" else "?";
    return std.fmt.allocPrint(allocator, "{s}{s}page={d}", .{ base_url, sep, page_num }) catch base_url;
}

/// Build hierarchical folder list sorted parent→children with depth (recursive)
fn buildFolderTree(
    allocator: std.mem.Allocator,
    folders: []const media.TermRecord,
    db: *db_mod.Db,
    folder_filter: ?[]const u8,
    view_mode: []const u8,
    active_tag_ids: []const []const u8,
    search_pattern: ?[]const u8,
    search_term: ?[]const u8,
    year: ?u16,
    month: ?u8,
) ![]FolderItem {
    var items: std.ArrayListUnmanaged(FolderItem) = .{};
    appendFolderChildren(allocator, folders, db, folder_filter, view_mode, active_tag_ids, search_pattern, search_term, &items, "", 0, year, month);
    return items.toOwnedSlice(allocator);
}

/// Recursively append children of parent_match_id at given depth
fn appendFolderChildren(
    allocator: std.mem.Allocator,
    folders: []const media.TermRecord,
    db: *db_mod.Db,
    folder_filter: ?[]const u8,
    view_mode: []const u8,
    active_tag_ids: []const []const u8,
    search_pattern: ?[]const u8,
    search_term: ?[]const u8,
    items: *std.ArrayListUnmanaged(FolderItem),
    parent_match_id: []const u8,
    depth: u32,
    year: ?u16,
    month: ?u8,
) void {
    for (folders) |f| {
        const pid = f.parent_id orelse "";
        if (std.mem.eql(u8, pid, parent_match_id)) {
            const count = media.countFolderInContext(allocator, db, f.id, active_tag_ids, search_pattern, year, month) catch 0;
            const is_active = if (folder_filter) |ff| std.mem.eql(u8, ff, f.id) else false;
            const has_context = active_tag_ids.len > 0 or search_pattern != null or year != null;
            items.append(allocator, .{
                .id = f.id,
                .name = f.name,
                .parent_id = parent_match_id,
                .count = count,
                .depth = depth,
                .is_active = is_active,
                .is_disabled = count == 0 and !is_active and has_context,
                .url = if (is_active)
                    buildMediaUrl(allocator, view_mode, null, active_tag_ids, false, search_term, year, month)
                else
                    buildMediaUrl(allocator, view_mode, f.id, active_tag_ids, false, search_term, year, month),
            }) catch {};
            appendFolderChildren(allocator, folders, db, folder_filter, view_mode, active_tag_ids, search_pattern, search_term, items, f.id, depth + 1, year, month);
        }
    }
}

/// Build breadcrumb trail: "All Files" → [Default | Folder → Subfolder → ...]
/// The last item has no URL (current location). All ancestors are clickable.
fn buildBreadcrumbs(
    allocator: std.mem.Allocator,
    folder_filter: ?[]const u8,
    folders: []const media.TermRecord,
    view_mode: []const u8,
    active_tag_ids: []const []const u8,
    search_term: ?[]const u8,
    year: ?u16,
    month: ?u8,
) []const BreadcrumbItem {
    var crumbs: std.ArrayListUnmanaged(BreadcrumbItem) = .{};

    if (folder_filter) |fid| {
        if (std.mem.eql(u8, fid, "default")) {
            // All Files / Default
            crumbs.append(allocator, .{
                .name = "All Files",
                .url = buildMediaUrl(allocator, view_mode, null, active_tag_ids, false, search_term, year, month),
            }) catch {};
            crumbs.append(allocator, .{ .name = "Default", .url = "" }) catch {};
        } else {
            // Walk up the parent chain to build path: All Files / A / B / C
            // Collect ancestors in reverse order first
            var ancestors: std.ArrayListUnmanaged(BreadcrumbItem) = .{};
            var current_id: ?[]const u8 = fid;
            while (current_id) |cid| {
                const folder = findFolder(folders, cid);
                if (folder) |f| {
                    ancestors.append(allocator, .{
                        .name = f.name,
                        .url = buildMediaUrl(allocator, view_mode, f.id, active_tag_ids, false, search_term, year, month),
                    }) catch {};
                    current_id = f.parent_id;
                } else break;
            }

            // "All Files" root
            crumbs.append(allocator, .{
                .name = "All Files",
                .url = buildMediaUrl(allocator, view_mode, null, active_tag_ids, false, search_term, year, month),
            }) catch {};

            // Reverse ancestors so it goes root→leaf
            if (ancestors.items.len > 0) {
                var i: usize = ancestors.items.len;
                while (i > 0) {
                    i -= 1;
                    const item = ancestors.items[i];
                    if (i == 0) {
                        // Last item (current folder) — no link
                        crumbs.append(allocator, .{ .name = item.name, .url = "" }) catch {};
                    } else {
                        crumbs.append(allocator, item) catch {};
                    }
                }
            }
        }
    } else {
        // No folder selected — just "All Files" as current (no link)
        crumbs.append(allocator, .{ .name = "All Files", .url = "" }) catch {};
    }

    return crumbs.toOwnedSlice(allocator) catch &.{};
}

/// Find a folder TermRecord by id
fn findFolder(folders: []const media.TermRecord, id: []const u8) ?media.TermRecord {
    for (folders) |f| {
        if (std.mem.eql(u8, f.id, id)) return f;
    }
    return null;
}

fn isIdInList(id: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, id, item)) return true;
    }
    return false;
}

fn removeFromList(allocator: std.mem.Allocator, list: []const []const u8, item: []const u8) []const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .{};
    for (list) |entry| {
        if (!std.mem.eql(u8, entry, item)) {
            result.append(allocator, entry) catch {};
        }
    }
    return result.toOwnedSlice(allocator) catch &[_][]const u8{};
}

fn appendToList(allocator: std.mem.Allocator, list: []const []const u8, item: []const u8) []const []const u8 {
    var result = allocator.alloc([]const u8, list.len + 1) catch return list;
    @memcpy(result[0..list.len], list);
    result[list.len] = item;
    return result;
}

fn findTagName(tags: []const media.TermRecord, id: []const u8) []const u8 {
    for (tags) |t| {
        if (std.mem.eql(u8, t.id, id)) return t.name;
    }
    return id;
}

fn findFolderName(folders: []const media.TermRecord, id: []const u8) []const u8 {
    for (folders) |f| {
        if (std.mem.eql(u8, f.id, id)) return f.name;
    }
    return id;
}

/// Decode percent-encoded URL string: '+' → space, '%XX' → byte
fn percentDecode(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    var buf = allocator.alloc(u8, input.len) catch return input;
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '+') {
            buf[out] = ' ';
            out += 1;
            i += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]);
            const lo = hexVal(input[i + 2]);
            if (hi != null and lo != null) {
                buf[out] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                out += 1;
                i += 3;
            } else {
                buf[out] = input[i];
                out += 1;
                i += 1;
            }
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return allocator.realloc(buf, out) catch buf[0..out];
}

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

/// URL-encode a string into the buffer (for use in query parameters)
fn urlEncode(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), input: []const u8) void {
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            buf.append(allocator, c) catch {};
        } else if (c == ' ') {
            buf.append(allocator, '+') catch {};
        } else {
            buf.append(allocator, '%') catch {};
            buf.append(allocator, hex[c >> 4]) catch {};
            buf.append(allocator, hex[c & 0x0f]) catch {};
        }
    }
}

/// Parse an integer query parameter by name, returning null if absent or unparseable
fn parseIntParam(query: ?[]const u8, name: []const u8, comptime T: type) ?T {
    const raw = parseQueryParam(query, name) orelse return null;
    if (raw.len == 0) return null;
    return std.fmt.parseInt(T, raw, 10) catch null;
}

/// Return month name abbreviation from 1-indexed month number
fn monthName(m: u8) []const u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (m >= 1 and m <= 12) return names[m - 1];
    return "?";
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

/// Extract a named text field value from multipart form data
fn parseMultipartField(body: []const u8, boundary: []const u8, field_name: []const u8) ?[]const u8 {
    var delim_buf: [256]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "\r\n--{s}", .{boundary}) catch return null;

    var start_buf: [256]u8 = undefined;
    const start_marker = std.fmt.bufPrint(&start_buf, "--{s}\r\n", .{boundary}) catch return null;

    var pos = (std.mem.indexOf(u8, body, start_marker) orelse return null) + start_marker.len;

    var name_buf: [128]u8 = undefined;
    const name_match = std.fmt.bufPrint(&name_buf, "name=\"{s}\"", .{field_name}) catch return null;

    while (pos < body.len) {
        const headers_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse return null;
        const headers = body[pos .. pos + headers_end];
        const data_start = pos + headers_end + 4;
        const data_end_rel = std.mem.indexOf(u8, body[data_start..], delim) orelse body.len - data_start;

        if (std.mem.indexOf(u8, headers, name_match) != null and std.mem.indexOf(u8, headers, "filename=\"") == null) {
            return body[data_start .. data_start + data_end_rel];
        }

        const next_part = data_start + data_end_rel + delim.len;
        if (next_part + 2 <= body.len and body[next_part] == '\r' and body[next_part + 1] == '\n') {
            pos = next_part + 2;
        } else {
            break;
        }
    }
    return null;
}
