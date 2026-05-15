//! Shared SQL filter clause builders + bind helpers for media_query.
//!
//! Most media query functions share the same filter tail:
//!
//!   AND filename LIKE ?N       (search)
//!   AND (mime_type LIKE ?M OR …) (mime_patterns, OR-joined)
//!   AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?P
//!   AND CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) = ?Q
//!   ORDER BY {col} {ASC|DESC}
//!   LIMIT ?R
//!   OFFSET ?S
//!
//! Every helper takes a `prefix` (e.g. `""` or `"m."`) to target either the
//! bare media table or a joined alias. The `bind_idx` pointer advances as
//! placeholders are written; the matching bind* helper must be called in the
//! same order to keep parameter indices in sync.

const std = @import("std");
const db_mod = @import("db");
const Statement = db_mod.Statement;

const Allocator = std.mem.Allocator;

// =============================================================================
// SQL clause appenders
// =============================================================================

/// Append " AND {prefix}filename LIKE ?{idx}" if `search` is non-null. Advances bind_idx.
pub fn appendSearchFilter(
    writer: anytype,
    search: ?[]const u8,
    bind_idx: *u32,
    prefix: []const u8,
) !void {
    if (search == null) return;
    try writer.print(" AND {s}filename LIKE ?{d}", .{ prefix, bind_idx.* });
    bind_idx.* += 1;
}

/// Append " AND ({prefix}mime_type LIKE ?A OR {prefix}mime_type LIKE ?B ...)"
/// when `patterns` is non-empty. Advances bind_idx by patterns.len.
pub fn appendMimePatterns(
    writer: anytype,
    patterns: []const []const u8,
    bind_idx: *u32,
    prefix: []const u8,
) !void {
    if (patterns.len == 0) return;
    try writer.writeAll(" AND (");
    for (patterns, 0..) |_, i| {
        if (i > 0) try writer.writeAll(" OR ");
        try writer.print("{s}mime_type LIKE ?{d}", .{ prefix, bind_idx.* });
        bind_idx.* += 1;
    }
    try writer.writeAll(")");
}

/// Append year and/or month filters via strftime on created_at. Advances bind_idx.
pub fn appendDateFilters(
    writer: anytype,
    year: ?u16,
    month: ?u8,
    bind_idx: *u32,
    prefix: []const u8,
) !void {
    if (year != null) {
        try writer.print(
            " AND CAST(strftime('%Y', {s}created_at, 'unixepoch') AS INTEGER) = ?{d}",
            .{ prefix, bind_idx.* },
        );
        bind_idx.* += 1;
    }
    if (month != null) {
        try writer.print(
            " AND CAST(strftime('%m', {s}created_at, 'unixepoch') AS INTEGER) = ?{d}",
            .{ prefix, bind_idx.* },
        );
        bind_idx.* += 1;
    }
}

/// Append " ORDER BY {prefix}{order_by} {ASC|DESC}" and optional LIMIT/OFFSET.
/// `order_by` is a column identifier; never user-controlled.
pub fn appendOrderLimitOffset(
    writer: anytype,
    order_by: []const u8,
    order_dir_asc: bool,
    limit: ?u32,
    offset: ?u32,
    bind_idx: *u32,
    prefix: []const u8,
) !void {
    try writer.print(" ORDER BY {s}{s} {s}", .{
        prefix, order_by, if (order_dir_asc) "ASC" else "DESC",
    });
    if (limit != null) {
        try writer.print(" LIMIT ?{d}", .{bind_idx.*});
        bind_idx.* += 1;
    }
    if (offset != null) {
        try writer.print(" OFFSET ?{d}", .{bind_idx.*});
        bind_idx.* += 1;
    }
}

// =============================================================================
// Bind helpers — call in same order as the matching append* invocations
// =============================================================================

pub fn bindSearchFilter(stmt: *Statement, search: ?[]const u8, bind_idx: *u32) !void {
    if (search) |s| {
        try stmt.bindText(@intCast(bind_idx.*), s);
        bind_idx.* += 1;
    }
}

pub fn bindMimePatterns(stmt: *Statement, patterns: []const []const u8, bind_idx: *u32) !void {
    for (patterns) |p| {
        try stmt.bindText(@intCast(bind_idx.*), p);
        bind_idx.* += 1;
    }
}

pub fn bindDateFilters(stmt: *Statement, year: ?u16, month: ?u8, bind_idx: *u32) !void {
    if (year) |y| {
        try stmt.bindInt(@intCast(bind_idx.*), @intCast(y));
        bind_idx.* += 1;
    }
    if (month) |m| {
        try stmt.bindInt(@intCast(bind_idx.*), @intCast(m));
        bind_idx.* += 1;
    }
}

pub fn bindLimitOffset(stmt: *Statement, limit: ?u32, offset: ?u32, bind_idx: *u32) !void {
    if (limit) |l| {
        try stmt.bindInt(@intCast(bind_idx.*), @intCast(l));
        bind_idx.* += 1;
    }
    if (offset) |o| {
        try stmt.bindInt(@intCast(bind_idx.*), @intCast(o));
        bind_idx.* += 1;
    }
}

