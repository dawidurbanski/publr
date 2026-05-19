//! Browser WASM entry point for the CMS
//! Uses the same plugin/registry system as the native build

const std = @import("std");
const db = @import("db");
const auth_mod = @import("auth");
const tpl = @import("tpl");
const mw = @import("middleware");
const admin_api = @import("admin_api");
const actions = @import("actions");
const content_actions = @import("content_actions");
const registry = @import("registry");
const WasmRouter = @import("wasm_router").WasmRouter;
const auth_middleware = @import("auth_middleware");
const csrf = @import("csrf");
const wasm_storage = @import("wasm_storage");
const wasm_media_handler = @import("wasm_media_handler");
const wasm_static_handler = @import("wasm_static_handler");
const error_pages = @import("error_pages");
const seed = @import("seed");
const config = @import("config");
const schema_registry = @import("schema_registry");
const schema_db_types = @import("schema_db_types");
const schemas = @import("schemas");
const db_open_hooks = @import("db_open_hooks");
const apply_remote_hooks = @import("apply_remote_hooks");
const sync_catchup_hooks = @import("sync_catchup_hooks");

// Generated ZSX views
const views = @import("views");

// Database schema (single source of truth)
const schema_sql = @embedFile("schema_sql");

// Optional snapshot of the native publr DB, embedded at build time. Empty
// when `data/publr.db` was absent during the WASM build. See
// `build/wasm.zig` for the embed wiring and `cms_init` for usage.
const starter_db: []const u8 = @embedFile("starter_db");

// Required for libc linking in WASM
pub fn main() void {}

// =============================================================================
// Global State
// =============================================================================

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var global_db: ?db.Db = null;
var global_auth: ?auth_mod.Auth = null;

// Session storage
var session_token: ?[]const u8 = null;

// Result buffer (2MB for serving images)
var result_buffer: [2 * 1024 * 1024]u8 = undefined;
var result_len: usize = 0;
var result_status: u16 = 200;
var redirect_buffer: [256]u8 = undefined;
var redirect_len: usize = 0;

// Content-Type buffer for binary responses
var content_type_buffer: [128]u8 = undefined;
var content_type_len: usize = 0;

// Request header injection (set before cms_request, consumed after)
var request_header_name_buf: [64]u8 = undefined;
var request_header_name_len: usize = 0;
var request_header_value_buf: [256]u8 = undefined;
var request_header_value_len: usize = 0;

// Route table (initialized once in cms_init)
var global_router: ?WasmRouter = null;

// =============================================================================
// WASM Exports - Memory
// =============================================================================

