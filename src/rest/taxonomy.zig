const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const taxonomy = @import("taxonomy");
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/taxonomies/:tax/terms", handleListTerms);
    try router.post("/api/taxonomies/:tax/terms", handleCreateTerm);
    try router.put("/api/terms/:id", handleUpdateTerm);
    try router.delete("/api/terms/:id", handleDeleteTerm);
}

fn handleListTerms(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const taxonomy_id = ctx.param("tax") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing taxonomy id");

    const terms = taxonomy.listTerms(ctx.allocator, session.auth.db, taxonomy_id) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "list_failed", "Failed to list terms");
    defer freeTerms(ctx.allocator, terms);
    try json.ok(ctx, terms);
}

fn handleCreateTerm(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const taxonomy_id = ctx.param("tax") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing taxonomy id");

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");
    const name_value = parsed.value.object.get("name") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing name");
    if (name_value != .string) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "name must be string");

    const parent_id = if (parsed.value.object.get("parent_id")) |value| blk: {
        if (value == .null) break :blk null;
        if (value == .string) break :blk value.string;
        return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "parent_id must be string or null");
    } else null;

    const term = taxonomy.createTerm(ctx.allocator, session.auth.db, taxonomy_id, name_value.string, parent_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "create_failed", "Failed to create term");
    defer freeTerm(ctx.allocator, term);

    try json.created(ctx, term);
}

fn handleUpdateTerm(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const term_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing term id");

    const parsed = json.parseJsonBody(ctx) catch return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Expected object body");

    if (parsed.value.object.get("name")) |name_value| {
        if (name_value != .string) return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "name must be string");
        taxonomy.renameTerm(session.auth.db, term_id, name_value.string) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "update_failed", "Failed to rename term");
    }

    if (parsed.value.object.get("parent_id")) |parent_value| {
        const parent_id = if (parent_value == .null)
            null
        else if (parent_value == .string)
            parent_value.string
        else
            return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "parent_id must be string or null");

        taxonomy.moveTermParent(session.auth.db, term_id, parent_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "update_failed", "Failed to move term");
    }

    try json.ok(ctx, .{ .updated = true, .id = term_id });
}

fn handleDeleteTerm(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const term_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing term id");

    const strategy = json.queryParam(ctx, "strategy") orelse "reparent";
    if (std.mem.eql(u8, strategy, "cascade")) {
        taxonomy.deleteTerm(session.auth.db, term_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "delete_failed", "Failed to delete term");
    } else {
        taxonomy.deleteTermWithReparent(session.auth.db, term_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "delete_failed", "Failed to delete term");
    }

    json.noContent(ctx);
}

fn freeTerms(allocator: std.mem.Allocator, terms: []taxonomy.TermRecord) void {
    for (terms) |term| {
        freeTerm(allocator, term);
    }
    allocator.free(terms);
}

fn freeTerm(allocator: std.mem.Allocator, term: taxonomy.TermRecord) void {
    allocator.free(term.id);
    allocator.free(term.taxonomy_id);
    allocator.free(term.slug);
    allocator.free(term.name);
    if (term.parent_id) |parent_id| allocator.free(parent_id);
    allocator.free(term.description);
}

test "rest taxonomy: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 4), router.routes.items.len);
}

test "rest taxonomy endpoints" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    var list = try ac.client.request("GET", "/api/taxonomies/category/terms", null, ac.token, .{});
    defer list.deinit();
    try helpers.expectStatus(list, 200);

    const term_id = try helpers.createTermApi(&ac.client, ac.token, "REST Category");
    defer std.testing.allocator.free(term_id);

    const rename_path = try std.fmt.allocPrint(std.testing.allocator, "/api/terms/{s}", .{term_id});
    defer std.testing.allocator.free(rename_path);
    var rename = try ac.client.request("PUT", rename_path, "{\"name\":\"REST Category Renamed\"}", ac.token, .{ .content_type = "application/json" });
    defer rename.deinit();
    try helpers.expectStatus(rename, 200);

    const delete_path = try std.fmt.allocPrint(std.testing.allocator, "/api/terms/{s}?strategy=reparent", .{term_id});
    defer std.testing.allocator.free(delete_path);
    var delete = try ac.client.request("DELETE", delete_path, null, ac.token, .{});
    defer delete.deinit();
    try helpers.expectStatus(delete, 204);
}

test "rest taxonomy: public API coverage" {
    _ = registerRoutes;
}
