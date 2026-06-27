//! Render hooks — fired just before the response body is written to the
//! wire. Plugins export `pub const render_hooks: []const render_hooks.Hook`
//! and the comptime collector below picks them up automatically. The core
//! kv live-var substitution runs unconditionally before plugin hooks.
//!
//! Hook runs on the buffered response — handlers that stream their output
//! (`headers_sent = true`) bypass this path entirely.
//!
//! Non-HTML responses (anything whose content_type doesn't start with
//! `text/html`) skip the kv substitution to avoid scanning images / JSON /
//! CSS for `[kv:` substrings. Plugin hooks still fire so they can do their
//! own filtering.

const std = @import("std");
const Db = @import("db").Db;
const mw = @import("middleware");
const plugin_registry = @import("plugin_registry");
const kv = @import("kv");

pub const Context = struct {
    response: *mw.Response,
    db: *Db,
    allocator: std.mem.Allocator,
    /// Request path. Used by core hooks to gate behavior — the kv live-var
    /// substitution skips admin paths entirely, since admin chrome isn't a
    /// content-render path and accidentally substituting `[kv:...]` text
    /// that appears in admin HTML (e.g. value previews on the variables
    /// list) causes corruption.
    path: []const u8,
};

pub const Hook = *const fn (Context) void;

pub const plugin_hooks: []const Hook = blk: {
    var list: []const Hook = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "render_hooks")) {
            list = list ++ p.mod.render_hooks;
        }
    }
    break :blk list;
};

/// Called from router dispatch just before sendResponse. Order:
///   1. KV live-var substitution (core, HTML only)
///   2. Plugin render hooks (always run, filter on their own)
pub fn beforeWrite(ctx: Context) void {
    if (isHtml(ctx.response.content_type) and !isAdminPath(ctx.path)) {
        substituteKvLive(ctx);
    }
    inline for (plugin_hooks) |h| h(ctx);
}

fn isAdminPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/admin");
}

fn substituteKvLive(ctx: Context) void {
    const maybe_new = kv.live.substitute(ctx.allocator, ctx.db, ctx.response.body) catch |err| {
        std.log.warn("kv live substitution failed: {s}", .{@errorName(err)});
        return;
    };
    if (maybe_new) |new_body| {
        ctx.response.setBody(new_body);
    }
}

fn isHtml(content_type: []const u8) bool {
    return std.mem.startsWith(u8, content_type, "text/html");
}

test "comptime collector compiles with no plugin render_hooks" {
    try std.testing.expect(plugin_hooks.len >= 0);
}
