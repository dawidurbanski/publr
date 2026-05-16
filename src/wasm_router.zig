//! WASM-compatible route matcher
//!
//! Lightweight alternative to router.zig that doesn't depend on std.net.Stream.
//! Implements the RouteRegistrar interface from admin_api.zig so plugins can
//! register routes the same way as the native build.

const std = @import("std");
const mw = @import("middleware");
const admin_api = @import("admin_api");
const route_match = @import("route_match");

const Context = mw.Context;
const Handler = mw.Handler;
const Method = mw.Method;

const Segment = route_match.Segment;

/// A registered route
const Route = struct {
    method: Method,
    pattern: []const u8,
    segments: []const Segment,
    handler: Handler,
};

/// WASM Router — stores routes and dispatches without stream dependency.
/// Routes grow dynamically via an ArrayList (same shape as native router);
/// route registration happens once at startup so we don't worry about
/// reallocation cost. Silent registration drops would be a worse failure
/// mode than OOM, so addRoute panics if append fails.
pub const WasmRouter = struct {
    routes: std.ArrayListUnmanaged(Route) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WasmRouter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WasmRouter) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.segments);
        }
        self.routes.deinit(self.allocator);
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
        const segments = route_match.parsePattern(self.allocator, pattern) catch @panic("OOM parsing route pattern");
        self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .segments = segments,
            .handler = handler,
        }) catch @panic("OOM registering WASM route");
    }

    /// Dispatch a request to matching handler. Returns true if a route matched.
    pub fn dispatch(self: *WasmRouter, ctx: *Context) !bool {
        const normalized_path = if (ctx.path.len > 1 and ctx.path[ctx.path.len - 1] == '/')
            ctx.path[0 .. ctx.path.len - 1]
        else
            ctx.path;

        for (self.routes.items) |route| {
            if (route.method != ctx.method) continue;

            if (route_match.matchRoute(route.segments, normalized_path, ctx)) {
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

