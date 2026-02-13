/// In-memory presence tracking for multi-user editing.
/// Tracks which users are viewing each entry and broadcasts presence changes.
/// Thread-safe: all operations are mutex-protected.
const std = @import("std");
const websocket = @import("websocket");
const gravatar = @import("gravatar");

// =========================================================================
// Types
// =========================================================================

pub const UserInfo = struct {
    user_id: []const u8,
    email: []const u8,
    display_name: []const u8,
};

const Subscriber = struct {
    conn: *websocket.Connection,
    user_id: []const u8, // owned
    email: []const u8, // owned
    display_name: []const u8, // owned
    avatar_url: gravatar.GravatarUrl,
    active: bool,
    last_heartbeat: i64,
};

const ConnEntry = struct {
    conn_id: u64,
    entry_id: []const u8, // owned
};

const PendingLeave = struct {
    entry_id: []const u8, // owned
    user_id: []const u8, // owned
    disconnect_time: i64,
};

const FieldLock = struct {
    conn_id: u64,
    user_id: []const u8, // owned
    name: []const u8, // display name, owned
    avatar_url: gravatar.GravatarUrl,
};

// =========================================================================
// State
// =========================================================================

const GRACE_PERIOD_S: i64 = 5;

var mutex: std.Thread.Mutex = .{};
var alloc: std.mem.Allocator = undefined;

/// entry_id → list of subscribers
var entries: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Subscriber)) = .{};

/// conn_id → entry_id mapping (small set, linear scan is fine)
var conn_map: std.ArrayListUnmanaged(ConnEntry) = .{};

/// Pending leaves awaiting grace period expiry
var pending_leaves: std.ArrayListUnmanaged(PendingLeave) = .{};

/// entry_id → { field_name → FieldLock }
var field_locks: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(FieldLock)) = .{};

pub fn init(a: std.mem.Allocator) void {
    alloc = a;
}

// =========================================================================
// Subscribe — join an entry session
// =========================================================================

pub fn subscribe(entry_id: []const u8, conn: *websocket.Connection, user: UserInfo) void {
    mutex.lock();
    defer mutex.unlock();

    const now = std.time.timestamp();

    // Check for reconnect within grace period (silent restore)
    var silent_restore = false;
    {
        var i: usize = 0;
        while (i < pending_leaves.items.len) {
            const pl = pending_leaves.items[i];
            if (std.mem.eql(u8, pl.entry_id, entry_id) and std.mem.eql(u8, pl.user_id, user.user_id)) {
                silent_restore = (now - pl.disconnect_time) <= GRACE_PERIOD_S;
                freePendingLeave(pl);
                _ = pending_leaves.swapRemove(i);
                break;
            }
            i += 1;
        }
    }

    // Sweep expired pending leaves
    sweepLocked(now);

    // Unsubscribe from any previous entry (navigating between entries in same tab)
    unsubConnLocked(conn.id, true);

    // Create subscriber with owned copies
    const sub = Subscriber{
        .conn = conn,
        .user_id = alloc.dupe(u8, user.user_id) catch return,
        .email = alloc.dupe(u8, user.email) catch return,
        .display_name = alloc.dupe(u8, user.display_name) catch return,
        .avatar_url = gravatar.url(user.email, 24),
        .active = true,
        .last_heartbeat = now,
    };

    // Get or create entry subscriber list
    const gop = entries.getOrPut(alloc, entry_id) catch return;
    if (!gop.found_existing) {
        // New entry — store owned key
        gop.key_ptr.* = alloc.dupe(u8, entry_id) catch return;
        gop.value_ptr.* = .{};
    }
    gop.value_ptr.append(alloc, sub) catch return;

    // Track conn → entry mapping
    conn_map.append(alloc, .{
        .conn_id = conn.id,
        .entry_id = alloc.dupe(u8, entry_id) catch return,
    }) catch return;

    // On silent restore, update lock conn_ids to the new connection
    if (silent_restore) {
        updateLockConnId(entry_id, user.user_id, conn.id);
    }

    // Send presence_sync to joiner (full user list + field lock state)
    sendPresenceSync(conn, entry_id, gop.value_ptr.*);

    // Broadcast user_joined to others (unless silent restore from reconnect)
    if (!silent_restore) {
        broadcastUserEvent("user_joined", sub, gop.value_ptr.*, conn.id);
    }
}

