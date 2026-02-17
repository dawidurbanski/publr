const std = @import("std");
pub const rest_client = @import("rest_client.zig");

pub const AuthedClient = struct {
    client: rest_client.RestTestClient,
    token: []const u8,
};

pub fn login(client: *rest_client.RestTestClient) ![]const u8 {
    return client.login("admin@test.local", "secret123");
}

pub fn parseJson(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
}

pub fn extractDataId(body: []const u8) ![]u8 {
    var parsed = try parseJson(body);
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
    if (data != .object) return error.InvalidResponse;
    const id = data.object.get("id") orelse return error.InvalidResponse;
    if (id != .string) return error.InvalidResponse;

    return std.testing.allocator.dupe(u8, id.string);
}

pub fn expectStatus(response: rest_client.Response, expected: u16) !void {
    try std.testing.expectEqual(expected, response.status_code);
}

pub fn expectBodyContains(body: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, body, needle) != null);
}

pub fn unique(prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{s}-{d}", .{ prefix, std.time.nanoTimestamp() });
}

pub fn initAuthedClient() !AuthedClient {
    var client = try rest_client.RestTestClient.init(std.testing.allocator);
    const token = try login(&client);
    return .{
        .client = client,
        .token = token,
    };
}

pub fn createPost(
    client: *rest_client.RestTestClient,
    token: []const u8,
    title: []const u8,
    slug: []const u8,
    body: []const u8,
) ![]u8 {
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"fields\":{{\"title\":\"{s}\",\"slug\":\"{s}\",\"body\":\"{s}\"}}}}",
        .{ title, slug, body },
    );
    defer std.testing.allocator.free(payload);

    var response = try client.request(
        "POST",
        "/api/content/post",
        payload,
        token,
        .{ .content_type = "application/json" },
    );
    defer response.deinit();
    try expectStatus(response, 201);
    return extractDataId(response.body);
}

pub fn versionPairFromApi(
    client: *rest_client.RestTestClient,
    token: []const u8,
    entry_id: []const u8,
) !struct { latest: []u8, previous: []u8 } {
    const versions_path = try std.fmt.allocPrint(std.testing.allocator, "/api/content/post/{s}/versions", .{entry_id});
    defer std.testing.allocator.free(versions_path);

    var versions = try client.request("GET", versions_path, null, token, .{});
    defer versions.deinit();
    try expectStatus(versions, 200);

    var parsed = try parseJson(versions.body);
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
    if (data != .array or data.array.items.len < 2) return error.InvalidResponse;

    const latest = data.array.items[0].object.get("id") orelse return error.InvalidResponse;
    const previous = data.array.items[1].object.get("id") orelse return error.InvalidResponse;
    if (latest != .string or previous != .string) return error.InvalidResponse;

    return .{
        .latest = try std.testing.allocator.dupe(u8, latest.string),
        .previous = try std.testing.allocator.dupe(u8, previous.string),
    };
}

pub fn createReleaseApi(
    client: *rest_client.RestTestClient,
    token: []const u8,
    name: []const u8,
) ![]u8 {
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"{s}\"}}", .{name});
    defer std.testing.allocator.free(payload);

    var response = try client.request("POST", "/api/releases", payload, token, .{ .content_type = "application/json" });
    defer response.deinit();
    try expectStatus(response, 201);
    return extractDataId(response.body);
}

pub fn addEntryToReleaseApi(
    client: *rest_client.RestTestClient,
    token: []const u8,
    release_id: []const u8,
    entry_id: []const u8,
) !rest_client.Response {
    const path = try std.fmt.allocPrint(std.testing.allocator, "/api/releases/{s}/entries", .{release_id});
    defer std.testing.allocator.free(path);
    const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"entry_id\":\"{s}\",\"fields\":[\"title\"]}}", .{entry_id});
    defer std.testing.allocator.free(body);
    return client.request("POST", path, body, token, .{ .content_type = "application/json" });
}

pub fn uploadMediaApi(client: *rest_client.RestTestClient, token: []const u8) ![]u8 {
    const boundary = "----publrBoundaryExplicit";
    const body =
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"rest.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n\r\n" ++
        "hello from rest explicit test\r\n" ++
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"visibility\"\r\n\r\n" ++
        "public\r\n" ++
        "--" ++ boundary ++ "--\r\n";
    const content_type = "multipart/form-data; boundary=" ++ boundary;

    var response = try client.request("POST", "/api/media", body, token, .{ .content_type = content_type });
    defer response.deinit();
    try expectStatus(response, 201);
    return extractDataId(response.body);
}

pub fn createTermApi(
    client: *rest_client.RestTestClient,
    token: []const u8,
    name: []const u8,
) ![]u8 {
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"{s}\"}}", .{name});
    defer std.testing.allocator.free(payload);

    var response = try client.request(
        "POST",
        "/api/taxonomies/category/terms",
        payload,
        token,
        .{ .content_type = "application/json" },
    );
    defer response.deinit();
    try expectStatus(response, 201);
    return extractDataId(response.body);
}
