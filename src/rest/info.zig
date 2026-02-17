const std = @import("std");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const registry = @import("schema_registry");
const Db = @import("db").Db;
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/info", handleInfo);
}

fn handleInfo(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const total_entries = countRows(session.auth.db, "SELECT COUNT(*) FROM content_anchors") catch return json.errorEnvelope(ctx, "500 Internal Server Error", "count_failed", "Failed to read entry count");
    const total_media = countRows(session.auth.db, "SELECT COUNT(*) FROM media") catch return json.errorEnvelope(ctx, "500 Internal Server Error", "count_failed", "Failed to read media count");

    var counts: std.ArrayList(struct { type_id: []const u8, count: i64 }) = .{};
    defer counts.deinit(ctx.allocator);
    for (registry.registered_types) |info| {
        const count = countType(session.auth.db, info.id) catch 0;
        try counts.append(ctx.allocator, .{
            .type_id = info.id,
            .count = count,
        });
    }

    try json.ok(ctx, .{
        .version = "dev",
        .timestamp = std.time.timestamp(),
        .total_entries = total_entries,
        .total_media = total_media,
        .content_types = counts.items,
    });
}

fn countRows(db: *Db, query: []const u8) !i64 {
    var stmt = try db.prepare(query);
    defer stmt.deinit();
    if (!try stmt.step()) return error.MissingCountRow;
    return stmt.columnInt(0);
}

fn countType(db: *Db, type_id: []const u8) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM content_anchors WHERE content_type = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, type_id);
    if (!try stmt.step()) return error.MissingCountRow;
    return stmt.columnInt(0);
}

test "rest info: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 1), router.routes.items.len);
}

test "rest info endpoint" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    var info = try ac.client.request("GET", "/api/info", null, ac.token, .{});
    defer info.deinit();
    try helpers.expectStatus(info, 200);
    try helpers.expectBodyContains(info.body, "\"version\"");
    try helpers.expectBodyContains(info.body, "\"total_entries\"");
}

test "rest info: public API coverage" {
    _ = registerRoutes;
}
