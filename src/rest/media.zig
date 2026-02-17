const std = @import("std");
const builtin = @import("builtin");
const Router = @import("router").Router;
const Context = @import("middleware").Context;
const media = @import("media");
const media_query = @import("media_query");
const mime = @import("mime");
const storage = @import("storage");
const multipart = @import("multipart");
const json = @import("rest_json");
const rest_auth = @import("rest_auth");

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub fn registerRoutes(router: *Router) !void {
    try router.get("/api/media", handleList);
    try router.post("/api/media", handleUpload);
    try router.get("/api/media/:id", handleGet);
    try router.delete("/api/media/:id", handleDelete);
}

fn handleList(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const mime_filter = json.queryParam(ctx, "mime");
    const visibility = json.queryParam(ctx, "visibility");
    const search_value = json.queryParam(ctx, "search");
    const search_pattern = if (search_value) |s| blk: {
        if (s.len == 0) break :blk null;
        break :blk std.fmt.allocPrint(ctx.allocator, "%{s}%", .{s}) catch null;
    } else null;
    defer if (search_pattern) |sp| ctx.allocator.free(sp);

    const limit = if (json.queryParam(ctx, "limit")) |v| std.fmt.parseInt(u32, v, 10) catch 50 else 50;
    const offset = if (json.queryParam(ctx, "offset")) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0;
    const year = if (json.queryParam(ctx, "year")) |v| std.fmt.parseInt(u16, v, 10) catch null else null;
    const month = if (json.queryParam(ctx, "month")) |v| std.fmt.parseInt(u8, v, 10) catch null else null;

    const mime_patterns = if (mime_filter) |m|
        if (std.mem.indexOfScalar(u8, m, '*') != null) m else null
    else
        null;
    const mime_exact = if (mime_filter) |m|
        if (std.mem.indexOfScalar(u8, m, '*') == null) m else null
    else
        null;

    const items = media_query.listMedia(ctx.allocator, session.auth.db, .{
        .visibility = visibility,
        .mime_type = mime_exact,
        .mime_patterns = mime_patterns,
        .search = search_pattern,
        .limit = limit,
        .offset = offset,
        .year = year,
        .month = month,
    }) catch return json.errorEnvelope(ctx, "500 Internal Server Error", "list_failed", "Failed to list media");
    defer freeMediaRecords(ctx.allocator, items);

    const total = if (mime_patterns != null or year != null or month != null)
        items.len
    else
        media_query.countMedia(session.auth.db, .{
            .visibility = visibility,
            .mime_type = mime_exact,
            .search = search_pattern,
        }) catch items.len;

    try json.paged(ctx, items, .{
        .total = total,
        .limit = limit,
        .offset = offset,
    });
}

fn handleUpload(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();

    const content_type = ctx.getRequestHeader("Content-Type") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing Content-Type");
    const boundary = multipart.parseMultipartBoundary(content_type) orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Invalid multipart boundary");
    const body = ctx.body orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing request body");
    const file = multipart.parseMultipartFile(ctx.allocator, body, boundary) orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing file field");

    const visibility_str = multipart.parseMultipartField(ctx.allocator, body, boundary, "visibility") orelse "public";
    const visibility = storage.Visibility.fromString(visibility_str) orelse storage.Visibility.public;
    const mime_type = if (file.content_type.len > 0 and !std.mem.eql(u8, file.content_type, "application/octet-stream"))
        file.content_type
    else
        mime.fromPath(file.filename);

    const record = media.uploadMedia(ctx.allocator, session.auth.db, getBackend(), .{
        .filename = file.filename,
        .mime_type = mime_type,
        .data = file.data,
        .visibility = visibility,
    }) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "upload_failed", "Failed to upload media");
    defer freeMediaRecord(ctx.allocator, record);

    try json.created(ctx, record);
}

fn handleGet(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const media_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing media id");

    const record = media.getMedia(ctx.allocator, session.auth.db, media_id) catch null;
    if (record == null) return json.errorEnvelope(ctx, "404 Not Found", "not_found", "Media not found");
    defer freeMediaRecord(ctx.allocator, record.?);

    try json.ok(ctx, record.?);
}

fn handleDelete(ctx: *Context) !void {
    var session = rest_auth.requireUser(ctx) catch return json.errorEnvelope(ctx, "401 Unauthorized", "unauthorized", "Unauthorized");
    defer session.deinit();
    const media_id = ctx.param("id") orelse return json.errorEnvelope(ctx, "400 Bad Request", "bad_request", "Missing media id");

    media.fullDeleteMedia(ctx.allocator, session.auth.db, getBackend(), media_id) catch return json.errorEnvelope(ctx, "422 Unprocessable Entity", "delete_failed", "Failed to delete media");
    json.noContent(ctx);
}

fn getBackend() storage.StorageBackend {
    if (is_wasm) return @import("wasm_storage").backend;
    return storage.filesystem;
}

fn freeMediaRecords(allocator: std.mem.Allocator, items: []media.MediaRecord) void {
    for (items) |item| {
        freeMediaRecord(allocator, item);
    }
    allocator.free(items);
}

fn freeMediaRecord(allocator: std.mem.Allocator, item: media.MediaRecord) void {
    allocator.free(item.id);
    allocator.free(item.filename);
    allocator.free(item.mime_type);
    allocator.free(item.storage_key);
    allocator.free(item.visibility);
    if (item.hash) |hash| allocator.free(hash);
}

test "rest media: registerRoutes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router);
    try std.testing.expectEqual(@as(usize, 4), router.routes.items.len);
}

test "rest media endpoints" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("rest_test_helpers");

    var ac = try helpers.initAuthedClient();
    defer ac.client.deinit();

    var list = try ac.client.request("GET", "/api/media", null, ac.token, .{});
    defer list.deinit();
    try helpers.expectStatus(list, 200);

    const media_id = try helpers.uploadMediaApi(&ac.client, ac.token);
    defer std.testing.allocator.free(media_id);

    const get_path = try std.fmt.allocPrint(std.testing.allocator, "/api/media/{s}", .{media_id});
    defer std.testing.allocator.free(get_path);
    var get = try ac.client.request("GET", get_path, null, ac.token, .{});
    defer get.deinit();
    try helpers.expectStatus(get, 200);

    const delete_path = try std.fmt.allocPrint(std.testing.allocator, "/api/media/{s}", .{media_id});
    defer std.testing.allocator.free(delete_path);
    var delete = try ac.client.request("DELETE", delete_path, null, ac.token, .{});
    defer delete.deinit();
    try helpers.expectStatus(delete, 204);
}

test "rest media: public API coverage" {
    _ = registerRoutes;
}
