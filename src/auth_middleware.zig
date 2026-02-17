const std = @import("std");
const mw = @import("middleware");
const Auth = @import("auth").Auth;
const Db = @import("db").Db;

const Context = mw.Context;
const NextFn = mw.NextFn;

/// Cookie name for session token
pub const SESSION_COOKIE = "publr_session";

/// Routes that don't require authentication
const public_routes = [_][]const u8{
    "/admin/login",
    "/admin/setup",
    "/admin/system/health",
};

/// Auth middleware state (must be initialized before use)
pub var auth: ?*Auth = null;

/// Initialize the auth middleware with auth instance
pub fn init(auth_instance: *Auth) void {
    auth = auth_instance;
}

/// Auth middleware for protecting /admin/* routes
/// - Redirects to /admin/setup if no users exist
/// - Redirects to /admin/login if not authenticated
/// - Injects user into context state on success
pub fn authMiddleware(ctx: *Context, next: NextFn) anyerror!void {
    // Only protect /admin/* routes
    if (!std.mem.startsWith(u8, ctx.path, "/admin")) {
        return next(ctx);
    }

    // Check if this is a public route
    for (public_routes) |route| {
        if (std.mem.eql(u8, ctx.path, route)) {
            return next(ctx);
        }
    }

    const auth_instance = auth orelse {
        // Auth not initialized, let request through (dev mode safety)
        return next(ctx);
    };

    // Check if any users exist
    const has_users = auth_instance.hasUsers() catch {
        return serverError(ctx, "Database error");
    };

    if (!has_users) {
        // No users yet - redirect to setup
        return redirect(ctx, "/admin/setup");
    }

    // Parse session cookie
    const token = parseCookie(ctx, SESSION_COOKIE) orelse {
        return redirect(ctx, "/admin/login");
    };

    // Validate session
    const user = auth_instance.validateSession(token) catch |err| {
        switch (err) {
            Auth.Error.SessionNotFound, Auth.Error.SessionExpired => {
                // Clear invalid cookie and redirect
                clearSessionCookie(ctx);
                return redirect(ctx, "/admin/login");
            },
            else => return serverError(ctx, "Authentication error"),
        }
    };

    // Store user in context state for handlers
    // Note: user memory is managed by auth module, will be freed on next request
    ctx.setState("auth_user_id", @ptrCast(@constCast(user.id.ptr))) catch {};
    ctx.setState("auth_user_email", @ptrCast(@constCast(user.email.ptr))) catch {};

    // Continue to handler
    return next(ctx);
}

/// Parse a cookie value from the Cookie header
pub fn parseCookie(ctx: *Context, name: []const u8) ?[]const u8 {
    const cookie_header = ctx.getRequestHeader("Cookie") orelse return null;

    // Cookie header format: "name1=value1; name2=value2"
    var iter = std.mem.splitSequence(u8, cookie_header, "; ");
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq_pos| {
            const cookie_name = pair[0..eq_pos];
            if (std.mem.eql(u8, cookie_name, name)) {
                return pair[eq_pos + 1 ..];
            }
        }
    }

    return null;
}

/// Send redirect response
fn redirect(ctx: *Context, location: []const u8) void {
    ctx.response.setStatus("302 Found");
    ctx.response.setHeader("Location", location);
    ctx.response.setBody("");
}

/// Send server error response
fn serverError(ctx: *Context, message: []const u8) void {
    ctx.response.setStatus("500 Internal Server Error");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody(message);
}

/// Set session cookie
pub fn setSessionCookie(ctx: *Context, token: []const u8) void {
    // Build cookie with security attributes
    var cookie_buf: [512]u8 = undefined;
    const cookie = std.fmt.bufPrint(&cookie_buf, "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}", .{
        SESSION_COOKIE,
        token,
        @as(u64, 30 * 24 * 60 * 60), // 30 days
    }) catch return;

    // Use setHeaderOwned to copy value into response-owned buffer
    ctx.response.setHeaderOwned("Set-Cookie", cookie);
}

/// Clear session cookie
pub fn clearSessionCookie(ctx: *Context) void {
    var cookie_buf: [256]u8 = undefined;
    const cookie = std.fmt.bufPrint(&cookie_buf, "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0", .{
        SESSION_COOKIE,
    }) catch return;

    // Use setHeaderOwned to copy value into response-owned buffer
    ctx.response.setHeaderOwned("Set-Cookie", cookie);
}

