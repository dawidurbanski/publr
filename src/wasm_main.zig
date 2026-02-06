//! Browser WASM entry point for the CMS
//! Uses shared handlers.dispatch() for all routing

const std = @import("std");
const db = @import("db.zig");
const auth_mod = @import("auth.zig");
const tpl = @import("tpl.zig");
const handlers = @import("handlers.zig");

// Static assets
const admin_css = @embedFile("static_admin_css");
const admin_js = @embedFile("static_admin_js");

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

// Result buffer
var result_buffer: [512 * 1024]u8 = undefined;
var result_len: usize = 0;
var result_status: u16 = 200;
var redirect_buffer: [256]u8 = undefined;
var redirect_len: usize = 0;

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

// =============================================================================
// WASM Exports - CMS
// =============================================================================

/// Initialize CMS (fresh database)
export fn cms_init() i32 {
    if (global_db != null) return 0;

    global_db = db.initWithSchema(allocator, ":memory:") catch return -1;
    global_auth = auth_mod.Auth.init(allocator, &global_db.?);
    tpl.init(false);

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
    if (!global_db.?.deserialize(data_ptr[0..data_len])) return -1;
    global_auth = auth_mod.Auth.init(allocator, &global_db.?);
    tpl.init(false);

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

    const method: handlers.Method = if (std.mem.eql(u8, method_str, "POST")) .POST else .GET;

    // Reset response
    result_len = 0;
    result_status = 200;
    redirect_len = 0;

    // Get database and auth
    var database = global_db orelse {
        respondError(500, "Not initialized");
        return 0;
    };
    var auth = global_auth orelse {
        respondError(500, "Not initialized");
        return 0;
    };

    // Validate session
    const session_valid = validateSession();

    // Build request context
    const ctx = handlers.RequestContext{
        .method = method,
        .path = path,
        .body = body,
        .db = &database,
        .auth = &auth,
        .session_valid = session_valid,
        .csrf_token = "", // WASM doesn't use CSRF tokens
        .allocator = allocator,
        .admin_css = admin_css,
        .admin_js = admin_js,
    };

    // Dispatch and handle result
    const result = handlers.dispatch(ctx);

    switch (result) {
        .html => |content| respond(content),
        .redirect => |path_r| redirect(path_r),
        .redirect_with_token => |r| {
            // Store the new session token
            if (session_token) |t| allocator.free(t);
            session_token = allocator.dupe(u8, r.token) catch null;
            redirectWithToken(r.path, r.token);
        },
        .static_css => |content| respondWithType(content, "text/css"),
        .static_js => |content| respondWithType(content, "application/javascript"),
        .not_found => respondError(404, "Not Found"),
        .server_error => |msg| respondError(500, msg),
        .needs_setup => redirect("/admin/setup"),
        .needs_auth => redirect("/admin/login"),
    }

    // Handle logout - invalidate session after dispatch
    if (std.mem.eql(u8, path, "/admin/logout") and method == .POST) {
        if (session_token) |token| {
            auth.invalidateSession(token) catch {};
            allocator.free(token);
            session_token = null;
        }
    }

    return 0;
}

// =============================================================================
// Helpers
// =============================================================================

fn validateSession() bool {
    const token = session_token orelse return false;
    var auth = global_auth orelse return false;
    var user = auth.validateSession(token) catch return false;
    auth.freeUser(&user);
    return true;
}

fn respond(body: []const u8) void {
    const len = @min(body.len, result_buffer.len);
    @memcpy(result_buffer[0..len], body[0..len]);
    result_len = len;
}

fn respondWithType(body: []const u8, content_type: []const u8) void {
    _ = content_type; // Content type handled by JS based on route
    respond(body);
}

fn respondError(status: u16, msg: []const u8) void {
    result_status = status;
    @memcpy(result_buffer[0..msg.len], msg);
    result_len = msg.len;
}

fn redirect(path: []const u8) void {
    result_status = 302;
    @memcpy(redirect_buffer[0..path.len], path);
    redirect_len = path.len;
    result_len = 0;
}

fn redirectWithToken(path: []const u8, token: []const u8) void {
    result_status = 302;
    // Format: path|token
    @memcpy(redirect_buffer[0..path.len], path);
    redirect_buffer[path.len] = '|';
    @memcpy(redirect_buffer[path.len + 1 ..][0..token.len], token);
    redirect_len = path.len + 1 + token.len;
    result_len = 0;
}
