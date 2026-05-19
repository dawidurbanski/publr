const std = @import("std");
const posix = std.posix;
const Context = @import("router").Context;
const auth_middleware = @import("auth_middleware");
const websocket = @import("websocket");
const presence = @import("presence");
const plugin_content = @import("plugin_content");
const plugin_utils = @import("plugin_utils");
const url_util = @import("url");
const sync_token = @import("sync_token");
const apply_remote_hooks = @import("apply_remote_hooks");
const sync_catchup_hooks = @import("sync_catchup_hooks");
const core_init = @import("core_init");
const collaboration_config = @import("../collaboration_config.zig");

var shutdown_requested: ?*const std.atomic.Value(bool) = null;
var is_dev_mode: bool = false;
var configured_db_path: []const u8 = "";

pub fn configure(shutdown: *const std.atomic.Value(bool), dev_mode: bool, db_path: []const u8) void {
    shutdown_requested = shutdown;
    is_dev_mode = dev_mode;
    configured_db_path = db_path;
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

/// Token-authenticated WS endpoint used by replicas that can't reuse the
/// admin cookie session (different origin / no cookies). Validates a
/// stable bearer token from the `?sync_token=` query param and joins the
/// same broadcast registry as `/admin/ws`. Pure relay — every received
/// frame is rebroadcast to all other connected sockets. No apply, no
/// inspection beyond the auth check.
pub fn handleSyncWebSocket(ctx: *Context) !void {
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

    const raw_token = plugin_utils.queryParam(ctx.query, "sync_token") orelse {
        ctx.response.setStatus("401 Unauthorized");
        ctx.response.setBody("Missing sync_token");
        return;
    };
    // queryParam returns the raw URL-encoded value; tokens are base64
    // (`+`, `/`, `=` all percent-encode), so we decode before compare.
    const presented = url_util.pathDecode(ctx.allocator, raw_token);
    if (!sync_token.verify(presented, std.heap.page_allocator)) {
        ctx.response.setStatus("401 Unauthorized");
        ctx.response.setBody("Invalid sync_token");
        return;
    }

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
        websocket.registry.remove(conn);
        std.heap.page_allocator.destroy(conn);
    }

    // Per-connection DB handle for applying incoming changesets locally.
    // SQLite's serialized threading mode (SQLITE_THREADSAFE=1) makes one
    // connection per thread the canonical pattern; opening here keeps
    // the WS thread independent of the main request thread's connection.
    // We also fire db_open_hooks so plugin extensions (cr-sqlite's UDFs
    // and the crsql_changes vtab) get registered on this connection —
    // without that, applyChanges' INSERT INTO crsql_changes fails.
    var db = core_init.initDatabase(std.heap.page_allocator, configured_db_path) catch |err| {
        if (is_dev_mode) std.debug.print("[ws/sync] DB open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer db.deinit();
    core_init.fireDbOpenHooks(&db) catch |err| {
        if (is_dev_mode) std.debug.print("[ws/sync] db_open_hooks failed: {s}\n", .{@errorName(err)});
        return;
    };

    conn.sendJson("connected", null) catch return;
    if (is_dev_mode) {
        std.debug.print("[ws/sync] Connection {d} opened (active: {d})\n", .{ conn.id, websocket.registry.count() });
    }

    // Emit this relay's full state outward. Reaches every connected
    // replica (cr-sqlite dedupes echoes on peers that already have the
    // rows). Lets a fresh WASM replica learn about whatever the native
    // server has stored locally without waiting for the next write.
    sync_catchup_hooks.fireAll(.{
        .db = &db,
        .allocator = std.heap.page_allocator,
    });
    defer {
        if (is_dev_mode) {
            std.debug.print("[ws/sync] Connection {d} closed (active: {d})\n", .{ conn.id, websocket.registry.count() });
        }
    }

    var poll_fds = [_]posix.pollfd{
        .{ .fd = stream.handle, .events = posix.POLL.IN, .revents = 0 },
    };

    while (!shouldShutdown()) {
        // 30s timeout: send a ping to keep NATs / load balancers from
        // dropping the connection.
        const poll_result = posix.poll(&poll_fds, 30_000) catch break;
        if (poll_result == 0) {
            websocket.writeFrame(stream, .ping, &.{}) catch break;
            continue;
        }

        const frame = websocket.readFrame(stream, std.heap.page_allocator) catch break;
        defer std.heap.page_allocator.free(frame.payload);

        switch (frame.opcode) {
            .text => {
                std.debug.print("[ws/sync] #{d}: received {d} bytes\n", .{ conn.id, frame.payload.len });
                // Apply locally so the relay node is itself a replica,
                // then rebroadcast so every OTHER connected replica
                // sees the frame. cr-sqlite's merge is idempotent so a
                // peer that ends up applying its own echo is a no-op.
                applySyncFrame(&db, frame.payload) catch |err| {
                    std.debug.print("[ws/sync] #{d}: apply failed: {s}\n", .{ conn.id, @errorName(err) });
                };
                websocket.registry.broadcast(frame.payload, conn);
            },
            .ping => websocket.writeFrame(stream, .pong, frame.payload) catch break,
            .pong => {},
            .close => {
                conn.sendClose();
                break;
            },
            else => {},
        }
    }
}

/// Unwrap a `{"type":"sync_changes","data":"<inner-json>"}` envelope and
/// dispatch the inner array through `apply_remote_hooks`. The envelope
/// shape is what `sync_transport.send` produces (both native and WASM
/// paths agree on it); `data` is a JSON-encoded string containing the
/// changeset array, so the JSON parser unescapes it for us before we
/// hand the inner bytes to the plugin.
fn applySyncFrame(db: *core_init.Db, envelope: []const u8) !void {
    const alloc = std.heap.page_allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, envelope, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.NotAnObject;

    const t = parsed.value.object.get("type") orelse return error.MissingType;
    if (t != .string or !std.mem.eql(u8, t.string, "sync_changes")) return;

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    if (data != .string) return error.DataNotString;

    try apply_remote_hooks.applyAll(.{
        .db = db,
        .allocator = alloc,
        .payload = data.string,
    });
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