// =============================================================================
// mime_patterns parsing
// =============================================================================

/// Parse a comma-separated mime pattern string ("image/*,application/pdf") into
/// SQL LIKE patterns. `image/*` → `image/%`; bare types become exact LIKE
/// patterns (no wildcard).
///
/// Caller owns the returned slice and each inner string; free via
/// `for (result) |p| allocator.free(p); allocator.free(result);`.
pub fn getMimePatterns(allocator: Allocator, patterns_str: ?[]const u8) ![][]const u8 {
    const s = patterns_str orelse return &[_][]const u8{};
    if (s.len == 0) return &[_][]const u8{};

    var result: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer result.deinit(allocator);

    var it = std.mem.splitSequence(u8, s, ",");
    while (it.next()) |pattern| {
        const trimmed = std.mem.trim(u8, pattern, " ");
        if (trimmed.len == 0) continue;

        if (std.mem.endsWith(u8, trimmed, "/*")) {
            const sql_pattern = try std.fmt.allocPrint(allocator, "{s}%", .{trimmed[0 .. trimmed.len - 1]});
            try result.append(allocator, sql_pattern);
        } else {
            try result.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "appendSearchFilter: null search emits nothing and does not advance bind_idx" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 5;

    try appendSearchFilter(buf.writer(std.testing.allocator), null, &idx, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
    try std.testing.expectEqual(@as(u32, 5), idx);
}

test "appendSearchFilter: non-null search emits AND clause and advances bind_idx" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 3;

    try appendSearchFilter(buf.writer(std.testing.allocator), "%cat%", &idx, "m.");
    try std.testing.expectEqualStrings(" AND m.filename LIKE ?3", buf.items);
    try std.testing.expectEqual(@as(u32, 4), idx);
}

test "appendMimePatterns: empty list emits nothing" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 1;

    try appendMimePatterns(buf.writer(std.testing.allocator), &.{}, &idx, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
    try std.testing.expectEqual(@as(u32, 1), idx);
}

test "appendMimePatterns: 3 patterns emit OR chain and advance bind_idx by 3" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 2;
    const patterns: []const []const u8 = &.{ "image/%", "video/%", "application/pdf" };

    try appendMimePatterns(buf.writer(std.testing.allocator), patterns, &idx, "");
    try std.testing.expectEqualStrings(
        " AND (mime_type LIKE ?2 OR mime_type LIKE ?3 OR mime_type LIKE ?4)",
        buf.items,
    );
    try std.testing.expectEqual(@as(u32, 5), idx);
}

test "appendDateFilters: both year and month, with prefix" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 1;

    try appendDateFilters(buf.writer(std.testing.allocator), 2025, 3, &idx, "m.");
    try std.testing.expectEqualStrings(
        " AND CAST(strftime('%Y', m.created_at, 'unixepoch') AS INTEGER) = ?1" ++
            " AND CAST(strftime('%m', m.created_at, 'unixepoch') AS INTEGER) = ?2",
        buf.items,
    );
    try std.testing.expectEqual(@as(u32, 3), idx);
}

test "appendDateFilters: year only, no prefix" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 7;

    try appendDateFilters(buf.writer(std.testing.allocator), 2024, null, &idx, "");
    try std.testing.expectEqualStrings(
        " AND CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?7",
        buf.items,
    );
    try std.testing.expectEqual(@as(u32, 8), idx);
}

test "appendOrderLimitOffset: order only" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 1;

    try appendOrderLimitOffset(buf.writer(std.testing.allocator), "created_at", false, null, null, &idx, "");
    try std.testing.expectEqualStrings(" ORDER BY created_at DESC", buf.items);
    try std.testing.expectEqual(@as(u32, 1), idx);
}

test "appendOrderLimitOffset: order asc + limit + offset, with prefix" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var idx: u32 = 3;

    try appendOrderLimitOffset(buf.writer(std.testing.allocator), "filename", true, 50, 100, &idx, "m.");
    try std.testing.expectEqualStrings(
        " ORDER BY m.filename ASC LIMIT ?3 OFFSET ?4",
        buf.items,
    );
    try std.testing.expectEqual(@as(u32, 5), idx);
}

test "getMimePatterns: null and empty return empty slice" {
    const a = std.testing.allocator;

    const r1 = try getMimePatterns(a, null);
    try std.testing.expectEqual(@as(usize, 0), r1.len);

    const r2 = try getMimePatterns(a, "");
    try std.testing.expectEqual(@as(usize, 0), r2.len);
}

test "getMimePatterns: wildcard expanded to SQL LIKE, exact preserved" {
    const a = std.testing.allocator;
    const result = try getMimePatterns(a, "image/*, application/pdf,  video/* ");
    defer {
        for (result) |p| a.free(p);
        a.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("image/%", result[0]);
    try std.testing.expectEqualStrings("application/pdf", result[1]);
    try std.testing.expectEqualStrings("video/%", result[2]);
}
