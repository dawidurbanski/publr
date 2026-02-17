const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const cms = @import("cms");
const core_time = @import("core_time");
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/releases", handleList);
    try router.post("/api/releases", handleCreate);
    try router.get("/api/releases/:id", handleGet);
    try router.post("/api/releases/:id/entries", handleAddEntry);
    try router.delete("/api/releases/:id/entries/:eid", handleRemoveEntry);
    try router.post("/api/releases/:id/publish", handlePublish);
    try router.post("/api/releases/:id/revert", handleRevert);
    try router.post("/api/releases/:id/schedule", handleSchedule);
    try router.delete("/api/releases/:id", handleArchive);
}

fn handleList(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const status = json.queryParam(ctx, "status");
    const limit = if (json.queryParam(ctx, "limit")) |v| std.fmt.parseInt(u32, v, 10) catch 50 else 50;
    const items = cms.listReleases(ctx.allocator, session.auth.db, .{
        .status = status,
        .limit = limit,
    }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "list_failed", "Failed to list releases");

    try json.ok(ctx, items);
}

fn handleCreate(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");
    const name_val = parsed.value.object.get("name") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing name");
    if (name_val != .string) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "name must be string");

    const release_id = cms.createPendingRelease(session.auth.db, name_val.string, session.user.id) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "create_failed", "Failed to create release");
    try json.created(ctx, .{ .id = release_id, .name = name_val.string });
}

fn handleGet(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const release_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing release id");
    const detail = cms.getRelease(ctx.allocator, session.auth.db, release_id) catch null;
    if (detail == null) return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Release not found");
    try json.ok(ctx, detail.?);
}

fn handleAddEntry(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const release_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing release id");
    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");
    const entry = parsed.value.object.get("entry_id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing entry_id");
    if (entry != .string) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "entry_id must be string");

    const fields_json = if (parsed.value.object.get("fields")) |fields| blk: {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(ctx.allocator);
        buf.writer(ctx.allocator).print("{f}", .{std.json.fmt(fields, .{})}) catch break :blk null;
        break :blk buf.toOwnedSlice(ctx.allocator) catch null;
    } else null;
    defer if (fields_json) |f| ctx.allocator.free(f);

    cms.addToRelease(session.auth.db, release_id, entry.string, fields_json) catch return json.errorEnvelope(ctx, "409 Conflict", "conflict", "Failed to add entry");
    try json.ok(ctx, .{ .added = true });
}

fn handleRemoveEntry(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const release_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing release id");
    const entry_id = ctx.param("eid") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing entry id");
    cms.removeFromRelease(session.auth.db, release_id, entry_id) catch return json.errorEnvelope(ctx, "409 Conflict", "conflict", "Failed to remove entry");
    json.noContent(ctx);
}

fn handlePublish(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const release_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing release id");
    cms.publishBatchRelease(ctx.allocator, session.auth.db, release_id) catch return json.errorEnvelope(ctx, "409 Conflict", "conflict", "Failed to publish release");
    try json.ok(ctx, .{ .published = true });
}

fn handleRevert(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const release_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing release id");
    cms.revertRelease(session.auth.db, release_id, session.user.id) catch return json.errorEnvelope(ctx, "409 Conflict", "conflict", "Failed to revert release");
    try json.ok(ctx, .{ .reverted = true });
}

fn handleSchedule(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const release_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing release id");
    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");
    const ts_val = parsed.value.object.get("scheduled_for") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing scheduled_for");
    if (ts_val != .string) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "scheduled_for must be ISO-8601 string");
    const ts = core_time.parseIso8601ToUnix(ts_val.string) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "validation_error", "Invalid timestamp");

    cms.scheduleRelease(session.auth.db, release_id, ts) catch return json.errorEnvelope(ctx, "409 Conflict", "conflict", "Failed to schedule release");
    try json.ok(ctx, .{ .scheduled = true, .scheduled_for = ts });
}

fn handleArchive(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const release_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing release id");
    cms.archiveRelease(session.auth.db, release_id) catch return json.errorEnvelope(ctx, "409 Conflict", "conflict", "Failed to archive release");
    try json.ok(ctx, .{ .archived = true });
}

test "rest release: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 9), router.routes.items.len);
}

test "rest release endpoints including schedule" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    var list_initial = try ac.client.request("GET", "/api/releases", null, ac.token, .{});
    defer list_initial.deinit();
    try helpers.expectStatus(list_initial, 200);

    const slug = try helpers.unique("rest-release-entry");
    defer std.testing.allocator.free(slug);
    const entry_id = try helpers.createPost(&ac.client, ac.token, "Release Entry", slug, "body");
    defer std.testing.allocator.free(entry_id);

    const release_id = try helpers.createReleaseApi(&ac.client, ac.token, "REST Batch");
    defer std.testing.allocator.free(release_id);

    const add_path = try std.fmt.allocPrint(std.testing.allocator, "/api/releases/{s}/entries", .{release_id});
    defer std.testing.allocator.free(add_path);
    const add_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"entry_id\":\"{s}\",\"fields\":[\"title\"]}}", .{entry_id});
    defer std.testing.allocator.free(add_body);

    var add = try ac.client.request("POST", add_path, add_body, ac.token, .{ .content_type = "application/json" });
    defer add.deinit();
    try helpers.expectStatus(add, 200);

    const remove_path = try std.fmt.allocPrint(std.testing.allocator, "/api/releases/{s}/entries/{s}", .{ release_id, entry_id });
    defer std.testing.allocator.free(remove_path);
    var remove = try ac.client.request("DELETE", remove_path, null, ac.token, .{});
    defer remove.deinit();
    try helpers.expectStatus(remove, 204);

    var add_again = try ac.client.request("POST", add_path, add_body, ac.token, .{ .content_type = "application/json" });
    defer add_again.deinit();
    try helpers.expectStatus(add_again, 200);

    const publish_path = try std.fmt.allocPrint(std.testing.allocator, "/api/releases/{s}/publish", .{release_id});
    defer std.testing.allocator.free(publish_path);
    var publish = try ac.client.request("POST", publish_path, null, ac.token, .{});
    defer publish.deinit();
    try helpers.expectStatus(publish, 200);

    const revert_path = try std.fmt.allocPrint(std.testing.allocator, "/api/releases/{s}/revert", .{release_id});
    defer std.testing.allocator.free(revert_path);
    var revert = try ac.client.request("POST", revert_path, null, ac.token, .{});
    defer revert.deinit();
    try helpers.expectStatus(revert, 200);

    const scheduled_id = try helpers.createReleaseApi(&ac.client, ac.token, "REST Scheduled");
    defer std.testing.allocator.free(scheduled_id);
    const schedule_path = try std.fmt.allocPrint(std.testing.allocator, "/api/releases/{s}/schedule", .{scheduled_id});
    defer std.testing.allocator.free(schedule_path);
    var schedule = try ac.client.request(
        "POST",
        schedule_path,
        "{\"scheduled_for\":\"2030-01-01T12:00:00Z\"}",
        ac.token,
        .{ .content_type = "application/json" },
    );
    defer schedule.deinit();
    try helpers.expectStatus(schedule, 200);

    const archive_path = try std.fmt.allocPrint(std.testing.allocator, "/api/releases/{s}", .{release_id});
    defer std.testing.allocator.free(archive_path);
    var archive = try ac.client.request("DELETE", archive_path, null, ac.token, .{});
    defer archive.deinit();
    try helpers.expectStatus(archive, 200);
}

test "rest release: public API coverage" {
    _ = registerRoutes;
}
