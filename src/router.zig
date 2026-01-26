const std = @import("std");
const Allocator = std.mem.Allocator;

/// HTTP methods supported by the router
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,

    pub fn fromString(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        return null;
    }
};

/// Request context passed to handlers
pub const Context = struct {
    method: Method,
    path: []const u8,
    params: std.StringHashMapUnmanaged([]const u8),
    wildcard: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, method: Method, path: []const u8) Context {
        return .{
            .method = method,
            .path = path,
            .params = .{},
            .wildcard = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Context) void {
        self.params.deinit(self.allocator);
    }

    /// Get a path parameter by name
    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }
};

/// Handler function signature
pub const Handler = *const fn (*Context, std.net.Stream) anyerror!void;

/// A registered route
const Route = struct {
    method: Method,
    pattern: []const u8,
    segments: []const Segment,
    handler: Handler,
};

/// Segment types in a route pattern
const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    wildcard: void,
};

/// HTTP Router with path matching and method dispatch
pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayListUnmanaged(Route),
    not_found_handler: ?Handler,

    pub fn init(allocator: Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = .{},
            .not_found_handler = null,
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.segments);
        }
        self.routes.deinit(self.allocator);
    }

    /// Register a GET route
    pub fn get(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.GET, pattern, handler);
    }

    /// Register a POST route
    pub fn post(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.POST, pattern, handler);
    }

    /// Register a PUT route
    pub fn put(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.PUT, pattern, handler);
    }

    /// Register a DELETE route
    pub fn delete(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.DELETE, pattern, handler);
    }

    /// Set custom 404 handler
    pub fn setNotFound(self: *Router, handler: Handler) void {
        self.not_found_handler = handler;
    }

    fn addRoute(self: *Router, method: Method, pattern: []const u8, handler: Handler) !void {
        const segments = try self.parsePattern(pattern);
        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .segments = segments,
            .handler = handler,
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

    /// Dispatch a request to the matching handler
    pub fn dispatch(self: *Router, method: Method, path: []const u8, stream: std.net.Stream) !void {
        var ctx = Context.init(self.allocator, method, path);
        defer ctx.deinit();

        for (self.routes.items) |route| {
            if (route.method != method) continue;

            if (self.matchRoute(route.segments, path, &ctx)) {
                try route.handler(&ctx, stream);
                return;
            }
            // Reset context for next route attempt
            ctx.params.clearRetainingCapacity();
            ctx.wildcard = null;
        }

        // No route matched
        if (self.not_found_handler) |handler| {
            try handler(&ctx, stream);
        } else {
            try defaultNotFound(&ctx, stream);
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

fn defaultNotFound(_: *Context, stream: std.net.Stream) !void {
    const body = "Not Found";
    const response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
    _ = try stream.write(response);
    _ = body;
}

// Tests
test "router exact path matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    var handler_called = false;
    const TestHandler = struct {
        fn handle(_: *Context, _: std.net.Stream) !void {
            // Can't easily set external var from here, but we test via dispatch
        }
    };
    _ = &handler_called;

    try router.get("/", TestHandler.handle);
    try router.get("/admin", TestHandler.handle);
    try router.get("/api/health", TestHandler.handle);

    // Test pattern parsing
    try std.testing.expectEqual(@as(usize, 3), router.routes.items.len);
    try std.testing.expectEqual(@as(usize, 0), router.routes.items[0].segments.len); // "/"
    try std.testing.expectEqual(@as(usize, 1), router.routes.items[1].segments.len); // "/admin"
    try std.testing.expectEqual(@as(usize, 2), router.routes.items[2].segments.len); // "/api/health"
}

test "router path parameter extraction" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/entries/:id", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
    }.handle);

    try router.get("/users/:user_id/posts/:post_id", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
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
        fn handle(_: *Context, _: std.net.Stream) !void {}
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
        fn handle(_: *Context, _: std.net.Stream) !void {}
    }.handle);
    try router.post("/entries", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
    }.handle);
    try router.put("/entries/:id", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
    }.handle);
    try router.delete("/entries/:id", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
    }.handle);

    try std.testing.expectEqual(@as(usize, 4), router.routes.items.len);
    try std.testing.expectEqual(Method.GET, router.routes.items[0].method);
    try std.testing.expectEqual(Method.POST, router.routes.items[1].method);
    try std.testing.expectEqual(Method.PUT, router.routes.items[2].method);
    try std.testing.expectEqual(Method.DELETE, router.routes.items[3].method);
}

test "context param extraction" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/entries/123");
    defer ctx.deinit();

    try ctx.params.put(allocator, "id", "123");
    try ctx.params.put(allocator, "slug", "hello-world");

    try std.testing.expectEqualStrings("123", ctx.param("id").?);
    try std.testing.expectEqualStrings("hello-world", ctx.param("slug").?);
    try std.testing.expect(ctx.param("missing") == null);
}

test "route matching exact paths" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
    }.handle);
    try router.get("/admin", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
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

    // Test non-matching path
    var ctx3 = Context.init(allocator, .GET, "/other");
    defer ctx3.deinit();
    try std.testing.expect(!router.matchRoute(router.routes.items[0].segments, "/other", &ctx3));
    try std.testing.expect(!router.matchRoute(router.routes.items[1].segments, "/other", &ctx3));
}

test "route matching with params" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.get("/entries/:id", struct {
        fn handle(_: *Context, _: std.net.Stream) !void {}
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
        fn handle(_: *Context, _: std.net.Stream) !void {}
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

test "method fromString" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try std.testing.expectEqual(Method.PUT, Method.fromString("PUT").?);
    try std.testing.expectEqual(Method.DELETE, Method.fromString("DELETE").?);
    try std.testing.expect(Method.fromString("PATCH") == null);
    try std.testing.expect(Method.fromString("invalid") == null);
}