// =========================================================================
// Unsubscribe — explicit leave (no grace period)
// =========================================================================

pub fn unsubscribe(conn_id: u64) void {
    mutex.lock();
    defer mutex.unlock();
    unsubConnLocked(conn_id, true);
}

// =========================================================================
// Disconnect — auto-leave with grace period
// =========================================================================

pub fn disconnect(conn_id: u64) void {
    mutex.lock();
    defer mutex.unlock();

    const entry_id = connEntryId(conn_id) orelse return;

    // Check if this user has another connection to the same entry (multiple tabs)
    if (entries.getPtr(entry_id)) |subs| {
        var this_user_id: ?[]const u8 = null;
        for (subs.items) |s| {
            if (s.conn.id == conn_id) {
                this_user_id = s.user_id;
                break;
            }
        }

        if (this_user_id) |uid| {
            var other_conns: usize = 0;
            for (subs.items) |s| {
                if (std.mem.eql(u8, s.user_id, uid) and s.conn.id != conn_id) other_conns += 1;
            }

            if (other_conns == 0) {
                // Last connection for this user — start grace period
                pending_leaves.append(alloc, .{
                    .entry_id = alloc.dupe(u8, entry_id) catch return,
                    .user_id = alloc.dupe(u8, uid) catch return,
                    .disconnect_time = std.time.timestamp(),
                }) catch {};
            }
        }
    }

    // Remove subscriber from entry (no broadcast — pending leave handles it)
    removeSubFromEntry(entry_id, conn_id, false);

    // Remove conn mapping
    removeConnMapping(conn_id);
}

// =========================================================================
// Activity — active/inactive status change
// =========================================================================

pub fn setActivity(conn_id: u64, active: bool) void {
    mutex.lock();
    defer mutex.unlock();

    const entry_id = connEntryId(conn_id) orelse return;
    const subs = entries.getPtr(entry_id) orelse return;

    for (subs.items) |*s| {
        if (s.conn.id == conn_id) {
            s.active = active;
            // Release all soft locks when going inactive
            if (!active) {
                releaseConnLocks(entry_id, conn_id);
            }
            broadcastUserEvent("user_activity", s.*, subs.*, conn_id);
            return;
        }
    }
}

// =========================================================================
// Heartbeat — keep-alive from client
// =========================================================================

pub fn heartbeat(conn_id: u64) void {
    mutex.lock();
    defer mutex.unlock();

    const now = std.time.timestamp();
    sweepLocked(now);

    const entry_id = connEntryId(conn_id) orelse return;
    const subs = entries.getPtr(entry_id) orelse return;

    for (subs.items) |*s| {
        if (s.conn.id == conn_id) {
            s.last_heartbeat = now;
            return;
        }
    }
}

/// Returns true if connection has missed 2+ heartbeats (>20s stale).
pub fn isHeartbeatStale(conn_id: u64) bool {
    mutex.lock();
    defer mutex.unlock();

    const entry_id = connEntryId(conn_id) orelse return false;
    const subs = entries.getPtr(entry_id) orelse return false;

    for (subs.items) |s| {
        if (s.conn.id == conn_id) {
            return (std.time.timestamp() - s.last_heartbeat) > 20;
        }
    }
    return false;
}

// =========================================================================
// Internal: subscriber management
// =========================================================================

/// Unsubscribe a connection. If broadcast is true, sends user_left.
fn unsubConnLocked(conn_id: u64, broadcast: bool) void {
    const entry_id = connEntryId(conn_id) orelse return;
    releaseConnLocks(entry_id, conn_id);
    removeSubFromEntry(entry_id, conn_id, broadcast);
    removeConnMapping(conn_id);
}

