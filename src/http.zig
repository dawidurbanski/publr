const std = @import("std");
const posix = std.posix;
const router_mod = @import("router");
const Router = router_mod.Router;
const Context = router_mod.Context;
const Method = router_mod.Method;
const logger = @import("logger.zig");
const error_pages = @import("error.zig");
const tpl = @import("tpl");
const dev = @import("dev.zig");
const recompile = @import("recompile.zig");
const core_init = @import("core_init");
const Auth = @import("auth").Auth;
const auth_middleware = @import("auth_middleware");
const csrf = @import("csrf");
const admin_api = @import("admin_api");
const media_handler = @import("media_handler");
const websocket = @import("websocket");
const presence = @import("presence");
const collaboration_config = @import("collaboration_config.zig");
const modules_api = @import("modules");
const admin_module = @import("module_admin");
const rest_auth = @import("rest_auth");
const rest_content = @import("rest_content");
const rest_version = @import("rest_version");
const rest_release = @import("rest_release");
const rest_media = @import("rest_media");
const rest_taxonomy = @import("rest_taxonomy");
const rest_user = @import("rest_user");
const rest_schema = @import("rest_schema");
const rest_info = @import("rest_info");
const site_handlers = @import("http_handlers/site.zig");
const setup_auth_handlers = @import("http_handlers/setup_auth.zig");
const static_handlers = @import("http_handlers/static_files.zig");
const ws_handlers = @import("http_handlers/websocket.zig");
const connection_handlers = @import("http_server/connection.zig");

// Global shutdown flag for signal handler
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Track active connections for graceful shutdown
var active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Global dev mode flag for handlers
var is_dev_mode: bool = false;

pub fn serve(
    port: u16,
    db_path: []const u8,
    lock_timeout_ms: u32,
    heartbeat_interval_ms: u32,
    dev_mode: bool,
) !void {
    is_dev_mode = dev_mode;
    static_handlers.setDevMode(dev_mode);
    ws_handlers.configure(&shutdown_requested, dev_mode);
    collaboration_config.setTiming(lock_timeout_ms, heartbeat_interval_ms);
    presence.setTiming(
        collaboration_config.getLockTimeoutMs(),
        collaboration_config.getHeartbeatIntervalMs(),
    );

    // Initialize router
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open database (created at build time by init_db)
    var db = core_init.initDatabase(allocator, db_path) catch |err| {
        std.debug.print("Failed to open database: {}\n", .{err});
        return err;
    };
    defer db.deinit();

    // Ensure all schema tables exist (safe to re-run — uses IF NOT EXISTS)
    core_init.ensureSchema(&db) catch |err| {
        std.debug.print("Failed to ensure schema: {}\n", .{err});
        return err;
    };

    // Seed content types and taxonomies (idempotent — uses INSERT OR IGNORE)
    core_init.seed(&db) catch |err| {
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
    try router.get("/", site_handlers.handleIndex);
    try router.get("/admin/setup", setup_auth_handlers.handleSetupGet);
    try router.post("/admin/setup", setup_auth_handlers.handleSetupPost);
    try router.get("/admin/login", setup_auth_handlers.handleLoginGet);
    try router.post("/admin/login", setup_auth_handlers.handleLoginPost);
    try router.post("/admin/logout", setup_auth_handlers.handleLogout);
    try router.get("/static/*", static_handlers.handleStatic);
    try router.get("/media/*", media_handler.handleMedia);
    try router.post("/admin/system/recompile", recompile.handleRecompile);
    try router.post("/admin/system/config", recompile.handleConfigUpdate);
    try router.get("/admin/system/health", recompile.handleHealth);
    try router.get("/admin/ws", ws_handlers.handleWebSocket);

    // REST API routes
    try rest_auth.registerRoutes(&router);
    try rest_content.registerRoutes(&router);
    try rest_version.registerRoutes(&router);
    try rest_release.registerRoutes(&router);
    try rest_media.registerRoutes(&router);
    try rest_taxonomy.registerRoutes(&router);
    try rest_user.registerRoutes(&router);
    try rest_schema.registerRoutes(&router);
    try rest_info.registerRoutes(&router);

    // Register plugin routes (arena freed on shutdown)
    var route_arena = std.heap.ArenaAllocator.init(allocator);
    defer route_arena.deinit();
    var module_context = modules_api.ModuleContext{
        .router = &router,
        .allocator = route_arena.allocator(),
        .db = &db,
    };
    if (comptime modules_api.hasModule(.admin_ui)) {
        admin_module.module.setup(&module_context);
    }

    // Dev-only test route to trigger 500 error
    if (dev_mode) {
        try router.get("/error-test", site_handlers.handleErrorTest);
    }

    // Custom 404 handler
    router.setNotFound(error_pages.notFoundHandler);

    connection_handlers.configure(&router, &active_connections);

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
        const thread = std.Thread.spawn(.{}, connection_handlers.handleConnectionThread, .{connection.stream}) catch |err| {
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
