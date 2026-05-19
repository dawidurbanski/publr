const std = @import("std");
const posix = std.posix;
const router_mod = @import("router");
const Router = router_mod.Router;
const Context = router_mod.Context;
const Method = router_mod.Method;
const logger = @import("logger.zig");
const error_pages = @import("error.zig");
const publish_hooks = @import("publish_hooks");
const ssg = @import("ssg.zig");
const tpl = @import("tpl");
const dev = @import("dev.zig");
const recompile = @import("recompile.zig");
const core_init = @import("core_init");
const schema_registry = @import("schema_registry");
const schema_db_types = @import("schema_db_types");
const schemas = @import("schemas");
const Auth = @import("auth").Auth;
const auth_middleware = @import("auth_middleware");
const csrf = @import("csrf");
const actions = @import("actions");
const content_actions = @import("content_actions");
const admin_api = @import("admin_api");
const media_handler = @import("media_handler");
const websocket = @import("websocket");
const presence = @import("presence");
const collaboration_config = @import("collaboration_config.zig");
const modules_api = @import("modules");
const admin_module = @import("module_admin");
const rest_auth = @import("rest/auth.zig");
const rest_content = @import("rest/content.zig");
const rest_version = @import("rest/version.zig");
const rest_release = @import("rest/release.zig");
const rest_media = @import("rest/media.zig");
const rest_taxonomy = @import("rest/taxonomy.zig");
const rest_user = @import("rest/user.zig");
const rest_schema = @import("rest/schema.zig");
const rest_info = @import("rest/info.zig");
const setup_auth_handlers = @import("http_handlers/setup_auth.zig");
const static_handlers = @import("http_handlers/static_files.zig");
const theme_handlers = @import("http_handlers/theme.zig");
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
    theme_handlers.setDevMode(dev_mode);
    ws_handlers.configure(&shutdown_requested, dev_mode, db_path);
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

    // Fire plugin db_open_hooks now that the schema + seed are in place.
    // The cr-sqlite plugin uses this to mark `content_entries` and
    // `content_versions` as CRRs, which is required for the native
    // server to ingest changeset frames from WASM replicas.
    core_init.fireDbOpenHooks(&db) catch |err| {
        std.debug.print("db_open_hooks failed (non-fatal): {s}\n", .{@errorName(err)});
    };

    // Initialize the runtime content type registry. `compiled_in_types`
    // already concatenates core schemas + plugin-discovered descriptors;
    // DB-defined types are loaded from the `content_types` table next.
    schema_registry.init(allocator);
    for (schema_registry.compiled_in_types) |def| {
        schema_registry.register(def) catch |err| {
            std.debug.print("Failed to register compile-in content type '{s}': {}\n", .{ def.type_id, err });
        };
    }
    if (schema_db_types.loadAll(allocator, &db)) |db_defs| {
        for (db_defs) |def| {
            schema_registry.register(def) catch |err| {
                std.debug.print("Failed to register DB-defined content type '{s}': {}\n", .{ def.type_id, err });
            };
        }
        allocator.free(db_defs);
    } else |err| {
        std.debug.print("Failed to load DB-defined content types: {}\n", .{err});
    }

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
    try router.get("/admin/setup", setup_auth_handlers.handleSetupGet);
    try router.post("/admin/setup", setup_auth_handlers.handleSetupPost);
    try router.get("/admin/login", setup_auth_handlers.handleLoginGet);
    try router.post("/admin/login", setup_auth_handlers.handleLoginPost);
    try router.post("/admin/logout", setup_auth_handlers.handleLogout);
    try router.get("/static/*", static_handlers.handleStatic);
    if (comptime modules_api.hasModule(.theme)) {
        try router.get("/theme/*", static_handlers.handleThemeStatic);
        try router.get("/sitemap.xml", handleSitemap);
    }
    try router.get("/media/*", media_handler.handleMedia);
    try router.post("/admin/system/recompile", recompile.handleRecompile);
    try router.post("/admin/system/config", recompile.handleConfigUpdate);
    try router.get("/admin/system/health", recompile.handleHealth);
    try router.get("/admin/ws", ws_handlers.handleWebSocket);
    // Sync-only endpoint for cr-sqlite replicas that can't reuse the admin
    // cookie. Token-authenticated via ?sync_token=<base64> query param.
    try router.get("/admin/ws/sync", ws_handlers.handleSyncWebSocket);

    // Action dispatcher — plugins register named actions via app.action(),
    // forms POST to /admin/action with a hidden `action=plugin.verb` field.
    actions.init(allocator, .{ .not_found = error_pages.notFoundHandler });
    try router.post("/admin/action", actions.dispatch);
    // Default `content.<verb>` action handlers (registered before plugin
    // setup so per-CT plugins can override with `app.action` if needed).
    content_actions.registerDefaults();

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
        try router.get("/error-test", devErrorTest);
    }

    // Theme routes (lowest priority — registered after admin, API, and plugin routes)
    if (comptime modules_api.hasModule(.theme)) {
        try theme_handlers.registerRoutes(&router);

        // Custom 404 handler (theme 404 page if available, otherwise default)
        if (!theme_handlers.setNotFoundHandler(&router)) {
            router.setNotFound(error_pages.notFoundHandler);
        }

        // Register SSG regeneration hook for publish/unpublish
        publish_hooks.register(&ssgRegenHook);
    } else {
        router.setNotFound(error_pages.notFoundHandler);
    }

    connection_handlers.configure(&router, &active_connections);

    setupSignalHandlers();

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);

    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("Publr running at http://localhost:{d}\n", .{port});
    if (std.fs.cwd().realpathAlloc(allocator, db_path)) |abs| {
        defer allocator.free(abs);
        std.debug.print("  db: {s}\n", .{abs});
    } else |_| {
        std.debug.print("  db: {s}\n", .{db_path});
    }
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

