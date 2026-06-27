//! `[kv:key]` token parser for variable interpolation.
//!
//! Pure functions over byte slices. No DB, no I/O.
//!
//! Grammar:
//!   `[kv:<identifier>]`           — token; substituted via lookup
//!   `[[kv:<identifier>]]`         — escape; renders literal `[kv:<identifier>]`
//!   identifier := [a-zA-Z_][a-zA-Z0-9_.]*
//!
//! Malformed sequences (e.g. `[kv:]`, `[kv: foo]`, unterminated) pass through
//! as literal text. Unknown keys (lookup returns null) preserve the token in
//! the output — preserves debuggability.

const std = @import("std");
const Allocator = std.mem.Allocator;

const TOKEN_OPEN: []const u8 = "[kv:";
const ESCAPE_OPEN: []const u8 = "[[kv:";

/// Returns deduplicated list of var keys referenced by tokens in `content`.
/// Escaped occurrences (`[[kv:foo]]`) are ignored. Caller owns the returned
/// slice and each element (allocated copies of identifiers).
pub fn extractKeys(allocator: Allocator, content: []const u8) ![][]const u8 {
    var keys: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var i: usize = 0;
    while (i < content.len) {
        if (matchEscape(content, i)) |end| {
            i = end;
            continue;
        }
        if (matchToken(content, i)) |m| {
            const gop = try seen.getOrPut(m.key);
            if (!gop.found_existing) {
                const owned = try allocator.dupe(u8, m.key);
                try keys.append(allocator, owned);
            }
            i = m.end;
            continue;
        }
        i += 1;
    }

    return try keys.toOwnedSlice(allocator);
}

/// Returns `content` with `[kv:key]` tokens substituted via `lookup_ctx.lookup(key)`.
/// `lookup_ctx` is any value with a method `lookup(key: []const u8) ?[]const u8`.
/// Escapes (`[[kv:foo]]`) are emitted as literal `[kv:foo]`. Unknown keys keep
/// their tokens. Caller owns the returned slice.
pub fn substitute(allocator: Allocator, content: []const u8, lookup_ctx: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (matchEscape(content, i)) |end| {
            // Emit literal: drop one outer bracket on each side.
            // `[[kv:foo]]` (i..end) → `[kv:foo]`
            try out.appendSlice(allocator, content[i + 1 .. end - 1]);
            i = end;
            continue;
        }
        if (matchToken(content, i)) |m| {
            if (lookup_ctx.lookup(m.key)) |value| {
                try out.appendSlice(allocator, value);
            } else {
                try out.appendSlice(allocator, content[i..m.end]);
            }
            i = m.end;
            continue;
        }
        try out.append(allocator, content[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

const TokenMatch = struct { key: []const u8, end: usize };

fn matchToken(content: []const u8, start: usize) ?TokenMatch {
    if (start + TOKEN_OPEN.len >= content.len) return null;
    if (!std.mem.startsWith(u8, content[start..], TOKEN_OPEN)) return null;

    const id_start = start + TOKEN_OPEN.len;
    var i = id_start;

    if (i >= content.len or !isIdentFirst(content[i])) return null;
    i += 1;
    while (i < content.len and isIdentRest(content[i])) : (i += 1) {}

    if (i >= content.len or content[i] != ']') return null;

    return .{ .key = content[id_start..i], .end = i + 1 };
}

fn matchEscape(content: []const u8, start: usize) ?usize {
    if (start + ESCAPE_OPEN.len >= content.len) return null;
    if (!std.mem.startsWith(u8, content[start..], ESCAPE_OPEN)) return null;

    const id_start = start + ESCAPE_OPEN.len;
    var i = id_start;

    if (i >= content.len or !isIdentFirst(content[i])) return null;
    i += 1;
    while (i < content.len and isIdentRest(content[i])) : (i += 1) {}

    if (i + 1 >= content.len) return null;
    if (content[i] != ']' or content[i + 1] != ']') return null;

    return i + 2;
}

inline fn isIdentFirst(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

inline fn isIdentRest(c: u8) bool {
    return isIdentFirst(c) or (c >= '0' and c <= '9') or c == '.';
}

// =============================================================================
// Tests
// =============================================================================

/// Test helper: lookup that returns a fixed map of key→value.
const MapLookup = struct {
    entries: []const struct { key: []const u8, value: []const u8 },

    pub fn lookup(self: MapLookup, key: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

/// Test helper: lookup that always returns null.
const NullLookup = struct {
    pub fn lookup(_: NullLookup, _: []const u8) ?[]const u8 {
        return null;
    }
};

fn freeKeys(allocator: Allocator, keys: [][]const u8) void {
    for (keys) |k| allocator.free(k);
    allocator.free(keys);
}

test "extractKeys: empty content" {
    const keys = try extractKeys(std.testing.allocator, "");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 0), keys.len);
}

test "extractKeys: no tokens" {
    const keys = try extractKeys(std.testing.allocator, "hello world, no tokens here");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 0), keys.len);
}

test "extractKeys: single token" {
    const keys = try extractKeys(std.testing.allocator, "Hello [kv:name], welcome");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings("name", keys[0]);
}

test "extractKeys: multiple distinct tokens" {
    const keys = try extractKeys(std.testing.allocator, "[kv:a] and [kv:b] then [kv:c]");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("b", keys[1]);
    try std.testing.expectEqualStrings("c", keys[2]);
}

test "extractKeys: duplicates deduplicated, first-occurrence order preserved" {
    const keys = try extractKeys(std.testing.allocator, "[kv:b] [kv:a] [kv:b] [kv:a]");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("b", keys[0]);
    try std.testing.expectEqualStrings("a", keys[1]);
}

test "extractKeys: escape ignored" {
    const keys = try extractKeys(std.testing.allocator, "literal [[kv:foo]] not a token");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 0), keys.len);
}

