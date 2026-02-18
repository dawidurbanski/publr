//! Collaboration Config Plugin API
//!
//! Re-exports collaboration timing configuration for plugins.
//! These are module-level functions (not request-scoped).
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const timeout = publr.collaboration.getLockTimeoutMs();
//! const heartbeat = publr.collaboration.getHeartbeatIntervalMs();
//! ```

const collaboration = @import("collaboration_config");

pub const default_lock_timeout_ms = collaboration.default_lock_timeout_ms;
pub const default_heartbeat_interval_ms = collaboration.default_heartbeat_interval_ms;

pub const setTiming = collaboration.setTiming;
pub const getLockTimeoutMs = collaboration.getLockTimeoutMs;
pub const getHeartbeatIntervalMs = collaboration.getHeartbeatIntervalMs;
pub const getHeartbeatStaleSeconds = collaboration.getHeartbeatStaleSeconds;
