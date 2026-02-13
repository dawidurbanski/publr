const std = @import("std");
const Allocator = std.mem.Allocator;

/// Request header entry
pub const RequestHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Request/response context passed through middleware chain
pub const Context = struct {
    // Request data
    method: Method,
    path: []const u8,
    params: std.StringHashMapUnmanaged([]const u8),
    wildcard: ?[]const u8,
    allocator: Allocator,

    // Request headers (fixed-size for common headers)
    request_headers: [32]?RequestHeader,
    request_header_count: usize,

    // Query string (everything after ? in URL)
    query: ?[]const u8,

    // Request body (for POST/PUT)
    body: ?[]const u8,

    // Response data (buffered for middleware to modify)
    response: Response,

    // Raw stream for streaming responses
    stream: ?std.net.Stream,

    // Arbitrary state for middleware to pass data
    state: std.StringHashMapUnmanaged(*anyopaque),

    pub fn init(allocator: Allocator, method: Method, path: []const u8) Context {
        return .{
            .method = method,
            .path = path,
            .params = .{},
            .wildcard = null,
            .allocator = allocator,
            .request_headers = [_]?RequestHeader{null} ** 32,
            .request_header_count = 0,
            .query = null,
            .body = null,
            .response = Response.init(),
            .stream = null,
            .state = .{},
        };
    }

    pub fn initWithStream(allocator: Allocator, method: Method, path: []const u8, stream: std.net.Stream) Context {
        return .{
            .method = method,
            .path = path,
            .params = .{},
            .wildcard = null,
            .allocator = allocator,
            .request_headers = [_]?RequestHeader{null} ** 32,
            .request_header_count = 0,
            .query = null,
            .body = null,
            .response = Response.init(),
            .stream = stream,
            .state = .{},
        };
    }

    /// Add a request header
    pub fn addRequestHeader(self: *Context, name: []const u8, value: []const u8) void {
        if (self.request_header_count < self.request_headers.len) {
            self.request_headers[self.request_header_count] = .{ .name = name, .value = value };
            self.request_header_count += 1;
        }
    }

    /// Get a request header by name (case-insensitive)
    pub fn getRequestHeader(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.request_headers[0..self.request_header_count]) |maybe_header| {
            if (maybe_header) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) {
                    return h.value;
                }
            }
        }
        return null;
    }

    /// Start a streaming response (sends headers, enables chunked transfer)
    pub fn startStreaming(self: *Context, content_type: []const u8) !void {
        if (self.stream) |s| {
            const header = "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
            var buf: [256]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&buf, header, .{content_type});
            _ = try s.write(formatted);
            self.response.headers_sent = true;
        }
    }

    /// Write a chunk to the streaming response
    pub fn writeChunk(self: *Context, data: []const u8) !void {
        if (self.stream) |s| {
            // Write chunk size in hex
            var size_buf: [20]u8 = undefined;
            const size_str = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
            _ = try s.write(size_str);
            // Write chunk data
            _ = try s.write(data);
            // Write chunk terminator
            _ = try s.write("\r\n");
        }
    }

    /// End the streaming response
    pub fn endStreaming(self: *Context) !void {
        if (self.stream) |s| {
            // Write final chunk (zero-length)
            _ = try s.write("0\r\n\r\n");
        }
    }

    pub fn deinit(self: *Context) void {
        self.params.deinit(self.allocator);
        self.state.deinit(self.allocator);
    }

    /// Get a path parameter by name
    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Set state value (for middleware to pass data to handlers)
    pub fn setState(self: *Context, key: []const u8, value: *anyopaque) !void {
        try self.state.put(self.allocator, key, value);
    }

    /// Get state value
    pub fn getState(self: *const Context, comptime T: type, key: []const u8) ?*T {
        const ptr = self.state.get(key) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Check if this is a partial (X-Partial: true) request
    pub fn isPartial(self: *const Context) bool {
        if (self.getRequestHeader("X-Partial")) |value| {
            return std.ascii.eqlIgnoreCase(value, "true");
        }
        return false;
    }

    /// Set HTML response body with correct content type
    pub fn html(self: *Context, content: []const u8) void {
        self.response.setContentType("text/html");
        self.response.setBody(content);
        // Set X-Partial header on partial responses so JS can detect them
        if (self.isPartial()) {
            self.response.setHeader("X-Partial", "true");
        }
    }

    /// Get form field value from URL-encoded body (returns decoded value)
    pub fn formValue(self: *Context, name: []const u8) ?[]const u8 {
        const body_content = self.body orelse return null;

        var iter = std.mem.splitScalar(u8, body_content, '&');
        while (iter.next()) |pair| {
            if (std.mem.indexOf(u8, pair, "=")) |eq_pos| {
                const field_name = pair[0..eq_pos];
                if (std.mem.eql(u8, field_name, name)) {
                    const encoded = pair[eq_pos + 1 ..];
                    return urlDecode(self.allocator, encoded) catch encoded;
                }
            }
        }
        return null;
    }

    const urlDecode = @import("url").formDecode;

    /// Set request body
    pub fn setBody(self: *Context, body_content: []const u8) void {
        self.body = body_content;
    }
};