export fn wasm_alloc(size: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn wasm_get_result_ptr() [*]const u8 {
    return &result_buffer;
}

export fn wasm_get_result_len() usize {
    return result_len;
}

export fn wasm_get_status() u16 {
    return result_status;
}

export fn wasm_get_redirect_ptr() [*]const u8 {
    return &redirect_buffer;
}

export fn wasm_get_redirect_len() usize {
    return redirect_len;
}

export fn wasm_get_content_type_ptr() [*]const u8 {
    return &content_type_buffer;
}

export fn wasm_get_content_type_len() usize {
    return content_type_len;
}

/// Set a request header before calling cms_request (e.g., Content-Type for file uploads)
export fn cms_set_request_header(
    name_ptr: ?[*]const u8,
    name_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) void {
    if (name_ptr != null and name_len > 0 and name_len <= request_header_name_buf.len) {
        @memcpy(request_header_name_buf[0..name_len], name_ptr.?[0..name_len]);
        request_header_name_len = name_len;
    }
    if (val_ptr != null and val_len > 0 and val_len <= request_header_value_buf.len) {
        @memcpy(request_header_value_buf[0..val_len], val_ptr.?[0..val_len]);
        request_header_value_len = val_len;
    }
}

// =============================================================================
// WASM Exports - CMS
// =============================================================================

/// Initialize CMS (fresh database)
export fn cms_init() i32 {
    if (global_db != null) return 0;

    global_db = db.Db.init(allocator, ":memory:") catch return -1;

    if (starter_db.len > 0) {
        // Bootstrap from a native-built snapshot baked in at WASM build
        // time. Same content types, same data, no schema/seed run.
        if (!global_db.?.deserialize(starter_db)) return -1;
        // Schema is idempotent (CREATE IF NOT EXISTS) — run it so an
        // out-of-date snapshot picks up any new tables added in code.
        global_db.?.exec(schema_sql) catch return -1;
    } else {
        global_db.?.exec(schema_sql) catch return -1;
        global_db.?.exec(seed.seed_sql) catch return -1;
    }

    db_open_hooks.fireAll(&global_db.?) catch |err| {
        std.log.warn("db_open_hooks.fireAll failed: {s}", .{@errorName(err)});
    };
    global_auth = auth_mod.Auth.init(allocator, &global_db.?);
    tpl.init(false);

    // Bootstrap the runtime content type registry. `compiled_in_types`
    // already concatenates core schemas + plugin-discovered descriptors;
    // DB-defined types are loaded next. See http.zig for the native equivalent.
    schema_registry.init(allocator);
    for (schema_registry.compiled_in_types) |def| {
        schema_registry.register(def) catch {};
    }
    if (schema_db_types.loadAll(allocator, &global_db.?)) |db_defs| {
        for (db_defs) |def| schema_registry.register(def) catch {};
        allocator.free(db_defs);
    } else |_| {}

    // Initialize auth middleware
    auth_middleware.init(&global_auth.?);

    // Initialize WASM blob storage
    wasm_storage.init(&global_db.?);

    // Initialize router and register all plugin routes
    var router = WasmRouter.init(allocator);

    // Register media file serving route
    router.get("/media/*", wasm_media_handler.handleMedia);

    // Register /static/* — serves tokens.css and publr.css (preflight + JIT) for the WASM dev shell.
    router.get("/static/*", wasm_static_handler.handleStatic);

    // Register core routes (setup, login, logout)
    router.get("/admin/setup", handleSetupGet);
    router.post("/admin/setup", handleSetupPost);
    router.get("/admin/login", handleLoginGet);
    router.post("/admin/login", handleLoginPost);
    router.post("/admin/logout", handleLogout);

    // Action dispatcher — must be initialized before plugin setup runs so any
    // app.action(...) calls land in the registry.
    actions.init(allocator, .{ .not_found = error_pages.notFoundHandler });
    router.post("/admin/action", actions.dispatch);
    content_actions.registerDefaults();

    // Register plugin routes (same pattern as http.zig:registerPluginRoutes)
    const reg = router.registrar();
    inline for (registry.pages) |page| {
        const base_path = admin_api.resolvePagePath(page, registry.pages);
        var app = admin_api.PageApp{
            .base_path = base_path,
            .page = page,
            .registrar = reg,
            .allocator = allocator,
        };
        page.setup(&app);
    }

    global_router = router;
    return 0;
}

/// Import database from bytes
export fn cms_import_db(data_ptr: [*]const u8, data_len: usize) i32 {
    if (data_len == 0) return -1;

    if (global_db) |*database| {
        database.deinit();
        global_db = null;
        global_auth = null;
    }

    global_db = db.Db.init(allocator, ":memory:") catch return -1;
    if (!global_db.?.deserialize(data_ptr[0..data_len])) {
        // Roll back: leave globals in the same "uninitialized" state the
        // worker expects after a failed restore, so the fallback cms_init()
        // call actually runs (otherwise its `if (global_db != null) return 0`
        // short-circuits and the router/auth pointers stay dangling).
        global_db.?.deinit();
        global_db = null;
        return -1;
    }
    // Re-apply schema (all CREATE statements are IF NOT EXISTS) so DBs cached
    // in OPFS from an older build pick up any new tables — e.g. the releases
    // tables were missing here, causing listReleases to fail with "no such table".
    global_db.?.exec(schema_sql) catch return -1;
    // Plugin db_open_hooks run after schema is in place (see cms_init).
    db_open_hooks.fireAll(&global_db.?) catch |err| {
        // Hook failures are logged but don't abort init — cr-sqlite CRR
        // marking can fail on a stale OPFS schema (e.g. a DB cached
        // before the unique-constraint drop), and we'd rather boot
        // without sync than refuse to start. Reset OPFS to recover.
        std.log.warn("db_open_hooks.fireAll failed: {s}", .{@errorName(err)});
    };
    global_auth = auth_mod.Auth.init(allocator, &global_db.?);
    tpl.init(false);
    auth_middleware.init(&global_auth.?);

    // Re-initialize WASM blob storage with the imported DB
    wasm_storage.init(&global_db.?);

    return 0;
}

/// Export database to bytes
export fn cms_export_db() i32 {
    var database = global_db orelse return -1;
    const data = database.serialize() orelse return -1;
    defer allocator.free(data);

    if (data.len > result_buffer.len) return -1;
    @memcpy(result_buffer[0..data.len], data);
    result_len = data.len;
    return 0;
}

/// Broadcast this replica's full state via `sync_transport.send`.
/// Called by cms-worker.js when the relay WebSocket opens so OPFS-
/// restored content + anything saved-while-disconnected gets pushed
/// to peers. cr-sqlite's merge dedupes against rows peers already have.
export fn cms_sync_emit_full() void {
    if (global_db == null) return;
    sync_catchup_hooks.fireAll(.{
        .db = &global_db.?,
        .allocator = allocator,
    });
}

/// Apply a remote sync frame to the local DB. Called by cms-worker.js
/// when the worker's WebSocket receives a `sync_changes` envelope —
/// `ptr/len` points at the inner `data` payload (the JSON array of
/// cr-sqlite changeset rows). Dispatches through `apply_remote_hooks`
/// so any plugin that registered for remote frames gets a shot at it.
/// Returns 0 on success, -1 on any failure (logged via std.log.warn).
export fn cms_apply_remote_changeset(ptr: [*]const u8, len: usize) i32 {
    if (global_db == null) return -1;
    if (len == 0) return 0;
    apply_remote_hooks.applyAll(.{
        .db = &global_db.?,
        .allocator = allocator,
        .payload = ptr[0..len],
    }) catch |err| {
        std.log.warn("cms_apply_remote_changeset failed: {s}", .{@errorName(err)});
        return -1;
    };
    return 0;
}

/// Set session token (from localStorage)
export fn cms_set_session(token_ptr: ?[*]const u8, token_len: usize) void {
    if (session_token) |t| allocator.free(t);
    if (token_ptr == null or token_len == 0) {
        session_token = null;
        return;
    }
    session_token = allocator.dupe(u8, token_ptr.?[0..token_len]) catch null;
}

/// Main entry point: handle HTTP-like request
export fn cms_request(
    method_ptr: ?[*]const u8,
    method_len: usize,
    path_ptr: ?[*]const u8,
    path_len: usize,
    body_ptr: ?[*]const u8,
    body_len: usize,
) i32 {
    const method_str = if (method_ptr != null and method_len > 0) method_ptr.?[0..method_len] else "GET";
    const path = if (path_ptr != null and path_len > 0) path_ptr.?[0..path_len] else "/admin";
    const body = if (body_ptr != null and body_len > 0) body_ptr.?[0..body_len] else "";

    const method: mw.Method = mw.Method.fromString(method_str) orelse .GET;

    // Reset response
    result_len = 0;
    result_status = 200;
    redirect_len = 0;

    var router = &(global_router orelse {
        respondError(500, "Not initialized");
        return 0;
    });

    // Split query string from path
    const qmark = std.mem.indexOf(u8, path, "?");
    const clean_path = if (qmark) |q| path[0..q] else path;
    const query_str: ?[]const u8 = if (qmark) |q| path[q + 1 ..] else null;

    // Create context (stream = null for WASM)
    var ctx = mw.Context.init(allocator, method, clean_path);
    ctx.query = query_str;
    defer ctx.deinit();

    // Set request body
    if (body.len > 0) {
        ctx.setBody(body);
    }

    // Inject request header if set (e.g., Content-Type for file uploads)
    if (request_header_name_len > 0) {
        ctx.addRequestHeader(
            request_header_name_buf[0..request_header_name_len],
            request_header_value_buf[0..request_header_value_len],
        );
        request_header_name_len = 0;
        request_header_value_len = 0;
    }

    // Inject session token as Cookie header so auth_middleware works
    var cookie_buf: [512]u8 = undefined;
    if (session_token) |token| {
        const cookie = std.fmt.bufPrint(&cookie_buf, "{s}={s}", .{
            auth_middleware.SESSION_COOKIE,
            token,
        }) catch "";
        if (cookie.len > 0) {
            ctx.addRequestHeader("Cookie", cookie);
        }
    }

    // Run auth middleware (check session, redirect to setup/login)
    // For WASM, we call it directly as a handler (not as middleware chain)
    const needs_auth = std.mem.startsWith(u8, path, "/admin") and
        !std.mem.eql(u8, path, "/admin/setup") and
        !std.mem.eql(u8, path, "/admin/login");

    if (needs_auth) {
        const auth_instance = auth_middleware.auth orelse {
            respondError(500, "Auth not initialized");
            return 0;
        };

        const has_users = auth_instance.hasUsers() catch {
            respondError(500, "Database error");
            return 0;
        };

        if (!has_users) {
            doRedirect("/admin/setup");
            return 0;
        }

        // Check session
        if (session_token) |token| {
            var user = auth_instance.validateSession(token) catch {
                doRedirect("/admin/login");
                return 0;
            };
            defer auth_instance.freeUser(&user);
            // auth.zig dupes id/email/display_name without a null terminator,
            // and getUserEmail/etc. in auth_middleware.zig recover length via
            // null-scan. Copy into ctx.allocator with an explicit sentinel so
            // the scan stops at the real end of the string (and survives the
            // freeUser above).
            storeUserField(&ctx, "auth_user_id", user.id);
            storeUserField(&ctx, "auth_user_email", user.email);
            storeUserField(&ctx, "auth_user_display_name", user.display_name);
        } else {
            doRedirect("/admin/login");
            return 0;
        }
    }

    // CSRF validation for POST requests
    if (method == .POST and !std.mem.eql(u8, path, "/admin/setup") and !std.mem.eql(u8, path, "/admin/login")) {
        // In WASM browser mode, skip CSRF validation — requests come from same origin
    }

    // Dispatch to matching route
    const matched = router.dispatch(&ctx) catch {
        respondError(500, "Handler error");
        return 0;
    };

    if (!matched) {
        // Render the same 404 page as the native build (ZSX template via tpl).
        error_pages.notFoundHandler(&ctx) catch {
            respondError(404, "Not Found");
            return 0;
        };
        result_status = 404;
        processResponse(&ctx);
        tpl.resetArena();
        return 0;
    }

    // Process response (copies body into result_buffer)
    processResponse(&ctx);

    // Free all template memory now that response is copied
    tpl.resetArena();
    return 0;
}

fn storeUserField(ctx: *mw.Context, key: []const u8, value: []const u8) void {
    const buf = ctx.allocator.alloc(u8, value.len + 1) catch return;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    ctx.setState(key, @ptrCast(buf.ptr)) catch {};
}

// =============================================================================
// Response Helpers
// =============================================================================

fn processResponse(ctx: *mw.Context) void {
    // Copy content type for binary response support
    const ct = ctx.response.content_type;
    const ct_len = @min(ct.len, content_type_buffer.len);
    @memcpy(content_type_buffer[0..ct_len], ct[0..ct_len]);
    content_type_len = ct_len;

    // Check for redirect
    for (ctx.response.getCustomHeaders()) |maybe_header| {
        if (maybe_header) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Location")) {
                result_status = 302;

                // Check if there's a Set-Cookie with session token
                for (ctx.response.getCustomHeaders()) |maybe_h2| {
                    if (maybe_h2) |h2| {
                        if (std.ascii.eqlIgnoreCase(h2.name, "Set-Cookie")) {
                            // Extract token from Set-Cookie header
                            if (extractSessionToken(h2.value)) |token| {
                                // Store the new session token
                                if (session_token) |t| allocator.free(t);
                                session_token = allocator.dupe(u8, token) catch null;
                                // Return path|token format
                                redirectWithToken(h.value, token);
                                return;
                            }
                        }
                    }
                }

                doRedirect(h.value);
                return;
            }
        }
    }

    // Parse status code from status string
    if (std.mem.startsWith(u8, ctx.response.status, "302") or
        std.mem.startsWith(u8, ctx.response.status, "303"))
    {
        result_status = 302;
    } else if (std.mem.startsWith(u8, ctx.response.status, "404")) {
        result_status = 404;
    } else if (std.mem.startsWith(u8, ctx.response.status, "500")) {
        result_status = 500;
    } else if (std.mem.startsWith(u8, ctx.response.status, "403")) {
        result_status = 403;
    }

    respond(ctx.response.body);
}

