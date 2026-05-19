//! Apply-remote hooks — fired when a sync frame arrives over the WS.
//!
//! Mirror of `save_hooks` / `db_open_hooks`. Plugins export
//! `pub const apply_remote_hooks: []const apply_remote_hooks.Hook` and
//! the comptime collector below picks them up. `wasm/main.zig` calls
//! `applyAll(...)` from the `cms_apply_remote_changeset` export when
//! the browser worker forwards a frame; the native relay's
//! `handleSyncWebSocket` may call it too if it decides the relay
//! should also participate as a replica.
//!
//! Each hook gets the raw payload bytes (the JSON array from
//! `sync_transport.send`'s `data` field, already unwrapped from the
//! envelope by the caller) and decides what to do with them.
//! cr-sqlite's hook parses the array and INSERTs into `crsql_changes`.

const std = @import("std");
const Db = @import("db").Db;
const plugin_registry = @import("plugin_registry");

pub const Context = struct {
    db: *Db,
    allocator: std.mem.Allocator,
    payload: []const u8,
};

pub const Hook = *const fn (Context) anyerror!void;

pub const hooks: []const Hook = blk: {
    var list: []const Hook = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "apply_remote_hooks")) {
            list = list ++ p.mod.apply_remote_hooks;
        }
    }
    break :blk list;
};

/// Run every plugin-contributed hook against the frame. Returns the
/// first error a hook produces; remaining hooks do not run.
pub fn applyAll(ctx: Context) !void {
    inline for (hooks) |h| try h(ctx);
}
