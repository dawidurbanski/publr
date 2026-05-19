//! Relay-side sync token storage.
//!
//! The native publr instance acting as a sync relay needs a stable bearer
//! token for replica authentication — replicas (WASM iOS, browser WASM,
//! etc.) can't reuse the admin session because they're on different
//! origins and don't share cookies. One random token per relay,
//! persisted on disk outside the DB so it doesn't replicate.
//!
//! Layout:
//!   data/sync_token   <- 32 random bytes, base64-encoded (44 chars)
//!
//! Generated lazily on first call; reused across restarts.
//! WASM build: returns an empty string — WASM clients aren't relays.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.os.tag == .wasi or builtin.cpu.arch == .wasm32;

const TOKEN_FILE = "data/sync_token";
const TOKEN_BYTES = 32;
const TOKEN_ENCODED_LEN = std.base64.standard.Encoder.calcSize(TOKEN_BYTES);

/// Return the relay token. Caller owns the returned slice.
/// On WASM, returns an empty string.
pub fn get(allocator: std.mem.Allocator) ![]u8 {
    if (comptime is_wasm) {
        return try allocator.dupe(u8, "");
    }

    if (std.fs.cwd().readFileAlloc(allocator, TOKEN_FILE, 1024)) |existing| {
        const trimmed = std.mem.trim(u8, existing, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const out = try allocator.dupe(u8, trimmed);
            allocator.free(existing);
            return out;
        }
        allocator.free(existing);
    } else |_| {}

    var raw: [TOKEN_BYTES]u8 = undefined;
    std.crypto.random.bytes(&raw);
    var encoded: [TOKEN_ENCODED_LEN]u8 = undefined;
    const token = std.base64.standard.Encoder.encode(&encoded, &raw);

    if (std.fs.path.dirname(TOKEN_FILE)) |dir| std.fs.cwd().makePath(dir) catch {};
    var file = try std.fs.cwd().createFile(TOKEN_FILE, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(token);

    return try allocator.dupe(u8, token);
}

/// Constant-time compare against the stored token. Returns false on WASM.
pub fn verify(presented: []const u8, allocator: std.mem.Allocator) bool {
    if (comptime is_wasm) return false;
    const stored = get(allocator) catch return false;
    defer allocator.free(stored);
    if (stored.len == 0) return false;
    if (stored.len != presented.len) return false;
    var diff: u8 = 0;
    for (stored, presented) |x, y| diff |= x ^ y;
    return diff == 0;
}
