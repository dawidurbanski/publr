const std = @import("std");

const output_bytes_max: u32 = 64 << 10;
const startup_attempts_max: u32 = 50;
const startup_wait_ms: u32 = 100;

pub fn main(init: std.process.Init) !u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());

    _ = iterator.next();

    const binary_arg = iterator.next() orelse return error.MissingBinaryPath;
    const work_dir = iterator.next() orelse return error.MissingWorkDir;
    const arena = init.arena.allocator();
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, binary_arg, arena);

    std.debug.assert(std.fs.path.isAbsolute(binary));
    std.debug.assert(std.fs.path.isAbsolute(work_dir));

    try std.Io.Dir.cwd().deleteTree(init.io, work_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, work_dir);

    const check = [_][]const u8{ "heartbeat", "check", "--echo", "smoke" };
    const admin_check = [_][]const u8{ "--as-admin", "heartbeat", "check" };

    try expect_output(init, binary, work_dir, &.{"--version"}, "publr 0.2.0\n");
    try expect_contains(init, binary, work_dir, &check, "\"echo\": \"smoke\"");
    try expect_contains(init, binary, work_dir, &admin_check, "\"caller\": \"system\"");
    try expect_contains(init, binary, work_dir, &.{"--help"}, "heartbeat check");
    try expect_contains(init, binary, work_dir, &.{ "user", "--help" }, "user password_link");
    try expect_auth(init, binary, work_dir);
    try expect_serve(init, binary, work_dir);

    std.debug.print("smoke: ok\n", .{});

    return 0;
}

fn run_publr(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    std.debug.assert(args.len < 16);
    std.debug.assert(binary.len > 0);

    var argv: [17][]const u8 = undefined;
    argv[0] = binary;

    for (args, 0..) |arg, index| argv[index + 1] = arg;

    return std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv[0 .. args.len + 1],
        .cwd = .{ .path = work_dir },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
}

fn expect_output(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
    expected: []const u8,
) !void {
    const result = try run_publr(init, binary, work_dir, args);

    std.debug.assert(expected.len > 0);
    std.debug.assert(args.len > 0);

    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print("smoke: {s}: expected {s}, got {s}{s}\n", .{
            args[0],
            expected,
            result.stdout,
            result.stderr,
        });
        return error.SmokeFailed;
    }
}

fn expect_contains(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
    needle: []const u8,
) !void {
    const result = try run_publr(init, binary, work_dir, args);

    std.debug.assert(needle.len > 0);
    std.debug.assert(args.len > 0);

    if (std.mem.indexOf(u8, result.stdout, needle) == null) {
        std.debug.print("smoke: {s}: missing {s} in {s}{s}\n", .{
            args[0],
            needle,
            result.stdout,
            result.stderr,
        });
        return error.SmokeFailed;
    }
}

fn expect_auth(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const email = "smoke@example.com";
    const password = "smoke test pass";
    const setup = [_][]const u8{
        "init", "--email", email, "--display_name", "Smoke", "--password", password,
    };
    const setup_again = [_][]const u8{
        "site", "init", "--email", "x@example.com", "--display_name", "X", "--password", password,
    };
    const login = [_][]const u8{ "user", "sign_in", "--email", email, "--password", password };
    const wrong = [_][]const u8{
        "user", "sign_in", "--email", email, "--password", "wrong wrong wrong",
    };
    const list = [_][]const u8{ "--as", "smoke@example.com", "user", "list" };
    const denied = [_][]const u8{ "user", "list" };
    const generated = [_][]const u8{
        "--as", email, "user", "create", "--email", "gen@example.com", "--display_name", "Gen",
    };
    const invited = [_][]const u8{
        "--as",            email,
        "user",            "create",
        "--email",         "new@example.com",
        "--display_name",  "New",
        "--password_link", "true",
    };
    const relink = [_][]const u8{
        "--as", email, "user", "password_link", "--user", "new@example.com",
    };
    const forged = [_][]const u8{
        "user", "set_password", "--token", "0" ** 64, "--password", password,
    };

    try expect_contains(init, binary, work_dir, &setup, "\"role\": \"admin\"");
    try expect_failure(init, binary, work_dir, &setup_again, "conflict");
    try expect_contains(init, binary, work_dir, &login, "\"token\": \"");
    try expect_failure(init, binary, work_dir, &wrong, "wrong email or password");
    try expect_contains(init, binary, work_dir, &list, "smoke@example.com");
    try expect_failure(init, binary, work_dir, &denied, "denied for an anonymous caller");
    try expect_contains(init, binary, work_dir, &generated, "\"password\": \"");
    try expect_contains(init, binary, work_dir, &invited, "/auth/set-password?token=");
    try expect_contains(init, binary, work_dir, &relink, "/auth/set-password?token=");
    try expect_failure(init, binary, work_dir, &forged, "not found");
    try expect_content(init, binary, work_dir, email);
}

