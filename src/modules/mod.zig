const std = @import("std");
const Router = @import("router").Router;
const Db = @import("db").Db;

pub const Module = struct {
    name: []const u8,
    setup: *const fn (*ModuleContext) void,
};

pub const ModuleContext = struct {
    router: *Router,
    allocator: std.mem.Allocator,
    db: *Db,
};

/// Comptime module switchpoint.
/// Future config can map publr.zon features to these flags.
pub const ModuleId = enum {
    admin_ui,
    theme,
};

pub fn hasModule(comptime id: ModuleId) bool {
    return switch (id) {
        .admin_ui => true,
        .theme => @hasField(@TypeOf(@import("publr_config")), "theme"),
    };
}

test "modules: hasModule branch" {
    try std.testing.expect(hasModule(.admin_ui));
    // .theme depends on publr.zon having .theme field
}

test "modules: public API coverage" {
    _ = hasModule;
}
