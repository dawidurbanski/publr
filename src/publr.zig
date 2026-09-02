const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.2.0";

pub const lib = @import("lib.zig");
pub const db = lib.db;
pub const auth = lib.auth;
pub const http = lib.http;
pub const report = lib.report;
pub const sdk = @import("sdk.zig");
pub const model = @import("model.zig");
pub const store = @import("store.zig");
pub const cli = @import("adapters/cli.zig");
pub const app = @import("app.zig");
pub const registry = @import("app/registry.zig");
pub const plugin = @import("sdk/plugin.zig");
pub const routes = @import("app/routes.zig");
pub const rest = @import("adapters/rest.zig");
pub const admin = @import("adapters/admin.zig");
pub const site = @import("app/site.zig");
pub const operations = struct {
    pub const heartbeat = @import("operations/heartbeat.zig");
    pub const site = @import("operations/site.zig");
    pub const user = @import("operations/user.zig");
    pub const sign_in = @import("operations/sign_in.zig");
    pub const status = @import("operations/status.zig");
    pub const content_type = @import("operations/content_type.zig");
    pub const record = @import("operations/record.zig");
    pub const snapshot = @import("operations/snapshot.zig");
};
pub const serve = if (builtin.os.tag == .wasi) void else @import("app/serve.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(operations);
    std.testing.refAllDecls(http);
}

test "version is a semantic version with three components" {
    var parts: u32 = 0;
    var iterator = std.mem.splitScalar(u8, version, '.');

    while (iterator.next()) |part| : (parts += 1) {
        try std.testing.expect(part.len > 0);
        _ = try std.fmt.parseInt(u32, part, 10);
    }

    try std.testing.expectEqual(@as(u32, 3), parts);
}
