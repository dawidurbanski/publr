//! Revert + re-release. revertRelease creates a new "reverted" version per
//! entry rolling back to from_version's data. reReleaseReverted does the
//! inverse, restoring to_version after a revert.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");

const types = @import("types.zig");
const internal = @import("internal.zig");

const ReleaseError = types.ReleaseError;

/// Revert a released release: for each item, create a new version with
/// from_version's data, update current_version_id, set release status to
/// 'reverted'. Blocked if any entry's current_version_id != to_version.
pub fn revertRelease(db: *Db, release_id: []const u8, author_id: ?[]const u8) (Db.Error || ReleaseError)!void {
    try internal.requireReleaseStatus(db, release_id, &.{"released"});

    // Check blocking: every entry's current_version must still match to_version
    {
        var stmt = try db.prepare(
            \\SELECT ri.entry_id FROM release_entries ri
            \\JOIN content_entries e ON e.id = ri.entry_id
            \\WHERE ri.release_id = ?1
            \\  AND e.current_version_id != ri.to_version_id
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (try stmt.step()) return ReleaseError.EntryModifiedSinceRelease;
    }

    // For each item, create new version with from_version's data
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.from_version_id, ri.to_version_id
            \\FROM release_entries ri
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const entry_id = items_stmt.columnText(0) orelse continue;
            const from_version = items_stmt.columnText(1);
            const current_to = items_stmt.columnText(2) orelse continue;

            // Get data to restore: from_version's data, or empty JSON if NULL (new entry)
            const data_owned: ?[]u8 = if (from_version) |fv|
                internal.loadVersionData(db.allocator, db, fv) catch null
            else
                null;
            defer if (data_owned) |d| db.allocator.free(d);
            const data: []const u8 = if (data_owned) |d| d else "{}";

            const new_vid = id_gen.generateVersionId();
            {
                var v_stmt = try db.prepare(
                    \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, version_type)
                    \\VALUES (?1, ?2, ?3, ?4, ?5, 'reverted')
                );
                defer v_stmt.deinit();
                try v_stmt.bindText(1, &new_vid);
                try v_stmt.bindText(2, entry_id);
                try v_stmt.bindText(3, current_to);
                try v_stmt.bindText(4, data);
                if (author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);
                _ = try v_stmt.step();
            }

            {
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET current_version_id = ?1, data = ?2, updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, &new_vid);
                try u_stmt.bindText(2, data);
                try u_stmt.bindText(3, entry_id);
                _ = try u_stmt.step();
            }
        }
    }

    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'reverted', reverted_at = unixepoch() WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// Re-release a reverted release: for each item, create a new version with
/// to_version's data, update current_version_id, set status back to 'released'.
/// Blocked if any entry has been modified since the revert.
pub fn reReleaseReverted(db: *Db, release_id: []const u8, author_id: ?[]const u8) (Db.Error || ReleaseError)!void {
    try internal.requireReleaseStatus(db, release_id, &.{"reverted"});

    // Check blocking: the entry's current_version must be the version the
    // revert created, i.e. its parent_id must equal to_version.
    {
        var stmt = try db.prepare(
            \\SELECT ri.entry_id FROM release_entries ri
            \\JOIN content_entries e ON e.id = ri.entry_id
            \\JOIN content_versions ev ON ev.id = e.current_version_id
            \\WHERE ri.release_id = ?1
            \\  AND (ev.parent_id IS NULL OR ev.parent_id != ri.to_version_id)
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (try stmt.step()) return ReleaseError.EntryModifiedSinceRelease;
    }

    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.to_version_id
            \\FROM release_entries ri
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const entry_id = items_stmt.columnText(0) orelse continue;
            const to_version = items_stmt.columnText(1) orelse continue;

            const data_owned = internal.loadVersionData(db.allocator, db, to_version) catch null;
            defer if (data_owned) |d| db.allocator.free(d);
            const data: []const u8 = if (data_owned) |d| d else "{}";

            // Get current version id for parent linkage
            const current_vid_owned: ?[]u8 = blk: {
                var stmt = try db.prepare("SELECT current_version_id FROM content_entries WHERE id = ?1");
                defer stmt.deinit();
                try stmt.bindText(1, entry_id);
                if (try stmt.step()) {
                    if (stmt.columnText(0)) |cv| {
                        break :blk try db.allocator.dupe(u8, cv);
                    }
                }
                break :blk null;
            };
            defer if (current_vid_owned) |c| db.allocator.free(c);

            const new_vid = id_gen.generateVersionId();
            {
                var v_stmt = try db.prepare(
                    \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, version_type)
                    \\VALUES (?1, ?2, ?3, ?4, ?5, 'restored')
                );
                defer v_stmt.deinit();
                try v_stmt.bindText(1, &new_vid);
                try v_stmt.bindText(2, entry_id);
                if (current_vid_owned) |cv| try v_stmt.bindText(3, cv) else try v_stmt.bindNull(3);
                try v_stmt.bindText(4, data);
                if (author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);
                _ = try v_stmt.step();
            }

            {
                var u_stmt = try db.prepare(
                    \\UPDATE content_entries SET current_version_id = ?1, data = ?2, updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, &new_vid);
                try u_stmt.bindText(2, data);
                try u_stmt.bindText(3, entry_id);
                _ = try u_stmt.step();
            }
        }
    }

    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'released', released_at = unixepoch(), reverted_at = NULL WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}
