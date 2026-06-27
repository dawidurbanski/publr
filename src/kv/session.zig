//! Publish session + cascade orchestration for build-time KV variables.
//!
//! A session holds a `(key → resolved value)` map for the lifetime of one
//! publish flow, guaranteeing within-cascade consistency: when X publishes
//! and references `computed-baked` var `T`, the resolver runs ONCE and all
//! other referencers (Y, Z) of `T` rebuild with that same value.
//!
//! Two entry points:
//!   - `cascadeOnPublish(db, alloc, entry_id)` — called from `publishEntry`.
//!     Re-resolves all computed-baked vars the entry references, persists
//!     them to `kv.last_resolved`, then triggers `publish_hooks.afterPublish`
//!     for every OTHER referencer (the caller handles the seed entry's own
//!     re-render). Only computed-baked vars propagate via cascade here —
//!     literal vars' values don't change on a publish action.
//!   - `cascadeOnVarEdit(db, alloc, var_key)` — called when an editor edits
//!     a literal-baked var's value. Triggers `publish_hooks.afterPublish`
//!     for every direct referencer of the edited var. Computed-baked vars
//!     those referencers may USE are also re-resolved during traversal
//!     (transitive cascade).
//!
//! No locking. Concurrent sessions are accepted — last-writer-wins on any
//! overlapping pages. SQLite write transactions serialize the actual row
//! updates so we never get corrupted state, just eventual consistency.

const std = @import("std");
const Db = @import("db").Db;
const publish_hooks = @import("publish_hooks");

const registry = @import("registry.zig");
const refs = @import("refs.zig");

const COMPUTED_BAKED = "computed-baked";

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    db: *Db,
    /// key → resolved value, both arena-allocated. Acts as the "run resolver
    /// at most once per session" cache.
    resolved: std.StringHashMapUnmanaged([]const u8) = .{},
    /// entry_ids that have been added to the queue (dedup).
    seen: std.StringHashMapUnmanaged(void) = .{},
    /// FIFO of entry_ids to process. Each item is a slice into arena memory
    /// (shared with `seen` keys — same underlying bytes, no double-free).
    queue: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn init(parent_allocator: std.mem.Allocator, db: *Db) Session {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .db = db,
        };
    }

    pub fn deinit(self: *Session) void {
        // Arena owns every allocation made via `self.arena.allocator()` —
        // resolved values, seen keys, queue backing storage. One free covers
        // all of it; no per-map deinit needed.
        self.arena.deinit();
    }

    fn alloc(self: *Session) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Add `entry_id` to the queue if not already seen. Returns true if newly
    /// enqueued. The caller is the SEED iff this returns true on first call.
    pub fn enqueue(self: *Session, entry_id: []const u8) !bool {
        if (self.seen.contains(entry_id)) return false;
        const a = self.alloc();
        const owned = try a.dupe(u8, entry_id);
        try self.seen.put(a, owned, {});
        try self.queue.append(a, owned);
        return true;
    }

    /// Returns the resolved value for `key`, running `registry.resolve` at
    /// most once per session (subsequent calls hit the cache). The returned
    /// slice is borrowed from the session arena — do not free.
    pub fn ensureResolved(self: *Session, key: []const u8) ![]const u8 {
        if (self.resolved.get(key)) |v| return v;
        const a = self.alloc();
        const value = try registry.resolve(self.db, a, key);
        const key_owned = try a.dupe(u8, key);
        try self.resolved.put(a, key_owned, value);
        return value;
    }
};

/// Cascade triggered by publishing a page. The caller (publishEntry) is
/// responsible for re-rendering the seed entry itself; this function
/// re-resolves and propagates to OTHER referencers.
pub fn cascadeOnPublish(db: *Db, allocator: std.mem.Allocator, entry_id: []const u8) !void {
    var s = Session.init(allocator, db);
    defer s.deinit();
    _ = try s.enqueue(entry_id);

    // BFS over (entry → computed-baked vars → other entries).
    var idx: usize = 0;
    while (idx < s.queue.items.len) : (idx += 1) {
        try processEntry(&s, s.queue.items[idx]);
    }

    // Re-publish every entry EXCEPT the seed (the caller handles seed's
    // own afterPublish — see content.zig:publishEntry).
    if (s.queue.items.len > 1) {
        for (s.queue.items[1..]) |eid| {
            publish_hooks.afterPublish(db, allocator, eid);
        }
    }
}