fn removeSubFromEntry(entry_id: []const u8, conn_id: u64, broadcast: bool) void {
    const subs = entries.getPtr(entry_id) orelse return;

    for (subs.items, 0..) |s, i| {
        if (s.conn.id == conn_id) {
            if (broadcast) broadcastLeave(s.user_id, subs.*, conn_id);
            freeSub(s);
            _ = subs.swapRemove(i);
            break;
        }
    }

    // Clean up empty entry
    if (subs.items.len == 0) {
        subs.deinit(alloc);
        if (entries.fetchRemove(entry_id)) |kv| {
            alloc.free(kv.key);
        }
    }
}

fn removeConnMapping(conn_id: u64) void {
    for (conn_map.items, 0..) |ce, i| {
        if (ce.conn_id == conn_id) {
            alloc.free(ce.entry_id);
            _ = conn_map.swapRemove(i);
            return;
        }
    }
}

fn connEntryId(conn_id: u64) ?[]const u8 {
    for (conn_map.items) |ce| {
        if (ce.conn_id == conn_id) return ce.entry_id;
    }
    return null;
}

/// Sweep expired pending leaves — broadcast user_left for each.
fn sweepLocked(now: i64) void {
    var i: usize = 0;
    while (i < pending_leaves.items.len) {
        const pl = pending_leaves.items[i];
        if (now - pl.disconnect_time > GRACE_PERIOD_S) {
            // Release field locks and broadcast user_left
            releaseUserLocks(pl.entry_id, pl.user_id);
            if (entries.getPtr(pl.entry_id)) |subs| {
                broadcastLeave(pl.user_id, subs.*, 0);
            }
            freePendingLeave(pl);
            _ = pending_leaves.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

fn freeSub(s: Subscriber) void {
    alloc.free(s.user_id);
    alloc.free(s.email);
    alloc.free(s.display_name);
}

fn freePendingLeave(pl: PendingLeave) void {
    alloc.free(pl.entry_id);
    alloc.free(pl.user_id);
}

// =========================================================================
// Field Locks — soft locking of individual fields
// =========================================================================

/// Claim a soft lock on a field. Rejected if already locked by another connection.
pub fn focus(conn_id: u64, field_name: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    const entry_id = connEntryId(conn_id) orelse return;
    const subs = entries.getPtr(entry_id) orelse return;

    // Find the subscriber for this connection
    var sub_info: ?Subscriber = null;
    for (subs.items) |s| {
        if (s.conn.id == conn_id) {
            sub_info = s;
            break;
        }
    }
    const sub = sub_info orelse return;

    // Get or create field lock map for this entry
    const gop = field_locks.getOrPut(alloc, entry_id) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = alloc.dupe(u8, entry_id) catch return;
        gop.value_ptr.* = .{};
    }

    // Check if already locked
    if (gop.value_ptr.get(field_name)) |existing| {
        if (existing.conn_id != conn_id) {
            // Locked by another user — reject silently (client should already disable)
            return;
        }
        // Already locked by this connection — no-op
        return;
    }

    // Acquire the lock
    const display = if (sub.display_name.len > 0) sub.display_name else sub.email;
    const lock = FieldLock{
        .conn_id = conn_id,
        .user_id = alloc.dupe(u8, sub.user_id) catch return,
        .name = alloc.dupe(u8, display) catch return,
        .avatar_url = sub.avatar_url,
    };
    const owned_field = alloc.dupe(u8, field_name) catch {
        freeFieldLock(lock);
        return;
    };
    gop.value_ptr.put(alloc, owned_field, lock) catch {
        alloc.free(owned_field);
        freeFieldLock(lock);
        return;
    };

    broadcastFieldFocused(field_name, lock, subs.*, conn_id);
}

/// Release a soft lock on a field.
pub fn blur(conn_id: u64, field_name: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    const entry_id = connEntryId(conn_id) orelse return;
    const subs = entries.getPtr(entry_id) orelse return;
    const locks = field_locks.getPtr(entry_id) orelse return;

    // Verify this connection owns the lock
    if (locks.get(field_name)) |lock| {
        if (lock.conn_id != conn_id) return;
    } else return;

    if (locks.fetchRemove(field_name)) |kv| {
        broadcastFieldBlurred(field_name, kv.value.user_id, subs.*, conn_id);
        freeFieldLock(kv.value);
        alloc.free(kv.key);
    }

    cleanupEntryLocks(entry_id);
}

/// Broadcast a field value edit to other subscribers (real-time sync).
/// raw_value is already JSON-escaped by the client — forwarded as-is.
pub fn fieldEdit(conn_id: u64, field_name: []const u8, raw_value: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    const entry_id = connEntryId(conn_id) orelse return;
    const subs = entries.getPtr(entry_id) orelse return;

    // Verify lock ownership (defense-in-depth)
    const locks = field_locks.getPtr(entry_id) orelse return;
    if (locks.get(field_name)) |lock| {
        if (lock.conn_id != conn_id) return;
    } else return;

    broadcastFieldEditValue(field_name, raw_value, subs.*, conn_id);
}

// =========================================================================
// Internal: field lock management
// =========================================================================

/// Release all field locks held by a connection, broadcasting field_blurred for each.
fn releaseConnLocks(entry_id: []const u8, conn_id: u64) void {
    const locks = field_locks.getPtr(entry_id) orelse return;
    const subs = entries.getPtr(entry_id);

    var to_release: std.ArrayListUnmanaged([]const u8) = .{};
    defer to_release.deinit(alloc);

    var iter = locks.iterator();
    while (iter.next()) |kv| {
        if (kv.value_ptr.conn_id == conn_id) {
            to_release.append(alloc, kv.key_ptr.*) catch continue;
        }
    }

    for (to_release.items) |field_name| {
        if (locks.fetchRemove(field_name)) |kv| {
            if (subs) |s| {
                broadcastFieldBlurred(field_name, kv.value.user_id, s.*, conn_id);
            }
            freeFieldLock(kv.value);
            alloc.free(kv.key);
        }
    }

    cleanupEntryLocks(entry_id);
}

/// Release all field locks held by a user_id (used when grace period expires).
fn releaseUserLocks(entry_id: []const u8, user_id: []const u8) void {
    const locks = field_locks.getPtr(entry_id) orelse return;
    const subs = entries.getPtr(entry_id);

    var to_release: std.ArrayListUnmanaged([]const u8) = .{};
    defer to_release.deinit(alloc);

    var iter = locks.iterator();
    while (iter.next()) |kv| {
        if (std.mem.eql(u8, kv.value_ptr.user_id, user_id)) {
            to_release.append(alloc, kv.key_ptr.*) catch continue;
        }
    }

    for (to_release.items) |field_name| {
        if (locks.fetchRemove(field_name)) |kv| {
            if (subs) |s| {
                broadcastFieldBlurred(field_name, kv.value.user_id, s.*, 0);
            }
            freeFieldLock(kv.value);
            alloc.free(kv.key);
        }
    }

    cleanupEntryLocks(entry_id);
}

/// Update conn_id on all locks for a user (used on silent reconnect restore).
fn updateLockConnId(entry_id: []const u8, user_id: []const u8, new_conn_id: u64) void {
    const locks = field_locks.getPtr(entry_id) orelse return;
    var iter = locks.iterator();
    while (iter.next()) |kv| {
        if (std.mem.eql(u8, kv.value_ptr.user_id, user_id)) {
            kv.value_ptr.conn_id = new_conn_id;
        }
    }
}

fn freeFieldLock(lock: FieldLock) void {
    alloc.free(lock.user_id);
    alloc.free(lock.name);
}

fn cleanupEntryLocks(entry_id: []const u8) void {
    const locks = field_locks.getPtr(entry_id) orelse return;
    if (locks.count() == 0) {
        locks.deinit(alloc);
        if (field_locks.fetchRemove(entry_id)) |kv| {
            alloc.free(kv.key);
        }
    }
}

// =========================================================================
// Internal: JSON building and sending
// =========================================================================

fn sendPresenceSync(conn: *websocket.Connection, entry_id: []const u8, subs: std.ArrayListUnmanaged(Subscriber)) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    const w = buf.writer(alloc);
    w.writeAll("{\"users\":[") catch return;

    for (subs.items, 0..) |s, i| {
        if (i > 0) w.writeByte(',') catch return;
        writeUserJson(w, s) catch return;
    }

    w.writeAll("],\"locks\":{") catch return;

    if (field_locks.getPtr(entry_id)) |locks| {
        var iter = locks.iterator();
        var first = true;
        while (iter.next()) |kv| {
            if (!first) w.writeByte(',') catch return;
            first = false;
            w.writeByte('"') catch return;
            writeJsonStr(w, kv.key_ptr.*) catch return;
            w.writeAll("\":{") catch return;
            writeFieldLockJson(w, kv.value_ptr.*) catch return;
            w.writeByte('}') catch return;
        }
    }

    w.writeAll("}}") catch return;
    conn.sendJson("presence_sync", buf.items) catch {};
}

fn broadcastUserEvent(event_type: []const u8, sub: Subscriber, subs: std.ArrayListUnmanaged(Subscriber), exclude_id: u64) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    writeUserJson(buf.writer(alloc), sub) catch return;
    broadcastToSubs(event_type, buf.items, subs, exclude_id);
}

