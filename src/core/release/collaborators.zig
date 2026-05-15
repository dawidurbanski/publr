//! Build the JSON collaborators array for a published version: every unique
//! author whose version landed between from_version and to_version, plus the
//! publisher who triggered the release.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const version_mod = @import("version");

const Allocator = std.mem.Allocator;

const writeEscaped = version_mod.writeEscaped;

/// Collect unique collaborators between from_version and to_version for an
/// entry. Returns a JSON array like
/// `[{"id":"u1","email":"a@b.com","name":"Alice"}]`, or null if there are
/// no contributors.
pub fn collectCollaborators(
    allocator: Allocator,
    db: *Db,
    entry_id: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    publisher_id: ?[]const u8,
) !?[]const u8 {
    // Get from_version's created_at as lower bound (0 if null = include all)
    var from_time: i64 = 0;
    if (from_version) |fv| {
        var t_stmt = try db.prepare("SELECT created_at FROM content_versions WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, fv);
        if (try t_stmt.step()) {
            from_time = t_stmt.columnInt(0);
        }
    }

    // Get to_version's created_at as upper bound
    var to_time: i64 = std.math.maxInt(i32);
    {
        var t_stmt = try db.prepare("SELECT created_at FROM content_versions WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, to_version);
        if (try t_stmt.step()) {
            to_time = t_stmt.columnInt(0);
        }
    }

    const Collab = struct { id: []const u8, email: []const u8, name: []const u8 };
    var collabs: std.ArrayListUnmanaged(Collab) = .{};
    defer {
        for (collabs.items) |c| {
            allocator.free(c.id);
            allocator.free(c.email);
            allocator.free(c.name);
        }
        collabs.deinit(allocator);
    }

    {
        var stmt = try db.prepare(
            \\SELECT DISTINCT ev.author_id, u.email, u.display_name
            \\FROM content_versions ev
            \\JOIN users u ON u.id = ev.author_id
            \\WHERE ev.entry_id = ?1
            \\  AND ev.author_id IS NOT NULL
            \\  AND ev.created_at > ?2
            \\  AND ev.created_at <= ?3
        );
        defer stmt.deinit();
        try stmt.bindText(1, entry_id);
        try stmt.bindInt(2, from_time);
        try stmt.bindInt(3, to_time);

        while (try stmt.step()) {
            const aid = stmt.columnText(0) orelse continue;
            const email = stmt.columnText(1) orelse continue;
            const name = stmt.columnText(2) orelse "";

            try collabs.append(allocator, .{
                .id = try allocator.dupe(u8, aid),
                .email = try allocator.dupe(u8, email),
                .name = try allocator.dupe(u8, name),
            });
        }
    }

    // Add publisher if not already present
    if (publisher_id) |pid| {
        var exists = false;
        for (collabs.items) |c| {
            if (std.mem.eql(u8, c.id, pid)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            var pu_stmt = try db.prepare("SELECT email, display_name FROM users WHERE id = ?1");
            defer pu_stmt.deinit();
            try pu_stmt.bindText(1, pid);
            if (try pu_stmt.step()) {
                if (pu_stmt.columnText(0)) |email| {
                    const name = pu_stmt.columnText(1) orelse "";
                    try collabs.append(allocator, .{
                        .id = try allocator.dupe(u8, pid),
                        .email = try allocator.dupe(u8, email),
                        .name = try allocator.dupe(u8, name),
                    });
                }
            }
        }
    }

    if (collabs.items.len == 0) return null;

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('[');
    for (collabs.items, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, c.id);
        try w.writeAll("\",\"email\":\"");
        try writeEscaped(w, c.email);
        try w.writeAll("\",\"name\":\"");
        try writeEscaped(w, c.name);
        try w.writeAll("\"}");
    }
    try w.writeByte(']');

    return try buf.toOwnedSlice(allocator);
}