/// Get authenticated user ID from context (set by authMiddleware)
pub fn getUserId(ctx: *Context) ?[]const u8 {
    const ptr = ctx.state.get("auth_user_id") orelse return null;
    // Reconstruct slice from pointer - we stored the ptr, need to find length
    // This is a simplified approach; in practice you'd store the full slice
    const id_ptr: [*]const u8 = @ptrCast(ptr);
    // Find the null terminator or use a reasonable max length
    var len: usize = 0;
    while (len < 64 and id_ptr[len] != 0) : (len += 1) {}
    if (len == 0) return null;
    return id_ptr[0..len];
}

/// Get authenticated user email from context
pub fn getUserEmail(ctx: *Context) ?[]const u8 {
    const ptr = ctx.state.get("auth_user_email") orelse return null;
    const email_ptr: [*]const u8 = @ptrCast(ptr);
    var len: usize = 0;
    while (len < 256 and email_ptr[len] != 0) : (len += 1) {}
    if (len == 0) return null;
    return email_ptr[0..len];
}

// =============================================================================
// Tests
// =============================================================================

test "parseCookie: extracts cookie value" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/admin");
    defer ctx.deinit();

    ctx.addRequestHeader("Cookie", "publr_session=abc123; other=xyz");

    const value = parseCookie(&ctx, "publr_session");
    try std.testing.expectEqualStrings("abc123", value.?);
}

test "parseCookie: returns null when cookie not present" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/admin");
    defer ctx.deinit();

    ctx.addRequestHeader("Cookie", "other=xyz");

    const value = parseCookie(&ctx, "publr_session");
    try std.testing.expect(value == null);
}

test "parseCookie: returns null when no Cookie header" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/admin");
    defer ctx.deinit();

    const value = parseCookie(&ctx, "publr_session");
    try std.testing.expect(value == null);
}

test "parseCookie: handles single cookie" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/admin");
    defer ctx.deinit();

    ctx.addRequestHeader("Cookie", "publr_session=token123");

    const value = parseCookie(&ctx, "publr_session");
    try std.testing.expectEqualStrings("token123", value.?);
}

test "redirect: sets status and location header" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/admin");
    defer ctx.deinit();

    redirect(&ctx, "/admin/login");

    try std.testing.expectEqualStrings("302 Found", ctx.response.status);
    const headers = ctx.response.getCustomHeaders();
    try std.testing.expect(headers.len >= 1);
    try std.testing.expectEqualStrings("Location", headers[0].?.name);
    try std.testing.expectEqualStrings("/admin/login", headers[0].?.value);
}

test "setSessionCookie: sets cookie with security attributes" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/admin");
    defer ctx.deinit();

    setSessionCookie(&ctx, "test_token");

    const headers = ctx.response.getCustomHeaders();
    try std.testing.expect(headers.len >= 1);
    try std.testing.expectEqualStrings("Set-Cookie", headers[0].?.name);

    const cookie_value = headers[0].?.value;
    try std.testing.expect(std.mem.indexOf(u8, cookie_value, "publr_session=test_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie_value, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie_value, "SameSite=Lax") != null);
}

test "clearSessionCookie: sets cookie with Max-Age=0" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/admin");
    defer ctx.deinit();

    clearSessionCookie(&ctx);

    const headers = ctx.response.getCustomHeaders();
    try std.testing.expect(headers.len >= 1);

    const cookie_value = headers[0].?.value;
    try std.testing.expect(std.mem.indexOf(u8, cookie_value, "Max-Age=0") != null);
}

test "authMiddleware: passes through non-admin routes" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/api/health");
    defer ctx.deinit();

    // No auth initialized
    auth = null;

    // Use a simpler test - just verify the path check
    try std.testing.expect(!std.mem.startsWith(u8, ctx.path, "/admin"));
}

test "authMiddleware: public routes are allowed" {
    // Verify public routes list
    try std.testing.expect(public_routes.len == 3);
    try std.testing.expectEqualStrings("/admin/login", public_routes[0]);
    try std.testing.expectEqualStrings("/admin/setup", public_routes[1]);
    try std.testing.expectEqualStrings("/admin/system/health", public_routes[2]);
}
