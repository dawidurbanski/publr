const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const cms = @import("cms");
const schemas = @import("schemas");
const schema_registry = @import("schema_registry");
const json = @import("json.zig");
const rest_auth = @import("auth.zig");

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/content/:type", handleList);
    try router.post("/api/content/:type", handleCreate);
    try router.get("/api/content/:type/:id", handleGet);
    try router.put("/api/content/:type/:id", handleUpdate);
    try router.delete("/api/content/:type/:id", handleDelete);
    try router.post("/api/content/:type/:id/publish", handlePublish);
    try router.post("/api/content/:type/:id/unpublish", handleUnpublish);
    try router.post("/api/content/:type/:id/discard", handleDiscard);
    try router.post("/api/content/:type/:id/archive", handleArchive);
    try router.get("/api/content/:type/:id/versions", handleVersions);
    try router.post("/api/content/:type/:id/restore/:vid", handleRestore);

    // Workflow stubs
    try router.get("/api/content/:type/:id/workflow", handleWorkflowStub);
    try router.post("/api/content/:type/:id/approve", handleWorkflowStub);
    try router.post("/api/content/:type/:id/reject", handleWorkflowStub);
}

fn handleList(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type");
    const status = json.queryParam(ctx, "status");
    const limit = if (json.queryParam(ctx, "limit")) |v| std.fmt.parseInt(u32, v, 10) catch 20 else 20;
    const offset = if (json.queryParam(ctx, "offset")) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0;
    const order_by = json.queryParam(ctx, "order_by") orelse "created_at";
    const order_dir = if (json.queryParam(ctx, "order_dir")) |dir|
        if (std.mem.eql(u8, dir, "asc")) cms.OrderDir.asc else cms.OrderDir.desc
    else
        cms.OrderDir.desc;

    if (schema_registry.findById(type_id) == null) {
        return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
    }

    const db = session.auth.db;
    const items = cms.query.listEntries(ctx.allocator, db, type_id, .{
        .status = status,
        .limit = limit,
        .offset = offset,
        .order_by = order_by,
        .order_dir = order_dir,
    }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "list_failed", "Failed to list entries");
    const total = cms.query.countEntries(db, type_id, .{ .status = status }) catch 0;

    return json.paged(ctx, items, .{
        .total = total,
        .limit = limit,
        .offset = offset,
    });
}

fn handleGet(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type");
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");

    if (schema_registry.findById(type_id) == null) {
        return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
    }

    const item = cms.query.getEntry(ctx.allocator, session.auth.db, type_id, entry_id) catch null;
    if (item == null) return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Entry not found");
    return json.ok(ctx, item.?);
}

fn handleCreate(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type");

    if (schema_registry.findById(type_id) == null) {
        return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
    }

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();

    const fields = getFieldsObject(parsed.value) orelse return json.errorEnvelope(ctx, "422 Unprocessable Entity", "validation_error", "Missing fields object");
    const data_json = stringifyJsonValue(ctx.allocator, fields) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "save_failed", "Failed to serialize fields");
    defer ctx.allocator.free(data_json);

    const status = if (parsed.value == .object and parsed.value.object.get("status") != null and parsed.value.object.get("status").? == .string) parsed.value.object.get("status").?.string else "draft";
    const locale = if (parsed.value == .object and parsed.value.object.get("locale") != null and parsed.value.object.get("locale").? == .string) parsed.value.object.get("locale").?.string else null;

    var entry = cms.saveEntry(ctx.allocator, session.auth.db, type_id, null, data_json, .{
        .author_id = session.user.id,
        .status = status,
        .locale = locale,
    }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "save_failed", "Failed to save entry");
    defer entry.deinit(ctx.allocator);

    return json.created(ctx, entry);
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.writer(allocator).print("{f}", .{std.json.fmt(value, .{})});
    return buf.toOwnedSlice(allocator);
}

