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
const csrf = @import("csrf.zig");
const handlers = @import("handlers.zig");

// Generated ZSX templates
const zsx_base = @import("zsx_base");
const zsx_index = @import("zsx_index");
const zsx_admin_layout = @import("zsx_admin_layout");
const zsx_admin_dashboard = @import("zsx_admin_dashboard");
const zsx_admin_posts_list = @import("zsx_admin_posts_list");
const zsx_admin_posts_edit = @import("zsx_admin_posts_edit");
const zsx_admin_components = @import("zsx_admin_components");
const zsx_admin_users_list = @import("zsx_admin_users_list");
const zsx_admin_users_new = @import("zsx_admin_users_new");
const zsx_admin_users_edit = @import("zsx_admin_users_edit");
const zsx_admin_users_profile = @import("zsx_admin_users_profile");
const zsx_admin_setup = @import("zsx_admin_setup");
const zsx_admin_login = @import("zsx_admin_login");
const zsx_admin_design_system = @import("zsx_admin_design_system");

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

    // CSRF protection for state-changing requests
    try router.use(csrf.csrfMiddleware);

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
    try router.get("/admin/users", handleAdminUsersList);
    try router.get("/admin/users/new", handleAdminUsersNew);
    try router.post("/admin/users/new", handleAdminUsersCreate);
    try router.get("/admin/users/profile", handleAdminUsersProfile);
    try router.post("/admin/users/profile", handleAdminUsersProfileUpdate);
    try router.get("/admin/users/:id", handleAdminUsersEdit);
    try router.post("/admin/users/:id", handleAdminUsersUpdate);
    try router.post("/admin/users/:id/delete", handleAdminUsersDelete);
    try router.get("/admin/components", handleAdminComponents);
    try router.get("/admin/design-system", handleAdminDesignSystem);
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
    var buf: [8192]u8 = undefined;

    // Read until we have the full headers (look for \r\n\r\n)
    var total_read: usize = 0;
    var header_end: usize = 0;
    while (total_read < buf.len) {
        const n = try stream.read(buf[total_read..]);
        if (n == 0) break;
        total_read += n;

        // Check if we have the end of headers
        if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |pos| {
            header_end = pos + 4;
            break;
        }
    }
    if (total_read == 0) return;

    // If we filled the buffer without finding end of headers, reject request
    if (header_end == 0) {
        try sendResponse(stream, "431 Request Header Fields Too Large", "text/plain", "Request headers too large");
        return;
    }

    const request_headers = buf[0..header_end];

    // Parse first line: "GET /path HTTP/1.1"
    var lines = std.mem.splitScalar(u8, request_headers, '\n');
    const first_line = lines.first();

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method_str = parts.next() orelse "GET";
    const raw_path = parts.next() orelse "/";

    // Strip query string — router matches on path only
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |qi| raw_path[0..qi] else raw_path;

    const method = Method.fromString(method_str) orelse .GET;

    // Parse headers and look for Content-Length
    var headers: [32]RequestHeader = undefined;
    var header_count: usize = 0;
    var content_length: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) break; // Empty line marks end of headers

        if (std.mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
            if (header_count < headers.len) {
                const name = trimmed[0..colon_pos];
                const value = trimmed[colon_pos + 2 ..];
                headers[header_count] = .{
                    .name = name,
                    .value = value,
                };
                header_count += 1;

                // Check for Content-Length
                if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                    content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                }
            }
        }
    }

    // Check if request would exceed buffer
    if (content_length > 0) {
        const expected_total = header_end + content_length;
        if (expected_total > buf.len) {
            try sendResponse(stream, "413 Content Too Large", "text/plain", "Request body too large");
            return;
        }

        // Read until we have the full body
        while (total_read < expected_total) {
            const n = try stream.read(buf[total_read..]);
            if (n == 0) break;
            total_read += n;
        }
    }

    // Extract body (everything after the headers)
    const body: ?[]const u8 = blk: {
        if (header_end < total_read) {
            break :blk buf[header_end..total_read];
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
    const csrf_token = csrf.ensureToken(ctx);
    // Mock data
    const Post = struct { id: []const u8, title: []const u8, status: []const u8, date: []const u8 };
    const posts = [_]Post{
        .{ .id = "1", .title = "Welcome to Publr", .status = "published", .date = "2024-01-15" },
        .{ .id = "2", .title = "Getting Started Guide", .status = "draft", .date = "2024-01-14" },
    };

    const content = tpl.renderFnToSlice(zsx_admin_dashboard.Dashboard, .{
        "12", "5", "34", "3", true, &posts,
    });

    ctx.html(wrapAdmin(content, "Dashboard", "", .{ .dashboard = true, .posts = false, .users = false, .users_all = false, .users_new = false, .users_profile = false, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn handleAdminPosts(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    ctx.html(handlers.renderPostsList(auth_instance.db, csrf_token));
}

fn handleAdminUsersList(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);

    const users = auth_instance.listUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };
    defer auth_instance.freeUsers(users);

    const ViewUser = struct {
        id: []const u8,
        display_name: []const u8,
        email: []const u8,
        edit_url: []const u8,
        delete_url: []const u8,
    };

    var view_users: std.ArrayListUnmanaged(ViewUser) = .{};
    errdefer {
        for (view_users.items) |vu| {
            ctx.allocator.free(vu.edit_url);
            ctx.allocator.free(vu.delete_url);
        }
        view_users.deinit(ctx.allocator);
    }

    for (users) |user| {
        const edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/users/{s}", .{user.id}) catch {
            ctx.response.setStatus("500 Internal Server Error");
            ctx.response.setBody("Out of memory");
            return;
        };
        const delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/users/{s}/delete", .{user.id}) catch {
            ctx.allocator.free(edit_url);
            ctx.response.setStatus("500 Internal Server Error");
            ctx.response.setBody("Out of memory");
            return;
        };

        view_users.append(ctx.allocator, .{
            .id = user.id,
            .display_name = user.display_name,
            .email = user.email,
            .edit_url = edit_url,
            .delete_url = delete_url,
        }) catch {
            ctx.allocator.free(edit_url);
            ctx.allocator.free(delete_url);
            ctx.response.setStatus("500 Internal Server Error");
            ctx.response.setBody("Out of memory");
            return;
        };
    }

    const content = tpl.renderFnToSlice(zsx_admin_users_list.List, .{
        view_users.items.len > 0, view_users.items, csrf_token,
    });

    for (view_users.items) |vu| {
        ctx.allocator.free(vu.edit_url);
        ctx.allocator.free(vu.delete_url);
    }
    view_users.deinit(ctx.allocator);

    const actions = "<a href=\"/admin/users/new\" class=\"btn btn-primary\">Add New</a>";
    ctx.html(wrapAdmin(content, "Users", actions, .{ .dashboard = false, .posts = false, .users = true, .users_all = true, .users_new = false, .users_profile = false, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn handleAdminUsersNew(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.renderFnToSlice(zsx_admin_users_new.New, .{ "", csrf_token });
    ctx.html(wrapAdmin(content, "Add User", "", .{ .dashboard = false, .posts = false, .users = true, .users_all = false, .users_new = true, .users_profile = false, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn handleAdminUsersCreate(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);

    const display_name_raw = ctx.formValue("display_name") orelse {
        return renderUsersNewError(ctx, "Display name is required", csrf_token);
    };
    const email_raw = ctx.formValue("email") orelse {
        return renderUsersNewError(ctx, "Email is required", csrf_token);
    };
    const password_raw = ctx.formValue("password") orelse {
        return renderUsersNewError(ctx, "Password is required", csrf_token);
    };
    const confirm_raw = ctx.formValue("confirm_password") orelse {
        return renderUsersNewError(ctx, "Please confirm your password", csrf_token);
    };

    var display_buf: [256]u8 = undefined;
    const display_name = urlDecode(display_name_raw, &display_buf) orelse {
        return renderUsersNewError(ctx, "Invalid display name format", csrf_token);
    };

    var email_buf: [256]u8 = undefined;
    const email = urlDecode(email_raw, &email_buf) orelse {
        return renderUsersNewError(ctx, "Invalid email format", csrf_token);
    };

    var password_buf: [256]u8 = undefined;
    const password = urlDecode(password_raw, &password_buf) orelse {
        return renderUsersNewError(ctx, "Invalid password format", csrf_token);
    };

    var confirm_buf: [256]u8 = undefined;
    const confirm_password = urlDecode(confirm_raw, &confirm_buf) orelse {
        return renderUsersNewError(ctx, "Invalid password format", csrf_token);
    };

    if (display_name.len == 0) {
        return renderUsersNewError(ctx, "Display name is required", csrf_token);
    }

    if (!isValidEmail(email)) {
        return renderUsersNewError(ctx, "Invalid email format", csrf_token);
    }

    if (password.len < 8) {
        return renderUsersNewError(ctx, "Password must be at least 8 characters", csrf_token);
    }

    if (!std.mem.eql(u8, password, confirm_password)) {
        return renderUsersNewError(ctx, "Passwords do not match", csrf_token);
    }

    const user_id = auth_instance.createUser(email, display_name, password) catch |err| {
        switch (err) {
            Auth.Error.EmailExists => return renderUsersNewError(ctx, "An account with this email already exists", csrf_token),
            else => return renderUsersNewError(ctx, "Failed to create user", csrf_token),
        }
    };
    auth_instance.allocator.free(user_id);

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users");
    ctx.response.setBody("");
}

fn handleAdminUsersEdit(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);

    const user_id = ctx.param("id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    var user = (auth_instance.getUserById(user_id) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    }) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };
    defer auth_instance.freeUser(&user);

    const content = tpl.renderFnToSlice(zsx_admin_users_edit.Edit, .{ "", .{
        .id = user.id,
        .display_name = userDisplayName(user),
        .email = user.email,
    }, csrf_token });

    ctx.html(wrapAdmin(content, "Edit User", "", .{ .dashboard = false, .posts = false, .users = true, .users_all = true, .users_new = false, .users_profile = false, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn handleAdminUsersUpdate(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);

    const user_id = ctx.param("id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    const display_name_raw = ctx.formValue("display_name") orelse {
        return renderUsersEditError(ctx, user_id, "Display name is required", csrf_token);
    };
    const email_raw = ctx.formValue("email") orelse {
        return renderUsersEditError(ctx, user_id, "Email is required", csrf_token);
    };
    const password_raw = ctx.formValue("password");
    const confirm_raw = ctx.formValue("confirm_password");

    var display_buf: [256]u8 = undefined;
    const display_name = urlDecode(display_name_raw, &display_buf) orelse {
        return renderUsersEditError(ctx, user_id, "Invalid display name format", csrf_token);
    };

    var email_buf: [256]u8 = undefined;
    const email = urlDecode(email_raw, &email_buf) orelse {
        return renderUsersEditError(ctx, user_id, "Invalid email format", csrf_token);
    };

    if (display_name.len == 0) {
        return renderUsersEditError(ctx, user_id, "Display name is required", csrf_token);
    }

    if (!isValidEmail(email)) {
        return renderUsersEditError(ctx, user_id, "Invalid email format", csrf_token);
    }

    var password: ?[]const u8 = null;
    if (password_raw) |raw| {
        if (raw.len > 0) {
            var password_buf: [256]u8 = undefined;
            const decoded = urlDecode(raw, &password_buf) orelse {
                return renderUsersEditError(ctx, user_id, "Invalid password format", csrf_token);
            };
            if (decoded.len < 8) {
                return renderUsersEditError(ctx, user_id, "Password must be at least 8 characters", csrf_token);
            }
            if (confirm_raw) |confirm_value| {
                var confirm_buf: [256]u8 = undefined;
                const confirm = urlDecode(confirm_value, &confirm_buf) orelse {
                    return renderUsersEditError(ctx, user_id, "Invalid password format", csrf_token);
                };
                if (!std.mem.eql(u8, decoded, confirm)) {
                    return renderUsersEditError(ctx, user_id, "Passwords do not match", csrf_token);
                }
            } else {
                return renderUsersEditError(ctx, user_id, "Please confirm your password", csrf_token);
            }
            password = decoded;
        }
    }

    auth_instance.updateUser(user_id, email, display_name, password) catch |err| {
        switch (err) {
            Auth.Error.EmailExists => return renderUsersEditError(ctx, user_id, "An account with this email already exists", csrf_token),
            else => return renderUsersEditError(ctx, user_id, "Failed to update user", csrf_token),
        }
    };

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users");
    ctx.response.setBody("");
}

fn handleAdminUsersProfile(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);

    const user_id = auth_middleware.getUserId(ctx) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    var user = (auth_instance.getUserById(user_id) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    }) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };
    defer auth_instance.freeUser(&user);

    const content = tpl.renderFnToSlice(zsx_admin_users_profile.Profile, .{ "", .{
        .id = user.id,
        .display_name = userDisplayName(user),
        .email = user.email,
    }, csrf_token });

    ctx.html(wrapAdmin(content, "Profile", "", .{ .dashboard = false, .posts = false, .users = true, .users_all = false, .users_new = false, .users_profile = true, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn handleAdminUsersProfileUpdate(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);

    const user_id = auth_middleware.getUserId(ctx) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    const display_name_raw = ctx.formValue("display_name") orelse {
        return renderUsersProfileError(ctx, user_id, "Display name is required", csrf_token);
    };
    const email_raw = ctx.formValue("email") orelse {
        return renderUsersProfileError(ctx, user_id, "Email is required", csrf_token);
    };
    const password_raw = ctx.formValue("password");
    const confirm_raw = ctx.formValue("confirm_password");

    var display_buf: [256]u8 = undefined;
    const display_name = urlDecode(display_name_raw, &display_buf) orelse {
        return renderUsersProfileError(ctx, user_id, "Invalid display name format", csrf_token);
    };

    var email_buf: [256]u8 = undefined;
    const email = urlDecode(email_raw, &email_buf) orelse {
        return renderUsersProfileError(ctx, user_id, "Invalid email format", csrf_token);
    };

    if (display_name.len == 0) {
        return renderUsersProfileError(ctx, user_id, "Display name is required", csrf_token);
    }

    if (!isValidEmail(email)) {
        return renderUsersProfileError(ctx, user_id, "Invalid email format", csrf_token);
    }

    var password: ?[]const u8 = null;
    if (password_raw) |raw| {
        if (raw.len > 0) {
            var password_buf: [256]u8 = undefined;
            const decoded = urlDecode(raw, &password_buf) orelse {
                return renderUsersProfileError(ctx, user_id, "Invalid password format", csrf_token);
            };
            if (decoded.len < 8) {
                return renderUsersProfileError(ctx, user_id, "Password must be at least 8 characters", csrf_token);
            }
            if (confirm_raw) |confirm_value| {
                var confirm_buf: [256]u8 = undefined;
                const confirm = urlDecode(confirm_value, &confirm_buf) orelse {
                    return renderUsersProfileError(ctx, user_id, "Invalid password format", csrf_token);
                };
                if (!std.mem.eql(u8, decoded, confirm)) {
                    return renderUsersProfileError(ctx, user_id, "Passwords do not match", csrf_token);
                }
            } else {
                return renderUsersProfileError(ctx, user_id, "Please confirm your password", csrf_token);
            }
            password = decoded;
        }
    }

    auth_instance.updateUser(user_id, email, display_name, password) catch |err| {
        switch (err) {
            Auth.Error.EmailExists => return renderUsersProfileError(ctx, user_id, "An account with this email already exists", csrf_token),
            else => return renderUsersProfileError(ctx, user_id, "Failed to update profile", csrf_token),
        }
    };

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users/profile");
    ctx.response.setBody("");
}

fn handleAdminUsersDelete(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    const user_id = ctx.param("id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    auth_instance.deleteUser(user_id) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Failed to delete user");
        return;
    };

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users");
    ctx.response.setBody("");
}

fn handleAdminComponents(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.renderFnToSlice(zsx_admin_components.Components, .{});
    ctx.html(wrapAdmin(content, "Components", "", .{ .dashboard = false, .posts = false, .users = false, .users_all = false, .users_new = false, .users_profile = false, .settings = false, .components = true, .design_system = false }, csrf_token));
}

fn handleAdminDesignSystem(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.renderFnToSlice(zsx_admin_design_system.DesignSystem, .{});
    ctx.html(wrapAdmin(content, "Design System", "", .{ .dashboard = false, .posts = false, .users = false, .users_all = false, .users_new = false, .users_profile = false, .settings = false, .components = false, .design_system = true }, csrf_token));
}

fn handleAdminPostNew(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    ctx.html(handlers.renderPostNew(csrf_token));
}

fn handleAdminPostEdit(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const post_id = ctx.wildcard orelse "1";
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    ctx.html(handlers.renderPostEdit(auth_instance.db, post_id, csrf_token));
}

const NavState = struct {
    dashboard: bool,
    posts: bool,
    users: bool,
    users_all: bool,
    users_new: bool,
    users_profile: bool,
    settings: bool,
    components: bool,
    design_system: bool,
};

fn wrapAdmin(content: []const u8, title: []const u8, actions: []const u8, nav: NavState, csrf_token: []const u8) []const u8 {
    return tpl.renderFnToSlice(zsx_admin_layout.Layout, .{
        title,
        content,
        actions,
        nav.dashboard,
        nav.posts,
        nav.users,
        nav.users_all,
        nav.users_new,
        nav.users_profile,
        nav.settings,
        nav.components,
        nav.design_system,
        csrf_token,
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
    const csrf_token = csrf.ensureToken(ctx);
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
    const content = tpl.renderFnToSlice(zsx_admin_setup.Setup, .{ "", csrf_token });
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
    const display_name = defaultDisplayName(decoded_email);
    const user_id = auth_instance.createUser(decoded_email, display_name, password) catch |err| {
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
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin");
    ctx.response.setBody("");
}

fn renderSetupError(ctx: *Context, message: []const u8) void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.renderFnToSlice(zsx_admin_setup.Setup, .{ message, csrf_token });
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
    const csrf_token = csrf.ensureToken(ctx);
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
    const content = tpl.renderFnToSlice(zsx_admin_login.Login, .{ "", csrf_token });
    ctx.html(content);
}

fn handleLoginPost(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

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
    ctx.response.setStatus("303 See Other");
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
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.renderFnToSlice(zsx_admin_login.Login, .{ message, csrf_token });
    ctx.html(content);
}

fn renderUsersNewError(ctx: *Context, message: []const u8, csrf_token: []const u8) void {
    const content = tpl.renderFnToSlice(zsx_admin_users_new.New, .{ message, csrf_token });
    ctx.html(wrapAdmin(content, "Add User", "", .{ .dashboard = false, .posts = false, .users = true, .users_all = false, .users_new = true, .users_profile = false, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn renderUsersEditError(ctx: *Context, user_id: []const u8, message: []const u8, csrf_token: []const u8) void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    var user = (auth_instance.getUserById(user_id) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    }) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };
    defer auth_instance.freeUser(&user);

    const content = tpl.renderFnToSlice(zsx_admin_users_edit.Edit, .{ message, .{
        .id = user.id,
        .display_name = userDisplayName(user),
        .email = user.email,
    }, csrf_token });

    ctx.html(wrapAdmin(content, "Edit User", "", .{ .dashboard = false, .posts = false, .users = true, .users_all = true, .users_new = false, .users_profile = false, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn renderUsersProfileError(ctx: *Context, user_id: []const u8, message: []const u8, csrf_token: []const u8) void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    var user = (auth_instance.getUserById(user_id) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    }) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };
    defer auth_instance.freeUser(&user);

    const content = tpl.renderFnToSlice(zsx_admin_users_profile.Profile, .{ message, .{
        .id = user.id,
        .display_name = userDisplayName(user),
        .email = user.email,
    }, csrf_token });

    ctx.html(wrapAdmin(content, "Profile", "", .{ .dashboard = false, .posts = false, .users = true, .users_all = false, .users_new = false, .users_profile = true, .settings = false, .components = false, .design_system = false }, csrf_token));
}

fn defaultDisplayName(email: []const u8) []const u8 {
    const at_pos = std.mem.indexOf(u8, email, "@") orelse return email;
    if (at_pos == 0) return email;
    return email[0..at_pos];
}

fn userDisplayName(user: Auth.User) []const u8 {
    return if (user.display_name.len > 0) user.display_name else user.email;
}
