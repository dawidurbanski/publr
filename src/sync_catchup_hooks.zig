//! Sync catch-up hooks — fired when a sync transport becomes available
//! and the plugin should rebroadcast everything it has so receivers can
//! reconcile.
//!
//! Two firing sites:
//!   - WASM: `cms_sync_emit_full` export, called by cms-worker.js when
//!     the relay WebSocket opens. Handles OPFS-restored content +
//!     anything saved while the WS was unavailable.
//!   - Native: `handleSyncWebSocket` calls this on each new replica
//!     connection so the relay's own state propagates outward. Sends
//!     via `websocket.registry.broadcast`, which reaches every
//!     connected client (cr-sqlite dedupes echoes).
//!
//! Plugins export `pub const sync_catchup_hooks: []const Hook` and the
//! comptime collector below picks them up. cr-sqlite's hook reads
//! `crsql_changes` from scratch and ships the lot through
//! `sync_transport.send`.

const std = @import("std");
const Db = @import("db").Db;
const plugin_registry = @import("plugin_registry");

pub const Context = struct {
    db: *Db,
    allocator: std.mem.Allocator,
};

pub const Hook = *const fn (Context) anyerror!void;

pub const hooks: []const Hook = blk: {
    var list: []const Hook = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "sync_catchup_hooks")) {
            list = list ++ p.mod.sync_catchup_hooks;
        }
    }
    break :blk list;
};

/// Run every plugin-contributed catch-up hook. Errors are swallowed —
/// catch-up is best-effort, the next save will trigger another broadcast.
pub fn fireAll(ctx: Context) void {
    inline for (hooks) |h| h(ctx) catch |err| {
        std.log.warn("sync_catchup_hooks: hook returned {s}", .{@errorName(err)});
    };
}
