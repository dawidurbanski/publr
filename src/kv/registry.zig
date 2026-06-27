//! KV variable registration + runtime resolver dispatch.
//!
//! Comptime registration mirrors `save_hooks`: plugins export
//! `pub const kv_vars: []const kv.Def`, the collector below picks them up
//! via `@hasDecl`. The `KV(...)` builder enforces mode/compute pairing at
//! compile time.
//!
//! Runtime dispatch reads the `kv` row (literal modes) or calls the compute
//! fn (computed modes). On compute failure, falls back to `last_resolved`
//! and logs the error so a flaky plugin can't block a publish.

const std = @import("std");
const Db = @import("db").Db;
const plugin_registry = @import("plugin_registry");

/// Sub-modules exposed via the `kv` namespace.
pub const parser = @import("parser.zig");
pub const refs = @import("refs.zig");
pub const session = @import("session.zig");
pub const live = @import("live.zig");

const PickerEntry = struct {
    key: []const u8,
    label: []const u8,
    mode: []const u8,
    source: []const u8,
    value: []const u8,
};

/// Build the JSON payload consumed by `static/interact/kv-picker.js`. Each
/// entry has `{key, label, mode, source, value}`. Values are truncated to
/// `max_value` chars. If `exclude_key` is non-empty, that key is filtered
/// out (used on var-edit pages so a variable can't reference itself via
/// its own picker). Returned slice is allocator-owned.
pub fn pickerVarsJson(
    allocator: std.mem.Allocator,
    db: *Db,
    exclude_key: []const u8,
    max_value: usize,
) ![]u8 {
    var entries: std.ArrayListUnmanaged(PickerEntry) = .{};
    defer entries.deinit(allocator);

    var stmt = try db.prepare("SELECT key, COALESCE(label, ''), mode, source, value FROM kv ORDER BY source, key");
    defer stmt.deinit();
    while (try stmt.step()) {
        const key = stmt.columnText(0) orelse continue;
        if (exclude_key.len > 0 and std.mem.eql(u8, key, exclude_key)) continue;
        const label = stmt.columnText(1) orelse "";
        const mode = stmt.columnText(2) orelse "";
        const source = stmt.columnText(3) orelse "";
        const value = stmt.columnText(4) orelse "";
        const trimmed = if (value.len > max_value) value[0..max_value] else value;
        try entries.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .label = try allocator.dupe(u8, label),
            .mode = try allocator.dupe(u8, mode),
            .source = try allocator.dupe(u8, source),
            .value = try allocator.dupe(u8, trimmed),
        });
    }

    return try std.json.Stringify.valueAlloc(allocator, entries.items, .{});
}

/// Whether the value is editor-set or function-computed, and whether refs
/// are substituted at publish (baked) or at render (live).
pub const Mode = enum {
    literal_baked,
    computed_baked,
    literal_live,
    computed_live,

    pub fn isComputed(self: Mode) bool {
        return self == .computed_baked or self == .computed_live;
    }

    pub fn isBaked(self: Mode) bool {
        return self == .literal_baked or self == .computed_baked;
    }

    pub fn toString(self: Mode) []const u8 {
        return switch (self) {
            .literal_baked => "literal-baked",
            .computed_baked => "computed-baked",
            .literal_live => "literal-live",
            .computed_live => "computed-live",
        };
    }
};

/// Context passed to compute fns. No request context — build-time has none.
pub const Ctx = struct {
    db: *Db,
    allocator: std.mem.Allocator,
};

/// Compute fn must return a `[]const u8` allocated via `ctx.allocator`. The
/// caller of `resolve` is responsible for freeing the returned slice.
pub const ComputeFn = *const fn (ctx: *Ctx) anyerror![]const u8;

