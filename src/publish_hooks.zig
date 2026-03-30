//! Publish hooks — notified after content publish/unpublish actions.
//! SSG regeneration registers a hook at startup; REST handlers call it.

const std = @import("std");
const Db = @import("db").Db;

pub const Hook = *const fn (*Db, std.mem.Allocator, []const u8) void;

var hook: ?Hook = null;

/// Register a post-publish hook (called by SSG setup at startup).
pub fn register(h: Hook) void {
    hook = h;
}

/// Trigger the hook after a publish/unpublish action.
/// `entry_id` is the content entry ID.
pub fn afterPublish(db: *Db, allocator: std.mem.Allocator, entry_id: []const u8) void {
    if (hook) |h| h(db, allocator, entry_id);
}