fn broadcastLeave(user_id: []const u8, subs: std.ArrayListUnmanaged(Subscriber), exclude_id: u64) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    const w = buf.writer(alloc);
    w.writeAll("{\"user_id\":\"") catch return;
    writeJsonStr(w, user_id) catch return;
    w.writeAll("\"}") catch return;

    broadcastToSubs("user_left", buf.items, subs, exclude_id);
}

fn broadcastToSubs(msg_type: []const u8, data: []const u8, subs: std.ArrayListUnmanaged(Subscriber), exclude_id: u64) void {
    for (subs.items) |s| {
        if (s.conn.id != exclude_id) {
            s.conn.sendJson(msg_type, data) catch {};
        }
    }
}

fn writeUserJson(w: anytype, s: Subscriber) !void {
    try w.writeAll("{\"user_id\":\"");
    try writeJsonStr(w, s.user_id);
    try w.writeAll("\",\"name\":\"");
    const name = if (s.display_name.len > 0) s.display_name else s.email;
    try writeJsonStr(w, name);
    try w.writeAll("\",\"avatar_url\":\"");
    try writeJsonStr(w, s.avatar_url.slice());
    try w.writeAll("\",\"active\":");
    try w.writeAll(if (s.active) "true" else "false");
    try w.writeByte('}');
}

