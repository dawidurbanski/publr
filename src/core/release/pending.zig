//! Pending-release lifecycle: schedule, create, add, remove, archive.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");

const types = @import("types.zig");
const internal = @import("internal.zig");

const ReleaseError = types.ReleaseError;

/// Set a pending release to scheduled state with a target timestamp.
/// No execution — just stores the state for future use.
pub fn scheduleRelease(db: *Db, release_id: []const u8, scheduled_for: i64) (Db.Error || ReleaseError)!void {
    try internal.requireReleaseStatus(db, release_id, &.{"pending"});

    var u_stmt = try db.prepare(
        "UPDATE releases SET status = 'scheduled', scheduled_for = ?1 WHERE id = ?2",
    );
    defer u_stmt.deinit();
    try u_stmt.bindInt(1, scheduled_for);
    try u_stmt.bindText(2, release_id);
    _ = try u_stmt.step();
}

/// Create a pending (batch) release with a name.
pub fn createPendingRelease(db: *Db, name: []const u8, author_id: ?[]const u8) (Db.Error || error{OutOfMemory})![20]u8 {
    const release_id = id_gen.generateReleaseId();

    var stmt = try db.prepare(
        \\INSERT INTO releases (id, name, status, author_id, created_at)
        \\VALUES (?1, ?2, 'pending', ?3, unixepoch())
    );
    defer stmt.deinit();
    try stmt.bindText(1, &release_id);
    try stmt.bindText(2, name);
    if (author_id) |aid| try stmt.bindText(3, aid) else try stmt.bindNull(3);
    _ = try stmt.step();

    return release_id;
}

/// Add an entry to a pending release. INSERT OR REPLACE — re-adding the same
/// entry refreshes the version references. Reads from_version
/// (published_version_id) and to_version (current_version_id) directly from
/// content_entries; callers never supply these.
pub fn addToRelease(
    db: *Db,
    release_id: []const u8,
    entry_id: []const u8,
    fields: ?[]const u8,
) (Db.Error || ReleaseError)!void {
    try internal.requireReleaseStatus(db, release_id, &.{"pending"});

    var e_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1",
    );
    defer e_stmt.deinit();
    try e_stmt.bindText(1, entry_id);
    if (!try e_stmt.step()) return ReleaseError.ReleaseNotFound;
    const to_version = e_stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
    const from_version = e_stmt.columnText(1);

    var stmt = try db.prepare(
        \\INSERT OR REPLACE INTO release_entries (release_id, entry_id, from_version_id, to_version_id, selected_fields)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    try stmt.bindText(2, entry_id);
    if (from_version) |fv| try stmt.bindText(3, fv) else try stmt.bindNull(3);
    try stmt.bindText(4, to_version);
    if (fields) |f| try stmt.bindText(5, f) else try stmt.bindNull(5);
    _ = try stmt.step();
}

/// Remove an entry from a pending release.
pub fn removeFromRelease(db: *Db, release_id: []const u8, entry_id: []const u8) (Db.Error || ReleaseError)!void {
    try internal.requireReleaseStatus(db, release_id, &.{"pending"});

    var stmt = try db.prepare(
        "DELETE FROM release_entries WHERE release_id = ?1 AND entry_id = ?2",
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    try stmt.bindText(2, entry_id);
    _ = try stmt.step();
}

/// Archive a release (any status except pending). Archived releases are
/// hidden from the list by default but can still be viewed directly.
pub fn archiveRelease(db: *Db, release_id: []const u8) (Db.Error || ReleaseError)!void {
    // Original semantic was "reject if pending, otherwise accept" — inverted
    // logic the requireReleaseStatus helper doesn't express, so this check
    // stays inline.
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    var stmt = try db.prepare(
        "UPDATE releases SET status = 'archived' WHERE id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    _ = try stmt.step();
}
