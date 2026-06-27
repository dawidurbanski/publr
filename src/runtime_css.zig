//! Thread-safe holder for the runtime `/static/admin.css` override.
//!
//! In dev mode the HMR loop recompiles CSS after every fast-path swap
//! (see src/css_jit.zig) and stores the bytes here. The static handler
//! (src/http_handlers/static_files.zig) checks this holder first and
//! serves its contents when present, falling back to the disk/embedded
//! copy otherwise. Production never writes to this slot — the embedded
//! `static_jit_css` stays authoritative.
//!
//! Lives in its own module so both readers (static handler) and writers
//! (HMR loop) can import it without crossing module-sandbox boundaries.

const std = @import("std");

var mu: std.Thread.Mutex = .{};
var current: ?[]u8 = null;

/// Replace the override. Caller transfers ownership of `new_css` allocated
/// with `std.heap.page_allocator`; any previous payload is freed. Pass
/// `null` to clear the override and fall back to disk/embedded.
pub fn set(new_css: ?[]u8) void {
    mu.lock();
    defer mu.unlock();
    if (current) |old| std.heap.page_allocator.free(old);
    current = new_css;
}

pub fn clear() void {
    set(null);
}

/// Return a copy of the current override (allocated with `allocator`),
/// or `null` if none is set. Caller owns the returned slice.
pub fn dupCurrent(allocator: std.mem.Allocator) !?[]u8 {
    mu.lock();
    defer mu.unlock();
    const cur = current orelse return null;
    return try allocator.dupe(u8, cur);
}