/// Builder options. See `KV(...)`.
pub const Options = struct {
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mode: Mode = .literal_baked,
    compute: ?ComputeFn = null,
    /// Initial value seeded into `kv.value` when the row is first
    /// materialised. Only applies to literal modes (computed modes ignore it;
    /// their value column stays empty). Editor overrides this value via the
    /// admin; subsequent plugin loads do NOT clobber the editor's edit
    /// (`materializeIfNeeded` uses INSERT OR IGNORE).
    default: ?[]const u8 = null,
};

/// Materialised variable definition. Plugins emit `[]const Def` slices via
/// `pub const kv_vars`.
pub const Def = struct {
    key: []const u8,
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mode: Mode = .literal_baked,
    compute: ?ComputeFn = null,
    default: ?[]const u8 = null,
    /// Filled in by the collector: `"plugin:<name>"` for plugin-registered
    /// rows, `"core"` for direct usage of the builder by core code.
    source: []const u8 = "core",
};

/// Comptime builder for variable definitions. Validation:
///   - key must be non-empty
///   - computed modes require a compute fn (compile error otherwise)
///   - literal modes forbid a compute fn  (compile error otherwise)
pub fn KV(comptime key: []const u8, comptime opts: Options) Def {
    if (key.len == 0) @compileError("KV: key must be non-empty");

    const has_compute = opts.compute != null;
    const wants_compute = opts.mode.isComputed();

    if (wants_compute and !has_compute) {
        @compileError("KV(\"" ++ key ++ "\"): mode '" ++ opts.mode.toString() ++ "' requires a compute fn");
    }
    if (!wants_compute and has_compute) {
        @compileError("KV(\"" ++ key ++ "\"): mode '" ++ opts.mode.toString() ++ "' forbids a compute fn");
    }

    return .{
        .key = key,
        .label = opts.label,
        .description = opts.description,
        .mode = opts.mode,
        .compute = opts.compute,
        .default = opts.default,
        .source = "core",
    };
}

/// Comptime-assembled registry of all plugin-declared variables. Plugins
/// export `pub const kv_vars: []const Def`; the collector rewrites `source`
/// to `"plugin:<name>"` per the plugin manifest.
pub const registry: []const Def = blk: {
    var list: []const Def = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "kv_vars")) {
            for (p.mod.kv_vars) |def| {
                const owned: Def = .{
                    .key = def.key,
                    .label = def.label,
                    .description = def.description,
                    .mode = def.mode,
                    .compute = def.compute,
                    .default = def.default,
                    .source = "plugin:" ++ p.name,
                };
                list = list ++ [_]Def{owned};
            }
        }
    }
    break :blk list;
};

/// Linear lookup of a registered Def by key. Registry is small; no index.
pub fn findDef(key: []const u8) ?*const Def {
    for (registry) |*def| {
        if (std.mem.eql(u8, def.key, key)) return def;
    }
    return null;
}

pub const ResolveError = error{
    NotFound,
    DbError,
    OutOfMemory,
};

/// Idempotent insert of a plugin-registered row into `kv`. Called lazily
/// on first access so editors can see plugin vars in admin without the
/// plugin having to write seed code. Binds `def.default` if provided,
/// empty string otherwise.
pub fn materializeIfNeeded(db: *Db, def: *const Def) ResolveError!void {
    var stmt = db.prepare(
        "INSERT OR IGNORE INTO kv (key, value, source, mode, label, description, updated_at) " ++
            "VALUES (?, ?, ?, ?, ?, ?, unixepoch())",
    ) catch return error.DbError;
    defer stmt.deinit();

    stmt.bindText(1, def.key) catch return error.DbError;
    stmt.bindText(2, def.default orelse "") catch return error.DbError;
    stmt.bindText(3, def.source) catch return error.DbError;
    stmt.bindText(4, def.mode.toString()) catch return error.DbError;
    if (def.label) |l| {
        stmt.bindText(5, l) catch return error.DbError;
    } else {
        stmt.bindNull(5) catch return error.DbError;
    }
    if (def.description) |d| {
        stmt.bindText(6, d) catch return error.DbError;
    } else {
        stmt.bindNull(6) catch return error.DbError;
    }
    _ = stmt.step() catch return error.DbError;
}

