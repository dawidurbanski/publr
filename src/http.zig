const std = @import("std");
const posix = std.posix;
const router_mod = @import("router");
const Router = router_mod.Router;
const Context = router_mod.Context;
const Method = router_mod.Method;
const logger = @import("logger.zig");
const static = @import("static.zig");
const error_pages = @import("error.zig");
const tpl = @import("tpl");
const dev = @import("dev.zig");
const recompile = @import("recompile.zig");
const db_mod = @import("db");
const Auth = @import("auth").Auth;
const auth_middleware = @import("auth_middleware");
const csrf = @import("csrf");
const admin_api = @import("admin_api");
const media_handler = @import("media_handler");
const schema_sync = @import("schema_sync");
const seed = @import("seed");
const websocket = @import("websocket");
const presence = @import("presence");
const url_mod = @import("url");

// Import plugins directly
const plugin_dashboard = @import("plugin_dashboard");
const plugin_posts = @import("plugin_posts");
const plugin_content = @import("plugin_content");
const plugin_media = @import("plugin_media");
const plugin_users = @import("plugin_users");
const plugin_settings = @import("plugin_settings");
const plugin_components = @import("plugin_components");
const plugin_design_system = @import("plugin_design_system");
const plugin_releases = @import("plugin_releases");

// Generated ZSX views
const views = @import("views");

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
const MediaSelectionJs = static.Asset("media-selection.js", @embedFile("static_media_selection_js"));
const InteractWebSocket = static.Asset("websocket.js", @embedFile("static_interact_websocket_js"));
const InteractPresence = static.Asset("presence.js", @embedFile("static_interact_presence_js"));

// Design system assets (from publr_ui amalgamation)
const publr_ui = @import("publr_ui");
const PublrCss = static.Asset("publr.css", publr_ui.css);
const PublrCoreJs = static.Asset("publr-core.js", publr_ui.core_js);
const PublrDialogJs = static.Asset("publr-dialog.js", publr_ui.dialog_js);
const PublrDropdownJs = static.Asset("publr-dropdown.js", publr_ui.dropdown_js);

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

    // Open database (created at build time by init_db)
    var db = db_mod.Db.init(allocator, "data/publr.db") catch |err| {
        std.debug.print("Failed to open database: {}\n", .{err});
        return err;
    };
    defer db.deinit();

    // Ensure all schema tables exist (safe to re-run — uses IF NOT EXISTS)
    schema_sync.ensureSchema(&db) catch |err| {
        std.debug.print("Failed to ensure schema: {}\n", .{err});
        return err;
    };

    // Seed content types and taxonomies (idempotent — uses INSERT OR IGNORE)
    db.exec(seed.seed_sql) catch |err| {
        std.debug.print("Failed to seed data: {}\n", .{err});
        return err;
    };

    // Initialize auth
    var auth = Auth.init(allocator, &db);

    // Initialize auth middleware
    auth_middleware.init(&auth);

    // Initialize WebSocket registry and presence
    websocket.initRegistry(allocator);
    presence.init(allocator);

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

    // Register core routes
    try router.get("/", handleIndex);
    try router.get("/admin/setup", handleSetupGet);
    try router.post("/admin/setup", handleSetupPost);
    try router.get("/admin/login", handleLoginGet);
    try router.post("/admin/login", handleLoginPost);
    try router.post("/admin/logout", handleLogout);
    try router.get("/static/*", handleStatic);
    try router.get("/media/*", media_handler.handleMedia);
    try router.post("/admin/system/recompile", recompile.handleRecompile);
    try router.post("/admin/system/config", recompile.handleConfigUpdate);
    try router.get("/admin/ws", handleWebSocket);

    // Register plugin routes (arena freed on shutdown)
    var route_arena = std.heap.ArenaAllocator.init(allocator);
    defer route_arena.deinit();
    registerPluginRoutes(&router, route_arena.allocator());

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

        // Check for restart request (recompile endpoint sets this after successful build)
        if (recompile.restart_requested.load(.acquire)) {
            waitForConnections(2000);
            std.debug.print("[publr] Recompilation successful, restarting (exit 100)...\n", .{});
            std.process.exit(100);
        }
    }

    // Graceful shutdown: wait for active connections with timeout
    waitForConnections(5000); // 5 second timeout

    // Exit immediately — defers are unnecessary at process termination
    // (OS reclaims memory, closes sockets/files). Without this, the process
    // lingers after zig-build's parent exits, leaving the terminal without a prompt.
    std.process.exit(0);
}

