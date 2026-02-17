const std = @import("std");
const posix = std.posix;
const Context = @import("router").Context;
const auth_middleware = @import("auth_middleware");
const websocket = @import("websocket");
const presence = @import("presence");
const plugin_content = @import("plugin_content");
const collaboration_config = @import("../collaboration_config.zig");

var shutdown_requested: ?*const std.atomic.Value(bool) = null;
var is_dev_mode: bool = false;

pub fn configure(shutdown: *const std.atomic.Value(bool), dev_mode: bool) void {
    shutdown_requested = shutdown;
    is_dev_mode = dev_mode;
}

pub fn handleWebSocket(ctx: *Context) !void {
    const upgrade_header = ctx.getRequestHeader("Upgrade") orelse {
        ctx.response.setStatus("400 Bad Request");
        ctx.response.setBody("Expected WebSocket upgrade");
        return;
    };
    if (!std.ascii.eqlIgnoreCase(upgrade_header, "websocket")) {
        ctx.response.setStatus("400 Bad Request");
        ctx.response.setBody("Expected WebSocket upgrade");
        return;
    }

    const ws_key = ctx.getRequestHeader("Sec-WebSocket-Key") orelse {
        ctx.response.setStatus("400 Bad Request");
        ctx.response.setBody("Missing Sec-WebSocket-Key");
        return;
    };

    const user_id = auth_middleware.getUserId(ctx) orelse return;
    const user_email = auth_middleware.getUserEmail(ctx) orelse return;

    const auth_instance = auth_middleware.auth orelse return;
    const display_name = blk: {
        var maybe_user = auth_instance.getUserById(user_id) catch null;
        if (maybe_user) |*user| {
            const dn = std.heap.page_allocator.dupe(u8, user.display_name) catch "";
            auth_instance.freeUser(user);
            break :blk dn;
        }
        break :blk @as([]const u8, "");
    };
    defer if (display_name.len > 0) std.heap.page_allocator.free(display_name);

    const user_info = presence.UserInfo{
        .user_id = user_id,
        .email = user_email,
        .display_name = display_name,
    };

    const stream = ctx.stream orelse return error.NoStream;

    try websocket.upgrade(stream, ws_key);
    ctx.response.headers_sent = true;

    const conn = try std.heap.page_allocator.create(websocket.Connection);
    conn.* = .{
        .stream = stream,
        .allocator = std.heap.page_allocator,
        .id = websocket.nextId(),
    };

    websocket.registry.add(conn);
    defer {
        presence.disconnect(conn.id);
        websocket.registry.remove(conn);
        std.heap.page_allocator.destroy(conn);
    }

    conn.sendJson("connected", null) catch return;
    if (is_dev_mode) {
        std.debug.print("[ws] Connection {d} opened (active: {d})\n", .{ conn.id, websocket.registry.count() });
    }
    defer {
        if (is_dev_mode) {
            std.debug.print("[ws] Connection {d} closed (active: {d})\n", .{ conn.id, websocket.registry.count() });
        }
    }

    const poll_timeout_ms: i32 = @intCast(@min(
        collaboration_config.getHeartbeatIntervalMs(),
        @as(u32, @intCast(std.math.maxInt(i32))),
    ));

    var poll_fds = [_]posix.pollfd{
        .{ .fd = stream.handle, .events = posix.POLL.IN, .revents = 0 },
    };
    var idle_ticks: u32 = 0;

    while (!shouldShutdown()) {
        const poll_result = posix.poll(&poll_fds, poll_timeout_ms) catch break;

        if (poll_result == 0) {
            idle_ticks += 1;
            if (presence.isHeartbeatStale(conn.id)) {
                if (is_dev_mode) std.debug.print("[ws] #{d}: heartbeat stale, closing\n", .{conn.id});
                break;
            }
            if (idle_ticks >= 3) {
                websocket.writeFrame(stream, .ping, &.{}) catch break;
                idle_ticks = 0;
            }
            continue;
        }

        idle_ticks = 0;

        const frame = websocket.readFrame(stream, std.heap.page_allocator) catch break;
        defer std.heap.page_allocator.free(frame.payload);

        switch (frame.opcode) {
            .text => {
                if (is_dev_mode) {
                    std.debug.print("[ws] #{d}: {s}\n", .{ conn.id, frame.payload });
                }
                dispatchMessage(conn, frame.payload, user_info);
            },
            .ping => {
                websocket.writeFrame(stream, .pong, frame.payload) catch break;
            },
            .pong => {},
            .close => {
                conn.sendClose();
                break;
            },
            else => {},
        }
    }
}

fn shouldShutdown() bool {
    if (shutdown_requested) |flag| {
        return flag.load(.acquire);
    }
    return false;
}

fn dispatchMessage(conn: *websocket.Connection, payload: []const u8, user: presence.UserInfo) void {
    const extractJsonString = websocket.extractJsonString;
    const extractJsonStringRaw = websocket.extractJsonStringRaw;

    const msg_type = extractJsonString(payload, "type") orelse return;

    if (std.mem.eql(u8, msg_type, "subscribe")) {
        const entry_id = extractJsonString(payload, "entry_id") orelse return;
        presence.subscribe(entry_id, conn, user);
    } else if (std.mem.eql(u8, msg_type, "unsubscribe")) {
        presence.unsubscribe(conn.id);
    } else if (std.mem.eql(u8, msg_type, "activity")) {
        const active_str = extractJsonString(payload, "active") orelse return;
        presence.setActivity(conn.id, std.mem.eql(u8, active_str, "true"));
    } else if (std.mem.eql(u8, msg_type, "heartbeat")) {
        presence.heartbeat(conn.id);
    } else if (std.mem.eql(u8, msg_type, "focus")) {
        const field = extractJsonString(payload, "field") orelse return;
        presence.focus(conn.id, field);
    } else if (std.mem.eql(u8, msg_type, "blur")) {
        const field = extractJsonString(payload, "field") orelse return;
        presence.blur(conn.id, field);
    } else if (std.mem.eql(u8, msg_type, "field_edit")) {
        const field = extractJsonString(payload, "field") orelse return;
        const value = extractJsonStringRaw(payload, "value") orelse return;
        presence.fieldEdit(conn.id, field, value);
    } else if (std.mem.eql(u8, msg_type, "takeover")) {
        const field = extractJsonString(payload, "field") orelse return;
        plugin_content.handleTakeover(conn, field, user);
    }
}