fn extractSessionToken(cookie_header: []const u8) ?[]const u8 {
    // Parse "publr_session=TOKEN; Path=/; ..."
    const prefix = auth_middleware.SESSION_COOKIE ++ "=";
    const start = std.mem.indexOf(u8, cookie_header, prefix) orelse return null;
    const value_start = start + prefix.len;
    const remaining = cookie_header[value_start..];
    const end = std.mem.indexOf(u8, remaining, ";") orelse remaining.len;
    const token = remaining[0..end];
    if (token.len == 0 or std.mem.eql(u8, token, "")) return null;
    return token;
}

fn respond(body: []const u8) void {
    const len = @min(body.len, result_buffer.len);
    @memcpy(result_buffer[0..len], body[0..len]);
    result_len = len;
}

fn respondError(status: u16, msg: []const u8) void {
    result_status = status;
    @memcpy(result_buffer[0..msg.len], msg);
    result_len = msg.len;
}

fn doRedirect(path: []const u8) void {
    result_status = 302;
    @memcpy(redirect_buffer[0..path.len], path);
    redirect_len = path.len;
    result_len = 0;
}

fn redirectWithToken(path: []const u8, token: []const u8) void {
    result_status = 302;
    @memcpy(redirect_buffer[0..path.len], path);
    redirect_buffer[path.len] = '|';
    @memcpy(redirect_buffer[path.len + 1 ..][0..token.len], token);
    redirect_len = path.len + 1 + token.len;
    result_len = 0;
}

