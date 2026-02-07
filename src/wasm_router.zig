//! WASM-compatible route matcher
//!
//! Lightweight alternative to router.zig that doesn't depend on std.net.Stream.
//! Implements the RouteRegistrar interface from admin_api.zig so plugins can
//! register routes the same way as the native build.

const std = @import("std");
const mw = @import("middleware");
const admin_api = @import("admin_api");

const Context = mw.Context;
const Handler = mw.Handler;
const Method = mw.Method;

/// A parsed route segment
const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    wildcard: void,
};

/// A registered route
const Route = struct {
    method: Method,
    pattern: []const u8,
    segments: []const Segment,
    handler: Handler,
};

const max_routes = 64;

/// WASM Router — stores routes and dispatches without stream dependency
pub const WasmRouter = struct {
    routes: [max_routes]Route = undefined,
    route_count: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WasmRouter {
        return .{ .allocator = allocator };
    }

    /// Register a GET route
    pub fn get(self: *WasmRouter, pattern: []const u8, handler: Handler) void {
        self.addRoute(.GET, pattern, handler);
    }

    /// Register a POST route
    pub fn post(self: *WasmRouter, pattern: []const u8, handler: Handler) void {
        self.addRoute(.POST, pattern, handler);
    }

    fn addRoute(self: *WasmRouter, method: Method, pattern: []const u8, handler: Handler) void {
        if (self.route_count >= max_routes) return;
        const segments = self.parsePattern(pattern);
        self.routes[self.route_count] = .{
            .method = method,
            .pattern = pattern,
            .segments = segments,
            .handler = handler,
        };
        self.route_count += 1;
    }

    fn parsePattern(self: *WasmRouter, pattern: []const u8) []const Segment {
        if (std.mem.eql(u8, pattern, "/")) {
            return &[_]Segment{};
        }

        const path = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
        var iter = std.mem.splitScalar(u8, path, '/');

        var count: usize = 0;
        var segments_buf: [16]Segment = undefined;

        while (iter.next()) |part| {
            if (part.len == 0) continue;
            if (count >= segments_buf.len) break;

            if (std.mem.eql(u8, part, "*")) {
                segments_buf[count] = .wildcard;
                count += 1;
                break;
            } else if (part.len > 0 and part[0] == ':') {
                segments_buf[count] = .{ .param = part[1..] };
                count += 1;
            } else {
                segments_buf[count] = .{ .literal = part };
                count += 1;
            }
        }

        const result = self.allocator.alloc(Segment, count) catch return &[_]Segment{};
        @memcpy(result, segments_buf[0..count]);
        return result;
    }

    /// Dispatch a request to matching handler. Returns true if a route matched.
    pub fn dispatch(self: *WasmRouter, ctx: *Context) !bool {
        const normalized_path = if (ctx.path.len > 1 and ctx.path[ctx.path.len - 1] == '/')
            ctx.path[0 .. ctx.path.len - 1]
        else
            ctx.path;

        for (self.routes[0..self.route_count]) |route| {
            if (route.method != ctx.method) continue;

            if (matchRoute(route.segments, normalized_path, ctx)) {
                try route.handler(ctx);
                return true;
            }
            // Reset params for next attempt
            ctx.params.clearRetainingCapacity();
            ctx.wildcard = null;
        }

        return false;
    }

    /// Create a RouteRegistrar that wraps this WasmRouter
    pub fn registrar(self: *WasmRouter) admin_api.RouteRegistrar {
        return .{
            .ctx = self,
            .register_get = registerGet,
            .register_post = registerPost,
        };
    }
};

fn registerGet(ctx: *anyopaque, path: []const u8, handler: Handler) void {
    const router: *WasmRouter = @ptrCast(@alignCast(ctx));
    router.get(path, handler);
}

fn registerPost(ctx: *anyopaque, path: []const u8, handler: Handler) void {
    const router: *WasmRouter = @ptrCast(@alignCast(ctx));
    router.post(path, handler);
}

fn matchRoute(segments: []const Segment, path: []const u8, ctx: *Context) bool {
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
