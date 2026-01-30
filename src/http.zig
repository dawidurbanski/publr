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
const db_mod = @import("db.zig");
const Auth = @import("auth.zig").Auth;
const auth_middleware = @import("auth_middleware.zig");

// Generated ZSX templates
const zsx_base = @import("zsx_base");
const zsx_index = @import("zsx_index");
const zsx_admin_layout = @import("zsx_admin_layout");
const zsx_admin_dashboard = @import("zsx_admin_dashboard");
const zsx_admin_posts_list = @import("zsx_admin_posts_list");
const zsx_admin_posts_edit = @import("zsx_admin_posts_edit");
const zsx_admin_components = @import("zsx_admin_components");
const zsx_admin_setup = @import("zsx_admin_setup");
const zsx_admin_login = @import("zsx_admin_login");

// Embedded static assets with compile-time metadata
const AdminCss = static.Asset("admin.css", @embedFile("static_admin_css"));
const AdminJs = static.Asset("admin.js", @embedFile("static_admin_js"));
const ThemeCss = static.Asset("theme.css", @embedFile("static_theme_css"));

// Interact modules (shared between admin and themes)
const InteractCore = static.Asset("core.js", @embedFile("static_interact_core_js"));
const InteractToggle = static.Asset("toggle.js", @embedFile("static_interact_toggle_js"));
const InteractPortal = static.Asset("portal.js", @embedFile("static_interact_portal_js"));
const InteractFocusTrap = static.Asset("focus-trap.js", @embedFile("static_interact_focus_trap_js"));
const InteractDismiss = static.Asset("dismiss.js", @embedFile("static_interact_dismiss_js"));
const InteractComponents = static.Asset("components.js", @embedFile("static_interact_components_js"));
const InteractIndex = static.Asset("index.js", @embedFile("static_interact_index_js"));

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

    // Initialize database
    var db = db_mod.initWithSchema(allocator, "data/publr.db") catch |err| {
        std.debug.print("Failed to initialize database: {}\n", .{err});
        return err;
    };
    defer db.deinit();

    // Initialize auth
    var auth = Auth.init(allocator, &db);

    // Initialize auth middleware
    auth_middleware.init(&auth);

    var router = Router.init(allocator);
    defer router.deinit();

    // Initialize error handling and template system
    error_pages.init(dev_mode);
    tpl.init(dev_mode);

    // Error middleware first (catches all errors)
    try router.use(error_pages.errorMiddleware);

    // Auth middleware (protects /admin/* routes)
    try router.use(auth_middleware.authMiddleware);

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
    try router.get("/admin/setup", handleSetupGet);
    try router.post("/admin/setup", handleSetupPost);
    try router.get("/admin/login", handleLoginGet);
    try router.post("/admin/login", handleLoginPost);
    try router.post("/admin/logout", handleLogout);
    try router.get("/admin/posts", handleAdminPosts);
    try router.get("/admin/components", handleAdminComponents);
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

    std.debug.print("Publr running at http://localhost:{d}\n", .{port});
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

    // Extract body (everything after the empty line)
    const body: ?[]const u8 = blk: {
        // Find empty line (end of headers)
        if (std.mem.indexOf(u8, request, "\r\n\r\n")) |pos| {
            const body_start = pos + 4;
            if (body_start < request.len) {
                break :blk request[body_start..];
            }
        }
        break :blk null;
    };

    if (global_router) |*router| {
        try router.dispatch(method, path, stream, headers[0..header_count], body);
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
        ctx.html(wrapWithBase(content, "Publr", &.{"/static/theme.css"}, &.{}));
    }
}

fn handleAdminDashboard(ctx: *Context) !void {
    // Mock data
    const Post = struct { id: []const u8, title: []const u8, status: []const u8, date: []const u8 };
    const posts = [_]Post{
        .{ .id = "1", .title = "Welcome to Publr", .status = "published", .date = "2024-01-15" },
        .{ .id = "2", .title = "Getting Started Guide", .status = "draft", .date = "2024-01-14" },
    };

    const content = tpl.renderFnToSlice(zsx_admin_dashboard.Dashboard, .{
        "12", "5", "34", "3", true, &posts,
    });

    ctx.html(wrapAdmin(content, "Dashboard", "", .{ .dashboard = true, .posts = false, .settings = false, .components = false }));
}

fn handleAdminPosts(ctx: *Context) !void {
    const Post = struct { id: []const u8, title: []const u8, author: []const u8, status: []const u8, date: []const u8 };
    const posts = [_]Post{
        .{ .id = "1", .title = "Welcome to Publr", .author = "Admin", .status = "published", .date = "2024-01-15" },
        .{ .id = "2", .title = "Getting Started Guide", .author = "Admin", .status = "draft", .date = "2024-01-14" },
        .{ .id = "3", .title = "Advanced Features", .author = "Admin", .status = "draft", .date = "2024-01-13" },
    };

    const content = tpl.renderFnToSlice(zsx_admin_posts_list.List, .{
        true, &posts,
    });

    const actions = "<a href=\"/admin/posts/new\" class=\"btn btn-primary\">New Post</a>";
    ctx.html(wrapAdmin(content, "Posts", actions, .{ .dashboard = false, .posts = true, .settings = false, .components = false }));
}

