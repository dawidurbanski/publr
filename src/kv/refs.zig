//! Reverse-index (`kv_refs`) maintenance.
//!
//! Tracks which `(entry_id, field_path)` locations reference which variable
//! keys. Populated by the `afterSave` hook (called from `saveEntry` after
//! the entry's data JSON lands in `content_entries`). Cleaned up by
//! `dropEntryRefs` (called from `deleteEntry`).
//!
//! The hook scans every string node in the entry's data JSON, runs the
//! parser to extract `[kv:key]` tokens, and writes one row per
//! `(var_key, entry_id, field_path)` to `kv_refs`. Non-string nodes are
//! recursed into (objects, arrays) so nested fields are tracked too.
//!
//! Failure mode: the hook swallows errors and logs. If a hook invocation
//! fails mid-way the entry may have fewer refs than reality until the next
//! save rebuilds them. Acceptable for v1 — eventual consistency.

const std = @import("std");
const Db = @import("db").Db;
const parser = @import("parser.zig");
const save_hooks = @import("save_hooks");

/// Replace refs for a single (entry, field_path) with those extracted from
/// `content`. Used by direct API callers and tests. The hook uses a
/// different path (`afterSave` → `walkAndIndex`) because the hook owns the
/// whole entry, not just one field.
pub fn updateRefs(
    db: *Db,
    allocator: std.mem.Allocator,
    entry_id: []const u8,
    field_path: []const u8,
    content: []const u8,
) !void {
    const keys = try parser.extractKeys(allocator, content);
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }

    try dropFieldRefs(db, entry_id, field_path);

    for (keys) |key| {
        try insertRef(db, key, entry_id, field_path);
    }
}

/// Remove all rows for an entry. Called from `deleteEntry`.
pub fn dropEntryRefs(db: *Db, entry_id: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM kv_refs WHERE entry_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    _ = try stmt.step();
}

/// Remove all rows for a single (entry, field_path).
pub fn dropFieldRefs(db: *Db, entry_id: []const u8, field_path: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM kv_refs WHERE entry_id = ? AND field_path = ?");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    try stmt.bindText(2, field_path);
    _ = try stmt.step();
}

fn insertRef(db: *Db, var_key: []const u8, entry_id: []const u8, field_path: []const u8) !void {
    var stmt = try db.prepare("INSERT OR IGNORE INTO kv_refs (var_key, entry_id, field_path) VALUES (?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, var_key);
    try stmt.bindText(2, entry_id);
    try stmt.bindText(3, field_path);
    _ = try stmt.step();
}

/// Entry-level save hook. Loads the entry's data JSON, walks every string
/// node, and rewrites the reverse index for the entry. Errors are logged
/// and swallowed — a flaky hook must not break the content save.
pub fn afterSave(ctx: save_hooks.Context) void {
    rebuildEntryRefs(ctx) catch |err| {
        std.log.warn("kv_refs: rebuildEntryRefs failed for entry '{s}': {s}", .{ ctx.entry_id, @errorName(err) });
    };
}

fn rebuildEntryRefs(ctx: save_hooks.Context) !void {
    var stmt = try ctx.db.prepare("SELECT data FROM content_entries WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, ctx.entry_id);
    if (!try stmt.step()) return; // entry not found — nothing to index

    const data_json = stmt.columnText(0) orelse return;

    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, data_json, .{});
    defer parsed.deinit();

    // Drop all refs for this entry; we re-add what remains in the new data.
    try dropEntryRefs(ctx.db, ctx.entry_id);

    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv_pair| {
        try walkAndIndex(ctx.db, ctx.allocator, ctx.entry_id, kv_pair.key_ptr.*, kv_pair.value_ptr.*);
    }
}

/// Recursively walks a JSON node. Strings are scanned for `[kv:...]`
/// tokens. Objects extend `field_path` by `.<key>`; arrays by `.<index>`.
/// Other primitives are skipped (no tokens possible).
fn walkAndIndex(
    db: *Db,
    allocator: std.mem.Allocator,
    entry_id: []const u8,
    field_path: []const u8,
    value: std.json.Value,
) !void {
    switch (value) {
        .string => |s| {
            const keys = try parser.extractKeys(allocator, s);
            defer {
                for (keys) |k| allocator.free(k);
                allocator.free(keys);
            }
            for (keys) |key| {
                try insertRef(db, key, entry_id, field_path);
            }
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |pair| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ field_path, pair.key_ptr.* });
                defer allocator.free(child_path);
                try walkAndIndex(db, allocator, entry_id, child_path, pair.value_ptr.*);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ field_path, i });
                defer allocator.free(child_path);
                try walkAndIndex(db, allocator, entry_id, child_path, item);
            }
        },
        else => {},
    }
}
