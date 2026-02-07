const std = @import("std");
const Allocator = std.mem.Allocator;
const mw = @import("middleware");

// Re-export types from middleware for convenience
pub const Context = mw.Context;
pub const Method = mw.Method;
pub const Middleware = mw.Middleware;
pub const Handler = mw.Handler;
pub const NextFn = mw.NextFn;
pub const Response = mw.Response;

/// Route options for per-route configuration
pub const RouteOptions = struct {
    middleware: []const Middleware = &[_]Middleware{},
};

/// A registered route
const Route = struct {
    method: Method,
    pattern: []const u8,
    segments: []const Segment,
    handler: Handler,
    middleware: []const Middleware,
};

/// Segment types in a route pattern
const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    wildcard: void,
};

/// HTTP Router with path matching, method dispatch, and middleware support
pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayListUnmanaged(Route),
    global_middleware: std.ArrayListUnmanaged(Middleware),
    not_found_handler: ?Handler,

    pub fn init(allocator: Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = .{},
            .global_middleware = .{},
            .not_found_handler = null,
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.segments);
        }
        self.routes.deinit(self.allocator);
        self.global_middleware.deinit(self.allocator);
    }

    /// Add global middleware (applies to all routes)
    pub fn use(self: *Router, middleware: Middleware) !void {
        try self.global_middleware.append(self.allocator, middleware);
    }

    /// Register a GET route
    pub fn get(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.GET, pattern, handler, .{});
    }

    /// Register a GET route with options
    pub fn getWithOptions(self: *Router, pattern: []const u8, handler: Handler, options: RouteOptions) !void {
        try self.addRoute(.GET, pattern, handler, options);
    }

    /// Register a POST route
    pub fn post(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.POST, pattern, handler, .{});
    }

    /// Register a POST route with options
    pub fn postWithOptions(self: *Router, pattern: []const u8, handler: Handler, options: RouteOptions) !void {
        try self.addRoute(.POST, pattern, handler, options);
    }

    /// Register a PUT route
    pub fn put(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.PUT, pattern, handler, .{});
    }

    /// Register a PUT route with options
    pub fn putWithOptions(self: *Router, pattern: []const u8, handler: Handler, options: RouteOptions) !void {
        try self.addRoute(.PUT, pattern, handler, options);
    }

    /// Register a DELETE route
    pub fn delete(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.DELETE, pattern, handler, .{});
    }

    /// Register a DELETE route with options
    pub fn deleteWithOptions(self: *Router, pattern: []const u8, handler: Handler, options: RouteOptions) !void {
        try self.addRoute(.DELETE, pattern, handler, options);
    }

    /// Set custom 404 handler
    pub fn setNotFound(self: *Router, handler: Handler) void {
        self.not_found_handler = handler;
    }

    fn addRoute(self: *Router, method: Method, pattern: []const u8, handler: Handler, options: RouteOptions) !void {
        const segments = try self.parsePattern(pattern);
        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .segments = segments,
            .handler = handler,
            .middleware = options.middleware,
        });
    }

    fn parsePattern(self: *Router, pattern: []const u8) ![]const Segment {
        var segments: std.ArrayListUnmanaged(Segment) = .{};
        errdefer segments.deinit(self.allocator);

        // Handle root path
        if (std.mem.eql(u8, pattern, "/")) {
            return segments.toOwnedSlice(self.allocator);
        }

        // Remove leading slash and split
        const path = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
        var iter = std.mem.splitScalar(u8, path, '/');

        while (iter.next()) |part| {
            if (part.len == 0) continue;

            if (std.mem.eql(u8, part, "*")) {
                try segments.append(self.allocator, .wildcard);
                break; // Wildcard must be last
            } else if (part.len > 0 and part[0] == ':') {
                try segments.append(self.allocator, .{ .param = part[1..] });
            } else {
                try segments.append(self.allocator, .{ .literal = part });
            }
        }

        return segments.toOwnedSlice(self.allocator);
    }

    /// Dispatch a request to the matching handler with middleware chain
    pub fn dispatch(self: *Router, method: Method, path: []const u8, stream: std.net.Stream, headers: []const mw.RequestHeader, body: ?[]const u8, query: ?[]const u8) !void {
        // Normalize path: strip trailing slash (except for root "/")
        const normalized_path = if (path.len > 1 and path[path.len - 1] == '/')
            path[0 .. path.len - 1]
        else
            path;

        var ctx = Context.initWithStream(self.allocator, method, normalized_path, stream);
        defer ctx.deinit();

        // Set query string
        ctx.query = query;

        // Copy request headers to context
        for (headers) |header| {
            ctx.addRequestHeader(header.name, header.value);
        }

        // Set request body if present
        if (body) |b| {
            ctx.setBody(b);
        }

        for (self.routes.items) |route| {
            if (route.method != method) continue;

            if (self.matchRoute(route.segments, normalized_path, &ctx)) {
                // Execute middleware chain then handler
                try mw.executeChain(
                    &ctx,
                    self.global_middleware.items,
                    route.middleware,
                    route.handler,
                );

                // Send buffered response (skip if streaming already sent headers)
                if (!ctx.response.headers_sent) {
                    try sendResponse(stream, &ctx.response);
                }
                return;
            }
            // Reset context for next route attempt
            ctx.params.clearRetainingCapacity();
            ctx.wildcard = null;
        }

        // No route matched
        if (self.not_found_handler) |handler| {
            try mw.executeChain(&ctx, self.global_middleware.items, &[_]Middleware{}, handler);
            if (!ctx.response.headers_sent) {
                try sendResponse(stream, &ctx.response);
            }
        } else {
            try defaultNotFound(&ctx);
            if (!ctx.response.headers_sent) {
                try sendResponse(stream, &ctx.response);
            }
        }
    }

    fn matchRoute(self: *Router, segments: []const Segment, path: []const u8, ctx: *Context) bool {
        _ = self;

        // Handle root path
        const clean_path = std.mem.trimRight(u8, path, "\r");
        if (segments.len == 0) {
            return std.mem.eql(u8, clean_path, "/");
        }

        // Remove leading slash and split path
        const path_str = if (clean_path.len > 0 and clean_path[0] == '/') clean_path[1..] else clean_path;

        // Handle empty path after removing slash
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
                    // Capture rest of path
                    const rest = path_iter.rest();
                    ctx.wildcard = if (rest.len > 0) rest else path_iter.next();
                    return true;
                },
            }
        }

        // Ensure no extra path segments
        return path_iter.next() == null;
    }
};