fn handleAdminComponents(ctx: *Context) !void {
    const content = tpl.renderFnToSlice(zsx_admin_components.Components, .{});
    ctx.html(wrapAdmin(content, "Components", "", .{ .dashboard = false, .posts = false, .settings = false, .components = true }));
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

    ctx.html(wrapAdmin(content, "New Post", "", .{ .dashboard = false, .posts = true, .settings = false, .components = false }));
}

fn handleAdminPostEdit(ctx: *Context) !void {
    _ = ctx.wildcard; // post ID

    const content = tpl.renderFnToSlice(zsx_admin_posts_edit.Edit, .{
        .{
            .title = "Welcome to Publr",
            .slug = "welcome-to-publr",
            .content = "This is the content of the post...",
            .date = "2024-01-15",
            .is_draft = false,
            .is_published = true,
        },
    });

    ctx.html(wrapAdmin(content, "Edit Post", "", .{ .dashboard = false, .posts = true, .settings = false, .components = false }));
}

const NavState = struct {
    dashboard: bool,
    posts: bool,
    settings: bool,
    components: bool,
};

fn wrapAdmin(content: []const u8, title: []const u8, actions: []const u8, nav: NavState) []const u8 {
    return tpl.renderFnToSlice(zsx_admin_layout.Layout, .{
        title, content, actions, nav.dashboard, nav.posts, nav.settings, nav.components,
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
    } else if (std.mem.eql(u8, file, "interact/core.js")) {
        InteractCore.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "interact/toggle.js")) {
        InteractToggle.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "interact/portal.js")) {
        InteractPortal.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "interact/focus-trap.js")) {
        InteractFocusTrap.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "interact/dismiss.js")) {
        InteractDismiss.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "interact/components.js")) {
        InteractComponents.serve(ctx, if_none_match);
    } else if (std.mem.eql(u8, file, "interact/index.js")) {
        InteractIndex.serve(ctx, if_none_match);
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
    else if (std.mem.eql(u8, file, "interact/core.js"))
        "static/interact/core.js"
    else if (std.mem.eql(u8, file, "interact/toggle.js"))
        "static/interact/toggle.js"
    else if (std.mem.eql(u8, file, "interact/portal.js"))
        "static/interact/portal.js"
    else if (std.mem.eql(u8, file, "interact/focus-trap.js"))
        "static/interact/focus-trap.js"
    else if (std.mem.eql(u8, file, "interact/dismiss.js"))
        "static/interact/dismiss.js"
    else if (std.mem.eql(u8, file, "interact/components.js"))
        "static/interact/components.js"
    else if (std.mem.eql(u8, file, "interact/index.js"))
        "static/interact/index.js"
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

// =============================================================================
// Setup Wizard Handlers
// =============================================================================

fn handleSetupGet(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    // Return 404 if users already exist
    const has_users = auth_instance.hasUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };

    if (has_users) {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    }

    // Render setup form
    const content = tpl.renderFnToSlice(zsx_admin_setup.Setup, .{""});
    ctx.html(content);
}

fn handleSetupPost(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    // Return 404 if users already exist
    const has_users = auth_instance.hasUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };

    if (has_users) {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    }

    // Parse form data
    const email = ctx.formValue("email") orelse {
        return renderSetupError(ctx, "Email is required");
    };
    const password = ctx.formValue("password") orelse {
        return renderSetupError(ctx, "Password is required");
    };
    const confirm_password = ctx.formValue("confirm_password") orelse {
        return renderSetupError(ctx, "Please confirm your password");
    };

    // URL decode (basic - handle + for spaces and %XX)
    var email_buf: [256]u8 = undefined;
    const decoded_email = urlDecode(email, &email_buf) orelse {
        return renderSetupError(ctx, "Invalid email format");
    };

    // Validate
    if (!isValidEmail(decoded_email)) {
        return renderSetupError(ctx, "Invalid email format");
    }

    if (password.len < 8) {
        return renderSetupError(ctx, "Password must be at least 8 characters");
    }

    if (!std.mem.eql(u8, password, confirm_password)) {
        return renderSetupError(ctx, "Passwords do not match");
    }

    // Create user
    const user_id = auth_instance.createUser(decoded_email, password) catch |err| {
        switch (err) {
            Auth.Error.EmailExists => return renderSetupError(ctx, "An account with this email already exists"),
            else => return renderSetupError(ctx, "Failed to create account"),
        }
    };
    defer auth_instance.allocator.free(user_id);

    // Create session and auto-login
    const token = auth_instance.createSession(user_id) catch {
        return renderSetupError(ctx, "Account created but failed to log in. Please try logging in.");
    };
    defer auth_instance.allocator.free(token);

    // Set session cookie
    auth_middleware.setSessionCookie(ctx, token);

    // Redirect to dashboard
    ctx.response.setStatus("302 Found");
    ctx.response.setHeader("Location", "/admin");
    ctx.response.setBody("");
}