// =============================================================================
// Plugin Route Registration
// =============================================================================

/// All registered admin pages
/// NOTE: Order matters for route matching! Child pages with literal paths
/// must come BEFORE parent pages that register parameterized routes (like /:id)
const all_pages = [_]admin_api.Page{
    plugin_dashboard.page,
    plugin_posts.page,
} ++ plugin_content.content_pages ++ [_]admin_api.Page{
    plugin_releases.page,
    plugin_media.page,
        // Users: only profile page remains, user management moved to Settings
    plugin_users.page_profile, // /admin/users/profile
    plugin_users.page, // /admin/users (parent, no routes)
    plugin_settings.page,
    plugin_components.page,
    plugin_design_system.page,
};

/// Register all plugin routes
fn registerPluginRoutes(router: *Router, allocator: std.mem.Allocator) void {
    // Create route registrar that wraps the real router
    const registrar = admin_api.RouteRegistrar{
        .ctx = router,
        .register_get = routerRegisterGet,
        .register_post = routerRegisterPost,
    };

    // Register routes for each page
    inline for (all_pages) |page| {
        const base_path = admin_api.resolvePagePath(page, &all_pages);

        var app = admin_api.PageApp{
            .base_path = base_path,
            .page = page,
            .registrar = registrar,
            .allocator = allocator,
        };

        // Call the plugin's setup function
        page.setup(&app);
    }
}

/// Wrapper to register GET route - adapts Router.get to RouteRegistrar interface
fn routerRegisterGet(ctx: *anyopaque, path: []const u8, handler: admin_api.Handler) void {
    const router: *Router = @ptrCast(@alignCast(ctx));
    router.get(path, handler) catch {};
}

/// Wrapper to register POST route - adapts Router.post to RouteRegistrar interface
fn routerRegisterPost(ctx: *anyopaque, path: []const u8, handler: admin_api.Handler) void {
    const router: *Router = @ptrCast(@alignCast(ctx));
    router.post(path, handler) catch {};
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
    // write() is async-signal-safe — prints before zig-build parent can exit
    _ = std.posix.write(2, "\nShutting down... Goodbye!\n") catch {};
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
        tpl.resetArena();
        _ = active_connections.fetchSub(1, .acq_rel);
        stream.close();
    }

    handleConnection(stream) catch |err| {
        std.debug.print("Request error: {}\n", .{err});
    };
}

/// Request header - imported from middleware
const RequestHeader = @import("middleware").RequestHeader;

/// Max request body size (2MB — enough for 1MB upload + multipart overhead)
const max_body_size: usize = 2 * 1024 * 1024;

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

    // Split path and query string — router matches on path only
    const qi = std.mem.indexOfScalar(u8, raw_path, '?');
    const path = if (qi) |i| raw_path[0..i] else raw_path;
    const query: ?[]const u8 = if (qi) |i| raw_path[i + 1 ..] else null;

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

    // Read body — use stack buffer for small requests, heap for large ones
    var heap_body: ?[]u8 = null;
    defer if (heap_body) |hb| std.heap.page_allocator.free(hb);

    var body: ?[]const u8 = null;

    if (content_length > 0) {
        if (content_length > max_body_size) {
            try sendResponse(stream, "413 Content Too Large", "text/plain", "Request body too large");
            return;
        }

        const already_read = total_read - header_end;

        if (header_end + content_length <= buf.len) {
            // Small body — fits in stack buffer
            while (total_read < header_end + content_length) {
                const n = try stream.read(buf[total_read..]);
                if (n == 0) break;
                total_read += n;
            }
            if (header_end < total_read) {
                body = buf[header_end..total_read];
            }
        } else {
            // Large body — allocate on heap
            const body_buf = std.heap.page_allocator.alloc(u8, content_length) catch {
                try sendResponse(stream, "413 Content Too Large", "text/plain", "Request body too large");
                return;
            };
            heap_body = body_buf;

            // Copy bytes already read past the headers
            if (already_read > 0) {
                @memcpy(body_buf[0..already_read], buf[header_end..total_read]);
            }

            // Read the rest
            var body_read = already_read;
            while (body_read < content_length) {
                const n = stream.read(body_buf[body_read..content_length]) catch break;
                if (n == 0) break;
                body_read += n;
            }
            body = body_buf[0..body_read];
        }
    } else {
        // No Content-Length but might have partial body from header read
        if (header_end < total_read) {
            body = buf[header_end..total_read];
        }
    }

    if (global_router) |*router| {
        try router.dispatch(method, path, stream, headers[0..header_count], body, query);
    } else {
        // Fallback if router not initialized
        try sendResponse(stream, "500 Internal Server Error", "text/plain", "Server not initialized");
    }
}

