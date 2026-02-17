const std = @import("std");
const Context = @import("middleware").Context;

pub const PaginationMeta = struct {
    total: usize,
    limit: usize,
    offset: usize,
};

pub fn ok(ctx: *Context, data: anytype) !void {
    return respond(ctx, "200 OK", .{ .data = data });
}

pub fn created(ctx: *Context, data: anytype) !void {
    return respond(ctx, "201 Created", .{ .data = data });
}

pub fn paged(ctx: *Context, data: anytype, meta: PaginationMeta) !void {
    return respond(ctx, "200 OK", .{
        .data = data,
        .meta = meta,
    });
}

pub fn noContent(ctx: *Context) void {
    ctx.response.setStatus("204 No Content");
    ctx.response.setContentType("application/json");
    ctx.response.setBody("");
    setCors(ctx);
}

pub fn errorEnvelope(ctx: *Context, status: []const u8, code: []const u8, message: []const u8) !void {
    return respond(ctx, status, .{
        .@"error" = .{
            .code = code,
            .message = message,
        },
    });
}

pub fn parseJsonBody(ctx: *Context) !std.json.Parsed(std.json.Value) {
    const body = ctx.body orelse return error.MissingBody;
    return std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
}

pub fn queryParam(ctx: *const Context, key: []const u8) ?[]const u8 {
    const query = ctx.query orelse return null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        if (!std.mem.eql(u8, k, key)) continue;
        return pair[eq + 1 ..];
    }
    return null;
}

fn respond(ctx: *Context, status: []const u8, payload: anytype) !void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(ctx.allocator);
    try buf.writer(ctx.allocator).print("{f}", .{std.json.fmt(payload, .{})});
    const body = try buf.toOwnedSlice(ctx.allocator);

    ctx.response.setStatus(status);
    ctx.response.setContentType("application/json");
    ctx.response.setBody(body);
    setCors(ctx);
}

fn setCors(ctx: *Context) void {
    ctx.response.setHeader("Access-Control-Allow-Origin", "*");
    ctx.response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
}

test "rest json: queryParam branches" {
    var ctx = Context.init(std.heap.page_allocator, .GET, "/api/content");
    defer ctx.deinit();

    ctx.query = "limit=10&offset=5&search=abc";
    try std.testing.expectEqualStrings("10", queryParam(&ctx, "limit").?);
    try std.testing.expectEqualStrings("abc", queryParam(&ctx, "search").?);
    try std.testing.expect(queryParam(&ctx, "missing") == null);
}

test "rest json: parseJsonBody branches" {
    var missing = Context.init(std.heap.page_allocator, .POST, "/api/content");
    defer missing.deinit();
    try std.testing.expectError(error.MissingBody, parseJsonBody(&missing));

    var ok_ctx = Context.init(std.heap.page_allocator, .POST, "/api/content");
    defer ok_ctx.deinit();
    ok_ctx.setBody("{\"x\":1}");
    var parsed = try parseJsonBody(&ok_ctx);
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "rest json: envelope helpers" {
    var ctx = Context.init(std.heap.page_allocator, .GET, "/api/content");
    defer ctx.deinit();

    try ok(&ctx, .{ .a = 1 });
    try std.testing.expectEqualStrings("200 OK", ctx.response.status);
    try std.testing.expectEqualStrings("application/json", ctx.response.content_type);

    try created(&ctx, .{ .id = "x" });
    try std.testing.expectEqualStrings("201 Created", ctx.response.status);

    try paged(&ctx, &.{1, 2}, .{ .total = 2, .limit = 2, .offset = 0 });
    try std.testing.expectEqualStrings("200 OK", ctx.response.status);

    noContent(&ctx);
    try std.testing.expectEqualStrings("204 No Content", ctx.response.status);

    try errorEnvelope(&ctx, "400 Bad Request", "bad_request", "oops");
    try std.testing.expectEqualStrings("400 Bad Request", ctx.response.status);
}

test "rest json: public API coverage" {
    _ = ok;
    _ = created;
    _ = paged;
    _ = noContent;
    _ = errorEnvelope;
    _ = parseJsonBody;
    _ = queryParam;
}
