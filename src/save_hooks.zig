//! Save hooks — fired after each successful content entry save.
//!
//! Plugins export `pub const save_hooks: []const save_hooks.Hook` and the
//! comptime collector below picks them up automatically. `core/content.zig:
//! saveEntry` calls `afterSave(...)` at the end of every successful write.
//!
//! This is the attachment point for things like CRDT changeset capture,
//! search index sync, webhook fanout, etc. Hooks run synchronously in the
//! writer's allocator scope — keep work bounded or defer to a background
//! queue from inside the hook.

const std = @import("std");
const Db = @import("db").Db;
const plugin_registry = @import("plugin_registry");

pub const Context = struct {
    db: *Db,
    allocator: std.mem.Allocator,
    entry_id: []const u8,
    content_type: []const u8,
};

pub const Hook = *const fn (Context) void;

pub const hooks: []const Hook = blk: {
    var list: []const Hook = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "save_hooks")) {
            list = list ++ p.mod.save_hooks;
        }
    }
    break :blk list;
};

pub fn afterSave(ctx: Context) void {
    inline for (hooks) |h| h(ctx);
}

test "comptime collector compiles with no plugin hooks" {
    try std.testing.expect(hooks.len >= 0);
}