fn handleUpdate(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type");
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");

    if (schema_registry.findById(type_id) == null) {
        return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
    }

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();

    // Merge: pull the existing entry's data JSON, overlay the patch fields,
    // re-serialize, and let saveEntry handle the rest. Avoids
    // needing per-CT applyPatch.
    var existing = (cms.query.getEntry(ctx.allocator, session.auth.db, type_id, entry_id) catch null) orelse
        return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Entry not found");
    defer existing.deinit(ctx.allocator);

    const patch = getFieldsObject(parsed.value) orelse return json.errorEnvelope(ctx, "422 Unprocessable Entity", "validation_error", "Missing fields object");

    const merged_json = mergeFieldsJson(ctx.allocator, existing.data, patch) catch
        return json.errorEnvelope(ctx, "500 Internal Server Error", "save_failed", "Failed to merge fields");
    defer ctx.allocator.free(merged_json);

    var updated = cms.saveEntry(ctx.allocator, session.auth.db, type_id, entry_id, merged_json, .{
        .author_id = session.user.id,
    }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "save_failed", "Failed to update entry");
    defer updated.deinit(ctx.allocator);

    return json.ok(ctx, updated);
}

/// Overlay `patch` (a JSON object) on top of `existing` (a FieldMap from
/// the current entry) and return the merged JSON as an owned string.
fn mergeFieldsJson(
    allocator: std.mem.Allocator,
    existing: cms.query.FieldMap,
    patch: std.json.Value,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var first = true;

    // First, fields from the patch (these win on conflict).
    if (patch == .object) {
        var pit = patch.object.iterator();
        while (pit.next()) |kv| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\":{f}", .{ kv.key_ptr.*, std.json.fmt(kv.value_ptr.*, .{}) });
        }
    }

    // Then any existing fields the patch didn't touch.
    var it = existing.inner.iterator();
    while (it.next()) |kv| {
        if (patch == .object and patch.object.contains(kv.key_ptr.*)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        const name = kv.key_ptr.*;
        switch (kv.value_ptr.*) {
            .text => |s| try w.print("\"{s}\":{f}", .{ name, std.json.fmt(s, .{}) }),
            .int => |n| try w.print("\"{s}\":{d}", .{ name, n }),
            .real => |n| try w.print("\"{s}\":{d}", .{ name, n }),
            .bool_ => |b| try w.print("\"{s}\":{s}", .{ name, if (b) "true" else "false" }),
            .datetime => |t| try w.print("\"{s}\":{d}", .{ name, t }),
            .json => |v| try w.print("\"{s}\":{f}", .{ name, std.json.fmt(v, .{}) }),
            .null_ => try w.print("\"{s}\":null", .{name}),
        }
    }

    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

fn handleDelete(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");
    cms.deleteEntry(session.auth.db, entry_id) catch return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Entry not found");
    json.noContent(ctx);
}

fn handlePublish(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");

    const parsed = json.parseJsonBody(ctx) catch null;
    defer if (parsed) |p| p.deinit();
    const fields = if (parsed) |p| extractFieldsArrayJson(ctx.allocator, p.value) else null;
    defer if (fields) |f| ctx.allocator.free(f);

    cms.publishEntry(ctx.allocator, session.auth.db, entry_id, session.user.id, fields) catch {
        return json.errorEnvelope(ctx, "500 Internal Server Error", "publish_failed", "Failed to publish entry");
    };
    try json.ok(ctx, .{ .published = true, .id = entry_id });
}

fn handleUnpublish(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");
    cms.unpublishEntry(session.auth.db, entry_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "unpublish_failed", "Failed to unpublish entry");
    try json.ok(ctx, .{ .unpublished = true, .id = entry_id });
}

fn handleDiscard(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");
    cms.discardToPublished(session.auth.db, entry_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "discard_failed", "Failed to discard entry");
    try json.ok(ctx, .{ .discarded = true, .id = entry_id });
}

fn handleArchive(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");
    cms.archiveEntry(session.auth.db, entry_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "archive_failed", "Failed to archive entry");
    try json.ok(ctx, .{ .archived = true, .id = entry_id });
}

fn handleVersions(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");
    const limit = if (json.queryParam(ctx, "limit")) |v| std.fmt.parseInt(u32, v, 10) catch 20 else 20;
    const items = cms.listVersions(ctx.allocator, session.auth.db, entry_id, .{ .limit = limit }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "versions_failed", "Failed to list versions");
    try json.ok(ctx, items);
}

fn handleRestore(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");
    const version_id = ctx.param("vid") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing version id");
    cms.restoreVersion(ctx.allocator, session.auth.db, entry_id, version_id, session.user.id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "restore_failed", "Failed to restore version");
    try json.ok(ctx, .{ .restored = true, .id = entry_id, .version_id = version_id });
}

fn handleWorkflowStub(ctx: *Context) !void {
    try json.errorEnvelope(ctx, "501 Not Implemented", "not_implemented", "Workflow API is not implemented yet");
}

/// Look up an entry's slug by trying each content type.
fn getFieldsObject(value: std.json.Value) ?std.json.Value {
    if (value == .object) {
        if (value.object.get("fields")) |fields| {
            return fields;
        }
    }
    return value;
}

fn extractFieldsArrayJson(allocator: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const fields = value.object.get("fields") orelse return null;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    buf.writer(allocator).print("{f}", .{std.json.fmt(fields, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

test "rest content: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 14), router.routes.items.len);
}

test "rest content endpoints lifecycle, pagination, and validation errors" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    var list_empty = try ac.client.request("GET", "/api/content/post?limit=5&offset=0", null, ac.token, .{});
    defer list_empty.deinit();
    try helpers.expectStatus(list_empty, 200);
    try helpers.expectBodyContains(list_empty.body, "\"meta\"");

    const title = try helpers.unique("rest-content-title");
    defer std.testing.allocator.free(title);
    const slug = try helpers.unique("rest-content-slug");
    defer std.testing.allocator.free(slug);

    const entry_id = try helpers.createPost(&ac.client, ac.token, title, slug, "rest content body");
    defer std.testing.allocator.free(entry_id);

    const get_path = try std.fmt.allocPrint(std.testing.allocator, "/api/content/post/{s}", .{entry_id});
    defer std.testing.allocator.free(get_path);
    var get = try ac.client.request("GET", get_path, null, ac.token, .{});
    defer get.deinit();
    try helpers.expectStatus(get, 200);

    var update = try ac.client.request("PUT", get_path, "{\"fields\":{\"title\":\"Updated REST Title\"}}", ac.token, .{ .content_type = "application/json" });
    defer update.deinit();
    try helpers.expectStatus(update, 200);

    const publish_path = try std.fmt.allocPrint(std.testing.allocator, "/api/content/post/{s}/publish", .{entry_id});
    defer std.testing.allocator.free(publish_path);
    var publish = try ac.client.request("POST", publish_path, null, ac.token, .{});
    defer publish.deinit();
    try helpers.expectStatus(publish, 200);

    const unpublish_path = try std.fmt.allocPrint(std.testing.allocator, "/api/content/post/{s}/unpublish", .{entry_id});
    defer std.testing.allocator.free(unpublish_path);
    var unpublish = try ac.client.request("POST", unpublish_path, null, ac.token, .{});
    defer unpublish.deinit();
    try helpers.expectStatus(unpublish, 200);

    var invalid_fields = try ac.client.request(
        "POST",
        "/api/content/post",
        "{\"fields\":{\"title\":123}}",
        ac.token,
        .{ .content_type = "application/json" },
    );
    defer invalid_fields.deinit();
    try helpers.expectStatus(invalid_fields, 422);
}

test "rest content: public API coverage" {
    _ = registerRoutes;
}