// =============================================================================
// Core Route Handlers (setup, login, logout)
// Same logic as http.zig but adapted for WASM context
// =============================================================================

fn handleSetupGet(ctx: *mw.Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const auth_instance = auth_middleware.auth orelse return;

    const has_users = auth_instance.hasUsers() catch return;
    if (has_users) {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    }

    const content = tpl.render(views.admin.setup.Setup, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
        .bg_dark = config.setup_bg_dark,
    }});
    ctx.html(content);
}

fn handleSetupPost(ctx: *mw.Context) !void {
    const auth_instance = auth_middleware.auth orelse return;

    const has_users = auth_instance.hasUsers() catch return;
    if (has_users) {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    }

    const email = ctx.formValue("email") orelse {
        return renderSetupError(ctx, "Email is required");
    };
    const password = ctx.formValue("password") orelse {
        return renderSetupError(ctx, "Password is required");
    };
    const confirm_password = ctx.formValue("confirm_password") orelse {
        return renderSetupError(ctx, "Please confirm your password");
    };

    if (password.len < 8) {
        return renderSetupError(ctx, "Password must be at least 8 characters");
    }

    if (!std.mem.eql(u8, password, confirm_password)) {
        return renderSetupError(ctx, "Passwords do not match");
    }

    const display_name = defaultDisplayName(email);
    const user_id = auth_instance.createUser(email, display_name, password) catch |err| {
        switch (err) {
            auth_mod.Auth.Error.EmailExists => return renderSetupError(ctx, "An account with this email already exists"),
            else => return renderSetupError(ctx, "Failed to create account"),
        }
    };
    defer auth_instance.allocator.free(user_id);

    const token = auth_instance.createSession(user_id) catch {
        return renderSetupError(ctx, "Account created but failed to log in.");
    };
    defer auth_instance.allocator.free(token);

    // Set session cookie (so processResponse picks up the token)
    auth_middleware.setSessionCookie(ctx, token);

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin");
    ctx.response.setBody("");
}