fn handleIndex(ctx: *Context) !void {
    const content = tpl.renderStatic(views.index.Index);
    if (ctx.isPartial()) {
        ctx.html(content);
    } else {
        ctx.html(wrapWithBase(content, "Publr", &.{"/static/theme.css"}, &.{}));
    }
}

fn wrapWithBase(content: []const u8, title: []const u8, css: []const []const u8, js: []const []const u8) []const u8 {
    return tpl.render(views.base.Base, .{.{
        .title = title,
        .content = content,
        .css = css,
        .js = js,
    }});
}

fn handleErrorTest(_: *Context) !void {
    return error.TestError;
}

/// Comptime asset map: URL path -> embedded asset + optional dev-mode disk path.
/// Design system assets have no disk path (always served from amalgamation, even in dev mode).
const AssetEntry = struct {
    asset: type,
    disk_path: ?[]const u8,
};

const asset_map = .{
    .{ "admin.css", AssetEntry{ .asset = AdminCss, .disk_path = "static/admin.css" } },
    .{ "admin.js", AssetEntry{ .asset = AdminJs, .disk_path = "static/admin.js" } },
    .{ "theme.css", AssetEntry{ .asset = ThemeCss, .disk_path = "themes/demo/static/theme.css" } },
    .{ "interact/core.js", AssetEntry{ .asset = InteractCore, .disk_path = "static/interact/core.js" } },
    .{ "interact/toggle.js", AssetEntry{ .asset = InteractToggle, .disk_path = "static/interact/toggle.js" } },
    .{ "interact/portal.js", AssetEntry{ .asset = InteractPortal, .disk_path = "static/interact/portal.js" } },
    .{ "interact/focus-trap.js", AssetEntry{ .asset = InteractFocusTrap, .disk_path = "static/interact/focus-trap.js" } },
    .{ "interact/dismiss.js", AssetEntry{ .asset = InteractDismiss, .disk_path = "static/interact/dismiss.js" } },
    .{ "interact/components.js", AssetEntry{ .asset = InteractComponents, .disk_path = "static/interact/components.js" } },
    .{ "interact/index.js", AssetEntry{ .asset = InteractIndex, .disk_path = "static/interact/index.js" } },
    .{ "media-selection.js", AssetEntry{ .asset = MediaSelectionJs, .disk_path = "static/media-selection.js" } },
    .{ "interact/websocket.js", AssetEntry{ .asset = InteractWebSocket, .disk_path = "static/interact/websocket.js" } },
    .{ "interact/presence.js", AssetEntry{ .asset = InteractPresence, .disk_path = "static/interact/presence.js" } },
    .{ "publr.css", AssetEntry{ .asset = PublrCss, .disk_path = null } },
    .{ "publr-core.js", AssetEntry{ .asset = PublrCoreJs, .disk_path = null } },
    .{ "publr-dialog.js", AssetEntry{ .asset = PublrDialogJs, .disk_path = null } },
    .{ "publr-dropdown.js", AssetEntry{ .asset = PublrDropdownJs, .disk_path = null } },
};

