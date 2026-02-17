const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const auth_middleware = @import("auth_middleware");
const auth_mod = @import("auth");
const Db = @import("db").Db;
const json = @import("rest_json");

pub const SessionUser = struct {
    auth: *auth_mod.Auth,
    user: auth_mod.Auth.User,

    pub fn deinit(self: *SessionUser) void {
        self.auth.freeUser(&self.user);
    }
};

pub fn registerRoutes(router: *Router) !void {
    try router.post("/api/auth/login", handleLogin);
    try router.post("/api/auth/logout", handleLogout);
    try router.get("/api/auth/me", handleMe);
}

pub fn authPtr() ?*auth_mod.Auth {
    return auth_middleware.auth;
}

pub fn dbPtr() ?*Db {
    if (auth_middleware.auth) |auth| return auth.db;
    return null;
}

pub fn requireUser(ctx: *Context) !SessionUser {
    const auth = auth_middleware.auth orelse return error.Unauthorized;
    const token = bearerToken(ctx) orelse return error.Unauthorized;
    const user = auth.validateSession(token) catch return error.Unauthorized;
    return .{ .auth = auth, .user = user };
}

fn handleLogin(ctx: *Context) !void {
    const auth = auth_middleware.auth orelse return json.errorEnvelope(ctx, "500 Internal Server Error", "auth_unavailable", "Auth not initialized");
    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();

    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");
    const email = parsed.value.object.get("email") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing email");
    const password = parsed.value.object.get("password") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing password");
    if (email != .string or password != .string) {
        return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "email and password must be strings");
    }

    const user_id = auth.authenticateUser(email.string, password.string) catch {
        return json.errorEnvelope(ctx, "401 Unauthorized", "invalid_credentials", "Invalid credentials");
    };
    defer ctx.allocator.free(user_id);

    const token = auth.createSession(user_id) catch {
        return json.errorEnvelope(ctx, "500 Internal Server Error", "session_error", "Failed to create session");
    };
    defer ctx.allocator.free(token);

    var user = (auth.getUserById(user_id) catch null) orelse return json.errorEnvelope(ctx, "401 Unauthorized", "user_not_found", "User not found");
    defer auth.freeUser(&user);

    try json.ok(ctx, .{
        .token = token,
        .user = user,
    });
}

fn handleLogout(ctx: *Context) !void {
    const auth = auth_middleware.auth orelse return json.errorEnvelope(ctx, "500 Internal Server Error", "auth_unavailable", "Auth not initialized");
    const token = bearerToken(ctx) orelse return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Missing bearer token");
    auth.invalidateSession(token) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Invalid session");
    try json.ok(ctx, .{ .logged_out = true });
}

fn handleMe(ctx: *Context) !void {
    var session = requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    try json.ok(ctx, session.user);
}

fn bearerToken(ctx: *const Context) ?[]const u8 {
    const header = ctx.getRequestHeader("Authorization") orelse return null;
    if (!std.mem.startsWith(u8, header, "Bearer ")) return null;
    return header["Bearer ".len..];
}

test "rest auth: registerRoutes and auth pointers" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 3), router.routes.items.len);

    try std.testing.expect(authPtr() == null);
    try std.testing.expect(dbPtr() == null);
}

test "rest auth: requireUser unauthorized when auth is missing" {
    var ctx: Context = undefined;
    try std.testing.expectError(error.Unauthorized, requireUser(&ctx));
}

test "rest auth endpoints: login me logout and invalid password" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");
    var client = try helpers.rest_client.RestTestClient.init(std.testing.allocator);
    defer client.deinit();

    const token = try helpers.login(&client);

    var me = try client.request("GET", "/api/auth/me", null, token, .{});
    defer me.deinit();
    try helpers.expectStatus(me, 200);

    var logout = try client.request("POST", "/api/auth/logout", null, token, .{});
    defer logout.deinit();
    try helpers.expectStatus(logout, 200);

    var me_after_logout = try client.request("GET", "/api/auth/me", null, token, .{});
    defer me_after_logout.deinit();
    try helpers.expectStatus(me_after_logout, 401);

    var bad_login = try client.request(
        "POST",
        "/api/auth/login",
        "{\"email\":\"admin@test.local\",\"password\":\"wrong\"}",
        null,
        .{ .content_type = "application/json" },
    );
    defer bad_login.deinit();
    try helpers.expectStatus(bad_login, 401);
}

test "rest auth: public API coverage" {
    _ = registerRoutes;
    _ = authPtr;
    _ = dbPtr;
    _ = requireUser;
}