/// Cascade triggered by editing a variable's value in admin. Only takes
/// effect for `literal-baked` vars — other modes are no-ops:
///   - `literal-live`: editor edit is visible on next render via the live
///     substitution path; no rebuild needed (deliberately fast for high-
///     fanout vars).
///   - `computed-*`: editor doesn't edit these (values are function-owned);
///     for computed-baked, manual refresh uses `cascadeOnComputedRefresh`.
///
/// For literal-baked: enqueues every direct referencer of `var_key`, then
/// transitively walks each referencer's computed-baked vars (since
/// rebuilding may surface fresh computed values), and re-publishes every
/// enqueued entry.
pub fn cascadeOnVarEdit(db: *Db, allocator: std.mem.Allocator, var_key: []const u8) !void {
    if (!isLiteralBaked(db, var_key)) return;
    try cascadeReferencersInternal(db, allocator, var_key);
}

/// Cascade triggered by a manual refresh of a computed-baked var. The
/// admin's refresh button on the variables list page calls this after
/// running the compute fn (which updates `last_resolved`). Only takes
/// effect when the var is `computed-baked` — other modes are no-ops
/// (computed-live re-runs every render; literal modes don't have a
/// refresh concept).
pub fn cascadeOnComputedRefresh(db: *Db, allocator: std.mem.Allocator, var_key: []const u8) !void {
    if (!isComputedBaked(db, var_key)) return;
    try cascadeReferencersInternal(db, allocator, var_key);
}

fn cascadeReferencersInternal(db: *Db, allocator: std.mem.Allocator, var_key: []const u8) !void {
    var s = Session.init(allocator, db);
    defer s.deinit();

    // Seed: all direct referencers of the edited/refreshed var.
    try enqueueReferencers(&s, var_key);

    // Transitive: each enqueued entry may use other computed-baked vars
    // whose other referencers should also be rebuilt with consistent values.
    var idx: usize = 0;
    while (idx < s.queue.items.len) : (idx += 1) {
        try processEntry(&s, s.queue.items[idx]);
    }

    for (s.queue.items) |eid| {
        publish_hooks.afterPublish(db, allocator, eid);
    }
}

/// Walks `entry_id`'s referenced vars. For each `computed-baked` var: cache
/// the resolved value in the session (so all other entries in this cascade
/// see the same value) and enqueue every other entry that references it.
/// Literal vars and live vars do not propagate the cascade — their values
/// don't change on a publish action.
fn processEntry(s: *Session, entry_id: []const u8) !void {
    var stmt = try s.db.prepare("SELECT DISTINCT var_key FROM kv_refs WHERE entry_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    while (try stmt.step()) {
        const key = stmt.columnText(0) orelse continue;
        if (!isComputedBaked(s.db, key)) continue;
        _ = try s.ensureResolved(key);
        try enqueueReferencers(s, key);
    }
}

fn enqueueReferencers(s: *Session, var_key: []const u8) !void {
    var stmt = try s.db.prepare("SELECT DISTINCT entry_id FROM kv_refs WHERE var_key = ?");
    defer stmt.deinit();
    try stmt.bindText(1, var_key);
    while (try stmt.step()) {
        const eid = stmt.columnText(0) orelse continue;
        _ = try s.enqueue(eid);
    }
}

fn isComputedBaked(db: *Db, key: []const u8) bool {
    return readModeIs(db, key, COMPUTED_BAKED);
}

fn isLiteralBaked(db: *Db, key: []const u8) bool {
    return readModeIs(db, key, "literal-baked");
}

fn readModeIs(db: *Db, key: []const u8, target_mode: []const u8) bool {
    var stmt = db.prepare("SELECT mode FROM kv WHERE key = ?") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, key) catch return false;
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    const mode = stmt.columnText(0) orelse return false;
    return std.mem.eql(u8, mode, target_mode);
}

// Keep `refs` reachable from the session module for symmetry — though it's
// reached via `kv.refs` from outside, importing it here lets future helpers
// (e.g. a "rebuild kv_refs after cascade" utility) live in this file.
comptime {
    _ = refs;
}