fn sendResponse(stream: std.net.Stream, response: *const Response) !void {
    var buf: [1024]u8 = undefined;
    var offset: usize = 0;

    // Write status line and standard headers
    const header_start = try std.fmt.bufPrint(
        buf[offset..],
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n",
        .{ response.status, response.content_type, response.body.len },
    );
    offset += header_start.len;

    // Write custom headers
    for (response.getCustomHeaders()) |maybe_header| {
        if (maybe_header) |h| {
            const custom = try std.fmt.bufPrint(
                buf[offset..],
                "{s}: {s}\r\n",
                .{ h.name, h.value },
            );
            offset += custom.len;
        }
    }

    // Write header terminator
    buf[offset] = '\r';
    buf[offset + 1] = '\n';
    offset += 2;

    _ = try stream.write(buf[0..offset]);
    _ = try stream.write(response.body);
}

fn defaultNotFound(ctx: *Context) !void {
    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
}

// Tests
test "router exact path matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const TestHandler = struct {
        fn handle(_: *Context) !void {}
    };

    try router.get("/", TestHandler.handle);
    try router.get("/admin", TestHandler.handle);
    try router.get("/api/health", TestHandler.handle);

    // Test pattern parsing
    try std.testing.expectEqual(@as(usize, 3), router.routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), router.routes.items[0].segments.len);
    try std.testing.expectEqual(@as(usize, 1), router.routes.items[1].segments.len);
    try std.testing.expectEqual(@as(usize, 2), router.routes.items[2].segments.len);
}

test "router path parameter extraction" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/entries/:id", struct {
        fn handle(_: *Context) !void {}
    }.handle);

    try router.get("/users/:user_id/posts/:post_id", struct {
        fn handle(_: *Context) !void {}
    }.handle);

    // Check segments parsed correctly
    const route1 = router.routes.items[0];
    try std.testing.expectEqual(@as(usize, 2), route1.segments.len);
    try std.testing.expectEqualStrings("entries", route1.segments[0].literal);
    try std.testing.expectEqualStrings("id", route1.segments[1].param);

    const route2 = router.routes.items[1];
    try std.testing.expectEqual(@as(usize, 4), route2.segments.len);
}