/// Resolve a variable by key. Returns a newly-allocated slice owned by the
/// caller; caller must free with `allocator.free`.
///
/// Recursively substitutes `[kv:other]` tokens inside the resolved value;
/// cycle-protected via a per-call visited set. If a cycle is detected at
/// runtime (it shouldn't happen in production — pre-save `validateNoCycle`
/// blocks them), the offending token resolves to empty + logs a warning.
pub fn resolve(db: *Db, allocator: std.mem.Allocator, key: []const u8) ResolveError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var visited: std.StringHashMapUnmanaged(void) = .{};
    const value = try resolveR(db, arena.allocator(), key, &visited);
    return try allocator.dupe(u8, value);
}

/// Read-only resolve: returns the cached value WITHOUT invoking the compute
/// fn for computed-baked vars. Used by the render path (and the publish
/// cascade). For computed-live, falls through to full `resolve` (live mode
/// means always fresh). Recursively substitutes nested `[kv:other]` refs
/// inside the read value.
pub fn resolveCached(db: *Db, allocator: std.mem.Allocator, key: []const u8) ResolveError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var visited: std.StringHashMapUnmanaged(void) = .{};
    const value = try resolveCachedR(db, arena.allocator(), key, &visited);
    return try allocator.dupe(u8, value);
}

/// Internal helper exposed for tests: resolve a specific Def directly,
/// bypassing the comptime registry lookup. Production code uses `resolve`.
pub fn resolveDef(db: *Db, allocator: std.mem.Allocator, def: *const Def) ResolveError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var visited: std.StringHashMapUnmanaged(void) = .{};
    try visited.put(arena.allocator(), def.key, {});
    const value = try resolveDefR(db, arena.allocator(), def, &visited);
    return try allocator.dupe(u8, value);
}

// =============================================================================
// Recursive internals. All allocations come from the per-call arena passed in
// by the public wrappers. `visited` is the stack of keys currently being
// resolved; cycle detection returns "" + logs for any repeat visit.
// =============================================================================

const SubstituteMode = enum { full, cached };

fn resolveR(
    db: *Db,
    alloc: std.mem.Allocator,
    key: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
) ResolveError![]const u8 {
    if (visited.contains(key)) {
        std.log.warn("kv: cycle detected at '{s}' during resolve; returning empty", .{key});
        return "";
    }
    try visited.put(alloc, key, {});
    defer _ = visited.remove(key);

    const raw = if (findDef(key)) |def|
        try resolveDefBody(db, alloc, def)
    else
        try readValue(db, alloc, key);

    return try recursiveSubstitute(db, alloc, raw, visited, .full);
}

fn resolveCachedR(
    db: *Db,
    alloc: std.mem.Allocator,
    key: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
) ResolveError![]const u8 {
    if (visited.contains(key)) {
        std.log.warn("kv: cycle detected at '{s}' during resolveCached; returning empty", .{key});
        return "";
    }
    try visited.put(alloc, key, {});
    defer _ = visited.remove(key);

    var mode_stmt = db.prepare("SELECT mode FROM kv WHERE key = ?") catch return error.DbError;
    defer mode_stmt.deinit();
    mode_stmt.bindText(1, key) catch return error.DbError;
    const has_row = mode_stmt.step() catch return error.DbError;
    if (!has_row) return error.NotFound;
    const mode_str = mode_stmt.columnText(0) orelse return error.NotFound;

    const raw: []const u8 = if (std.mem.eql(u8, mode_str, "computed-baked"))
        try readLastResolvedOrEmpty(db, alloc, key)
    else if (std.mem.eql(u8, mode_str, "computed-live")) blk: {
        if (findDef(key)) |def| {
            break :blk try resolveDefBody(db, alloc, def);
        }
        break :blk try readValue(db, alloc, key);
    } else try readValue(db, alloc, key);

    return try recursiveSubstitute(db, alloc, raw, visited, .cached);
}

