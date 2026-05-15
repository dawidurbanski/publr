//! Takeover request handler — invoked from WebSocket dispatch (http.zig)
//! when a user requests to take over a hard-locked field.

const std = @import("std");
const auth_middleware = @import("auth_middleware");
const gravatar = @import("gravatar");
const pu = @import("plugin_utils");
const _p = @import("_platform.zig");
const parse = @import("parse.zig");

const websocket = _p.websocket;
const presence = _p.presence;
const writeJsonEscaped = pu.writeJsonEscaped;

/// Handle a takeover request from a WebSocket connection. Content-type
/// agnostic — works for any entry.
pub fn handleTakeover(conn: *websocket.Connection, field_name: []const u8, user: _p.UserInfo) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db = if (auth_middleware.auth) |a| a.db else return;
    const entry_id = presence.getConnEntryId(conn.id) orelse return;

    const owners = parse.getFieldOwnership(allocator, db, entry_id) catch {
        sendTakeoverResult(conn, field_name, false, "internal error");
        return;
    };

    if (owners == null) {
        sendTakeoverResult(conn, field_name, false, "no pending changes on this field");
        return;
    }

    const field_info = owners.?.get(field_name) orelse {
        sendTakeoverResult(conn, field_name, false, "no pending changes on this field");
        return;
    };

    const owner_id = field_info.changed_by_id orelse {
        sendTakeoverResult(conn, field_name, false, "field has no owner");
        return;
    };

    if (std.mem.eql(u8, owner_id, user.user_id)) {
        sendTakeoverResult(conn, field_name, false, "you already own this field");
        return;
    }

    if (!presence.checkTakeoverAllowed(entry_id, owner_id, field_name)) {
        sendTakeoverResult(conn, field_name, false, "user is currently editing this field");
        return;
    }

    const display_name = if (user.display_name.len > 0) user.display_name else user.email;
    const avatar = gravatar.url(user.email, 24);
    presence.registerTakeover(entry_id, field_name, user.user_id, display_name, avatar.slice());

    sendTakeoverResult(conn, field_name, true, null);
}

fn sendTakeoverResult(conn: *websocket.Connection, field_name: []const u8, success: bool, reason: ?[]const u8) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.heap.page_allocator);
    const w = buf.writer(std.heap.page_allocator);

    w.writeAll("{\"field\":\"") catch return;
    writeJsonEscaped(w, field_name) catch return;
    if (success) {
        w.writeAll("\",\"success\":true}") catch return;
    } else {
        w.writeAll("\",\"success\":false") catch return;
        if (reason) |r| {
            w.writeAll(",\"reason\":\"") catch return;
            writeJsonEscaped(w, r) catch return;
            w.writeByte('"') catch return;
        }
        w.writeByte('}') catch return;
    }

    conn.sendJson("takeover_result", buf.items) catch {};
}
