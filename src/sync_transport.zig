//! Outbound transport for cr-sqlite changeset frames.
//!
//! WASM build: `send(msg)` calls into a JS import (`js_sync_send`) that
//! forwards the bytes over the worker's WebSocket as a `sync_changes`
//! envelope. cms-worker.js implements that import.
//!
//! Native build: stub — the native server is the relay hub, not a
//! replica, so it doesn't emit local changes. If we ever ship a native
//! replica (e.g. iOS), we'd add a real WebSocket client here.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.os.tag == .wasi or builtin.cpu.arch == .wasm32;

const wasm_externs = if (is_wasm) struct {
    pub extern fn js_sync_send(ptr: [*]const u8, len: usize) void;
} else struct {};

// Pulled in only on native — WASM doesn't use it, and dragging the
// websocket module into the WASM build would surface POSIX deps that
// can't link.
const websocket = if (is_wasm) struct {} else @import("websocket");

var native_lock: std.Thread.Mutex = .{};

/// Publish a sync frame. `msg` is the inner JSON array of changeset rows.
///
/// WASM path: hand off to a JS import, which wraps the payload in the
/// `{"type":"sync_changes","data":"<inner>"}` envelope and ships it over
/// the worker's WebSocket.
///
/// Native path: native publr IS the relay. The save_hook captured local
/// changes; we wrap them in the same envelope and broadcast to every
/// connected WS replica via `websocket.registry`. Serialized by a mutex
/// — `websocket.registry.broadcast` is internally locked, but we also
/// guard the envelope build so two concurrent saves don't interleave.
pub fn send(msg: []const u8) void {
    if (comptime is_wasm) {
        wasm_externs.js_sync_send(msg.ptr, msg.len);
        return;
    }
    nativeBroadcast(msg);
}

fn nativeBroadcast(inner: []const u8) void {
    native_lock.lock();
    defer native_lock.unlock();

    const allocator = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    w.writeAll("{\"type\":\"sync_changes\",\"data\":") catch return;
    writeJsonString(w, inner) catch return;
    w.writeByte('}') catch return;

    std.debug.print("[sync] nativeBroadcast: {d} conns, {d} bytes inner / {d} bytes envelope\n", .{
        websocket.registry.count(),
        inner.len,
        buf.items.len,
    });
    websocket.registry.broadcast(buf.items, null);
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
