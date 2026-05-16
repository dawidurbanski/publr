//! Detect per-field conflicts for a release: places where from_version_id
//! has drifted from current published_version_id since the release was
//! staged. Drives the warning banner on the release detail page.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;

const types = @import("types.zig");
const internal = @import("internal.zig");
const entry_ops = @import("entry_ops.zig");

const Allocator = std.mem.Allocator;
const ReleaseFieldConflict = types.ReleaseFieldConflict;

/// Returns one entry per conflicted field. For full-publish entries that
/// have drifted, emits one synthetic "(full entry)" conflict per entry.
pub fn detectReleaseConflicts(allocator: Allocator, db: *Db, release_id: []const u8) ![]const ReleaseFieldConflict {
    var items_stmt = try db.prepare(
        \\SELECT ri.entry_id, COALESCE(e.title, '(untitled)'),
        \\  ri.from_version_id, e.published_version_id,
        \\  ri.selected_fields, ri.to_version_id
        \\FROM release_entries ri
        \\JOIN content_entries e ON e.id = ri.entry_id
        \\WHERE ri.release_id = ?1
    );
    defer items_stmt.deinit();
    try items_stmt.bindText(1, release_id);

    var conflicts: std.ArrayList(ReleaseFieldConflict) = .{};
    errdefer conflicts.deinit(allocator);

    while (try items_stmt.step()) {
        const entry_id = items_stmt.columnText(0) orelse continue;
        const entry_title = items_stmt.columnText(1) orelse "(untitled)";
        const from_vid = items_stmt.columnText(2);
        const published_vid = items_stmt.columnText(3);

        // No conflict if from_version matches current published version
        if (from_vid) |fv| {
            if (published_vid) |pv| {
                if (std.mem.eql(u8, fv, pv)) continue;
            } else continue; // from_vid set but no published — shouldn't happen, skip
        } else {
            if (published_vid == null) continue; // Both null — first publish, no conflict
            // from_vid null but published exists — entry was published after staging
        }

        const fields_json = items_stmt.columnText(4);
        const to_vid = items_stmt.columnText(5) orelse continue;

        // Get the release's snapshot data (to_version) via the shared loader.
        const to_data_owned = internal.loadVersionData(allocator, db, to_vid) catch null;
        defer if (to_data_owned) |d| allocator.free(d);
        const to_data: []const u8 = if (to_data_owned) |d| d else "{}";

        const pub_data = entry_ops.getPublishedData(allocator, db, entry_id) catch continue orelse continue;
        defer allocator.free(pub_data);

        if (fields_json) |fj| {
            // Partial publish — compare per-field
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, fj, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .array) continue;

            const to_parsed = std.json.parseFromSlice(std.json.Value, allocator, to_data, .{}) catch continue;
            defer to_parsed.deinit();
            const to_obj = if (to_parsed.value == .object) to_parsed.value.object else continue;

            const pub_parsed = std.json.parseFromSlice(std.json.Value, allocator, pub_data, .{}) catch continue;
            defer pub_parsed.deinit();
            const pub_obj = if (pub_parsed.value == .object) pub_parsed.value.object else continue;

            // Get from_version data for comparison
            const from_owned: ?[]u8 = if (from_vid) |fv|
                internal.loadVersionData(allocator, db, fv) catch null
            else
                null;
            defer if (from_owned) |fa| allocator.free(fa);
            const from_data: []const u8 = if (from_owned) |fa| fa else "{}";

            const from_parsed = std.json.parseFromSlice(std.json.Value, allocator, from_data, .{}) catch continue;
            defer from_parsed.deinit();
            const from_obj = if (from_parsed.value == .object) from_parsed.value.object else continue;

            for (parsed.value.array.items) |field_item| {
                if (field_item != .string) continue;
                const fname = field_item.string;

                const from_val = from_obj.get(fname);
                const pub_val = pub_obj.get(fname);

                const from_str = if (from_val) |v| internal.stringifyJsonValue(allocator, v) catch null else null;
                defer if (from_str) |s| allocator.free(s);
                const pub_str = if (pub_val) |v| internal.stringifyJsonValue(allocator, v) catch null else null;
                defer if (pub_str) |s| allocator.free(s);

                const from_s = from_str orelse "";
                const pub_s = pub_str orelse "";
                if (std.mem.eql(u8, from_s, pub_s)) continue;

                const release_val = if (to_obj.get(fname)) |v| internal.stringifyJsonValue(allocator, v) catch try allocator.dupe(u8, "?") else try allocator.dupe(u8, "(not set)");
                try conflicts.append(allocator, .{
                    .entry_id = try allocator.dupe(u8, entry_id),
                    .entry_title = try allocator.dupe(u8, entry_title),
                    .field_name = try allocator.dupe(u8, fname),
                    .release_value = release_val,
                    .current_value = try allocator.dupe(u8, pub_s),
                });
            }
        } else {
            // Full publish — synthetic per-entry conflict
            try conflicts.append(allocator, .{
                .entry_id = try allocator.dupe(u8, entry_id),
                .entry_title = try allocator.dupe(u8, entry_title),
                .field_name = try allocator.dupe(u8, "(full entry)"),
                .release_value = try allocator.dupe(u8, "(full snapshot)"),
                .current_value = try allocator.dupe(u8, "(modified since staging)"),
            });
        }
    }

    return conflicts.toOwnedSlice(allocator);
}
