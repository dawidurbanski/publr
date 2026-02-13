//! Shared utility functions for CMS plugins.
//!
//! Consolidates common patterns used across plugin handlers:
//! HTTP redirects, query parameter parsing, size formatting, etc.

const std = @import("std");
const Context = @import("middleware").Context;

const Allocator = std.mem.Allocator;

/// Send a 303 See Other redirect.
pub fn redirect(ctx: *Context, location: []const u8) void {
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", location);
    ctx.response.setBody("");
}

/// Parse a single query parameter value by name.
pub fn queryParam(query: ?[]const u8, name: []const u8) ?[]const u8 {
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

/// Parse an integer query parameter by name.
pub fn queryInt(query: ?[]const u8, name: []const u8, comptime T: type) ?T {
    const raw = queryParam(query, name) orelse return null;
    if (raw.len == 0) return null;
    return std.fmt.parseInt(T, raw, 10) catch null;
}

/// Parse all values for a query parameter key (e.g. ?tag=a&tag=b -> ["a","b"]).
pub fn queryParamAll(allocator: Allocator, query: ?[]const u8, name: []const u8) []const []const u8 {
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

/// Format a file size in human-readable form (B, KB, MB).
pub fn formatSize(allocator: Allocator, size: i64) ![]const u8 {
    const s: u64 = @intCast(if (size < 0) 0 else size);
    if (s < 1024) {
        return std.fmt.allocPrint(allocator, "{d} B", .{s});
    } else if (s < 1024 * 1024) {
        return std.fmt.allocPrint(allocator, "{d} KB", .{s / 1024});
    } else {
        return std.fmt.allocPrint(allocator, "{d}.{d} MB", .{ s / (1024 * 1024), (s % (1024 * 1024)) * 10 / (1024 * 1024) });
    }
}

/// Return month name abbreviation from 1-indexed month number.
pub fn monthName(m: u8) []const u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (m >= 1 and m <= 12) return names[m - 1];
    return "?";
}

/// Build a page URL by appending &page=N (or ?page=N) to a base URL.
pub fn buildPageUrl(allocator: Allocator, base_url: []const u8, page_num: u32) []const u8 {
    if (page_num <= 1) return base_url;
    const sep: []const u8 = if (std.mem.indexOf(u8, base_url, "?") != null) "&" else "?";
    return std.fmt.allocPrint(allocator, "{s}{s}page={d}", .{ base_url, sep, page_num }) catch base_url;
}

/// Write a JSON-escaped string to a writer (escapes ", \, newlines, tabs).
pub fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

test "queryParam finds existing param" {
    try std.testing.expectEqualStrings("bar", queryParam("foo=bar&baz=qux", "foo").?);
    try std.testing.expectEqualStrings("qux", queryParam("foo=bar&baz=qux", "baz").?);
}

test "queryParam returns null for missing" {
    try std.testing.expect(queryParam("foo=bar", "missing") == null);
    try std.testing.expect(queryParam(null, "foo") == null);
}

test "queryInt parses integer" {
    try std.testing.expectEqual(@as(?u32, 42), queryInt("page=42", "page", u32));
    try std.testing.expectEqual(@as(?u32, null), queryInt("page=abc", "page", u32));
    try std.testing.expectEqual(@as(?u32, null), queryInt("page=", "page", u32));
    try std.testing.expectEqual(@as(?u32, null), queryInt(null, "page", u32));
}

test "queryParamAll collects all values" {
    const allocator = std.testing.allocator;
    const result = queryParamAll(allocator, "tag=a&tag=b&tag=c", "tag");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("b", result[1]);
    try std.testing.expectEqualStrings("c", result[2]);
}

test "formatSize formats correctly" {
    const allocator = std.testing.allocator;

    const b = try formatSize(allocator, 500);
    defer allocator.free(b);
    try std.testing.expectEqualStrings("500 B", b);

    const kb = try formatSize(allocator, 2048);
    defer allocator.free(kb);
    try std.testing.expectEqualStrings("2 KB", kb);

    const mb = try formatSize(allocator, 5 * 1024 * 1024);
    defer allocator.free(mb);
    try std.testing.expectEqualStrings("5.0 MB", mb);
}

test "monthName returns correct names" {
    try std.testing.expectEqualStrings("Jan", monthName(1));
    try std.testing.expectEqualStrings("Dec", monthName(12));
    try std.testing.expectEqualStrings("?", monthName(0));
    try std.testing.expectEqualStrings("?", monthName(13));
}

test "buildPageUrl" {
    const allocator = std.testing.allocator;

    // Page 1 returns base URL unchanged
    try std.testing.expectEqualStrings("/admin/posts", buildPageUrl(allocator, "/admin/posts", 1));

    // Page > 1 appends ?page=N
    const url2 = buildPageUrl(allocator, "/admin/posts", 3);
    defer allocator.free(url2);
    try std.testing.expectEqualStrings("/admin/posts?page=3", url2);

    // With existing query params uses &
    const url3 = buildPageUrl(allocator, "/admin/posts?status=draft", 2);
    defer allocator.free(url3);
    try std.testing.expectEqualStrings("/admin/posts?status=draft&page=2", url3);
}
