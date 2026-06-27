//! Live-mode variable substitution applied to rendered HTML at request time.
//!
//! Scans the baked body for `[kv:key]` tokens and substitutes:
//!   - `literal-live` → `kv.value` (current row state)
//!   - `computed-live` → resolver call (always fresh, runs every render)
//!   - `literal-baked` / `computed-baked` → token preserved + warning logged
//!     (these should have been substituted at publish; their presence in
//!     the final HTML is a sign that bake didn't run for this output)
//!   - unknown key → token preserved (debuggability)
//!
//! Returns null when the body has no `[kv:` substring (no allocation made —
//! caller keeps the original body slice).

const std = @import("std");
const Db = @import("db").Db;
const parser = @import("parser.zig");
const registry = @import("registry.zig");

/// Substitute live-mode tokens. Returns null on fast-path (no tokens),
/// otherwise an allocator-owned slice the caller is responsible for.
pub fn substitute(allocator: std.mem.Allocator, db: *Db, body: []const u8) !?[]const u8 {
    // Fast path: no `[kv:` substring → no allocation.
    if (std.mem.indexOf(u8, body, "[kv:") == null) return null;

    // Lookup arena: each substituted value is allocated by resolveCached
    // and lives only as long as parser.substitute is copying it into the
    // output. Freed in one shot when this fn returns.
    var lookup_arena = std.heap.ArenaAllocator.init(allocator);
    defer lookup_arena.deinit();

    var lookup_ctx = LookupCtx{ .db = db, .allocator = lookup_arena.allocator() };
    const result = try parser.substitute(allocator, body, &lookup_ctx);
    return result;
}

const LookupCtx = struct {
    db: *Db,
    allocator: std.mem.Allocator,

    /// Returns the value to substitute, or null to preserve the token.
    /// Slice lifetime: borrowed from `self.allocator` (the lookup arena).
    /// `parser.substitute` copies the bytes into its own output buffer
    /// before this slice's storage is freed.
    pub fn lookup(self: *LookupCtx, key: []const u8) ?[]const u8 {
        var mode_stmt = self.db.prepare("SELECT mode FROM kv WHERE key = ?") catch return null;
        defer mode_stmt.deinit();
        mode_stmt.bindText(1, key) catch return null;
        const has_row = mode_stmt.step() catch return null;
        if (!has_row) return null;
        const mode = mode_stmt.columnText(0) orelse return null;

        if (std.mem.eql(u8, mode, "literal-live") or std.mem.eql(u8, mode, "computed-live")) {
            // resolveCached handles both: literal-live reads value, computed-live
            // falls through to running the compute fn.
            return registry.resolveCached(self.db, self.allocator, key) catch null;
        }
        if (std.mem.eql(u8, mode, "literal-baked") or std.mem.eql(u8, mode, "computed-baked")) {
            std.log.warn("kv: baked-mode token '[kv:{s}]' found in rendered HTML — bake step may not have run for this output", .{key});
            return null;
        }
        return null;
    }
};