/// Custom header entry
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Buffered response that middleware can inspect/modify
pub const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    headers_sent: bool,
    custom_headers: [8]?Header,
    custom_header_count: usize,
    /// Buffer for dynamic header values (e.g., Set-Cookie)
    header_value_buf: [1024]u8,
    header_value_offset: usize,

    pub fn init() Response {
        return .{
            .status = "200 OK",
            .content_type = "text/html",
            .body = "",
            .headers_sent = false,
            .custom_headers = [_]?Header{null} ** 8,
            .custom_header_count = 0,
            .header_value_buf = undefined,
            .header_value_offset = 0,
        };
    }

    pub fn setStatus(self: *Response, status: []const u8) void {
        self.status = status;
    }

    pub fn setContentType(self: *Response, content_type: []const u8) void {
        self.content_type = content_type;
    }

    pub fn setBody(self: *Response, body: []const u8) void {
        self.body = body;
    }

    /// Add a custom header to the response
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) void {
        if (self.custom_header_count < self.custom_headers.len) {
            self.custom_headers[self.custom_header_count] = .{ .name = name, .value = value };
            self.custom_header_count += 1;
        }
    }

    /// Add a custom header, copying the value into internal buffer
    /// Use this for dynamically built header values (e.g., Set-Cookie)
    pub fn setHeaderOwned(self: *Response, name: []const u8, value: []const u8) void {
        const end = self.header_value_offset + value.len;
        if (end > self.header_value_buf.len) return; // Buffer full
        if (self.custom_header_count >= self.custom_headers.len) return;

        // Copy value into buffer
        @memcpy(self.header_value_buf[self.header_value_offset..end], value);
        const owned_value = self.header_value_buf[self.header_value_offset..end];
        self.header_value_offset = end;

        // Store header with owned value
        self.custom_headers[self.custom_header_count] = .{ .name = name, .value = owned_value };
        self.custom_header_count += 1;
    }

    /// Get custom headers as a slice
    pub fn getCustomHeaders(self: *const Response) []const ?Header {
        return self.custom_headers[0..self.custom_header_count];
    }
};

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

/// Function to call next middleware or handler in chain
pub const NextFn = *const fn (*Context) anyerror!void;

/// Middleware function signature
pub const Middleware = *const fn (*Context, NextFn) anyerror!void;

/// Handler function signature (final handler, no next)
pub const Handler = *const fn (*Context) anyerror!void;

/// Executes a middleware chain, then calls the handler
pub fn executeChain(
    ctx: *Context,
    global_middleware: []const Middleware,
    route_middleware: []const Middleware,
    handler: Handler,
) anyerror!void {
    // Build combined chain: global + route middleware
    const ChainState = struct {
        global: []const Middleware,
        route: []const Middleware,
        handler: Handler,
        global_idx: usize,
        route_idx: usize,

        fn next(state: *@This(), c: *Context) anyerror!void {
            // First, execute global middleware
            if (state.global_idx < state.global.len) {
                const mw = state.global[state.global_idx];
                state.global_idx += 1;
                return mw(c, makeNextFn(state));
            }

            // Then, execute route middleware
            if (state.route_idx < state.route.len) {
                const mw = state.route[state.route_idx];
                state.route_idx += 1;
                return mw(c, makeNextFn(state));
            }

            // Finally, call the handler
            return state.handler(c);
        }

        fn makeNextFn(state: *@This()) NextFn {
            // Create a closure-like function pointer
            // We use a thread-local to pass state since Zig doesn't have closures
            current_chain = state;
            return &chainNext;
        }
    };

    var state = ChainState{
        .global = global_middleware,
        .route = route_middleware,
        .handler = handler,
        .global_idx = 0,
        .route_idx = 0,
    };

    try state.next(ctx);
}

