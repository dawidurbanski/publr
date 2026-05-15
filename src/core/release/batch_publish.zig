//! The single shared batch-publish path. Was two near-identical functions —
//! publishBatchRelease and publishBatchReleaseWithSkips — with the latter
//! re-implementing the former's full-publish branch verbatim and adding an
//! optional skip-set for the partial-publish merge.
//!
//! Now: one implementation. `publishBatchRelease` is a strict wrapper that
//! preserves the original "pending only" status check and forwards to
//! `publishBatchReleaseWithSkips` with `null` skips.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");

const internal = @import("internal.zig");
const entry_ops = @import("entry_ops.zig");
const collaborators = @import("collaborators.zig");

const Allocator = std.mem.Allocator;

/// Strict wrapper: only accepts `pending` releases. Preserves the original
/// (pre-unification) behavior of `publishBatchRelease`. Internally delegates
/// to `publishBatchReleaseWithSkips` with null skip-set.
pub fn publishBatchRelease(allocator: Allocator, db: *Db, release_id: []const u8) !void {
    try internal.requireReleaseStatus(db, release_id, &.{"pending"});
    try publishBatchReleaseWithSkips(allocator, db, release_id, null);
}

/// Publish a batch release with an optional list of field names to skip from
/// partial-publish merges. Accepts `pending` or `scheduled` releases.
///
/// When `skip_fields_json` is null/empty the behavior reduces to the
/// pre-unification `publishBatchRelease`: every field of every selected
/// partial-publish entry is merged in, and full-publish entries take the
/// full to_version state.
pub fn publishBatchReleaseWithSkips(
    allocator: Allocator,
    db: *Db,
    release_id: []const u8,
    skip_fields_json: ?[]const u8,
) !void {
    // Parse skip fields. The `if (skip_set) |ss|` guard inside the loop
    // means a null skip_set leaves behavior exactly as if no skips were
    // requested — that's what makes the wrapper call valid.
    var skip_set: ?std.json.ArrayHashMap(void) = null;
    defer if (skip_set) |*ss| ss.map.deinit(allocator);

    if (skip_fields_json) |sfj| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, sfj, .{}) catch null;
        defer if (parsed) |p| p.deinit();

        if (parsed) |p| {
            if (p.value == .array) {
                var set: std.json.ArrayHashMap(void) = .{};
                for (p.value.array.items) |item| {
                    if (item == .string) {
                        set.map.put(allocator, item.string, {}) catch continue;
                    }
                }
                skip_set = set;
            }
        }
    }

    try internal.requireReleaseStatus(db, release_id, &.{ "pending", "scheduled" });

    // Fetch release author for collaborator attribution
    var release_author_id: ?[]const u8 = null;
    {
        var a_stmt = try db.prepare("SELECT author_id FROM releases WHERE id = ?1");
        defer a_stmt.deinit();
        try a_stmt.bindText(1, release_id);
        if (try a_stmt.step()) {
            if (a_stmt.columnText(0)) |aid| {
                release_author_id = try allocator.dupe(u8, aid);
            }
        }
    }
    defer if (release_author_id) |a| allocator.free(a);

    // For each item: apply to_version data and set status/published_version_id
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.to_version_id, ev.data_json, ri.selected_fields, ri.from_version_id
            \\FROM release_entries ri
            \\JOIN content_versions ev ON ev.id = ri.to_version_id
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const eid = items_stmt.columnText(0) orelse continue;
            const to_vid = items_stmt.columnText(1) orelse continue;
            const to_data = items_stmt.columnText(2) orelse continue;
            const fields = items_stmt.columnText(3);
            const from_vid = items_stmt.columnText(4);

            if (fields) |fields_json| {
                try publishPartial(allocator, db, eid, to_vid, to_data, from_vid, fields_json, skip_set, release_id, release_author_id);
            } else {
                try publishFull(allocator, db, eid, to_vid, to_data, from_vid, release_author_id);
            }
        }
    }

    // Mark release as released
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'released', released_at = unixepoch() WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// Partial-publish path: merge selected fields from to_version data into
/// current published data, create a new "published" version, and update
/// the entry/release-entries rows accordingly.
fn publishPartial(
    allocator: Allocator,
    db: *Db,
    eid: []const u8,
    to_vid: []const u8,
    to_data: []const u8,
    from_vid: ?[]const u8,
    fields_json: []const u8,
    skip_set: ?std.json.ArrayHashMap(void),
    release_id: []const u8,
    release_author_id: ?[]const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, fields_json, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .array) return;

    const arr = parsed.value.array;
    var names = allocator.alloc([]const u8, arr.items.len) catch return;
    defer allocator.free(names);
    var count: usize = 0;

    for (arr.items) |item| {
        if (item == .string) {
            // Skip filtering: only consult skip_set if it was provided.
            // Null skip_set ⇒ no filtering ⇒ original behavior.
            if (skip_set) |ss| {
                if (ss.map.contains(item.string)) continue;
            }
            names[count] = item.string;
            count += 1;
        }
    }
    if (count == 0) return;
    const field_names = names[0..count];

    // Get current published data
    const published_data = entry_ops.getPublishedData(allocator, db, eid) catch return orelse return;
    defer allocator.free(published_data);

    // Merge: published + selected fields from to_version data
    const merged_data = entry_ops.mergeJsonFields(allocator, published_data, to_data, field_names) catch return;
    defer allocator.free(merged_data);

    // Collect collaborators from version chain
    const collab_json = collaborators.collectCollaborators(
        allocator,
        db,
        eid,
        from_vid,
        to_vid,
        release_author_id,
    ) catch null;
    defer if (collab_json) |c| allocator.free(c);

    // Create new version with merged data, author, and collaborators
    const new_vid = id_gen.generateVersionId();
    {
        var v_stmt = try db.prepare(
            \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, version_type, collaborators)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 'published', ?6)
        );
        defer v_stmt.deinit();
        try v_stmt.bindText(1, &new_vid);
        try v_stmt.bindText(2, eid);
        try v_stmt.bindText(3, to_vid);
        try v_stmt.bindText(4, merged_data);
        try v_stmt.bindNull(5);
        if (collab_json) |cj| try v_stmt.bindText(6, cj) else try v_stmt.bindNull(6);
        _ = try v_stmt.step();
    }

    // Update release_entries.to_version to point to the new published version
    {
        var ri_stmt = try db.prepare(
            "UPDATE release_entries SET to_version_id = ?1 WHERE release_id = ?2 AND entry_id = ?3",
        );
        defer ri_stmt.deinit();
        try ri_stmt.bindText(1, &new_vid);
        try ri_stmt.bindText(2, release_id);
        try ri_stmt.bindText(3, eid);
        _ = try ri_stmt.step();
    }

    // Determine status: compare merged (new published) vs current draft
    const still_changed = try compareCurrentToPublished(db, eid, merged_data, .true_on_missing);

    const new_status: []const u8 = if (still_changed) "changed" else "published";
    var u_stmt = try db.prepare(
        \\UPDATE content_entries SET status = ?1, published_version_id = ?2,
        \\published_at = unixepoch(), updated_at = unixepoch()
        \\WHERE id = ?3
    );
    defer u_stmt.deinit();
    try u_stmt.bindText(1, new_status);
    try u_stmt.bindText(2, &new_vid);
    try u_stmt.bindText(3, eid);
    _ = try u_stmt.step();

    try internal.mirrorPublishedState(db, eid, &new_vid, new_status, release_author_id);
}

