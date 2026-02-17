const std = @import("std");
pub const runner_mod = @import("cli_runner.zig");

pub fn initDb(runner: *runner_mod.CliTestRunner) !void {
    var db_init = try runner.run(&.{"db", "init"});
    defer db_init.deinit();
    try runner_mod.expectSuccess(db_init);
}

pub fn unique(prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{s}-{d}", .{ prefix, std.time.nanoTimestamp() });
}

pub fn createPostViaFields(
    runner: *runner_mod.CliTestRunner,
    title: []const u8,
    slug: []const u8,
    body: []const u8,
) ![]u8 {
    const title_field = try std.fmt.allocPrint(std.testing.allocator, "title={s}", .{title});
    defer std.testing.allocator.free(title_field);
    const slug_field = try std.fmt.allocPrint(std.testing.allocator, "slug={s}", .{slug});
    defer std.testing.allocator.free(slug_field);
    const body_field = try std.fmt.allocPrint(std.testing.allocator, "body={s}", .{body});
    defer std.testing.allocator.free(body_field);

    var create = try runner.run(&.{
        "content",
        "create",
        "post",
        "--field",
        title_field,
        "--field",
        slug_field,
        "--field",
        body_field,
        "--format",
        "json",
    });
    defer create.deinit();
    try runner_mod.expectSuccess(create);
    return extractDataIdFromJson(create);
}

pub fn extractDataIdFromJson(result: runner_mod.RunResult) ![]u8 {
    var parsed = try runner_mod.expectJsonOutput(std.testing.allocator, result);
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
    if (data != .object) return error.InvalidResponse;
    const id_val = data.object.get("id") orelse return error.InvalidResponse;
    if (id_val != .string) return error.InvalidResponse;
    return std.testing.allocator.dupe(u8, id_val.string);
}

pub fn extractFirstArrayDataIdFromJson(result: runner_mod.RunResult) ![]u8 {
    var parsed = try runner_mod.expectJsonOutput(std.testing.allocator, result);
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
    if (data != .array or data.array.items.len == 0) return error.InvalidResponse;
    const first = data.array.items[0];
    if (first != .object) return error.InvalidResponse;
    const id_val = first.object.get("id") orelse return error.InvalidResponse;
    if (id_val != .string) return error.InvalidResponse;
    return std.testing.allocator.dupe(u8, id_val.string);
}

pub fn writeAbsoluteFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

pub fn versionPairIds(
    runner: *runner_mod.CliTestRunner,
    entry_id: []const u8,
) !struct { latest: []u8, previous: []u8 } {
    var list = try runner.run(&.{ "version", "list", entry_id, "--format", "json" });
    defer list.deinit();
    try runner_mod.expectSuccess(list);

    var parsed = try runner_mod.expectJsonOutput(std.testing.allocator, list);
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

pub fn createReleaseViaCli(runner: *runner_mod.CliTestRunner, name: []const u8) ![]u8 {
    var create = try runner.run(&.{ "release", "create", name, "--format", "json" });
    defer create.deinit();
    try runner_mod.expectSuccess(create);
    return extractDataIdFromJson(create);
}

pub fn createUserViaCli(
    runner: *runner_mod.CliTestRunner,
    email: []const u8,
    name: []const u8,
) ![]u8 {
    var create = try runner.run(&.{
        "user",
        "create",
        "--email",
        email,
        "--name",
        name,
        "--password",
        "secret123",
        "--format",
        "json",
    });
    defer create.deinit();
    try runner_mod.expectSuccess(create);
    return extractDataIdFromJson(create);
}

pub fn createTermViaCli(
    runner: *runner_mod.CliTestRunner,
    taxonomy_id: []const u8,
    name: []const u8,
    parent_id: ?[]const u8,
) ![]u8 {
    var result: runner_mod.RunResult = undefined;
    if (parent_id) |parent| {
        result = try runner.run(&.{ "taxonomy", "create", taxonomy_id, name, "--parent", parent, "--format", "json" });
    } else {
        result = try runner.run(&.{ "taxonomy", "create", taxonomy_id, name, "--format", "json" });
    }
    defer result.deinit();
    try runner_mod.expectSuccess(result);
    return extractDataIdFromJson(result);
}

pub fn createTempMediaFile(label: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(std.testing.allocator, "tmp-media-{s}-{d}.jpg", .{ label, std.time.nanoTimestamp() });
    errdefer std.testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "fake-jpeg-content" });
    return path;
}
