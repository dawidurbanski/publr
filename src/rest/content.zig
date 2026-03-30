const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const cms = @import("cms");
const schemas = @import("schemas");
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

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

    inline for (schemas.content_types) |CT| {
        if (std.mem.eql(u8, type_id, CT.type_id)) {
            const db = session.auth.db;
            const items = cms.listEntries(CT, ctx.allocator, db, .{
                .status = status,
                .limit = limit,
                .offset = offset,
                .order_by = order_by,
                .order_dir = order_dir,
            }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "list_failed", "Failed to list entries");
            const total = cms.countEntries(CT, db, .{ .status = status }) catch 0;

            return json.paged(ctx, items, .{
                .total = total,
                .limit = limit,
                .offset = offset,
            });
        }
    }

    return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
}

fn handleGet(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type");
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");

    inline for (schemas.content_types) |CT| {
        if (std.mem.eql(u8, type_id, CT.type_id)) {
            const item = cms.getEntry(CT, ctx.allocator, session.auth.db, entry_id) catch null;
            if (item == null) return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Entry not found");
            return json.ok(ctx, item.?);
        }
    }

    return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
}

fn handleCreate(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type");

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();

    inline for (schemas.content_types) |CT| {
        if (std.mem.eql(u8, type_id, CT.type_id)) {
            const fields = getFieldsObject(parsed.value) orelse return json.errorEnvelope(ctx, "422 Unprocessable Entity", "validation_error", "Missing fields object");
            var parsed_data = parseCreateData(CT, ctx.allocator, fields) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "validation_error", "Invalid fields");
            defer parsed_data.deinit();
            const status = if (parsed.value == .object and parsed.value.object.get("status") != null and parsed.value.object.get("status").? == .string) parsed.value.object.get("status").?.string else "draft";
            const locale = if (parsed.value == .object and parsed.value.object.get("locale") != null and parsed.value.object.get("locale").? == .string) parsed.value.object.get("locale").?.string else null;

            const entry = cms.saveEntry(CT, ctx.allocator, session.auth.db, null, parsed_data.value, .{
                .author_id = session.user.id,
                .status = status,
                .locale = locale,
            }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "save_failed", "Failed to save entry");

            return json.created(ctx, entry);
        }
    }

    return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
}

fn handleUpdate(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const type_id = ctx.param("type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing type");
    const entry_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing id");

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();

    inline for (schemas.content_types) |CT| {
        if (std.mem.eql(u8, type_id, CT.type_id)) {
            const existing = (cms.getEntry(CT, ctx.allocator, session.auth.db, entry_id) catch null) orelse
                return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Entry not found");

            const fields = getFieldsObject(parsed.value) orelse return json.errorEnvelope(ctx, "422 Unprocessable Entity", "validation_error", "Missing fields object");
            const merged = applyPatch(CT, existing.data, fields) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "validation_error", "Invalid fields");

            const updated = cms.saveEntry(CT, ctx.allocator, session.auth.db, entry_id, merged, .{
                .author_id = session.user.id,
            }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "save_failed", "Failed to update entry");

            return json.ok(ctx, updated);
        }
    }

    return json.errorEnvelope(ctx, "404 Not Found", "unknown_type", "Unknown content type");
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

fn parseCreateData(comptime CT: type, allocator: std.mem.Allocator, fields: std.json.Value) !std.json.Parsed(CT.Data) {
    return CT.parseDataFromValue(allocator, fields);
}

fn applyPatch(comptime CT: type, base: CT.Data, fields: std.json.Value) !CT.Data {
    if (fields != .object) return error.InvalidPatch;
    var out = base;

    var iter = fields.object.iterator();
    while (iter.next()) |kv| {
        var matched = false;
        inline for (std.meta.fields(CT.Data)) |df| {
            if (std.mem.eql(u8, kv.key_ptr.*, df.name)) {
                matched = true;
                @field(out, df.name) = try convertJsonValue(df.type, kv.value_ptr.*);
            }
        }
        if (!matched) return error.UnknownField;
    }
    return out;
}

fn convertJsonValue(comptime T: type, value: std.json.Value) !T {
    if (T == []const u8) {
        if (value == .string) return value.string;
        return error.InvalidType;
    }
    if (T == ?[]const u8) {
        if (value == .null) return null;
        if (value == .string) return value.string;
        return error.InvalidType;
    }
    if (T == bool) {
        if (value == .bool) return value.bool;
        return error.InvalidType;
    }
    if (T == ?bool) {
        if (value == .null) return null;
        if (value == .bool) return value.bool;
        return error.InvalidType;
    }
    if (T == i64) {
        if (value == .integer) return @intCast(value.integer);
        return error.InvalidType;
    }
    if (T == ?i64) {
        if (value == .null) return null;
        if (value == .integer) return @intCast(value.integer);
        return error.InvalidType;
    }
    return error.UnsupportedType;
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