/// Full-publish path: set published_version_id to to_version, mark the
/// version as 'published', and stash collaborators on it.
fn publishFull(
    allocator: Allocator,
    db: *Db,
    eid: []const u8,
    to_vid: []const u8,
    to_data: []const u8,
    from_vid: ?[]const u8,
    release_author_id: ?[]const u8,
) !void {
    const still_changed = try compareCurrentToPublished(db, eid, to_data, .false_on_missing);

    const new_status: []const u8 = if (still_changed) "changed" else "published";
    var u_stmt = try db.prepare(
        \\UPDATE content_entries SET status = ?1, published_version_id = ?2,
        \\published_at = unixepoch(), updated_at = unixepoch()
        \\WHERE id = ?3
    );
    defer u_stmt.deinit();
    try u_stmt.bindText(1, new_status);
    try u_stmt.bindText(2, to_vid);
    try u_stmt.bindText(3, eid);
    _ = try u_stmt.step();

    try internal.mirrorPublishedState(db, eid, to_vid, new_status, release_author_id);

    const collab_json = collaborators.collectCollaborators(allocator, db, eid, from_vid, to_vid, release_author_id) catch null;
    defer if (collab_json) |c| allocator.free(c);

    var vt_stmt = try db.prepare(
        "UPDATE content_versions SET version_type = 'published', collaborators = ?1 WHERE id = ?2",
    );
    defer vt_stmt.deinit();
    if (collab_json) |cj| try vt_stmt.bindText(1, cj) else try vt_stmt.bindNull(1);
    try vt_stmt.bindText(2, to_vid);
    _ = try vt_stmt.step();
}

/// Returns whether the entry's current_version's data still differs from
/// the just-published version. The original partial path defaulted to
/// "still_changed = true" when the current version row was missing; the
/// full path defaulted to "false". Keeping that asymmetry preserves
/// observable behavior. Pass `.true_on_missing` or `.false_on_missing`.
const MissingPolicy = enum { true_on_missing, false_on_missing };

fn compareCurrentToPublished(
    db: *Db,
    entry_id: []const u8,
    new_published_data: []const u8,
    on_missing: MissingPolicy,
) !bool {
    var stmt = try db.prepare(
        \\SELECT ev.data_json FROM content_entries e
        \\JOIN content_versions ev ON ev.id = e.current_version_id
        \\WHERE e.id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);

    if (!try stmt.step()) {
        return on_missing == .true_on_missing;
    }
    if (stmt.columnText(0)) |cur_data| {
        return !std.mem.eql(u8, cur_data, new_published_data);
    }
    // current_version_id is NULL — same as missing for behavior purposes.
    return on_missing == .true_on_missing;
}