// Thread-local storage for chain state (needed for NextFn callback)
threadlocal var current_chain: ?*anyopaque = null;

fn chainNext(ctx: *Context) anyerror!void {
    const ChainState = struct {
        global: []const Middleware,
        route: []const Middleware,
        handler: Handler,
        global_idx: usize,
        route_idx: usize,

        fn next(state: *@This(), c: *Context) anyerror!void {
            if (state.global_idx < state.global.len) {
                const mw = state.global[state.global_idx];
                state.global_idx += 1;
                current_chain = state;
                return mw(c, &chainNext);
            }
            if (state.route_idx < state.route.len) {
                const mw = state.route[state.route_idx];
                state.route_idx += 1;
                current_chain = state;
                return mw(c, &chainNext);
            }
            return state.handler(c);
        }
    };

    if (current_chain) |ptr| {
        const state: *ChainState = @ptrCast(@alignCast(ptr));
        try state.next(ctx);
    }
}

// Tests
test "context init and deinit" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    try std.testing.expectEqual(Method.GET, ctx.method);
    try std.testing.expectEqualStrings("/test", ctx.path);
}

test "context params" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/entries/123");
    defer ctx.deinit();

    try ctx.params.put(allocator, "id", "123");
    try std.testing.expectEqualStrings("123", ctx.param("id").?);
    try std.testing.expect(ctx.param("missing") == null);
}

test "context state" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    var user_id: u32 = 42;
    try ctx.setState("user_id", &user_id);

    const retrieved = ctx.getState(u32, "user_id").?;
    try std.testing.expectEqual(@as(u32, 42), retrieved.*);
}

test "response defaults" {
    const resp = Response.init();
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("text/html", resp.content_type);
    try std.testing.expectEqualStrings("", resp.body);
}

test "response modification" {
    var resp = Response.init();
    resp.setStatus("404 Not Found");
    resp.setContentType("application/json");
    resp.setBody("{\"error\": \"not found\"}");

    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"error\": \"not found\"}", resp.body);
}

test "method fromString" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try std.testing.expectEqual(Method.PUT, Method.fromString("PUT").?);
    try std.testing.expectEqual(Method.DELETE, Method.fromString("DELETE").?);
    try std.testing.expect(Method.fromString("PATCH") == null);
}

test "middleware chain execution" {
    const allocator = std.testing.allocator;

    // Track execution order
    const TestState = struct {
        var order: [10]u8 = undefined;
        var idx: usize = 0;

        fn reset() void {
            idx = 0;
            order = undefined;
        }

        fn record(c: u8) void {
            if (idx < order.len) {
                order[idx] = c;
                idx += 1;
            }
        }
    };

    TestState.reset();

    const mw1 = struct {
        fn call(_: *Context, next: NextFn) !void {
            TestState.record('1');
            try next(@constCast(&Context.init(std.testing.allocator, .GET, "/")));
            TestState.record('a');
        }
    }.call;

    const mw2 = struct {
        fn call(_: *Context, next: NextFn) !void {
            TestState.record('2');
            try next(@constCast(&Context.init(std.testing.allocator, .GET, "/")));
            TestState.record('b');
        }
    }.call;

    const handler = struct {
        fn call(_: *Context) !void {
            TestState.record('H');
        }
    }.call;

    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    const global = [_]Middleware{mw1};
    const route = [_]Middleware{mw2};

    try executeChain(&ctx, &global, &route, handler);

    // Expected order: 1 -> 2 -> H -> b -> a
    try std.testing.expectEqualStrings("12Hba", TestState.order[0..TestState.idx]);
}