fn resolveDefR(
    db: *Db,
    alloc: std.mem.Allocator,
    def: *const Def,
    visited: *std.StringHashMapUnmanaged(void),
) ResolveError![]const u8 {
    const raw = try resolveDefBody(db, alloc, def);
    return try recursiveSubstitute(db, alloc, raw, visited, .full);
}

/// Single-step resolution for a Def: materialize, run compute (or read value).
/// Does NOT recurse. Used by all three recursive entry points.
fn resolveDefBody(db: *Db, alloc: std.mem.Allocator, def: *const Def) ResolveError![]const u8 {
    try materializeIfNeeded(db, def);
    if (def.compute) |fn_ptr| {
        var ctx = Ctx{ .db = db, .allocator = alloc };
        const result = fn_ptr(&ctx) catch |err| {
            std.log.warn("kv: resolver failed for key '{s}': {s}", .{ def.key, @errorName(err) });
            return try readLastResolvedOrEmpty(db, alloc, def.key);
        };
        if (def.mode == .computed_baked) {
            writeLastResolved(db, def.key, result) catch {};
        }
        return result;
    }
    return try readValue(db, alloc, def.key);
}

fn recursiveSubstitute(
    db: *Db,
    alloc: std.mem.Allocator,
    raw: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
    mode: SubstituteMode,
) ResolveError![]const u8 {
    if (std.mem.indexOf(u8, raw, "[kv:") == null) return raw;

    var lookup = NestedLookup{ .db = db, .allocator = alloc, .visited = visited, .mode = mode };
    return parser.substitute(alloc, raw, &lookup) catch return error.OutOfMemory;
}

const NestedLookup = struct {
    db: *Db,
    allocator: std.mem.Allocator,
    visited: *std.StringHashMapUnmanaged(void),
    mode: SubstituteMode,

    pub fn lookup(self: *NestedLookup, key: []const u8) ?[]const u8 {
        const result = switch (self.mode) {
            .full => resolveR(self.db, self.allocator, key, self.visited),
            .cached => resolveCachedR(self.db, self.allocator, key, self.visited),
        } catch |err| {
            if (err != error.NotFound) {
                std.log.warn("kv: nested lookup failed for '{s}': {s}", .{ key, @errorName(err) });
            }
            return null;
        };
        return result;
    }
};

// =============================================================================
// Pre-save cycle validation. Used by the admin update handler BEFORE writing
// a new value, so editors get a clear error rather than silent runtime
// truncation. Walks the proposed value's tokens against the current kv graph
// and reports the first cycle path found.
// =============================================================================

/// Validate that storing `proposed_value` at `key` would not introduce a
/// cycle. Returns the cycle path (e.g. `["tagline", "site_name", "tagline"]`)
/// or null if no cycle. Caller frees the returned slice and each element via
/// `freeCyclePath`.
pub fn validateNoCycle(
    allocator: std.mem.Allocator,
    db: *Db,
    key: []const u8,
    proposed_value: []const u8,
) !?[]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Extract direct refs from the proposed value.
    const direct = try parser.extractKeys(a, proposed_value);

    if (direct.len == 0) {
        arena.deinit();
        return null;
    }

    var visited: std.StringHashMapUnmanaged(void) = .{};
    try visited.put(a, key, {}); // the seed key is "currently being set"

    var path: std.ArrayListUnmanaged([]const u8) = .{};
    try path.append(a, key);

    for (direct) |ref| {
        if (try walkForCycle(db, a, ref, key, &visited, &path)) {
            // Cycle found — dupe the path out to the CALLER's allocator
            // (so we can free the arena).
            const out = try allocator.alloc([]const u8, path.items.len);
            for (path.items, 0..) |p, i| out[i] = try allocator.dupe(u8, p);
            arena.deinit();
            return out;
        }
    }

    arena.deinit();
    return null;
}