fn broadcastFieldFocused(field_name: []const u8, lock: FieldLock, subs: std.ArrayListUnmanaged(Subscriber), exclude_id: u64) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    const w = buf.writer(alloc);
    w.writeAll("{\"field\":\"") catch return;
    writeJsonStr(w, field_name) catch return;
    w.writeAll("\",") catch return;
    writeFieldLockJson(w, lock) catch return;
    w.writeByte('}') catch return;

    broadcastToSubs("field_focused", buf.items, subs, exclude_id);
}

fn broadcastFieldEditValue(field_name: []const u8, raw_value: []const u8, subs: std.ArrayListUnmanaged(Subscriber), exclude_id: u64) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    const w = buf.writer(alloc);
    w.writeAll("{\"field\":\"") catch return;
    writeJsonStr(w, field_name) catch return;
    w.writeAll("\",\"value\":\"") catch return;
    w.writeAll(raw_value) catch return; // Already JSON-escaped by client
    w.writeAll("\"}") catch return;

    broadcastToSubs("field_edit", buf.items, subs, exclude_id);
}

fn broadcastFieldBlurred(field_name: []const u8, user_id: []const u8, subs: std.ArrayListUnmanaged(Subscriber), exclude_id: u64) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    const w = buf.writer(alloc);
    w.writeAll("{\"field\":\"") catch return;
    writeJsonStr(w, field_name) catch return;
    w.writeAll("\",\"user_id\":\"") catch return;
    writeJsonStr(w, user_id) catch return;
    w.writeAll("\"}") catch return;

    broadcastToSubs("field_blurred", buf.items, subs, exclude_id);
}

fn writeFieldLockJson(w: anytype, lock: FieldLock) !void {
    try w.writeAll("\"user_id\":\"");
    try writeJsonStr(w, lock.user_id);
    try w.writeAll("\",\"name\":\"");
    try writeJsonStr(w, lock.name);
    try w.writeAll("\",\"avatar_url\":\"");
    try writeJsonStr(w, lock.avatar_url.slice());
    try w.writeByte('"');
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}
