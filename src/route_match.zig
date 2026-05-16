//! Shared route pattern matcher used by both `router.zig` (native, stream-
//! based dispatch) and `wasm_router.zig` (WASM, bool-return dispatch). The
//! parsing and matching is identical; only the surrounding dispatch loop
//! differs between the two.

const std = @import("std");
const mw = @import("middleware");

const Context = mw.Context;

/// One element in a parsed route pattern.
pub const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    wildcard: void,
};

/// Parse a pattern like `/admin/content/:type/:id` into a slice of Segments.
/// The caller owns the returned slice (free via `allocator.free`). Returns
/// an empty slice for the root path `/`.
pub fn parsePattern(allocator: std.mem.Allocator, pattern: []const u8) ![]const Segment {
    var segments: std.ArrayListUnmanaged(Segment) = .{};
    errdefer segments.deinit(allocator);

    if (std.mem.eql(u8, pattern, "/")) {
        return segments.toOwnedSlice(allocator);
    }

    const path = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
    var iter = std.mem.splitScalar(u8, path, '/');

    while (iter.next()) |part| {
        if (part.len == 0) continue;

        if (std.mem.eql(u8, part, "*")) {
            try segments.append(allocator, .wildcard);
            break; // Wildcard must be last
        } else if (part.len > 0 and part[0] == ':') {
            try segments.append(allocator, .{ .param = part[1..] });
        } else {
            try segments.append(allocator, .{ .literal = part });
        }
    }

    return segments.toOwnedSlice(allocator);
}

/// Match a path against a parsed pattern. On success, populates
/// `ctx.params` with named captures and `ctx.wildcard` with the trailing
/// segment if the pattern had `*`. Returns `false` without modifying ctx
/// state (beyond what was already in flight) on mismatch — callers should
/// `ctx.params.clearRetainingCapacity()` between attempts if they iterate
/// candidate routes.
pub fn matchRoute(segments: []const Segment, path: []const u8, ctx: *Context) bool {
    const clean_path = std.mem.trimRight(u8, path, "\r");
    if (segments.len == 0) {
        return std.mem.eql(u8, clean_path, "/");
    }

    const path_str = if (clean_path.len > 0 and clean_path[0] == '/') clean_path[1..] else clean_path;

    if (path_str.len == 0 and segments.len > 0) {
        return false;
    }

    var path_iter = std.mem.splitScalar(u8, path_str, '/');
    var seg_idx: usize = 0;

    while (seg_idx < segments.len) : (seg_idx += 1) {
        const segment = segments[seg_idx];

        switch (segment) {
            .literal => |lit| {
                const part = path_iter.next() orelse return false;
                if (!std.mem.eql(u8, part, lit)) return false;
            },
            .param => |name| {
                const part = path_iter.next() orelse return false;
                ctx.params.put(ctx.allocator, name, part) catch return false;
            },
            .wildcard => {
                const rest = path_iter.rest();
                ctx.wildcard = if (rest.len > 0) rest else path_iter.next();
                return true;
            },
        }
    }

    return path_iter.next() == null;
}