fn renderSetupError(ctx: *mw.Context, message: []const u8) void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.render(views.admin.setup.Setup, .{.{
        .error_message = message,
        .csrf_token = csrf_token,
        .bg_dark = config.setup_bg_dark,
    }});
    ctx.html(content);
}

fn handleLoginGet(ctx: *mw.Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const auth_instance = auth_middleware.auth orelse return;

    const has_users = auth_instance.hasUsers() catch return;
    if (!has_users) {
        ctx.response.setStatus("302 Found");
        ctx.response.setHeader("Location", "/admin/setup");
        ctx.response.setBody("");
        return;
    }

    const content = tpl.render(views.admin.login.Login, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
    }});
    ctx.html(content);
}

fn handleLoginPost(ctx: *mw.Context) !void {
    const auth_instance = auth_middleware.auth orelse return;

    const email = ctx.formValue("email") orelse {
        return renderLoginError(ctx, "Email is required");
    };
    const password = ctx.formValue("password") orelse {
        return renderLoginError(ctx, "Password is required");
    };

    const user_id = auth_instance.authenticateUser(email, password) catch {
        return renderLoginError(ctx, "Invalid email or password");
    };
    defer auth_instance.allocator.free(user_id);

    const token = auth_instance.createSession(user_id) catch {
        return renderLoginError(ctx, "Failed to create session");
    };
    defer auth_instance.allocator.free(token);

    auth_middleware.setSessionCookie(ctx, token);

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin");
    ctx.response.setBody("");
}

fn handleLogout(ctx: *mw.Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("302 Found");
        ctx.response.setHeader("Location", "/admin/login");
        ctx.response.setBody("");
        return;
    };

    if (auth_middleware.parseCookie(ctx, auth_middleware.SESSION_COOKIE)) |token| {
        auth_instance.invalidateSession(token) catch {};
    }

    auth_middleware.clearSessionCookie(ctx);

    ctx.response.setStatus("302 Found");
    ctx.response.setHeader("Location", "/admin/login");
    ctx.response.setBody("");
}

fn renderLoginError(ctx: *mw.Context, message: []const u8) void {
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
