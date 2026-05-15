//! Single-entry publish via the shared batch path. Creates a transient
//! "instant release" (unnamed pending row), adds the entry, and publishes.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");

const pending = @import("pending.zig");
const batch_publish = @import("batch_publish.zig");

const Allocator = std.mem.Allocator;

/// Publish a single entry by creating an instant release and publishing it.
/// Handles both full and partial (field-level) publish through the same
/// publishBatchRelease path — one code path for all publishing.
pub fn publishEntry(allocator: Allocator, db: *Db, entry_id: []const u8, author_id: ?[]const u8, fields_json: ?[]const u8) !void {
    // Skip if already published with same version and no partial fields
    if (fields_json == null) {
        var e_stmt = try db.prepare("SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1");
        defer e_stmt.deinit();
        try e_stmt.bindText(1, entry_id);
        if (!try e_stmt.step()) return error.EntryNotFound;
        const to_version = e_stmt.columnText(0) orelse return error.EntryNotFound;
        if (e_stmt.columnText(1)) |fv| {
            if (std.mem.eql(u8, fv, to_version)) return;
        }
    }

    // Create pending release (instant = unnamed)
    const release_id = id_gen.generateReleaseId();
    {
        var stmt = try db.prepare(
            \\INSERT INTO releases (id, name, status, author_id, created_at)
            \\VALUES (?1, NULL, 'pending', ?2, unixepoch())
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        if (author_id) |aid| try stmt.bindText(2, aid) else try stmt.bindNull(2);
        _ = try stmt.step();
    }

    // Add single item — addToRelease reads from/to versions from content_entries
    try pending.addToRelease(db, &release_id, entry_id, fields_json);

    // Publish through the single shared path
    try batch_publish.publishBatchRelease(allocator, db, &release_id);
}
