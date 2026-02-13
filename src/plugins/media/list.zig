//! Media list handler — the main media library listing page.

const std = @import("std");
const admin = @import("admin_api");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const csrf = @import("csrf");
const media = @import("media");
const auth_middleware = @import("auth_middleware");
const registry = @import("registry");
const views = @import("views");
const pagination = @import("pagination");

const h = @import("helpers.zig");

pub fn handleList(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);

    // Parse query params
    const view_mode = h.parseQueryParam(ctx.query, "view") orelse "grid";
    const folder_filter = h.parseQueryParam(ctx.query, "folder");
    const active_tag_ids = h.parseQueryParamAll(ctx.allocator, ctx.query, "tag");
    const show_unreviewed = h.parseQueryParam(ctx.query, "unreviewed") != null;
    const raw_search = h.parseQueryParam(ctx.query, "search");
    const search_term: ?[]const u8 = if (raw_search) |s| if (s.len > 0) h.percentDecode(ctx.allocator, s) else null else null;
    const search_pattern: ?[]const u8 = if (search_term) |s| std.fmt.allocPrint(ctx.allocator, "%{s}%", .{s}) catch null else null;

    // Parse date filters
    const year_filter: ?u16 = h.parseIntParam(ctx.query, "year", u16);
    const month_filter: ?u8 = h.parseIntParam(ctx.query, "month", u8);

    // Parse scan result (from handleScan redirect)
    const scan_result: ?u32 = h.parseIntParam(ctx.query, "scan_result", u32);

    // Pagination — parse page early for offset; total_pages computed after filtered_count
    const items_per_page: u32 = 25;
    const pag_early = pagination.Paginator.init(ctx.query, 0, items_per_page);
    const offset: u32 = pag_early.offset();

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

    // Get counts (no mime_patterns filter in main media list)
    const total_count = media.countMedia(db, .{ .search = search_pattern }) catch 0;
    const unsorted_count = media.countUnsortedInContext(ctx.allocator, db, media.tax_media_folders, active_tag_ids, search_pattern, year_filter, month_filter, null) catch total_count;
    const unreviewed_count = media.countUnreviewedMedia(ctx.allocator, db, search_pattern, year_filter, month_filter) catch 0;

    // Compute filtered count for pagination (matches the list query dispatch)
    const filtered_count: u32 = blk: {
        if (show_unreviewed) break :blk unreviewed_count;
        if (folder_filter) |fid| {
            if (std.mem.eql(u8, fid, "default")) {
                break :blk unsorted_count;
            } else {
                break :blk media.countFolderInContext(ctx.allocator, db, fid, active_tag_ids, search_pattern, year_filter, month_filter, null) catch 0;
            }
        } else if (active_tag_ids.len > 0) {
            break :blk media.countAllInContext(ctx.allocator, db, active_tag_ids, search_pattern, year_filter, month_filter) catch 0;
        } else {
            break :blk total_count;
        }
    };

    // Build final paginator with real filtered count
    const pag = pagination.Paginator{
        .current_page = pag_early.current_page,
        .total_pages = if (filtered_count == 0) 1 else (filtered_count + items_per_page - 1) / items_per_page,
        .items_per_page = items_per_page,
    };

    // Fetch folders and tags for sidebar
    const folders = media.listTerms(ctx.allocator, db, media.tax_media_folders) catch &[_]media.TermRecord{};
    const tags = media.listTerms(ctx.allocator, db, media.tax_media_tags) catch &[_]media.TermRecord{};

    // Fetch date periods for sidebar selects
    const raw_years = media.getDistinctYears(ctx.allocator, db) catch &[_]u16{};
    const year_options: []const h.YearOption = blk: {
        const opts = ctx.allocator.alloc(h.YearOption, raw_years.len) catch break :blk &[_]h.YearOption{};
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
    const month_options: []const h.MonthOption = blk: {
        const opts = ctx.allocator.alloc(h.MonthOption, raw_months.len) catch break :blk &[_]h.MonthOption{};
        for (raw_months, 0..) |mo, i| {
            opts[i] = .{
                .value = std.fmt.allocPrint(ctx.allocator, "{d}", .{mo}) catch "",
                .label = h.monthName(mo),
                .is_selected = if (month_filter) |am| am == mo else false,
            };
        }
        break :blk opts;
    };

    // Build folder tree
    const folder_items = h.buildFolderTree(ctx.allocator, folders, db, folder_filter, view_mode, active_tag_ids, search_pattern, search_term, year_filter, month_filter) catch {
        ctx.html("Error building folder tree");
        return;
    };

    // Convert tags to view format
    const tag_items = ctx.allocator.alloc(h.TagItem, tags.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (tags, 0..) |t, i| {
        const is_active = h.isIdInList(t.id, active_tag_ids);
        const other_tags = h.removeFromList(ctx.allocator, active_tag_ids, t.id);
        const count = media.countTagInContext(ctx.allocator, db, t.id, folder_filter, other_tags, search_pattern, year_filter, month_filter, null) catch 0;
        tag_items[i] = .{
            .id = t.id,
            .name = t.name,
            .count = count,
            .is_active = is_active,
            .is_disabled = count == 0 and !is_active,
            .url = if (is_active)
                h.buildMediaUrl(ctx.allocator, view_mode, folder_filter, other_tags, false, search_term, year_filter, month_filter)
            else
                h.buildMediaUrl(ctx.allocator, view_mode, folder_filter, h.appendToList(ctx.allocator, active_tag_ids, t.id), false, search_term, year_filter, month_filter),
        };
    }

    // Build active tag refinements
    const active_tags = ctx.allocator.alloc(h.ActiveTag, active_tag_ids.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (active_tag_ids, 0..) |tid, i| {
        active_tags[i] = .{
            .id = tid,
            .name = h.findTagName(tags, tid),
            .remove_url = h.buildMediaUrl(ctx.allocator, view_mode, folder_filter, h.removeFromList(ctx.allocator, active_tag_ids, tid), false, search_term, year_filter, month_filter),
        };
    }

    const active_folder_name: []const u8 = if (folder_filter) |fid|
        (if (std.mem.eql(u8, fid, "default")) "Default" else h.findFolderName(folders, fid))
    else
        "";

    const breadcrumbs = h.buildBreadcrumbs(ctx.allocator, folder_filter, folders, view_mode, active_tag_ids, search_term, year_filter, month_filter);

    // Build unified active_filters list (folder + tags + search + date)
    const date_filter_count: usize = (if (year_filter != null) @as(usize, 1) else @as(usize, 0));
    const filter_count = (if (folder_filter != null) @as(usize, 1) else @as(usize, 0)) + active_tag_ids.len + (if (search_term != null) @as(usize, 1) else @as(usize, 0)) + date_filter_count;
    const active_filters = ctx.allocator.alloc(h.ActiveFilter, filter_count) catch {
        ctx.html("Error allocating memory");
        return;
    };
    {
        var fi: usize = 0;
        if (folder_filter != null) {
            active_filters[fi] = .{
                .label = "Folder:",
                .value = active_folder_name,
                .remove_url = h.buildMediaUrl(ctx.allocator, view_mode, null, active_tag_ids, false, search_term, year_filter, month_filter),
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
                .remove_url = h.buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, false, null, year_filter, month_filter),
            };
            fi += 1;
        }
        if (year_filter != null) {
            const date_label = if (month_filter) |m|
                std.fmt.allocPrint(ctx.allocator, "{s} {d}", .{ h.monthName(m), year_filter.? }) catch "?"
            else
                std.fmt.allocPrint(ctx.allocator, "{d}", .{year_filter.?}) catch "?";
            active_filters[fi] = .{
                .label = "Date:",
                .value = date_label,
                .remove_url = h.buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, false, search_term, null, null),
            };
        }
    }

    // Build hidden params for the search form
    const year_param_count: usize = if (year_filter != null) 1 else 0;
    const month_param_count: usize = if (month_filter != null) 1 else 0;
    const view_param_count: usize = if (!std.mem.eql(u8, view_mode, "grid")) 1 else 0;
    const folder_param_count: usize = if (folder_filter != null) 1 else 0;
    const hidden_param_count = view_param_count + folder_param_count + active_tag_ids.len + year_param_count + month_param_count;
    const search_hidden_params = ctx.allocator.alloc(h.HiddenParam, hidden_param_count) catch {
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
    const date_hidden_params = ctx.allocator.alloc(h.HiddenParam, date_base_count) catch {
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
    var items = ctx.allocator.alloc(h.MediaListItem, entries.len) catch {
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
            .size_display = h.formatSize(ctx.allocator, entry.size) catch "?",
            .visibility = entry.visibility,
            .edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}", .{entry.id}) catch "/admin/media",
            .delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/media/{s}/delete", .{entry.id}) catch "/admin/media",
            .thumb_url = if (is_image) std.fmt.allocPrint(ctx.allocator, "/media/{s}?w=200", .{entry.storage_key}) catch "" else "",
            .is_image = is_image,
            .is_private = is_private,
        };
    }

    // Build pagination URLs
    const base_url = h.buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter);
    const page_urls_result = pag.buildPageUrls(ctx.allocator, base_url);

    const page_reg = @import("main.zig").page;

    const content = tpl.render(views.admin.media.list.List, .{.{
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
        .view_grid_url = h.buildMediaUrl(ctx.allocator, "grid", folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter),
        .view_list_url = h.buildMediaUrl(ctx.allocator, "list", folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter),
        .unsorted_url = if (folder_filter != null and std.mem.eql(u8, folder_filter.?, "default"))
            h.buildMediaUrl(ctx.allocator, view_mode, null, active_tag_ids, false, search_term, year_filter, month_filter)
        else
            h.buildMediaUrl(ctx.allocator, view_mode, "default", active_tag_ids, false, search_term, year_filter, month_filter),
        .reset_url = h.buildMediaUrl(ctx.allocator, view_mode, null, &.{}, false, null, null, null),
        .unreviewed_url = h.buildMediaUrl(ctx.allocator, view_mode, null, &.{}, !show_unreviewed, search_term, year_filter, month_filter),
        .folder_remove_url = h.buildMediaUrl(ctx.allocator, view_mode, null, active_tag_ids, false, search_term, year_filter, month_filter),
        .search_term = search_term orelse "",
        .search_remove_url = h.buildMediaUrl(ctx.allocator, view_mode, folder_filter, active_tag_ids, false, null, year_filter, month_filter),
        .active_filters = active_filters,
        .search_hidden_params = search_hidden_params,
        .date_hidden_params = date_hidden_params,
        .year_options = year_options,
        .month_options = month_options,
        .scan_result = scan_result,
        .current_page = pag.current_page,
        .total_pages = pag.total_pages,
        .page_urls = page_urls_result.items,
        .prev_page_url = page_urls_result.prev_url,
        .next_page_url = page_urls_result.next_url,
        .items_per_page = pag.items_per_page,
        .filtered_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{filtered_count}) catch "0",
        .items_per_page_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{items_per_page}) catch "25",
    }});

    const subtitle = tpl.render(views.admin.media.list.Breadcrumbs, .{.{
        .items = breadcrumbs,
    }});

    const bottom_bar = tpl.render(views.admin.media.list.BottomBar, .{.{
        .active_folder = folder_filter orelse "",
        .total_pages = pag.total_pages,
        .prev_page_url = page_urls_result.prev_url,
        .next_page_url = page_urls_result.next_url,
        .page_urls = page_urls_result.items,
        .csrf_token = csrf.ensureToken(ctx),
    }});

    const page_title_actions = tpl.render(views.admin.media.list.MediaControls, .{.{
        .filtered_count = filtered_count,
        .view_mode = view_mode,
        .view_grid_url = h.buildMediaUrl(ctx.allocator, "grid", folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter),
        .view_list_url = h.buildMediaUrl(ctx.allocator, "list", folder_filter, active_tag_ids, show_unreviewed, search_term, year_filter, month_filter),
    }});

    ctx.html(registry.renderPageFull(page_reg, ctx, content, subtitle, bottom_bar, page_title_actions));
}
