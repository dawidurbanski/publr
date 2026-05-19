//! Hooks fired once after each successful `Db.init`.
//!
//! Plugins export `pub const db_open_hooks: []const db_open_hooks.Hook` and
//! the comptime collector below picks them up. `core/init.zig:initDatabase`
//! invokes `fireAll(...)` after `Db.init` succeeds, so plugins can run
//! per-connection setup SQL — e.g. cr-sqlite calling
//! `SELECT crsql_as_crr('content_entries')` to mark CRR tables. Idempotent
//! by convention (cr-sqlite, like most extensions of this shape, no-ops on
//! already-marked tables).

const std = @import("std");
const Db = @import("db").Db;
const plugin_registry = @import("plugin_registry");

pub const Hook = *const fn (*Db) anyerror!void;

pub const hooks: []const Hook = blk: {
    var list: []const Hook = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "db_open_hooks")) {
            list = list ++ p.mod.db_open_hooks;
        }
    }
    break :blk list;
};

/// Run every plugin-contributed hook against the freshly opened db.
/// Returns the first error a hook produces; remaining hooks do not run.
pub fn fireAll(db: *Db) !void {
    inline for (hooks) |h| try h(db);
}
