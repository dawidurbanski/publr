const std = @import("std");
const posix = std.posix;
const Router = @import("router.zig").Router;
const Context = @import("router.zig").Context;
const Method = @import("router.zig").Method;
const logger = @import("logger.zig");
const static = @import("static.zig");
const error_pages = @import("error.zig");
const tpl = @import("tpl.zig");
const dev = @import("dev.zig");

// Generated ZSX templates
const zsx_base = @import("zsx_base");
const zsx_index = @import("zsx_index");
const zsx_admin_layout = @import("zsx_admin_layout");
const zsx_admin_dashboard = @import("zsx_admin_dashboard");
const zsx_admin_posts_list = @import("zsx_admin_posts_list");
const zsx_admin_posts_edit = @import("zsx_admin_posts_edit");

// Embedded static assets with compile-time metadata
const AdminCss = static.Asset("admin.css", @embedFile("static_admin_css"));
const AdminJs = static.Asset("admin.js", @embedFile("static_admin_js"));
const ThemeCss = static.Asset("theme.css", @embedFile("static_theme_css"));

// Global shutdown flag for signal handler
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Track active connections for graceful shutdown
var active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Global router instance (initialized once at startup)
var global_router: ?Router = null;

// Global dev mode flag for handlers
var is_dev_mode: bool = false;

pub fn serve(port: u16, dev_mode: bool) !void {
    is_dev_mode = dev_mode;
    // Initialize router
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = Router.init(allocator);
    defer router.deinit();

    // Initialize error handling and template system
    error_pages.init(dev_mode);
    tpl.init(dev_mode);

    // Error middleware first (catches all errors)
    try router.use(error_pages.errorMiddleware);

    // Dev mode middleware
    if (dev_mode) {
        std.debug.print("Dev mode enabled (live reload active)\n", .{});
        try router.use(dev.devMiddleware);
        try router.use(logger.requestLogger);
        try router.get("/__dev/events", dev.eventsHandler);
        try router.get("/__dev/ready", dev.readyHandler);
    }

    // Register routes
    try router.get("/", handleIndex);
    try router.get("/admin", handleAdminDashboard);
    try router.get("/admin/posts", handleAdminPosts);
    try router.get("/admin/posts/new", handleAdminPostNew);
    try router.get("/admin/posts/*", handleAdminPostEdit);
    try router.get("/static/*", handleStatic);

    // Dev-only test route to trigger 500 error
    if (dev_mode) {
        try router.get("/error-test", handleErrorTest);
    }

    // Custom 404 handler
    router.setNotFound(error_pages.notFoundHandler);

    global_router = router;
    defer global_router = null;

    // Set up signal handlers for graceful shutdown
    setupSignalHandlers();

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);

    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("Minizen running at http://localhost:{d}\n", .{port});
    std.debug.print("Press Ctrl+C to stop\n", .{});

    // Set up poll for timeout-based accept
    var poll_fds = [_]posix.pollfd{
        .{ .fd = server.stream.handle, .events = posix.POLL.IN, .revents = 0 },
    };

    while (!shutdown_requested.load(.acquire)) {
        // Poll with 100ms timeout to periodically check shutdown flag
        const poll_result = posix.poll(&poll_fds, 100) catch |err| {
            if (err == error.Interrupted) continue;
            std.debug.print("Poll error: {}\n", .{err});
            continue;
        };

        if (poll_result == 0) continue; // timeout, check shutdown flag
        if (shutdown_requested.load(.acquire)) break;

        var connection = server.accept() catch |err| {
            if (err == error.Interrupted) continue;
            if (err == error.WouldBlock) continue;
            if (shutdown_requested.load(.acquire)) break;
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };

        // Spawn thread to handle connection
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{connection.stream}) catch |err| {
            std.debug.print("Thread spawn error: {}\n", .{err});
            connection.stream.close();
            continue;
        };
        thread.detach();
    }

    // Graceful shutdown: wait for active connections with timeout
    std.debug.print("\nShutting down...\n", .{});
    waitForConnections(5000); // 5 second timeout
    std.debug.print("Goodbye!\n", .{});
}

fn setupSignalHandlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &handler, null);
    posix.sigaction(posix.SIG.TERM, &handler, null);
}

