//! Shared types and helper functions for the media plugin module.

const std = @import("std");
const media = @import("media");
const db_mod = @import("db");
const storage = @import("storage");

const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32;

const pu = @import("plugin_utils");
pub const redirect = pu.redirect;
pub const formatSize = pu.formatSize;
pub const parseQueryParam = pu.queryParam;
pub const parseQueryParamAll = pu.queryParamAll;
pub const parseIntParam = pu.queryInt;
pub const monthName = pu.monthName;

// =============================================================================
// View Types
// =============================================================================

pub const ActiveTag = struct {
    id: []const u8,
    name: []const u8,
    remove_url: []const u8,
};

pub const BreadcrumbItem = struct {
    name: []const u8,
    url: []const u8,
};

pub const ActiveFilter = struct {
    label: []const u8,
    value: []const u8,
    remove_url: []const u8,
};

pub const HiddenParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const FolderItem = struct {
    id: []const u8,
    name: []const u8,
    parent_id: []const u8,
    count: u32,
    depth: u32,
    is_active: bool,
    is_disabled: bool,
    url: []const u8,
};

pub const TagItem = struct {
    id: []const u8,
    name: []const u8,
    count: u32,
    is_active: bool,
    is_disabled: bool,
    url: []const u8,
};

pub const YearOption = struct {
    value: []const u8,
    label: []const u8,
    is_selected: bool,
};

pub const MonthOption = struct {
    value: []const u8,
    label: []const u8,
    is_selected: bool,
};

pub const FolderOption = struct {
    id: []const u8,
    name: []const u8,
    depth: u32,
    is_selected: bool,
};

pub const TagOption = struct {
    id: []const u8,
    name: []const u8,
    is_selected: bool,
};

pub const MediaListItem = struct {
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

// =============================================================================
// Helper Functions
// =============================================================================

/// Build a media page URL preserving view, folder, tag[], unreviewed, search, year, and month params
pub fn buildMediaUrl(allocator: std.mem.Allocator, view: []const u8, folder: ?[]const u8, tags: []const []const u8, unreviewed: bool, search: ?[]const u8, year: ?u16, month: ?u8) []const u8 {
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

/// Build hierarchical folder list sorted parent->children with depth (recursive)
pub fn buildFolderTree(
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
pub fn appendFolderChildren(
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
            const count = media.countFolderInContext(allocator, db, f.id, active_tag_ids, search_pattern, year, month, null) catch 0;
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

/// Build breadcrumb trail: "All Files" -> [Default | Folder -> Subfolder -> ...]
/// The last item has no URL (current location). All ancestors are clickable.
pub fn buildBreadcrumbs(
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

            // Reverse ancestors so it goes root->leaf
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
pub fn findFolder(folders: []const media.TermRecord, id: []const u8) ?media.TermRecord {
    for (folders) |f| {
        if (std.mem.eql(u8, f.id, id)) return f;
    }
    return null;
}

pub fn isIdInList(id: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, id, item)) return true;
    }
    return false;
}

pub fn removeFromList(allocator: std.mem.Allocator, list: []const []const u8, item: []const u8) []const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .{};
    for (list) |entry| {
        if (!std.mem.eql(u8, entry, item)) {
            result.append(allocator, entry) catch {};
        }
    }
    return result.toOwnedSlice(allocator) catch &[_][]const u8{};
}

pub fn appendToList(allocator: std.mem.Allocator, list: []const []const u8, item: []const u8) []const []const u8 {
    var result = allocator.alloc([]const u8, list.len + 1) catch return list;
    @memcpy(result[0..list.len], list);
    result[list.len] = item;
    return result;
}

pub fn findTagName(tags: []const media.TermRecord, id: []const u8) []const u8 {
    for (tags) |t| {
        if (std.mem.eql(u8, t.id, id)) return t.name;
    }
    return id;
}

pub fn findFolderName(folders: []const media.TermRecord, id: []const u8) []const u8 {
    for (folders) |f| {
        if (std.mem.eql(u8, f.id, id)) return f.name;
    }
    return id;
}

pub fn isTermSelected(term_id: []const u8, assigned_ids: []const []const u8) bool {
    for (assigned_ids) |aid| {
        if (std.mem.eql(u8, term_id, aid)) return true;
    }
    return false;
}

/// Decode percent-encoded URL string: '+' -> space, '%XX' -> byte
pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8) []const u8 {
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

pub fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

/// URL-encode a string into the buffer (for use in query parameters)
pub fn urlEncode(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), input: []const u8) void {
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

/// Find a tag by name or create it
pub fn findOrCreateTag(allocator: std.mem.Allocator, db: *db_mod.Db, name: []const u8) ![]const u8 {
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

/// Get the appropriate storage backend for the current platform
pub fn getBackend() storage.StorageBackend {
    if (is_wasm) return @import("wasm_storage").backend;
    return storage.filesystem;
}