fn handleStatic(ctx: *Context) !void {
    const file = ctx.wildcard orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
        return;
    };

    inline for (asset_map) |entry| {
        if (std.mem.eql(u8, file, entry[0])) {
            if (is_dev_mode) {
                if (entry[1].disk_path) |disk_path| {
                    // Dev mode: serve from disk for instant updates
                    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, disk_path, 1024 * 1024) catch {
                        ctx.response.setStatus("404 Not Found");
                        ctx.response.setContentType("text/plain");
                        ctx.response.setBody("File not found");
                        return;
                    };
                    // Note: memory leak in dev mode, acceptable for development
                    ctx.response.setContentType(static.getMimeType(file));
                    ctx.response.setBody(content);
                    return;
                }
            }
            // Production mode, or embedded-only asset (design system)
            entry[1].asset.serve(ctx, ctx.getRequestHeader("If-None-Match"));
            return;
        }
    }

    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
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
    const content = tpl.render(views.admin.setup.Setup, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
        .bg_dark = false,
    }});
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
    const decoded_email = url_mod.formDecode(ctx.allocator, email) catch {
        return renderSetupError(ctx, "Invalid email format");
    };

    // Validate
    const auth_mod = @import("auth");
    if (!auth_mod.isValidEmail(decoded_email)) {
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
    const content = tpl.render(views.admin.setup.Setup, .{.{
        .error_message = message,
        .csrf_token = csrf_token,
        .bg_dark = false,
    }});
    ctx.html(content);
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
    const content = tpl.render(views.admin.login.Login, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
    }});
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
    const decoded_email = url_mod.formDecode(ctx.allocator, email) catch {
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
    const content = tpl.render(views.admin.login.Login, .{.{
        .error_message = message,
        .csrf_token = csrf_token,
    }});
    ctx.html(content);
}

fn defaultDisplayName(email: []const u8) []const u8 {
    const at_pos = std.mem.indexOf(u8, email, "@") orelse return email;
    if (at_pos == 0) return email;
    return email[0..at_pos];
}

// =============================================================================
// WebSocket Handler
// =============================================================================