fn signalHandler(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

fn waitForConnections(timeout_ms: u64) void {
    const start = std.time.milliTimestamp();
    while (active_connections.load(.acquire) > 0) {
        const elapsed: u64 = @intCast(std.time.milliTimestamp() - start);
        if (elapsed >= timeout_ms) {
            const remaining = active_connections.load(.acquire);
            if (remaining > 0) {
                std.debug.print("Timeout: {d} connection(s) still active\n", .{remaining});
            }
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn handleConnectionThread(stream: std.net.Stream) void {
    _ = active_connections.fetchAdd(1, .acq_rel);
    defer {
        _ = active_connections.fetchSub(1, .acq_rel);
        stream.close();
    }

    handleConnection(stream) catch |err| {
        std.debug.print("Request error: {}\n", .{err});
    };
}

const RequestHeader = @import("middleware.zig").RequestHeader;

fn handleConnection(stream: std.net.Stream) !void {
    var buf: [4096]u8 = undefined;
    const n = try stream.read(&buf);
    if (n == 0) return;

    const request = buf[0..n];

    // Parse first line: "GET /path HTTP/1.1"
    var lines = std.mem.splitScalar(u8, request, '\n');
    const first_line = lines.first();

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method_str = parts.next() orelse "GET";
    const raw_path = parts.next() orelse "/";

    // Strip query string — router matches on path only
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |qi| raw_path[0..qi] else raw_path;

    const method = Method.fromString(method_str) orelse .GET;

    // Parse headers
    var headers: [16]RequestHeader = undefined;
    var header_count: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) break; // Empty line marks end of headers

        if (std.mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
            if (header_count < headers.len) {
                headers[header_count] = .{
                    .name = trimmed[0..colon_pos],
                    .value = trimmed[colon_pos + 2 ..],
                };
                header_count += 1;
            }
        }
    }

    if (global_router) |*router| {
        try router.dispatch(method, path, stream, headers[0..header_count]);
    } else {
        // Fallback if router not initialized
        try sendResponse(stream, "500 Internal Server Error", "text/plain", "Server not initialized");
    }
}

fn handleIndex(ctx: *Context) !void {
    const content = tpl.renderFnToSlice(zsx_index.Index, .{});
    if (ctx.isPartial()) {
        ctx.html(content);
    } else {
        ctx.html(wrapWithBase(content, "Minizen", &.{"/static/theme.css"}, &.{}));
    }
}

fn handleAdminDashboard(ctx: *Context) !void {
    // Mock data
    const Post = struct { id: []const u8, title: []const u8, status: []const u8, date: []const u8 };
    const posts = [_]Post{
        .{ .id = "1", .title = "Welcome to Minizen", .status = "published", .date = "2024-01-15" },
        .{ .id = "2", .title = "Getting Started Guide", .status = "draft", .date = "2024-01-14" },
    };

    const content = tpl.renderFnToSlice(zsx_admin_dashboard.Dashboard, .{
        "12", "5", "34", "3", true, &posts,
    });

    ctx.html(wrapAdmin(content, "Dashboard", "", .{ .dashboard = true, .posts = false, .settings = false }));
}

fn handleAdminPosts(ctx: *Context) !void {
    const Post = struct { id: []const u8, title: []const u8, author: []const u8, status: []const u8, date: []const u8 };
    const posts = [_]Post{
        .{ .id = "1", .title = "Welcome to Minizen", .author = "Admin", .status = "published", .date = "2024-01-15" },
        .{ .id = "2", .title = "Getting Started Guide", .author = "Admin", .status = "draft", .date = "2024-01-14" },
        .{ .id = "3", .title = "Advanced Features", .author = "Admin", .status = "draft", .date = "2024-01-13" },
    };

    const content = tpl.renderFnToSlice(zsx_admin_posts_list.List, .{
        true, &posts,
    });

    const actions = "<a href=\"/admin/posts/new\" class=\"btn btn-primary\">New Post</a>";
    ctx.html(wrapAdmin(content, "Posts", actions, .{ .dashboard = false, .posts = true, .settings = false }));
}

fn handleAdminPostNew(ctx: *Context) !void {
    const content = tpl.renderFnToSlice(zsx_admin_posts_edit.Edit, .{
        .{
            .title = "",
            .slug = "",
            .content = "",
            .date = "2024-01-15",
            .is_draft = true,
            .is_published = false,
        },
    });

    ctx.html(wrapAdmin(content, "New Post", "", .{ .dashboard = false, .posts = true, .settings = false }));
}

fn handleAdminPostEdit(ctx: *Context) !void {
    _ = ctx.wildcard; // post ID

    const content = tpl.renderFnToSlice(zsx_admin_posts_edit.Edit, .{
        .{
            .title = "Welcome to Minizen",
            .slug = "welcome-to-minizen",
            .content = "This is the content of the post...",
            .date = "2024-01-15",
            .is_draft = false,
            .is_published = true,
        },
    });

    ctx.html(wrapAdmin(content, "Edit Post", "", .{ .dashboard = false, .posts = true, .settings = false }));
}

const NavState = struct {
    dashboard: bool,
    posts: bool,
    settings: bool,
};

fn wrapAdmin(content: []const u8, title: []const u8, actions: []const u8, nav: NavState) []const u8 {
    return tpl.renderFnToSlice(zsx_admin_layout.Layout, .{
        title, content, actions, nav.dashboard, nav.posts, nav.settings,
    });
}

fn wrapWithBase(content: []const u8, title: []const u8, css: []const []const u8, js: []const []const u8) []const u8 {
    return tpl.renderFnToSlice(zsx_base.Base, .{
        title, content, css, js,
    });
}

fn handleErrorTest(_: *Context) !void {
    return error.TestError;
}

fn handleStatic(ctx: *Context) !void {
    const file = ctx.wildcard orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
        return;
    };

    // In dev mode, serve from disk for instant updates
    if (is_dev_mode) {
        serveStaticFromDisk(ctx, file);
        return;
    }

    // Production: use embedded assets
    const if_none_match = ctx.getRequestHeader("If-None-Match");

    if (std.mem.eql(u8, file, "admin.css")) {
        AdminCss.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "admin.js")) {
        AdminJs.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "theme.css")) {
        ThemeCss.serve(ctx, if_none_match);
    } else {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
    }
}

/// Serve static files from disk (dev mode only)
fn serveStaticFromDisk(ctx: *Context, file: []const u8) void {
    // Map file names to disk paths
    const path = if (std.mem.eql(u8, file, "admin.css"))
        "static/admin.css"
    else if (std.mem.eql(u8, file, "admin.js"))
        "static/admin.js"
    else if (std.mem.eql(u8, file, "theme.css"))
        "themes/demo/static/theme.css"
    else {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
        return;
    };

    // Read file from disk
    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("File not found");
        return;
    };
    // Note: memory leak in dev mode, acceptable for development

    ctx.response.setContentType(static.getMimeType(file));
    ctx.response.setBody(content);
}

fn sendResponse(
    stream: std.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    _ = try stream.write(header);
    _ = try stream.write(body);
}