test "router wildcard pattern" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/static/*", struct {
        fn handle(_: *Context) !void {}
    }.handle);

    const route = router.routes.items[0];
    try std.testing.expectEqual(@as(usize, 2), route.segments.len);
    try std.testing.expectEqualStrings("static", route.segments[0].literal);
    try std.testing.expect(route.segments[1] == .wildcard);
}

test "router method dispatch" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/entries", struct {
        fn handle(_: *Context) !void {}
    }.handle);
    try router.post("/entries", struct {
        fn handle(_: *Context) !void {}
    }.handle);
    try router.put("/entries/:id", struct {
        fn handle(_: *Context) !void {}
    }.handle);
    try router.delete("/entries/:id", struct {
        fn handle(_: *Context) !void {}
    }.handle);

    try std.testing.expectEqual(@as(usize, 4), router.routes.items.len);
    try std.testing.expectEqual(Method.GET, router.routes.items[0].method);
    try std.testing.expectEqual(Method.POST, router.routes.items[1].method);
    try std.testing.expectEqual(Method.PUT, router.routes.items[2].method);
    try std.testing.expectEqual(Method.DELETE, router.routes.items[3].method);
}

test "global middleware registration" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const mw1 = struct {
        fn call(_: *Context, next: NextFn) !void {
            try next(@constCast(&Context.init(std.testing.allocator, .GET, "/")));
        }
    }.call;

    const mw2 = struct {
        fn call(_: *Context, next: NextFn) !void {
            try next(@constCast(&Context.init(std.testing.allocator, .GET, "/")));
        }
    }.call;

    try router.use(mw1);
    try router.use(mw2);

    try std.testing.expectEqual(@as(usize, 2), router.global_middleware.items.len);
}

test "per-route middleware registration" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const authMiddleware = struct {
        fn call(_: *Context, next: NextFn) !void {
            try next(@constCast(&Context.init(std.testing.allocator, .GET, "/")));
        }
    }.call;

    const routeMiddleware = [_]Middleware{authMiddleware};

    try router.getWithOptions("/admin", struct {
        fn handle(_: *Context) !void {}
    }.handle, .{ .middleware = &routeMiddleware });

    try std.testing.expectEqual(@as(usize, 1), router.routes.items[0].middleware.len);
}

test "route matching exact paths" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/", struct {
        fn handle(_: *Context) !void {}
    }.handle);
    try router.get("/admin", struct {
        fn handle(_: *Context) !void {}
    }.handle);

    // Test root matching
    var ctx1 = Context.init(allocator, .GET, "/");
    defer ctx1.deinit();
    try std.testing.expect(router.matchRoute(router.routes.items[0].segments, "/", &ctx1));
    try std.testing.expect(!router.matchRoute(router.routes.items[1].segments, "/", &ctx1));

    // Test /admin matching
    var ctx2 = Context.init(allocator, .GET, "/admin");
    defer ctx2.deinit();
    try std.testing.expect(!router.matchRoute(router.routes.items[0].segments, "/admin", &ctx2));
    try std.testing.expect(router.matchRoute(router.routes.items[1].segments, "/admin", &ctx2));
}

test "route matching with params" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/entries/:id", struct {
        fn handle(_: *Context) !void {}
    }.handle);

    var ctx = Context.init(allocator, .GET, "/entries/123");
    defer ctx.deinit();

    try std.testing.expect(router.matchRoute(router.routes.items[0].segments, "/entries/123", &ctx));
    try std.testing.expectEqualStrings("123", ctx.param("id").?);
}

test "route matching with wildcard" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/static/*", struct {
        fn handle(_: *Context) !void {}
    }.handle);

    var ctx1 = Context.init(allocator, .GET, "/static/admin.css");
    defer ctx1.deinit();
    try std.testing.expect(router.matchRoute(router.routes.items[0].segments, "/static/admin.css", &ctx1));
    try std.testing.expectEqualStrings("admin.css", ctx1.wildcard.?);

    var ctx2 = Context.init(allocator, .GET, "/static/js/app.js");
    defer ctx2.deinit();
    try std.testing.expect(router.matchRoute(router.routes.items[0].segments, "/static/js/app.js", &ctx2));
    try std.testing.expectEqualStrings("js/app.js", ctx2.wildcard.?);
}
