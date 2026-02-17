const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const registry = @import("schema_registry");
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/schema", handleListSchema);
    try router.get("/api/schema/:type", handleGetSchema);
}

fn handleListSchema(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    try json.ok(ctx, registry.registered_types);
}

fn handleGetSchema(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type id");

    const info = registry.getTypeInfo(type_id) orelse return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Schema not found");
    try json.ok(ctx, info);
}

test "rest schema: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 2), router.routes.items.len);
}

test "rest schema endpoints" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    var list = try ac.client.request("GET", "/api/schema", null, ac.token, .{});
    defer list.deinit();
    try helpers.expectStatus(list, 200);
    try helpers.expectBodyContains(list.body, "\"post\"");

    var get = try ac.client.request("GET", "/api/schema/post", null, ac.token, .{});
    defer get.deinit();
    try helpers.expectStatus(get, 200);
}

test "rest schema: public API coverage" {
    _ = registerRoutes;
}
