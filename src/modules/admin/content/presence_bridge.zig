//! Bridges between content actions and the presence/WS broadcast layer:
//! lock-released notifications, published-state broadcast, release-update
//! broadcast, and a small DB helper for user display names.

const std = @import("std");
const db_mod = @import("db");
const cms = @import("cms");
const _p = @import("_platform.zig");

const Allocator = std.mem.Allocator;
const Db = db_mod.Db;
const presence = _p.presence;

/// Notify presence system that published fields had their hard locks released.
pub fn notifyPublishedFieldsReleased(allocator: Allocator, db: *Db, entry_id: []const u8, fields_json: ?[]const u8) void {
    if (fields_json) |fj| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, fj, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;

        var names: std.ArrayListUnmanaged([]const u8) = .{};
        defer names.deinit(allocator);
        for (parsed.value.array.items) |item| {
            if (item == .string) names.append(allocator, item.string) catch continue;
        }
        if (names.items.len > 0) {
            presence.notifyLocksReleased(entry_id, names.items);
            presence.clearOwnershipOverrides(entry_id, names.items);
        }
    } else {
        var stmt = db.prepare("SELECT data FROM content_entries WHERE id = ?1") catch return;
        defer stmt.deinit();
        stmt.bindText(1, entry_id) catch return;
        if (!(stmt.step() catch return)) return;
        const data_str = stmt.columnText(0) orelse return;

        const data_parsed = std.json.parseFromSlice(std.json.Value, allocator, data_str, .{}) catch return;
        defer data_parsed.deinit();
        if (data_parsed.value != .object) return;

        var names: std.ArrayListUnmanaged([]const u8) = .{};
        defer names.deinit(allocator);
        var iter = data_parsed.value.object.iterator();
        while (iter.next()) |kv| {
            names.append(allocator, kv.key_ptr.*) catch continue;
        }
        if (names.items.len > 0) {
            presence.notifyLocksReleased(entry_id, names.items);
            presence.clearOwnershipOverrides(entry_id, names.items);
        }
    }
}

/// Broadcast the new published state to all subscribers of an entry.
pub fn broadcastPublishedState(allocator: Allocator, db: *Db, entry_id: []const u8) void {
    const published_data = cms.getPublishedData(allocator, db, entry_id) catch return orelse return;

    var stmt = db.prepare("SELECT status FROM content_entries WHERE id = ?1") catch return;
    defer stmt.deinit();
    stmt.bindText(1, entry_id) catch return;
    const status = if (stmt.step() catch return)
        (stmt.columnText(0) orelse "published")
    else
        "published";

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"published_state\":") catch return;
    w.writeAll(published_data) catch return;
    w.writeAll(",\"status\":\"") catch return;
    w.writeAll(status) catch return;
    w.writeAll("\"}") catch return;

    presence.broadcastEntryMessage(entry_id, "published_state", buf.items);
}

/// Broadcast updated fieldsInReleases to all subscribers of an entry.
pub fn broadcastReleaseUpdate(allocator: Allocator, db: *Db, entry_id: []const u8) void {
    const editor_json = @import("editor_json.zig");
    const release_field_info = cms.getEntryPendingReleaseFields(allocator, db, entry_id) catch return;
    const json = editor_json.buildFieldsInReleasesJson(allocator, release_field_info) catch return;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"fields_in_releases\":") catch return;
    w.writeAll(json) catch return;
    w.writeByte('}') catch return;

    presence.broadcastEntryMessage(entry_id, "release_updated", buf.items);
}

/// Get a user's display_name from the DB.
pub fn getUserDisplayName(allocator: Allocator, db: *Db, user_id: ?[]const u8) ?[]const u8 {
    const uid = user_id orelse return null;
    var stmt = db.prepare("SELECT display_name FROM users WHERE id = ?1") catch return null;
    defer stmt.deinit();
    stmt.bindText(1, uid) catch return null;
    if (!(stmt.step() catch return null)) return null;
    const dn = stmt.columnText(0) orelse return null;
    if (dn.len == 0) return null;
    return allocator.dupe(u8, dn) catch null;
}
