//! Shared pagination module for CMS plugins.
//!
//! Extracts common pagination logic: page calculation, offset, URL generation,
//! and windowed page number display with ellipsis support.

const std = @import("std");
const pu = @import("plugin_utils");

const Allocator = std.mem.Allocator;

pub const PageUrl = struct {
    page_num: []const u8,
    url: []const u8,
    is_current: bool,
    is_ellipsis: bool = false,
};

pub const PageUrls = struct {
    items: []const PageUrl,
    prev_url: []const u8,
    next_url: []const u8,
};

pub const Paginator = struct {
    current_page: u32,
    total_pages: u32,
    items_per_page: u32,

    /// Create a Paginator from a query string, total item count, and page size.
    pub fn init(query: ?[]const u8, total_count: u32, items_per_page: u32) Paginator {
        const current_page: u32 = @max(1, pu.queryInt(query, "page", u32) orelse 1);
        const total_pages: u32 = if (total_count == 0) 1 else (total_count + items_per_page - 1) / items_per_page;
        return .{
            .current_page = current_page,
            .total_pages = total_pages,
            .items_per_page = items_per_page,
        };
    }

    /// Database offset for the current page.
    pub fn offset(self: Paginator) u32 {
        return (self.current_page - 1) * self.items_per_page;
    }

    /// Build a full set of page URLs for rendering pagination controls.
    /// Uses a simple list of all pages (suitable for small page counts).
    pub fn buildPageUrls(self: Paginator, allocator: Allocator, base_url: []const u8) PageUrls {
        const page_urls = allocator.alloc(PageUrl, self.total_pages) catch return .{
            .items = &[_]PageUrl{},
            .prev_url = "",
            .next_url = "",
        };
        for (page_urls, 0..) |*page_url, i| {
            const pg: u32 = @intCast(i + 1);
            page_url.* = .{
                .page_num = std.fmt.allocPrint(allocator, "{d}", .{pg}) catch "?",
                .url = pu.buildPageUrl(allocator, base_url, pg),
                .is_current = pg == self.current_page,
            };
        }

        return .{
            .items = page_urls,
            .prev_url = if (self.current_page > 1) pu.buildPageUrl(allocator, base_url, self.current_page - 1) else "",
            .next_url = if (self.current_page < self.total_pages) pu.buildPageUrl(allocator, base_url, self.current_page + 1) else "",
        };
    }

    /// Build truncated pagination URLs with ellipsis: 1 ... 4 [5] 6 ... 251
    /// Shows first page, last page, and a window around the current page.
    pub fn buildTruncatedPageUrls(self: Paginator, allocator: Allocator, base_url: []const u8) PageUrls {
        const empty: PageUrls = .{ .items = &[_]PageUrl{}, .prev_url = "", .next_url = "" };
        const window = 1; // pages on each side of current

        // Collect which page numbers to show
        var pages_to_show: std.ArrayListUnmanaged(u32) = .{};
        // Always page 1
        pages_to_show.append(allocator, 1) catch return empty;
        // Window around current page
        const win_start = @max(2, if (self.current_page > window) self.current_page - window else 1);
        const win_end = @min(self.total_pages - 1, self.current_page + window);
        var pg = win_start;
        while (pg <= win_end) : (pg += 1) {
            pages_to_show.append(allocator, pg) catch return empty;
        }
        // Always last page (if > 1)
        if (self.total_pages > 1) {
            pages_to_show.append(allocator, self.total_pages) catch return empty;
        }

        // Build PageUrl entries, inserting ellipsis between gaps
        var list: std.ArrayListUnmanaged(PageUrl) = .{};
        var prev_pg: u32 = 0;
        for (pages_to_show.items) |p| {
            if (prev_pg > 0 and p > prev_pg + 1) {
                list.append(allocator, .{
                    .page_num = "...",
                    .url = "",
                    .is_current = false,
                    .is_ellipsis = true,
                }) catch return empty;
            }
            list.append(allocator, .{
                .page_num = std.fmt.allocPrint(allocator, "{d}", .{p}) catch "?",
                .url = pu.buildPageUrl(allocator, base_url, p),
                .is_current = p == self.current_page,
            }) catch return empty;
            prev_pg = p;
        }

        return .{
            .items = list.toOwnedSlice(allocator) catch &[_]PageUrl{},
            .prev_url = if (self.current_page > 1) pu.buildPageUrl(allocator, base_url, self.current_page - 1) else "",
            .next_url = if (self.current_page < self.total_pages) pu.buildPageUrl(allocator, base_url, self.current_page + 1) else "",
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

// Tests use an arena allocator since pagination is designed for arena-style use
// in request handlers (all allocations freed together at end of request).

test "Paginator.init basic" {
    const p = Paginator.init(null, 100, 20);
    try std.testing.expectEqual(@as(u32, 1), p.current_page);
    try std.testing.expectEqual(@as(u32, 5), p.total_pages);
    try std.testing.expectEqual(@as(u32, 20), p.items_per_page);
}

test "Paginator.init with page query param" {
    const p = Paginator.init("page=3", 100, 20);
    try std.testing.expectEqual(@as(u32, 3), p.current_page);
    try std.testing.expectEqual(@as(u32, 5), p.total_pages);
}

test "Paginator.init with zero items" {
    const p = Paginator.init(null, 0, 20);
    try std.testing.expectEqual(@as(u32, 1), p.total_pages);
}

test "Paginator.init rounds up total pages" {
    const p = Paginator.init(null, 21, 20);
    try std.testing.expectEqual(@as(u32, 2), p.total_pages);
}

test "Paginator.init page clamped to 1" {
    const p = Paginator.init("page=0", 100, 20);
    try std.testing.expectEqual(@as(u32, 1), p.current_page);
}

test "Paginator.offset" {
    const p = Paginator.init("page=3", 100, 20);
    try std.testing.expectEqual(@as(u32, 40), p.offset());
}

test "Paginator.offset first page" {
    const p = Paginator.init(null, 100, 20);
    try std.testing.expectEqual(@as(u32, 0), p.offset());
}

test "Paginator.buildPageUrls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const p = Paginator.init("page=2", 60, 20);
    const urls = p.buildPageUrls(allocator, "/admin/posts");

    try std.testing.expectEqual(@as(usize, 3), urls.items.len);

    // Page 1
    try std.testing.expectEqualStrings("1", urls.items[0].page_num);
    try std.testing.expect(!urls.items[0].is_current);

    // Page 2 (current)
    try std.testing.expectEqualStrings("2", urls.items[1].page_num);
    try std.testing.expect(urls.items[1].is_current);

    // Page 3
    try std.testing.expectEqualStrings("3", urls.items[2].page_num);
    try std.testing.expect(!urls.items[2].is_current);

    // Prev/next
    try std.testing.expect(urls.prev_url.len > 0);
    try std.testing.expect(urls.next_url.len > 0);
}

test "Paginator.buildPageUrls no prev on first page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const p = Paginator.init(null, 40, 20);
    const urls = p.buildPageUrls(allocator, "/admin/posts");

    try std.testing.expectEqualStrings("", urls.prev_url);
    try std.testing.expect(urls.next_url.len > 0);
}

test "Paginator.buildPageUrls no next on last page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const p = Paginator.init("page=2", 40, 20);
    const urls = p.buildPageUrls(allocator, "/admin/posts");

    try std.testing.expect(urls.prev_url.len > 0);
    try std.testing.expectEqualStrings("", urls.next_url);
}

