const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const cms = @import("cms");
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/versions/:vid", handleGetVersion);
    try router.get("/api/versions/:v1/diff/:v2", handleDiffVersions);
}

fn handleGetVersion(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const vid = ctx.param("vid") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing version id");
    const version = cms.getVersion(ctx.allocator, session.auth.db, vid) catch null;
    if (version == null) return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Version not found");
    try json.ok(ctx, version.?);
}

fn handleDiffVersions(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const v1_id = ctx.param("v1") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing v1");
    const v2_id = ctx.param("v2") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing v2");

    const v1 = cms.getVersion(ctx.allocator, session.auth.db, v1_id) catch null;
    const v2 = cms.getVersion(ctx.allocator, session.auth.db, v2_id) catch null;
    if (v1 == null or v2 == null) return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Version not found");

    const diff = cms.compareVersionFields(ctx.allocator, v1.?.data, v2.?.data) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "diff_failed", "Failed to diff versions");
    try json.ok(ctx, diff);
}

test "rest version: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 2), router.routes.items.len);
}

test "rest version endpoints" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    const slug = try helpers.unique("rest-version");
    defer std.testing.allocator.free(slug);
    const entry_id = try helpers.createPost(&ac.client, ac.token, "Version Base", slug, "v1");
    defer std.testing.allocator.free(entry_id);

    const update_path = try std.fmt.allocPrint(std.testing.allocator, "/api/content/post/{s}", .{entry_id});
    defer std.testing.allocator.free(update_path);
    var update = try ac.client.request("PUT", update_path, "{\"fields\":{\"title\":\"Version Updated\"}}", ac.token, .{ .content_type = "application/json" });
    defer update.deinit();
    try helpers.expectStatus(update, 200);

    const ids = try helpers.versionPairFromApi(&ac.client, ac.token, entry_id);
    defer std.testing.allocator.free(ids.latest);
    defer std.testing.allocator.free(ids.previous);

    const version_get_path = try std.fmt.allocPrint(std.testing.allocator, "/api/versions/{s}", .{ids.latest});
    defer std.testing.allocator.free(version_get_path);
    var get_version = try ac.client.request("GET", version_get_path, null, ac.token, .{});
    defer get_version.deinit();
    try helpers.expectStatus(get_version, 200);

    const diff_path = try std.fmt.allocPrint(std.testing.allocator, "/api/versions/{s}/diff/{s}", .{ ids.previous, ids.latest });
    defer std.testing.allocator.free(diff_path);
    var diff = try ac.client.request("GET", diff_path, null, ac.token, .{});
    defer diff.deinit();
    try helpers.expectStatus(diff, 200);
}

test "rest version: public API coverage" {
    _ = registerRoutes;
}