/// Frees a cycle path returned by `validateNoCycle`.
pub fn freeCyclePath(allocator: std.mem.Allocator, path: []const []const u8) void {
    for (path) |p| allocator.free(p);
    allocator.free(path);
}

// =============================================================================
// Manual refresh for computed-baked vars. Used by the admin "refresh" button.
// Re-runs the compute fn, persists the new value to last_resolved, and
// triggers a publish-cascade so all referencers re-render with the new value.
// =============================================================================

pub const RefreshError = error{
    NotFound,
    WrongMode,
    NoComputeFn,
    DbError,
    OutOfMemory,
};

/// Refresh a computed-baked var. Looks up its registered Def, runs the
/// compute fn (updating `last_resolved`), and cascades to referencers.
/// Returns errors that the admin handler can map to HTTP status codes.
pub fn refresh(db: *Db, allocator: std.mem.Allocator, key: []const u8) RefreshError!void {
    // Confirm the key exists with the right mode.
    var mode_stmt = db.prepare("SELECT mode FROM kv WHERE key = ?") catch return error.DbError;
    defer mode_stmt.deinit();
    mode_stmt.bindText(1, key) catch return error.DbError;
    const has_row = mode_stmt.step() catch return error.DbError;
    if (!has_row) return error.NotFound;
    const mode_str = mode_stmt.columnText(0) orelse return error.NotFound;
    if (!std.mem.eql(u8, mode_str, "computed-baked")) return error.WrongMode;

    // Compute fn comes from the comptime registry.
    const def = findDef(key) orelse return error.NoComputeFn;
    if (def.compute == null) return error.NoComputeFn;

    // Run the compute fn (also updates last_resolved as a side effect).
    const value = resolveDef(db, allocator, def) catch return error.DbError;
    defer allocator.free(value);

    // Re-publish all referencers.
    session.cascadeOnComputedRefresh(db, allocator, key) catch return error.DbError;
}

fn walkForCycle(
    db: *Db,
    alloc: std.mem.Allocator,
    key: []const u8,
    seed_key: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
    path: *std.ArrayListUnmanaged([]const u8),
) !bool {
    // Reaching the seed_key transitively means a cycle.
    if (std.mem.eql(u8, key, seed_key)) {
        try path.append(alloc, key);
        return true;
    }
    if (visited.contains(key)) return false; // explored, no cycle through this branch

    try visited.put(alloc, key, {});
    try path.append(alloc, key);
    var popped = false;
    errdefer if (!popped) {
        _ = path.pop();
    };

    // Read the referenced var's current stored value.
    var stmt = db.prepare("SELECT value FROM kv WHERE key = ?") catch return error.DbError;
    defer stmt.deinit();
    stmt.bindText(1, key) catch return error.DbError;
    const has_row = stmt.step() catch return error.DbError;
    if (!has_row) {
        // Reference points at a non-existent var; no cycle possible through it.
        _ = path.pop();
        popped = true;
        return false;
    }
    const value = stmt.columnText(0) orelse "";
    const child_refs = try parser.extractKeys(alloc, value);

    for (child_refs) |ref| {
        if (try walkForCycle(db, alloc, ref, seed_key, visited, path)) {
            return true;
        }
    }

    _ = path.pop();
    popped = true;
    return false;
}

fn readValue(db: *Db, allocator: std.mem.Allocator, key: []const u8) ResolveError![]const u8 {
    var stmt = db.prepare("SELECT value FROM kv WHERE key = ?") catch return error.DbError;
    defer stmt.deinit();
    stmt.bindText(1, key) catch return error.DbError;
    const has_row = stmt.step() catch return error.DbError;
    if (!has_row) return error.NotFound;
    const v = stmt.columnText(0) orelse "";
    return try allocator.dupe(u8, v);
}

