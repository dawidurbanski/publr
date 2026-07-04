//! Author resolution helpers for the content list view + ownership tracking.

const std = @import("std");
const db_mod = @import("db");
const gravatar = @import("gravatar");
const views = @import("views");

const Allocator = std.mem.Allocator;
const Db = db_mod.Db;

pub const AuthorInfo = struct {
    id: []const u8,
    display_name: []const u8,
    email: []const u8,

    pub fn label(self: AuthorInfo) []const u8 {
        return if (self.display_name.len > 0) self.display_name else self.email;
    }
};

pub const AuthorOption = struct {
    value: []const u8,
    label: []const u8,
    selected: bool,
};

pub const EntryAuthors = struct {
    entry_id: []const u8,
    authors: []const AuthorInfo,
};

pub fn resolveEntryAuthors(allocator: Allocator, db: *Db, entry_ids: []const []const u8) []const EntryAuthors {
    if (entry_ids.len == 0) return &.{};

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    w.writeAll(
        \\SELECT DISTINCT ev.entry_id, u.id, u.display_name, u.email
        \\ FROM content_versions ev JOIN users u ON u.id = ev.author_id
        \\ WHERE ev.author_id IS NOT NULL AND ev.version_type IN ('created', 'updated', 'published')
        \\ AND ev.entry_id IN (
    ) catch return &.{};

    for (entry_ids, 0..) |_, i| {
        if (i > 0) w.writeByte(',') catch return &.{};
        w.print("?{d}", .{i + 1}) catch return &.{};
    }
    w.writeAll(") ORDER BY ev.entry_id, ev.created_at ASC") catch return &.{};

    const sql = sql_buf.toOwnedSlice(allocator) catch return &.{};
    defer allocator.free(sql);

    var stmt = db.prepare(sql) catch return &.{};
    defer stmt.deinit();

    for (entry_ids, 0..) |eid, i| {
        stmt.bindText(@intCast(i + 1), eid) catch return &.{};
    }

    var results: std.ArrayListUnmanaged(EntryAuthors) = .{};
    var current_authors: std.ArrayListUnmanaged(AuthorInfo) = .{};
    var current_entry_id: ?[]const u8 = null;

    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        const row_entry_id = stmt.columnText(0) orelse continue;
        const user_id = stmt.columnText(1) orelse continue;
        const display_name = stmt.columnText(2) orelse "";
        const email = stmt.columnText(3) orelse continue;

        if (current_entry_id) |cur| {
            if (!std.mem.eql(u8, cur, row_entry_id)) {
                const authors_slice = current_authors.toOwnedSlice(allocator) catch continue;
                results.append(allocator, .{ .entry_id = cur, .authors = authors_slice }) catch continue;
                current_entry_id = allocator.dupe(u8, row_entry_id) catch continue;
            }
        } else {
            current_entry_id = allocator.dupe(u8, row_entry_id) catch continue;
        }

        var duplicate = false;
        for (current_authors.items) |existing| {
            if (std.mem.eql(u8, existing.id, user_id)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            current_authors.append(allocator, .{
                .id = allocator.dupe(u8, user_id) catch continue,
                .display_name = allocator.dupe(u8, display_name) catch continue,
                .email = allocator.dupe(u8, email) catch continue,
            }) catch continue;
        }
    }

    if (current_entry_id) |cur| {
        const authors_slice = current_authors.toOwnedSlice(allocator) catch return results.toOwnedSlice(allocator) catch &.{};
        results.append(allocator, .{ .entry_id = cur, .authors = authors_slice }) catch {};
    }

    return results.toOwnedSlice(allocator) catch &.{};
}

pub fn findAuthorsForEntry(all: []const EntryAuthors, entry_id: []const u8) []const AuthorInfo {
    for (all) |ea| {
        if (std.mem.eql(u8, ea.entry_id, entry_id)) return ea.authors;
    }
    return &.{};
}

pub fn renderAuthorCell(allocator: Allocator, authors: []const AuthorInfo) []const u8 {
    const max_show: usize = 3;
    // Single author shows just itself; groups show up to `max_show`. Dupe the
    // gravatar URL — `avatar.slice()` points into a loop-local that dies each
    // iteration, so it must be copied to outlive the component call.
    const Shown = struct { avatar_url: []const u8, label: []const u8 };
    const show_count = if (authors.len == 1) @as(usize, 1) else @min(authors.len, max_show);
    var shown: std.ArrayListUnmanaged(Shown) = .{};
    for (authors[0..show_count]) |a| {
        const avatar = gravatar.url(a.email, 24);
        shown.append(allocator, .{
            .avatar_url = allocator.dupe(u8, avatar.slice()) catch continue,
            .label = a.label(),
        }) catch continue;
    }

    var buf: std.ArrayList(u8) = .{};
    views.components.author_cell.AuthorCell(buf.writer(allocator).any(), .{
        .authors = shown.items,
        .total = authors.len,
        .overflow = if (authors.len > max_show) authors.len - max_show else 0,
    }) catch return "System";
    return buf.toOwnedSlice(allocator) catch "System";
}

pub fn getAvailableAuthors(allocator: Allocator, db: *Db, content_type_id: []const u8) []const AuthorInfo {
    var stmt = db.prepare(
        \\SELECT DISTINCT u.id, u.display_name, u.email FROM users u
        \\JOIN content_versions ev ON ev.author_id = u.id
        \\JOIN content_entries e ON e.id = ev.entry_id
        \\WHERE e.content_type_id = ?1 AND ev.version_type IN ('created', 'updated', 'published')
        \\ORDER BY u.display_name, u.email
    ) catch return &.{};
    defer stmt.deinit();
    stmt.bindText(1, content_type_id) catch return &.{};

    var results: std.ArrayListUnmanaged(AuthorInfo) = .{};
    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        results.append(allocator, .{
            .id = allocator.dupe(u8, stmt.columnText(0) orelse continue) catch continue,
            .display_name = allocator.dupe(u8, stmt.columnText(1) orelse "") catch continue,
            .email = allocator.dupe(u8, stmt.columnText(2) orelse continue) catch continue,
        }) catch continue;
    }
    return results.toOwnedSlice(allocator) catch &.{};
}

pub fn getEntryIdsByAuthor(allocator: Allocator, db: *Db, author_id: []const u8, content_type_id: []const u8) []const []const u8 {
    var stmt = db.prepare(
        \\SELECT DISTINCT ev.entry_id FROM content_versions ev
        \\JOIN content_entries e ON e.id = ev.entry_id
        \\WHERE ev.author_id = ?1 AND e.content_type_id = ?2
        \\AND ev.version_type IN ('created', 'updated', 'published')
    ) catch return &.{};
    defer stmt.deinit();
    stmt.bindText(1, author_id) catch return &.{};
    stmt.bindText(2, content_type_id) catch return &.{};

    var results: std.ArrayListUnmanaged([]const u8) = .{};
    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        results.append(allocator, allocator.dupe(u8, stmt.columnText(0) orelse continue) catch continue) catch continue;
    }
    return results.toOwnedSlice(allocator) catch &.{};
}
