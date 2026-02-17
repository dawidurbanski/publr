const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const auth_mod = @import("auth");
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/users", handleListUsers);
    try router.post("/api/users", handleCreateUser);
    try router.get("/api/users/:id", handleGetUser);
    try router.put("/api/users/:id", handleUpdateUser);
    try router.delete("/api/users/:id", handleDeleteUser);
}

fn handleListUsers(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const users = session.auth.listUsers() catch return json.errorEnvelope(ctx, "500 Internal Server Error", "list_failed", "Failed to list users");
    defer freeUsers(session.auth, users);

    try json.ok(ctx, users);
}

fn handleCreateUser(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");

    const email_value = parsed.value.object.get("email") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing email");
    const name_value = parsed.value.object.get("name") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing name");
    const password_value = parsed.value.object.get("password") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing password");

    if (email_value != .string or name_value != .string or password_value != .string) {
        return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "email, name, and password must be strings");
    }

    const user_id = session.auth.createUser(email_value.string, name_value.string, password_value.string) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "create_failed", "Failed to create user");
    defer ctx.allocator.free(user_id);

    try json.created(ctx, .{
        .id = user_id,
        .email = email_value.string,
        .display_name = name_value.string,
    });
}

fn handleGetUser(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const user_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing user id");

    var user = (session.auth.getUserById(user_id) catch null) orelse return json.errorEnvelope(ctx, "404 Not Found", "not_found", "User not found");
    defer session.auth.freeUser(&user);

    try json.ok(ctx, user);
}

fn handleUpdateUser(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const user_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing user id");

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");

    var current = (session.auth.getUserById(user_id) catch null) orelse return json.errorEnvelope(ctx, "404 Not Found", "not_found", "User not found");
    defer session.auth.freeUser(&current);

    var email = current.email;
    var display_name = current.display_name;
    var password: ?[]const u8 = null;

    if (parsed.value.object.get("email")) |email_value| {
        if (email_value != .string) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "email must be string");
        email = email_value.string;
    }
    if (parsed.value.object.get("name")) |name_value| {
        if (name_value != .string) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "name must be string");
        display_name = name_value.string;
    }
    if (parsed.value.object.get("password")) |password_value| {
        if (password_value == .null) {
            password = null;
        } else if (password_value == .string) {
            password = password_value.string;
        } else {
            return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "password must be string or null");
        }
    }

    session.auth.updateUser(user_id, email, display_name, password) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "update_failed", "Failed to update user");

    var updated = (session.auth.getUserById(user_id) catch null) orelse return json.errorEnvelope(ctx, "404 Not Found", "not_found", "User not found");
    defer session.auth.freeUser(&updated);
    try json.ok(ctx, updated);
}

fn handleDeleteUser(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const user_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing user id");

    session.auth.deleteUser(user_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "delete_failed", "Failed to delete user");
    json.noContent(ctx);
}

fn freeUsers(auth: *auth_mod.Auth, users: []auth_mod.Auth.User) void {
    for (users) |*user| auth.freeUser(user);
    auth.allocator.free(users);
}

test "rest user: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 5), router.routes.items.len);
}

test "rest user endpoints" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    var list = try ac.client.request("GET", "/api/users", null, ac.token, .{});
    defer list.deinit();
    try helpers.expectStatus(list, 200);

    var create_user = try ac.client.request(
        "POST",
        "/api/users",
        "{\"email\":\"rest-user@test.local\",\"name\":\"REST User\",\"password\":\"secret123\"}",
        ac.token,
        .{ .content_type = "application/json" },
    );
    defer create_user.deinit();
    try helpers.expectStatus(create_user, 201);
    const user_id = try helpers.extractDataId(create_user.body);
    defer std.testing.allocator.free(user_id);

    const get_path = try std.fmt.allocPrint(std.testing.allocator, "/api/users/{s}", .{user_id});
    defer std.testing.allocator.free(get_path);
    var get = try ac.client.request("GET", get_path, null, ac.token, .{});
    defer get.deinit();
    try helpers.expectStatus(get, 200);

    const update_path = try std.fmt.allocPrint(std.testing.allocator, "/api/users/{s}", .{user_id});
    defer std.testing.allocator.free(update_path);
    var update = try ac.client.request("PUT", update_path, "{\"name\":\"REST User Updated\"}", ac.token, .{ .content_type = "application/json" });
    defer update.deinit();
    try helpers.expectStatus(update, 200);

    const delete_path = try std.fmt.allocPrint(std.testing.allocator, "/api/users/{s}", .{user_id});
    defer std.testing.allocator.free(delete_path);
    var delete = try ac.client.request("DELETE", delete_path, null, ac.token, .{});
    defer delete.deinit();
    try helpers.expectStatus(delete, 204);
}

test "rest user: public API coverage" {
    _ = registerRoutes;
}