test "extractKeys: identifier with dot (namespaced)" {
    const keys = try extractKeys(std.testing.allocator, "see [kv:seo.title_sep] in title");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings("seo.title_sep", keys[0]);
}

test "extractKeys: adjacent tokens" {
    const keys = try extractKeys(std.testing.allocator, "[kv:a][kv:b]");
    defer freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("b", keys[1]);
}

test "extractKeys: malformed forms are literal text" {
    // Empty identifier, leading space, unterminated, case-mismatched prefix
    const cases = [_][]const u8{
        "[kv:]",
        "[kv: foo]",
        "[kv:foo",
        "[Kv:foo]",
        "[KV:foo]",
        "[kv:1foo]", // identifier must start with [a-zA-Z_]
    };
    for (cases) |c| {
        const keys = try extractKeys(std.testing.allocator, c);
        defer freeKeys(std.testing.allocator, keys);
        try std.testing.expectEqual(@as(usize, 0), keys.len);
    }
}

test "substitute: empty content" {
    const lookup = MapLookup{ .entries = &.{} };
    const out = try substitute(std.testing.allocator, "", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "substitute: passes through content with no tokens" {
    const lookup = MapLookup{ .entries = &.{} };
    const out = try substitute(std.testing.allocator, "plain text", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("plain text", out);
}

test "substitute: single token" {
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "name", .value = "Acme" },
    } };
    const out = try substitute(std.testing.allocator, "Hello [kv:name]!", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Hello Acme!", out);
}

test "substitute: multiple and adjacent tokens" {
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "a", .value = "X" },
        .{ .key = "b", .value = "Y" },
    } };
    const out = try substitute(std.testing.allocator, "[kv:a][kv:b]-[kv:a]", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("XY-X", out);
}

test "substitute: escape becomes literal kv token" {
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "foo", .value = "BAD" },
    } };
    const out = try substitute(std.testing.allocator, "literal [[kv:foo]] here", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("literal [kv:foo] here", out);
}

test "substitute: escape and token side by side" {
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "name", .value = "Acme" },
    } };
    const out = try substitute(std.testing.allocator, "[[kv:name]] is [kv:name]", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("[kv:name] is Acme", out);
}

test "substitute: unknown key preserves token" {
    const lookup = NullLookup{};
    const out = try substitute(std.testing.allocator, "before [kv:missing] after", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("before [kv:missing] after", out);
}

test "substitute: malformed forms pass through as literal text" {
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "foo", .value = "REPLACED" },
    } };
    const cases = [_][]const u8{
        "[kv:]",
        "[kv: foo]",
        "[kv:foo", // unterminated
        "[Kv:foo]",
    };
    for (cases) |c| {
        const out = try substitute(std.testing.allocator, c, lookup);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(c, out);
    }
}

test "substitute: identifier with dot" {
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "seo.title_sep", .value = " — " },
    } };
    const out = try substitute(std.testing.allocator, "Title[kv:seo.title_sep]Site", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Title — Site", out);
}

test "substitute: value containing kv-like text is not re-parsed" {
    // Substitution result is emitted as-is; no recursive parsing.
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "tagline", .value = "Visit [kv:other]" },
    } };
    const out = try substitute(std.testing.allocator, "[kv:tagline]", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Visit [kv:other]", out);
}

test "substitute: triple bracket left-edge case" {
    // `[[[kv:foo]]]` → `[` (literal) + `[kv:foo]` (escape literal) + `]` = `[[kv:foo]]`
    const lookup = MapLookup{ .entries = &.{
        .{ .key = "foo", .value = "BAD" },
    } };
    const out = try substitute(std.testing.allocator, "[[[kv:foo]]]", lookup);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("[[kv:foo]]", out);
}