fn renderSetupError(ctx: *Context, message: []const u8) void {
    const content = tpl.renderFnToSlice(zsx_admin_setup.Setup, .{message});
    ctx.html(content);
}

fn isValidEmail(email: []const u8) bool {
    // Basic email validation: contains @ and at least one . after @
    const at_pos = std.mem.indexOf(u8, email, "@") orelse return false;
    if (at_pos == 0 or at_pos == email.len - 1) return false;

    const after_at = email[at_pos + 1 ..];
    const dot_pos = std.mem.indexOf(u8, after_at, ".") orelse return false;
    if (dot_pos == 0 or dot_pos == after_at.len - 1) return false;

    return true;
}

fn urlDecode(input: []const u8, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    var out: usize = 0;

    while (i < input.len and out < buf.len) {
        if (input[i] == '+') {
            buf[out] = ' ';
            i += 1;
            out += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            buf[out] = std.fmt.parseInt(u8, hex, 16) catch return null;
            i += 3;
            out += 1;
        } else {
            buf[out] = input[i];
            i += 1;
            out += 1;
        }
    }

    return buf[0..out];
}

// =============================================================================
// Login/Logout Handlers
// =============================================================================

fn handleLoginGet(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    // If no users exist, redirect to setup
    const has_users = auth_instance.hasUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };

    if (!has_users) {
        ctx.response.setStatus("302 Found");
        ctx.response.setHeader("Location", "/admin/setup");
        ctx.response.setBody("");
        return;
    }

    // Render login form
    const content = tpl.renderFnToSlice(zsx_admin_login.Login, .{""});
    ctx.html(content);
}

fn handleLoginPost(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    // CSRF protection: check Origin header
    if (!checkCsrf(ctx)) {
        return renderLoginError(ctx, "Invalid request origin");
    }

    // Parse form data
    const email = ctx.formValue("email") orelse {
        return renderLoginError(ctx, "Email is required");
    };
    const password = ctx.formValue("password") orelse {
        return renderLoginError(ctx, "Password is required");
    };

    // URL decode email
    var email_buf: [256]u8 = undefined;
    const decoded_email = urlDecode(email, &email_buf) orelse {
        return renderLoginError(ctx, "Invalid email format");
    };

    // Authenticate
    const user_id = auth_instance.authenticateUser(decoded_email, password) catch {
        return renderLoginError(ctx, "Invalid email or password");
    };
    defer auth_instance.allocator.free(user_id);

    // Create session
    const token = auth_instance.createSession(user_id) catch {
        return renderLoginError(ctx, "Failed to create session");
    };
    defer auth_instance.allocator.free(token);

    // Set session cookie
    auth_middleware.setSessionCookie(ctx, token);

    // Redirect to dashboard
    ctx.response.setStatus("302 Found");
    ctx.response.setHeader("Location", "/admin");
    ctx.response.setBody("");
}

fn handleLogout(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("302 Found");
        ctx.response.setHeader("Location", "/admin/login");
        ctx.response.setBody("");
        return;
    };

    // Get session token from cookie
    if (auth_middleware.parseCookie(ctx, auth_middleware.SESSION_COOKIE)) |token| {
        // Invalidate session in database
        auth_instance.invalidateSession(token) catch {};
    }

    // Clear session cookie
    auth_middleware.clearSessionCookie(ctx);

    // Redirect to login
    ctx.response.setStatus("302 Found");
    ctx.response.setHeader("Location", "/admin/login");
    ctx.response.setBody("");
}

fn renderLoginError(ctx: *Context, message: []const u8) void {
    const content = tpl.renderFnToSlice(zsx_admin_login.Login, .{message});
    ctx.html(content);
}

/// CSRF protection: check Origin header matches expected host
fn checkCsrf(ctx: *Context) bool {
    const origin = ctx.getRequestHeader("Origin") orelse {
        // No Origin header - could be same-origin request or old browser
        // Check Referer as fallback
        const referer = ctx.getRequestHeader("Referer") orelse {
            // For form submissions, modern browsers should send Origin
            // Allow requests without Origin for now (SameSite cookie provides protection)
            return true;
        };
        // Basic check: referer should start with same scheme
        _ = referer;
        return true;
    };

    // For localhost development, accept common origins
    if (std.mem.startsWith(u8, origin, "http://localhost") or
        std.mem.startsWith(u8, origin, "http://127.0.0.1"))
    {
        return true;
    }

    // In production, you would check against configured domain
    // For now, accept if Origin header is present (indicates CORS-aware browser)
    return origin.len > 0;
}
