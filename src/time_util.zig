const std = @import("std");
const builtin = @import("builtin");

/// Returns the current time as a Unix timestamp (seconds since epoch).
/// On WASI, avoids 128-bit integer math that the self-hosted backend can't handle.
pub fn timestamp() i64 {
    if (comptime builtin.os.tag == .wasi) {
        var ts: std.os.wasi.timestamp_t = undefined;
        const ret = std.os.wasi.clock_time_get(.REALTIME, 1, &ts);
        if (ret != .SUCCESS) return 0;
        return @intCast(ts / std.time.ns_per_s);
    } else {
        return std.time.timestamp();
    }
}

/// Returns the current time in milliseconds since epoch.
/// On WASI, avoids 128-bit integer math that the self-hosted backend can't handle.
pub fn milliTimestamp() i64 {
    if (comptime builtin.os.tag == .wasi) {
        var ts: std.os.wasi.timestamp_t = undefined;
        const ret = std.os.wasi.clock_time_get(.REALTIME, 1, &ts);
        if (ret != .SUCCESS) return 0;
        return @intCast(ts / std.time.ns_per_ms);
    } else {
        return std.time.milliTimestamp();
    }
}
