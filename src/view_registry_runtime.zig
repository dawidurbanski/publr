//! Startup hashmap over the codegen'd view registry (see
//! `src/tools/registry_gen.zig` for the upstream emit).
//!
//! Init runs once at server boot in `--dev` mode. The HMR swap loop
//! (task-06) calls `lookup(name)` per `.zsx` save event to find the
//! baked manifest, the `setL` writer, and the render trampoline for
//! that view.
//!
//! Inline mode (no `-Dhmr`) sees an empty `entries` slice — `init` is
//! a no-op and `lookup` always returns `null`, so non-dev callers can
//! depend on the same module unconditionally.

const std = @import("std");
const registry = @import("view_registry");

pub const Entry = registry.Entry;

var map: std.StringHashMap(*const registry.Entry) = undefined;
var initialized: bool = false;

pub fn init(allocator: std.mem.Allocator) !void {
    if (initialized) return;
    map = std.StringHashMap(*const registry.Entry).init(allocator);
    errdefer map.deinit();

    for (registry.entries) |*entry| {
        try map.put(entry.name, entry);
    }
    initialized = true;
    std.log.info(
        "[hmr] registered {d} views from registry.zig",
        .{registry.entries.len},
    );
}

pub fn lookup(name: []const u8) ?*const registry.Entry {
    if (!initialized) return null;
    return map.get(name);
}

/// Iterate every entry. Useful for debug dumps and tests; the swap loop
/// hits the hashmap directly.
pub fn iter() []const registry.Entry {
    return registry.entries;
}

pub fn deinit() void {
    if (initialized) {
        map.deinit();
        initialized = false;
    }
}
