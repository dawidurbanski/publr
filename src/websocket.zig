/// Minimal RFC 6455 WebSocket implementation.
/// No compression, no buffer pooling, no fragmentation sending.
/// Handles upgrade handshake, frame read/write, ping/pong, close.
const std = @import("std");
const posix = std.posix;
const Sha1 = std.crypto.hash.Sha1;

const ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// =========================================================================
// Types
// =========================================================================

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

// =========================================================================
// Connection
// =========================================================================

pub const Connection = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    write_mutex: std.Thread.Mutex = .{},
    id: u64,

    /// Send a text frame.
    pub fn sendText(self: *Connection, data: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try writeFrame(self.stream, .text, data);
    }

    /// Send a JSON message with type envelope: {"type":"<t>","data":<d>}
    pub fn sendJson(self: *Connection, msg_type: []const u8, data: ?[]const u8) !void {
        const json = if (data) |d|
            try std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"data\":{s}}}", .{ msg_type, d })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\"}}", .{msg_type});
        defer self.allocator.free(json);
        try self.sendText(json);
    }

    /// Send a close frame (does not close the TCP connection).
    pub fn sendClose(self: *Connection) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        writeFrame(self.stream, .close, &.{}) catch {};
    }
};

// =========================================================================
// Protocol
// =========================================================================

/// Perform the WebSocket upgrade handshake (send 101 Switching Protocols).
pub fn upgrade(stream: std.net.Stream, key: []const u8) !void {
    // SHA-1(key + magic GUID) → base64
    var hasher = Sha1.init(.{});
    hasher.update(key);
    hasher.update(ws_magic);
    var hash: [Sha1.digest_length]u8 = undefined;
    hasher.final(&hash);

    const accept_len = comptime std.base64.standard.Encoder.calcSize(Sha1.digest_length);
    var accept_buf: [accept_len]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &hash);

    var buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    ) catch return error.ResponseTooLarge;

    _ = try stream.write(response);
}

/// Read one WebSocket frame. Caller must free frame.payload.
pub fn readFrame(stream: std.net.Stream, allocator: std.mem.Allocator) !Frame {
    var header: [2]u8 = undefined;
    try readExact(stream, &header);

    const fin = header[0] & 0x80 != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(header[0])));
    const masked = header[1] & 0x80 != 0;
    var payload_len: u64 = header[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        try readExact(stream, &mask);
    }

    // 1 MB payload limit
    if (payload_len > 1024 * 1024) return error.PayloadTooLarge;

    const len: usize = @intCast(payload_len);
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);

    if (len > 0) {
        try readExact(stream, payload);
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask[i % 4];
            }
        }
    }

    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

/// Write one WebSocket frame (server → client, unmasked per spec).
pub fn writeFrame(stream: std.net.Stream, opcode: Opcode, data: []const u8) !void {
    var header: [10]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN=1

    if (data.len < 126) {
        header[1] = @intCast(data.len);
    } else if (data.len <= 65535) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(data.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @intCast(data.len), .big);
        header_len = 10;
    }

    _ = try stream.write(header[0..header_len]);
    if (data.len > 0) {
        _ = try stream.write(data);
    }
}

fn readExact(stream: std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

// =========================================================================
// Registry — thread-safe tracking of active WebSocket connections
// =========================================================================

var next_conn_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub fn nextId() u64 {
    return next_conn_id.fetchAdd(1, .monotonic);
}

pub const Registry = struct {
    mutex: std.Thread.Mutex = .{},
    connections: std.ArrayListUnmanaged(*Connection) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.connections.deinit(self.allocator);
    }

    pub fn add(self: *Registry, conn: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connections.append(self.allocator, conn) catch {};
    }

    pub fn remove(self: *Registry, conn: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.connections.items, 0..) |c, i| {
            if (c.id == conn.id) {
                _ = self.connections.swapRemove(i);
                return;
            }
        }
    }

    /// Send a text message to all connections except `exclude`.
    pub fn broadcast(self: *Registry, data: []const u8, exclude: ?*Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.connections.items) |conn| {
            if (exclude) |ex| {
                if (conn.id == ex.id) continue;
            }
            conn.sendText(data) catch {};
        }
    }

    pub fn count(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.items.len;
    }
};

pub var registry: Registry = undefined;

pub fn initRegistry(allocator: std.mem.Allocator) void {
    registry = Registry.init(allocator);
}