fn expect_content(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    admin: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(admin.len > 0);

    const definition = "{\"handle\":\"post\",\"name\":\"Post\",\"name_plural\":\"Posts\"," ++
        "\"public\":true,\"fields\":[" ++
        "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\",\"required\":true}," ++
        "{\"name\":\"slug\",\"label\":\"Slug\",\"kind\":\"slug\"," ++
        "\"options\":{\"source\":\"title\"}}," ++
        "{\"name\":\"body\",\"label\":\"Body\",\"kind\":\"richtext\",\"searchable\":true}]}";
    const create_type = [_][]const u8{
        "--as", admin, "content_type", "create", "--definition", definition,
    };
    const document = "{\"title\":\"Smoke\",\"body\":\"hello there\"}";
    const create_entry = [_][]const u8{
        "--as", admin, "record", "create", "--type", "post", "--document", document,
    };
    const list_anonymous = [_][]const u8{ "record", "list", "--type", "post" };
    const search = [_][]const u8{
        "--as", admin, "record", "list", "--type", "post", "--search", "hello",
    };
    const editor_types = [_][]const u8{ "--as", admin, "content_type", "list" };

    try expect_contains(init, binary, work_dir, &create_type, "\"handle\": \"post\"");
    try expect_contains(init, binary, work_dir, &create_entry, "\"slug\": \"smoke\"");
    try expect_contains(init, binary, work_dir, &list_anonymous, "\"records\": []");
    try expect_contains(init, binary, work_dir, &search, "\"title\": \"Smoke\"");
    try expect_contains(init, binary, work_dir, &editor_types, "\"handle\": \"post\"");
}

fn expect_failure(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
    expected: []const u8,
) !void {
    const result = try run_publr(init, binary, work_dir, args);

    std.debug.assert(expected.len > 0);
    std.debug.assert(args.len > 0);

    const failed = result.term == .exited and result.term.exited != 0;

    if (!failed or std.mem.indexOf(u8, result.stderr, expected) == null) {
        std.debug.print("smoke: {s} {s}: expected failure containing {s}, got {s}{s}\n", .{
            args[0],
            args[1],
            expected,
            result.stdout,
            result.stderr,
        });

        return error.SmokeFailed;
    }
}

fn expect_serve(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8090" },
        .cwd = .{ .path = work_dir },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    const port = try read_port(init, child.stderr.?);
    const body = try http_get(init, port, "/api/health");

    if (std.mem.indexOf(u8, body, "\"version\":\"0.2.0\"") == null) {
        std.debug.print("smoke: serve: unexpected /api/health body: {s}\n", .{body});
        return error.SmokeFailed;
    }

    const login_body = "{\"email\":\"smoke@example.com\",\"password\":\"smoke test pass\"}";
    const login = try http_post(init, port, "/api/auth/sign-in", login_body);

    if (std.mem.indexOf(u8, login, "Set-Cookie: publr_session=") == null) {
        std.debug.print("smoke: serve: login did not set a session cookie: {s}\n", .{login});
        return error.SmokeFailed;
    }

    const listed = try http_get(init, port, "/api/record/list?type=post");

    if (std.mem.indexOf(u8, listed, "\"records\":[]") == null) {
        std.debug.print("smoke: serve: unexpected /api/record/list body: {s}\n", .{listed});
        return error.SmokeFailed;
    }

    const denied = try http_get(init, port, "/api/content_type/list");

    if (std.mem.indexOf(u8, denied, "403 Forbidden") == null) {
        std.debug.print("smoke: serve: anonymous content_type list not denied: {s}\n", .{denied});
        return error.SmokeFailed;
    }
}

fn read_port(init: std.process.Init, stderr: std.Io.File) !u16 {
    var buffer: [256]u8 = undefined;
    var reader = stderr.reader(init.io, &buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');

    std.debug.assert(line.len < buffer.len);
    std.debug.assert(buffer.len == 256);

    return parse_announced_port(line);
}

fn parse_announced_port(line: []const u8) !u16 {
    const marker = "127.0.0.1:";
    const marker_at = std.mem.indexOf(u8, line, marker) orelse return error.NoPortAnnounced;
    const digits = std.mem.trimEnd(u8, line[marker_at + marker.len ..], "/ \r");
    const port = try std.fmt.parseInt(u16, digits, 10);

    std.debug.assert(port > 0);
    std.debug.assert(line.len > marker.len);

    return port;
}

test "the announced port is parsed from the serve banner" {
    const plain = try parse_announced_port("publr serving on http://127.0.0.1:8090");
    const slashed = try parse_announced_port("... on http://127.0.0.1:8091/\r");
    try std.testing.expectEqual(@as(u16, 8090), plain);
    try std.testing.expectEqual(@as(u16, 8091), slashed);
    try std.testing.expectError(error.NoPortAnnounced, parse_announced_port("nothing here"));
    const garbage = parse_announced_port("http://127.0.0.1:abc");
    try std.testing.expectError(error.InvalidCharacter, garbage);
}

fn http_get(init: std.process.Init, port: u16, path: []const u8) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(path.len > 0);

    const request = try std.fmt.allocPrint(
        init.arena.allocator(),
        "GET {s} HTTP/1.1\r\nHost: smoke\r\nConnection: close\r\n\r\n",
        .{path},
    );

    return http_exchange(init, port, request);
}

fn http_post(init: std.process.Init, port: u16, path: []const u8, body: []const u8) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(path.len > 0);

    const request = try std.fmt.allocPrint(
        init.arena.allocator(),
        "POST {s} HTTP/1.1\r\nHost: smoke\r\nOrigin: http://smoke\r\n" ++
            "Content-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, body.len, body },
    );

    return http_exchange(init, port, request);
}

fn http_exchange(init: std.process.Init, port: u16, request: []const u8) ![]const u8 {
    std.debug.assert(port > 0);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(init.io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(init.io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);
    const response = try init.arena.allocator().alloc(u8, 4096);
    const len = try reader.interface.readSliceShort(response);

    std.debug.assert(len <= response.len);

    return response[0..len];
}
