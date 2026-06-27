//! Publr Plugin SDK — dual-mode.
//!
//! One plugin source compiles to two targets:
//!   - wasm32-freestanding: runtime-loaded `.wasm` plugin. SDK resolves to
//!     `extern "env" fn host_*` imports + buffer marshalling.
//!   - native: compile-in plugin linked into the CMS binary. SDK resolves to
//!     direct calls into a `HostVTable` the CMS registers at startup.
//!
//! Plugin code is byte-identical for both targets. Pick which compiler
//! invocation to use; the rest follows.
//!
//! Plugin shape (both targets):
//!
//!     const publr = @import("publr_sdk");
//!
//!     pub const subscribers = .{
//!         publr.render(landing),
//!     };
//!
//!     fn landing(ctx: *publr.Context) void {
//!         _ = ctx;
//!         const w = publr.writer();
//!         const posts = publr.content.list("post");
//!         w.print("posts: {d}\n", .{posts.len}) catch return;
//!         for (posts) |p| w.print("- {s}\n", .{p.title}) catch return;
//!     }
//!
//! THIS FILE IS A SPIKE — task-01 of the wasm-plugin-promotion epic. The
//! shape is the load-bearing piece; the surface is intentionally minimal
//! (one host API, one subscriber kind). Task-02 fills in the rest.

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch == .wasm32;

// Backend selection. The unused branch is dead-stripped at comptime; its
// `extern fn` declarations and global buffers never reach the linker.
const backend = if (is_wasm) WasmBackend else NativeBackend;

// =============================================================================
// Public types. Defined once at the top level — backends reference these
// rather than redeclaring them, otherwise references from inside the
// backend struct see both the inner and outer `Context` and Zig errors
// out on ambiguity.
// =============================================================================

pub const Entry = struct {
    id: []const u8,
    type_id: []const u8,
    title: []const u8,
};

pub const Context = if (is_wasm) struct {
    path: []const u8 = &.{},
    method: []const u8 = &.{},
    plugin_name: []const u8 = &.{},
} else struct {
    path: []const u8 = "",
    method: []const u8 = "",
    plugin_name: []const u8 = "",
    allocator: std.mem.Allocator,
    /// Opaque to the SDK — the host knows what it points at.
    host_state: *anyopaque,
};

pub const Writer = if (is_wasm) struct {
    pub fn write(_: *Writer, data: []const u8) void {
        for (data) |byte| {
            if (WasmBackend.output_len >= WasmBackend.output_buf.len) return;
            WasmBackend.output_buf[WasmBackend.output_len] = byte;
            WasmBackend.output_len += 1;
        }
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        var tmp: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, fmt, args);
        self.write(s);
    }
} else struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn write(self: *Writer, data: []const u8) void {
        self.buf.appendSlice(self.allocator, data) catch {};
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.writer(self.allocator).print(fmt, args);
    }

    pub fn slice(self: *const Writer) []const u8 {
        return self.buf.items;
    }
};

pub const Subscriber = struct {
    kind: enum { render },
    handler: *const fn (*Context) void,
};

// =============================================================================
// Public API — same call sites work for both targets.
// =============================================================================

pub fn context() *Context {
    return backend.context();
}

pub fn writer() *Writer {
    return backend.writer();
}

pub const content = struct {
    /// Returns entries for the given content type. In WASM the slice points
    /// into a per-call buffer in plugin linear memory; in native it points
    /// into memory the host owns for the duration of the call. Either way:
    /// don't keep the slice beyond the current handler invocation.
    pub fn list(type_id: []const u8) []const Entry {
        return backend.contentList(type_id);
    }
};

/// Register a render handler. Returns a Subscriber the plugin embeds in its
/// `pub const subscribers` tuple. In WASM mode also emits a `@export` named
/// "render" so the host can locate the handler by symbol; in native mode the
/// host iterates the subscribers tuple directly.
pub fn render(comptime handler: *const fn (*Context) void) Subscriber {
    return backend.render(handler);
}

// =============================================================================
// Host-side surface — only meaningful for native builds. Lets the CMS host
// register a vtable of real implementations and set the per-call Context.
// =============================================================================

pub const HostVTable = struct {
    content_list: *const fn (ctx: *Context, type_id: []const u8) []const Entry,
};

/// Native-only. Registers the host's real implementations. Calling from a
/// WASM build is a no-op (the WASM backend doesn't have a vtable; it imports
/// host functions directly).
pub fn registerHost(vtable: HostVTable) void {
    if (!is_wasm) NativeBackend.registerHost(vtable);
}

/// Native-only. Sets the current per-call Context. Host calls this before
/// invoking each subscriber, then resets after. WASM uses a different
/// mechanism (`publr_set_context` import).
pub fn setContext(ctx: ?*Context) void {
    if (!is_wasm) NativeBackend.setContext(ctx);
}

// =============================================================================
// Native backend — direct calls into the host via vtable. Context lives in
// a thread-local so plugin code can `publr.context()` without parameter
// threading. Writer wraps `std.ArrayList(u8)` so the host gets back a slice.
// =============================================================================

