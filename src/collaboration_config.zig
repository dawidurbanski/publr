const std = @import("std");

pub const default_lock_timeout_ms: u32 = 60_000;
pub const default_heartbeat_interval_ms: u32 = 10_000;

var lock_timeout_ms: u32 = default_lock_timeout_ms;
var heartbeat_interval_ms: u32 = default_heartbeat_interval_ms;

/// Apply runtime collaboration timing configuration.
pub fn setTiming(lock_timeout: u32, heartbeat_interval: u32) void {
    lock_timeout_ms = if (lock_timeout < 250) 250 else lock_timeout;
    heartbeat_interval_ms = if (heartbeat_interval < 100) 100 else heartbeat_interval;
}

pub fn getLockTimeoutMs() u32 {
    return lock_timeout_ms;
}

pub fn getHeartbeatIntervalMs() u32 {
    return heartbeat_interval_ms;
}

/// Server-side stale threshold derived from heartbeat interval.
/// With 3 missed heartbeats we consider a connection stale.
pub fn getHeartbeatStaleSeconds() i64 {
    const stale_ms: u64 = @as(u64, heartbeat_interval_ms) * 3;
    const secs = (stale_ms + 999) / 1000;
    const bounded = @max(secs, 1);
    return @intCast(bounded);
}

test "setTiming applies minimum bounds" {
    setTiming(1, 1);
    try std.testing.expectEqual(@as(u32, 250), getLockTimeoutMs());
    try std.testing.expectEqual(@as(u32, 100), getHeartbeatIntervalMs());
}
