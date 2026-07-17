//! Thread-safe holder for the runtime `/static/styles/publr.css` utility delta.
//!
//! In dev mode the HMR loop recompiles CSS after every fast-path swap
//! (see src/css_jit.zig) and stores the bytes here. These bytes contain only
//! utilities discovered in the swapped HTML (and no preflight), so the
//! static handler appends them to the complete embedded stylesheet rather
//! than serving them as a replacement. Production never writes to this slot
//! — the embedded `static_jit_css` stays authoritative.
//!
//! Lives in its own module so both readers (static handler) and writers
//! (HMR loop) can import it without crossing module-sandbox boundaries.

const std = @import("std");

var mu: std.Thread.Mutex = .{};
var current: ?[]u8 = null;

/// Merge a runtime delta into the current payload. Caller transfers ownership
/// of `new_css`, allocated with `std.heap.page_allocator`. Deltas accumulate
/// for the lifetime of the dev server so a later component swap cannot remove
/// utilities discovered by an earlier one. Pass `null` to clear all deltas.
pub fn set(new_css: ?[]u8) void {
    mu.lock();
    defer mu.unlock();

    const incoming = new_css orelse {
        if (current) |old| std.heap.page_allocator.free(old);
        current = null;
        return;
    };

    const old = current orelse {
        current = incoming;
        return;
    };

    const merged = std.heap.page_allocator.alloc(u8, old.len + 1 + incoming.len) catch {
        // Preserve the newest usable delta if accumulation itself runs out of
        // memory; serving a partial delta is still better than serving none.
        std.heap.page_allocator.free(old);
        current = incoming;
        return;
    };
    @memcpy(merged[0..old.len], old);
    merged[old.len] = '\n';
    @memcpy(merged[old.len + 1 ..], incoming);
    std.heap.page_allocator.free(old);
    std.heap.page_allocator.free(incoming);
    current = merged;
}

pub fn clear() void {
    set(null);
}

/// Return a copy of the current delta (allocated with `allocator`),
/// or `null` if none is set. Caller owns the returned slice.
pub fn dupCurrent(allocator: std.mem.Allocator) !?[]u8 {
    mu.lock();
    defer mu.unlock();
    const cur = current orelse return null;
    return try allocator.dupe(u8, cur);
}

test "runtime CSS deltas accumulate across component swaps" {
    clear();
    defer clear();

    set(try std.heap.page_allocator.dupe(u8, ".first { display: block; }"));
    set(try std.heap.page_allocator.dupe(u8, ".second { display: flex; }"));

    const css = (try dupCurrent(std.testing.allocator)).?;
    defer std.testing.allocator.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".first") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".second") != null);
}
