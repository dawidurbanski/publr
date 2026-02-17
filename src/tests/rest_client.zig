const std = @import("std");
const builtin = @import("builtin");
const core_init = @import("core_init");
const auth_mod = @import("auth");
const Db = @import("db").Db;
const storage = @import("storage");

pub const Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

pub const RestTestClient = struct {
    allocator: std.mem.Allocator,
    db_path: []const u8,
    port: u16,
    child: std.process.Child,
    token: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) !RestTestClient {
        if (builtin.os.tag == .wasi) return error.UnsupportedOnWasi;

        const db_path = try std.fmt.allocPrint(allocator, "/tmp/publr-rest-test-{d}.db", .{std.time.nanoTimestamp()});
        try initDbWithUser(allocator, db_path);

        const port = pickPort();
        var port_buf: [6]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

        var child = std.process.Child.init(&.{
            "zig-out/bin/publr",
            "serve",
            "--port",
            port_str,
            "--db",
            db_path,
        }, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        var client = RestTestClient{
            .allocator = allocator,
            .db_path = db_path,
            .port = port,
            .child = child,
        };

        try client.waitUntilReady();
        return client;
    }

    pub fn deinit(self: *RestTestClient) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};

        if (self.token) |token| self.allocator.free(token);
        cleanupFilesystemMediaForDb(self.allocator, self.db_path);
        std.fs.cwd().deleteFile(self.db_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };
        self.allocator.free(self.db_path);
    }

    pub fn login(self: *RestTestClient, email: []const u8, password: []const u8) ![]const u8 {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"email\":\"{s}\",\"password\":\"{s}\"}}", .{ email, password });
        defer self.allocator.free(body);

        var response = try self.request("POST", "/api/auth/login", body, null, .{
            .content_type = "application/json",
        });
        defer response.deinit();

        if (response.status_code != 200) return error.LoginFailed;
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
        if (data != .object) return error.InvalidResponse;
        const token_value = data.object.get("token") orelse return error.InvalidResponse;
        if (token_value != .string) return error.InvalidResponse;

        if (self.token) |token| self.allocator.free(token);
        self.token = try self.allocator.dupe(u8, token_value.string);
        return self.token.?;
    }

    pub fn request(
        self: *RestTestClient,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        bearer_token: ?[]const u8,
        opts: struct {
            content_type: ?[]const u8 = null,
            cookie: ?[]const u8 = null,
        },
    ) !Response {
        const address = std.net.Address.parseIp4("127.0.0.1", self.port) catch return error.ConnectFailed;
        var stream = std.net.tcpConnectToAddress(address) catch return error.ConnectFailed;
        defer stream.close();

        var request_buf: std.ArrayList(u8) = .{};
        defer request_buf.deinit(self.allocator);
        const writer = request_buf.writer(self.allocator);

        try writer.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
        try writer.print("Host: 127.0.0.1:{d}\r\n", .{self.port});
        try writer.writeAll("Connection: close\r\n");
        if (opts.content_type) |content_type| {
            try writer.print("Content-Type: {s}\r\n", .{content_type});
        }
        if (bearer_token) |token| {
            try writer.print("Authorization: Bearer {s}\r\n", .{token});
        }
        if (opts.cookie) |cookie| {
            try writer.print("Cookie: {s}\r\n", .{cookie});
        }
        if (body) |payload| {
            try writer.print("Content-Length: {d}\r\n", .{payload.len});
        } else {
            try writer.writeAll("Content-Length: 0\r\n");
        }
        try writer.writeAll("\r\n");
        if (body) |payload| try writer.writeAll(payload);

        try stream.writeAll(request_buf.items);

        var response_buf: std.ArrayList(u8) = .{};
        defer response_buf.deinit(self.allocator);
        var temp: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&temp) catch |err| switch (err) {
                error.ConnectionResetByPeer => break,
                else => return err,
            };
            if (n == 0) break;
            try response_buf.appendSlice(self.allocator, temp[0..n]);
        }

        const split_idx = std.mem.indexOf(u8, response_buf.items, "\r\n\r\n") orelse return error.InvalidHttpResponse;
        const head = response_buf.items[0..split_idx];
        const body_slice = response_buf.items[split_idx + 4 ..];

        const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
        const first_line = head[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        _ = parts.next() orelse return error.InvalidHttpResponse;
        const status_str = parts.next() orelse return error.InvalidHttpResponse;
        const status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidHttpResponse;

        return .{
            .allocator = self.allocator,
            .status_code = status_code,
            .body = try self.allocator.dupe(u8, body_slice),
        };
    }

    fn waitUntilReady(self: *RestTestClient) !void {
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            var response = self.request("GET", "/admin/system/health", null, null, .{}) catch null;
            if (response) |*res| {
                defer res.deinit();
                if (res.status_code == 200) return;
            }
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return error.ServerStartTimeout;
    }
};

fn initDbWithUser(allocator: std.mem.Allocator, db_path: []const u8) !void {
    var db = try core_init.initDatabase(allocator, db_path);
    defer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);

    var auth = auth_mod.Auth.init(allocator, &db);
    const created_user_id = auth.createUser("admin@test.local", "Admin", "secret123") catch |err| switch (err) {
        error.EmailExists => null,
        else => return err,
    };
    if (created_user_id) |user_id| allocator.free(user_id);
}

fn pickPort() u16 {
    const now: u64 = @intCast(std.time.nanoTimestamp());
    return 19000 + @as(u16, @intCast(now % 1000));
}

fn cleanupFilesystemMediaForDb(allocator: std.mem.Allocator, db_path: []const u8) void {
    std.fs.cwd().access(db_path, .{}) catch return;

    var db = Db.init(allocator, db_path) catch return;
    defer db.deinit();

    var stmt = db.prepare("SELECT storage_key FROM media") catch return;
    defer stmt.deinit();

    while (true) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;
        const storage_key = stmt.columnText(0) orelse continue;
        const key_copy = allocator.dupe(u8, storage_key) catch continue;
        storage.filesystem.delete(allocator, key_copy) catch {};
        allocator.free(key_copy);
    }
}