test "middleware can short-circuit" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var handler_called: bool = false;

        fn reset() void {
            handler_called = false;
        }
    };

    TestState.reset();

    const authMiddleware = struct {
        fn call(ctx: *Context, _: NextFn) !void {
            // Short-circuit: don't call next
            ctx.response.setStatus("401 Unauthorized");
        }
    }.call;

    const handler = struct {
        fn call(_: *Context) !void {
            TestState.handler_called = true;
        }
    }.call;

    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    const global = [_]Middleware{authMiddleware};
    const route = [_]Middleware{};

    try executeChain(&ctx, &global, &route, handler);

    try std.testing.expect(!TestState.handler_called);
    try std.testing.expectEqualStrings("401 Unauthorized", ctx.response.status);
}

test "response custom headers" {
    var resp = Response.init();
    resp.setHeader("ETag", "\"abc123\"");
    resp.setHeader("Cache-Control", "max-age=3600");

    try std.testing.expectEqual(@as(usize, 2), resp.custom_header_count);

    const headers = resp.getCustomHeaders();
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("ETag", headers[0].?.name);
    try std.testing.expectEqualStrings("\"abc123\"", headers[0].?.value);
    try std.testing.expectEqualStrings("Cache-Control", headers[1].?.name);
    try std.testing.expectEqualStrings("max-age=3600", headers[1].?.value);
}

test "context request headers" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.addRequestHeader("If-None-Match", "\"etag123\"");
    ctx.addRequestHeader("Accept", "text/html");

    try std.testing.expectEqualStrings("\"etag123\"", ctx.getRequestHeader("If-None-Match").?);
    try std.testing.expectEqualStrings("text/html", ctx.getRequestHeader("Accept").?);
    try std.testing.expect(ctx.getRequestHeader("Missing") == null);
}

test "context request headers case-insensitive" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.addRequestHeader("Content-Type", "application/json");

    try std.testing.expectEqualStrings("application/json", ctx.getRequestHeader("content-type").?);
    try std.testing.expectEqualStrings("application/json", ctx.getRequestHeader("CONTENT-TYPE").?);
}

test "isPartial returns true when X-Partial header is true" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.addRequestHeader("X-Partial", "true");
    try std.testing.expect(ctx.isPartial());
}

test "isPartial returns true case-insensitive" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.addRequestHeader("X-Partial", "TRUE");
    try std.testing.expect(ctx.isPartial());
}

test "isPartial returns false when header absent" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    try std.testing.expect(!ctx.isPartial());
}

test "isPartial returns false when header is not true" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.addRequestHeader("X-Partial", "false");
    try std.testing.expect(!ctx.isPartial());
}

test "html sets content type and body" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.html("<h1>Test</h1>");

    try std.testing.expectEqualStrings("text/html", ctx.response.content_type);
    try std.testing.expectEqualStrings("<h1>Test</h1>", ctx.response.body);
}

test "html sets X-Partial response header on partial request" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.addRequestHeader("X-Partial", "true");
    ctx.html("<h1>Test</h1>");

    const headers = ctx.response.getCustomHeaders();
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("X-Partial", headers[0].?.name);
    try std.testing.expectEqualStrings("true", headers[0].?.value);
}

test "html does not set X-Partial header on full request" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    ctx.html("<h1>Test</h1>");

    const headers = ctx.response.getCustomHeaders();
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

test "formValue extracts and decodes form field from body" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .POST, "/form");
    defer ctx.deinit();

    ctx.setBody("email=test%40example.com&password=secret123&msg=Hello+World%21");

    try std.testing.expectEqualStrings("test@example.com", ctx.formValue("email").?);
    try std.testing.expectEqualStrings("secret123", ctx.formValue("password").?);
    try std.testing.expectEqualStrings("Hello World!", ctx.formValue("msg").?);
    try std.testing.expect(ctx.formValue("missing") == null);
}

test "formValue returns null when no body" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .POST, "/form");
    defer ctx.deinit();

    try std.testing.expect(ctx.formValue("email") == null);
}
