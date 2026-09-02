//! The tables, one module each: SQL and nothing else.

pub const content_types = @import("store/content_types.zig");
pub const records = @import("store/records.zig");
pub const values = @import("store/values.zig");
pub const snapshots = @import("store/snapshots.zig");
pub const settings = @import("store/settings.zig");
pub const users = @import("store/users.zig");
pub const sessions = @import("store/sessions.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
