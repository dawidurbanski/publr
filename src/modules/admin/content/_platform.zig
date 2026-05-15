//! Platform-conditional aliases for `websocket` and `presence` so each
//! submodule imports them from a single source instead of restating the
//! WASM stubs locally.

const builtin = @import("builtin");

pub const websocket = if (builtin.target.os.tag != .wasi) @import("websocket") else struct {
    pub const Connection = struct {};
};

pub const presence = if (builtin.target.os.tag != .wasi) @import("presence") else struct {
    pub fn getLockTimeoutMs() u32 {
        return 60_000;
    }
    pub fn getHeartbeatIntervalMs() u32 {
        return 10_000;
    }
    pub fn notifyLockAcquired(_: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) void {}
    pub fn notifyLocksReleased(_: []const u8, _: []const []const u8) void {}
    pub fn broadcastEntryMessage(_: []const u8, _: []const u8, _: []const u8) void {}
    pub fn getConnEntryId(_: u64) ?[]const u8 {
        return null;
    }
    pub fn checkTakeoverAllowed(_: []const u8, _: []const u8, _: []const u8) bool {
        return false;
    }
    pub fn registerTakeover(_: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) void {}
    pub const OverrideCheck = enum { none, owner, not_owner };
    pub fn checkOwnershipOverride(_: []const u8, _: []const u8, _: []const u8) OverrideCheck {
        return .none;
    }
    pub fn clearOwnershipOverrides(_: []const u8, _: []const []const u8) void {}
};

// presence.UserInfo isn't a member of the WASM stub above because nothing in
// the WASM path constructs one. Re-export from the real module on native.
pub const UserInfo = if (builtin.target.os.tag != .wasi) @import("presence").UserInfo else struct {
    user_id: []const u8,
    email: []const u8,
    display_name: []const u8,
};