const NativeBackend = struct {
    threadlocal var current_context: ?*Context = null;
    threadlocal var active_writer: ?*Writer = null;
    var vtable: ?HostVTable = null;

    pub fn context() *Context {
        return current_context orelse @panic("publr: no active context (host must call setContext before invoking subscribers)");
    }

    pub fn writer() *Writer {
        return active_writer orelse @panic("publr: no active writer (host must set the writer before invoking a render subscriber)");
    }

    pub fn contentList(type_id: []const u8) []const Entry {
        const vt = vtable orelse return &.{};
        const ctx = current_context orelse return &.{};
        return vt.content_list(ctx, type_id);
    }

    pub fn render(comptime handler: *const fn (*Context) void) Subscriber {
        return .{ .kind = .render, .handler = handler };
    }

    pub fn registerHost(vt: HostVTable) void {
        vtable = vt;
    }

    pub fn setContext(ctx: ?*Context) void {
        current_context = ctx;
    }

    /// Host-facing: invoke a render subscriber, capturing its writes.
    /// Spike-only convenience — the real runtime will dispatch through
    /// `host.zig`, but this is enough to drive parity tests.
    pub fn runRender(sub: Subscriber, ctx: *Context, buf: *std.ArrayList(u8)) void {
        var w: Writer = .{ .buf = buf, .allocator = ctx.allocator };
        const saved_ctx = current_context;
        const saved_w = active_writer;
        current_context = ctx;
        active_writer = &w;
        defer {
            current_context = saved_ctx;
            active_writer = saved_w;
        }
        sub.handler(ctx);
    }
};

// =============================================================================
// WASM backend — host functions imported from "env", buffers in plugin
// linear memory. Mirrors the POC's shape but pared down to the spike's
// surface (one host API, one subscriber kind).
//
// Layout note: every `extern fn` and global is inside this struct, so the
// declarations only reach the linker when `is_wasm == true`.
// =============================================================================

const WasmBackend = struct {
    // One host import: `host_call(fn_id, arg_ptr, arg_len, out_ptr, out_max) -> u32`.
    // Matches the POC's single-import shape. Function IDs are stable enough
    // for the spike; task-02 may revisit when the full API surface lands.
    extern "env" fn host_call(fn_id: u32, arg_ptr: u32, arg_len: u32, out_ptr: u32, out_max: u32) u32;

    const FN_CONTENT_LIST: u32 = 0;

    // Per-call buffers. Fixed sizes mirror the POC — bounded because plugin
    // linear memory is the hard ceiling regardless.
    var output_buf: [4096]u8 = undefined;
    var output_len: u32 = 0;
    var content_buf: [4096]u8 = undefined;

    var global_ctx: Context = .{};
    var global_writer: Writer = .{};

    // Cached parsed entries pointing into `content_buf`. The slice header
    // returned to plugin code references this; valid only until the next
    // `content.list` call.
    var entry_storage: [32]Entry = undefined;
    var entry_count: usize = 0;

    pub fn context() *Context {
        return &global_ctx;
    }

    pub fn writer() *Writer {
        return &global_writer;
    }

    pub fn contentList(type_id: []const u8) []const Entry {
        const len = host_call(
            FN_CONTENT_LIST,
            ptrToOffset(type_id.ptr),
            @intCast(type_id.len),
            ptrToOffset(&content_buf),
            content_buf.len,
        );
        if (len == 0) {
            entry_count = 0;
            return &.{};
        }
        return parseEntries(content_buf[0..len]);
    }

    /// Wire format from host: lines of `id\ttype_id\ttitle\n`. Plain text so
    /// parity tests can hand-craft fixtures without dragging in a serializer.
    /// Task-04 will replace this with the real CMS wire format.
    fn parseEntries(bytes: []const u8) []const Entry {
        entry_count = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i < bytes.len and entry_count < entry_storage.len) : (i += 1) {
            if (bytes[i] != '\n') continue;
            const line = bytes[start..i];
            start = i + 1;
            const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const t2_offset = std.mem.indexOfScalar(u8, line[t1 + 1 ..], '\t') orelse continue;
            const t2 = t1 + 1 + t2_offset;
            entry_storage[entry_count] = .{
                .id = line[0..t1],
                .type_id = line[t1 + 1 .. t2],
                .title = line[t2 + 1 ..],
            };
            entry_count += 1;
        }
        return entry_storage[0..entry_count];
    }

    pub fn render(comptime handler: *const fn (*Context) void) Subscriber {
        // @export must be called in a comptime context. `publr.render(...)` is
        // invoked from `pub const subscribers = .{ publr.render(landing) };` —
        // the right-hand initializer runs at comptime when the plugin module
        // is compiled, so these @export calls fire then.
        const Wrapper = struct {
            fn renderExport() callconv(.c) u32 {
                output_len = 0;
                handler(&global_ctx);
                return output_len;
            }
            fn getOutputBufPtr() callconv(.c) [*]u8 {
                return &output_buf;
            }
        };
        @export(&Wrapper.renderExport, .{ .name = "render" });
        @export(&Wrapper.getOutputBufPtr, .{ .name = "get_output_buf_ptr" });
        return .{ .kind = .render, .handler = handler };
    }

    fn ptrToOffset(ptr: anytype) u32 {
        return @intCast(@intFromPtr(ptr));
    }
};

// =============================================================================
// Host-facing re-exports — let the CMS reach into the native backend without
// having to know about it directly. WASM target leaves these as unused.
// =============================================================================

pub const native = if (is_wasm) struct {} else struct {
    pub const runRender = NativeBackend.runRender;
};