fn handleWebSocket(ctx: *Context) !void {
    // Validate WebSocket upgrade request
    const upgrade_header = ctx.getRequestHeader("Upgrade") orelse {
        ctx.response.setStatus("400 Bad Request");
        ctx.response.setBody("Expected WebSocket upgrade");
        return;
    };
    if (!std.ascii.eqlIgnoreCase(upgrade_header, "websocket")) {
        ctx.response.setStatus("400 Bad Request");
        ctx.response.setBody("Expected WebSocket upgrade");
        return;
    }

    const ws_key = ctx.getRequestHeader("Sec-WebSocket-Key") orelse {
        ctx.response.setStatus("400 Bad Request");
        ctx.response.setBody("Missing Sec-WebSocket-Key");
        return;
    };

    // Get user info from auth context (WS route is behind auth middleware)
    const user_id = auth_middleware.getUserId(ctx) orelse return;
    const user_email = auth_middleware.getUserEmail(ctx) orelse return;

    // Look up display name from database
    const auth_instance = auth_middleware.auth orelse return;
    const display_name = blk: {
        var maybe_user = auth_instance.getUserById(user_id) catch null;
        if (maybe_user) |*user| {
            const dn = std.heap.page_allocator.dupe(u8, user.display_name) catch "";
            auth_instance.freeUser(user);
            break :blk dn;
        }
        break :blk @as([]const u8, "");
    };
    defer if (display_name.len > 0) std.heap.page_allocator.free(display_name);

    const user_info = presence.UserInfo{
        .user_id = user_id,
        .email = user_email,
        .display_name = display_name,
    };

    const stream = ctx.stream orelse return error.NoStream;

    // Perform upgrade handshake (sends 101 response)
    try websocket.upgrade(stream, ws_key);
    ctx.response.headers_sent = true;

    // Heap-allocate connection (must outlive registry references from other threads)
    const conn = try std.heap.page_allocator.create(websocket.Connection);
    conn.* = .{
        .stream = stream,
        .allocator = std.heap.page_allocator,
        .id = websocket.nextId(),
    };

    websocket.registry.add(conn);
    defer {
        presence.disconnect(conn.id);
        websocket.registry.remove(conn);
        std.heap.page_allocator.destroy(conn);
    }

    conn.sendJson("connected", null) catch return;
    if (is_dev_mode) {
        std.debug.print("[ws] Connection {d} opened (active: {d})\n", .{ conn.id, websocket.registry.count() });
    }
    defer {
        if (is_dev_mode) {
            std.debug.print("[ws] Connection {d} closed (active: {d})\n", .{ conn.id, websocket.registry.count() });
        }
    }

    // Message loop — 10s poll timeout for heartbeat checking
    var poll_fds = [_]posix.pollfd{
        .{ .fd = stream.handle, .events = posix.POLL.IN, .revents = 0 },
    };
    var idle_ticks: u32 = 0;

    while (!shutdown_requested.load(.acquire)) {
        const poll_result = posix.poll(&poll_fds, 10_000) catch break;

        if (poll_result == 0) {
            idle_ticks += 1;
            // Check heartbeat staleness (>20s without heartbeat)
            if (presence.isHeartbeatStale(conn.id)) {
                if (is_dev_mode) std.debug.print("[ws] #{d}: heartbeat stale, closing\n", .{conn.id});
                break;
            }
            // 30s idle — send ping to verify TCP liveness
            if (idle_ticks >= 3) {
                websocket.writeFrame(stream, .ping, &.{}) catch break;
                idle_ticks = 0;
            }
            continue;
        }

        idle_ticks = 0;

        const frame = websocket.readFrame(stream, std.heap.page_allocator) catch break;
        defer std.heap.page_allocator.free(frame.payload);

        switch (frame.opcode) {
            .text => {
                if (is_dev_mode) {
                    std.debug.print("[ws] #{d}: {s}\n", .{ conn.id, frame.payload });
                }
                dispatchMessage(conn, frame.payload, user_info);
            },
            .ping => {
                websocket.writeFrame(stream, .pong, frame.payload) catch break;
            },
            .pong => {},
            .close => {
                conn.sendClose();
                break;
            },
            else => {},
        }
    }
}

/// Dispatch a WebSocket JSON message to the appropriate handler.
fn dispatchMessage(conn: *websocket.Connection, payload: []const u8, user: presence.UserInfo) void {
    const extractJsonString = websocket.extractJsonString;
    const extractJsonStringRaw = websocket.extractJsonStringRaw;

    // Parse message type: {"type":"...","data":{...}}
    const msg_type = extractJsonString(payload, "type") orelse return;

    if (std.mem.eql(u8, msg_type, "subscribe")) {
        const entry_id = extractJsonString(payload, "entry_id") orelse return;
        presence.subscribe(entry_id, conn, user);
    } else if (std.mem.eql(u8, msg_type, "unsubscribe")) {
        presence.unsubscribe(conn.id);
    } else if (std.mem.eql(u8, msg_type, "activity")) {
        const active_str = extractJsonString(payload, "active") orelse return;
        presence.setActivity(conn.id, std.mem.eql(u8, active_str, "true"));
    } else if (std.mem.eql(u8, msg_type, "heartbeat")) {
        presence.heartbeat(conn.id);
    } else if (std.mem.eql(u8, msg_type, "focus")) {
        const field = extractJsonString(payload, "field") orelse return;
        presence.focus(conn.id, field);
    } else if (std.mem.eql(u8, msg_type, "blur")) {
        const field = extractJsonString(payload, "field") orelse return;
        presence.blur(conn.id, field);
    } else if (std.mem.eql(u8, msg_type, "field_edit")) {
        const field = extractJsonString(payload, "field") orelse return;
        const value = extractJsonStringRaw(payload, "value") orelse return;
        presence.fieldEdit(conn.id, field, value);
    } else if (std.mem.eql(u8, msg_type, "takeover")) {
        const field = extractJsonString(payload, "field") orelse return;
        plugin_posts.handleTakeover(conn, field, user);
    }
}