fn readLastResolvedOrEmpty(db: *Db, allocator: std.mem.Allocator, key: []const u8) ResolveError![]const u8 {
    var stmt = db.prepare("SELECT last_resolved FROM kv WHERE key = ?") catch return error.DbError;
    defer stmt.deinit();
    stmt.bindText(1, key) catch return error.DbError;
    const has_row = stmt.step() catch return error.DbError;
    if (!has_row) return try allocator.dupe(u8, "");
    const v = stmt.columnText(0) orelse "";
    return try allocator.dupe(u8, v);
}

fn writeLastResolved(db: *Db, key: []const u8, value: []const u8) ResolveError!void {
    var stmt = db.prepare("UPDATE kv SET last_resolved = ?, updated_at = unixepoch() WHERE key = ?") catch return error.DbError;
    defer stmt.deinit();
    stmt.bindText(1, value) catch return error.DbError;
    stmt.bindText(2, key) catch return error.DbError;
    _ = stmt.step() catch return error.DbError;
}

// =============================================================================
// Tests — non-DB. DB-dependent tests live in src/tests/kv_tests.zig because
// Zig 0.15's test runner needs the schema-SQL embed-path to resolve from a
// test root reachable via the build's module graph.
// =============================================================================

test "Mode.isComputed and isBaked partition the modes correctly" {
    try std.testing.expect(!Mode.literal_baked.isComputed());
    try std.testing.expect(Mode.computed_baked.isComputed());
    try std.testing.expect(!Mode.literal_live.isComputed());
    try std.testing.expect(Mode.computed_live.isComputed());

    try std.testing.expect(Mode.literal_baked.isBaked());
    try std.testing.expect(Mode.computed_baked.isBaked());
    try std.testing.expect(!Mode.literal_live.isBaked());
    try std.testing.expect(!Mode.computed_live.isBaked());
}

test "Mode.toString uses kebab-case strings matching schema constraint" {
    try std.testing.expectEqualStrings("literal-baked", Mode.literal_baked.toString());
    try std.testing.expectEqualStrings("computed-baked", Mode.computed_baked.toString());
    try std.testing.expectEqualStrings("literal-live", Mode.literal_live.toString());
    try std.testing.expectEqualStrings("computed-live", Mode.computed_live.toString());
}

test "KV builder produces Def with literal-baked default mode" {
    const def = KV("site_name", .{ .label = "Site name" });
    try std.testing.expectEqualStrings("site_name", def.key);
    try std.testing.expectEqual(Mode.literal_baked, def.mode);
    try std.testing.expect(def.compute == null);
    try std.testing.expectEqualStrings("Site name", def.label.?);
    try std.testing.expectEqualStrings("core", def.source);
}

test "KV builder accepts computed-baked with compute fn" {
    const stub = struct {
        fn fn_(_: *Ctx) anyerror![]const u8 {
            return "ok";
        }
    }.fn_;
    const def = KV("now", .{ .mode = .computed_baked, .compute = stub });
    try std.testing.expectEqual(Mode.computed_baked, def.mode);
    try std.testing.expect(def.compute != null);
}

// NOTE on compile-time validation:
// The following invocations would each fail to compile, demonstrating the
// builder's mode/compute pairing rules. They cannot be expressed as runtime
// tests because @compileError aborts compilation.
//
//   _ = KV("x", .{ .mode = .computed_baked });               // missing compute
//   _ = KV("x", .{ .mode = .literal_live, .compute = stub }); // forbids compute
//   _ = KV("",  .{});                                          // empty key
//
// Verify manually by uncommenting individually if changing the validator.

test "findDef returns null when comptime registry is empty (no plugin kv_vars)" {
    // In a build with no plugin declaring `kv_vars`, registry is empty.
    // This test will need adjustment once a plugin registers KV vars; for
    // now it confirms the lookup is well-formed under the empty case.
    if (registry.len == 0) {
        try std.testing.expect(findDef("anything") == null);
    }
}