fn handleSitemap(ctx: *router_mod.Context) !void {
    // Try pre-generated file first
    const output_dir = ssg.getOutputDir();
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/sitemap.xml", .{output_dir}) catch "";
    if (path.len > 0) {
        if (std.fs.cwd().readFileAlloc(ctx.allocator, path, 1024 * 1024)) |content| {
            ctx.response.setContentType("application/xml");
            ctx.response.setBody(content);
            return;
        } else |_| {}
    }

    // Generate on the fly (includes dynamic routes from DB)
    const db = if (auth_middleware.auth) |a| a.db else return error_pages.notFoundHandler(ctx);
    const content = ssg.generateSitemapContent(ctx.allocator, db) catch return error_pages.notFoundHandler(ctx);
    ctx.response.setContentType("application/xml");
    ctx.response.setBody(content);
}

fn ssgRegenHook(db: *@import("db").Db, alloc: std.mem.Allocator, entry_id: []const u8) void {
    const output_dir = ssg.getOutputDir();

    // Look up slug and content type from entry_id (using arena so strings stay valid)
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const slug = blk: {
        var stmt = db.prepare("SELECT slug FROM content_entries WHERE id = ?1") catch break :blk null;
        defer stmt.deinit();
        stmt.bindText(1, entry_id) catch break :blk null;
        if ((stmt.step() catch null) orelse false) {
            if (stmt.columnText(0)) |s| break :blk a.dupe(u8, s) catch null;
        }
        break :blk null;
    };

    const content_type_id = blk: {
        var stmt = db.prepare("SELECT a.content_type FROM content_anchors a JOIN content_entries e ON e.anchor_id = a.id WHERE e.id = ?1") catch break :blk null;
        defer stmt.deinit();
        stmt.bindText(1, entry_id) catch break :blk null;
        if ((stmt.step() catch null) orelse false) {
            if (stmt.columnText(0)) |s| break :blk a.dupe(u8, s) catch null;
        }
        break :blk null;
    };

    if (slug) |s| {
        // Convert DB type_id to handle for manifest matching by looking up
        // the descriptor in the runtime registry.
        const handle = if (content_type_id) |ct|
            if (schema_registry.findById(ct)) |def| def.handle else null
        else
            null;
        if (ssg.regenerateEntry(a, db, output_dir, s, handle)) |n| {
            std.debug.print("[ssg] Regenerated {d} pages for '{s}'\n", .{ n, s });
        }
    } else {
        if (ssg.regeneratePages(a, db, output_dir)) |n| {
            std.debug.print("[ssg] Regenerated {d} pages\n", .{n});
        }
    }
    ssg.regenerateSitemap(a, db, output_dir) catch {};
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

/// Dev-only test route to trigger a 500 error so we can see the error page.
/// Wired only when `--dev` is passed.
fn devErrorTest(_: *Context) !void {
    return error.TestError;
}
