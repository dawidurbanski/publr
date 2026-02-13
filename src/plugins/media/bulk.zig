//! Bulk action handlers — delete, add-tag, remove-tag, move-folder in bulk.

const std = @import("std");
const Context = @import("middleware").Context;
const media = @import("media");
const auth_middleware = @import("auth_middleware");

const h = @import("helpers.zig");

pub fn handleBulkDelete(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.fullDeleteMedia(ctx.allocator, db, h.getBackend(), media_id) catch |err| {
            std.debug.print("Bulk delete error for {s}: {}\n", .{ media_id, err });
        };
    }

    h.redirect(ctx, "/admin/media");
}

pub fn handleBulkAddTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };
    if (term_id.len == 0) {
        h.redirect(ctx, "/admin/media");
        return;
    }

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.addTermToMedia(db, media_id, term_id) catch |err| {
            std.debug.print("Bulk add-tag error for {s}: {}\n", .{ media_id, err });
        };
    }

    h.redirect(ctx, "/admin/media");
}

pub fn handleBulkRemoveTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };
    if (term_id.len == 0) {
        h.redirect(ctx, "/admin/media");
        return;
    }

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.removeTermFromMedia(db, media_id, term_id) catch |err| {
            std.debug.print("Bulk remove-tag error for {s}: {}\n", .{ media_id, err });
        };
    }

    h.redirect(ctx, "/admin/media");
}

pub fn handleBulkMoveFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };
    if (term_id.len == 0) {
        h.redirect(ctx, "/admin/media");
        return;
    }

    const ids = parseBulkIds(ctx);
    for (ids) |media_id| {
        media.replaceMediaFolder(db, media_id, term_id) catch |err| {
            std.debug.print("Bulk move-folder error for {s}: {}\n", .{ media_id, err });
        };
    }

    h.redirect(ctx, "/admin/media");
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