test "Paginator.buildTruncatedPageUrls with ellipsis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const p = Paginator.init("page=5", 200, 20);
    const urls = p.buildTruncatedPageUrls(allocator, "/admin/posts");

    // Should have: 1 ... 4 [5] 6 ... 10
    // That's 7 entries: 1, ellipsis, 4, 5, 6, ellipsis, 10
    try std.testing.expectEqual(@as(usize, 7), urls.items.len);

    // First should be page 1
    try std.testing.expectEqualStrings("1", urls.items[0].page_num);
    try std.testing.expect(!urls.items[0].is_ellipsis);

    // Second should be ellipsis
    try std.testing.expectEqualStrings("...", urls.items[1].page_num);
    try std.testing.expect(urls.items[1].is_ellipsis);

    // Current page (5) should be marked
    try std.testing.expectEqualStrings("5", urls.items[3].page_num);
    try std.testing.expect(urls.items[3].is_current);

    // Last should be page 10
    try std.testing.expectEqualStrings("10", urls.items[6].page_num);
    try std.testing.expect(!urls.items[6].is_ellipsis);
}

test "Paginator.buildTruncatedPageUrls no ellipsis for small page count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const p = Paginator.init("page=2", 60, 20);
    const urls = p.buildTruncatedPageUrls(allocator, "/admin/posts");

    // 3 pages, all should be shown, no ellipsis
    try std.testing.expectEqual(@as(usize, 3), urls.items.len);
    for (urls.items) |item| {
        try std.testing.expect(!item.is_ellipsis);
    }
}
