//! Native-backend exerciser for the dual-mode SDK spike.
//!
//! Loads the spike plugin (compiled native, native backend selected by the
//! SDK's comptime `is_wasm` check), registers a fake host vtable with fixed
//! data, runs the plugin's render subscriber, and asserts on the captured
//! output. The output string is the contract for the spike: if the WASM
//! build (run via WAMR in task-02) produces the same bytes for the same
//! input, the dual-mode design holds.

const std = @import("std");
const publr = @import("publr_sdk");
const spike = @import("spike_plugin");

const Entry = publr.Entry;
const Context = publr.Context;

const FixtureState = struct {
    posts: []const Entry,
};

fn mockContentList(ctx: *Context, type_id: []const u8) []const Entry {
    const state: *FixtureState = @ptrCast(@alignCast(ctx.host_state));
    if (std.mem.eql(u8, type_id, "post")) return state.posts;
    return &.{};
}

test "spike plugin produces expected output in native backend" {
    const allocator = std.testing.allocator;

    var state: FixtureState = .{
        .posts = &.{
            .{ .id = "p1", .type_id = "post", .title = "First Post" },
            .{ .id = "p2", .type_id = "post", .title = "Second Post" },
        },
    };

    publr.registerHost(.{
        .content_list = mockContentList,
    });

    var ctx: Context = .{
        .path = "/",
        .method = "GET",
        .plugin_name = "spike",
        .allocator = allocator,
        .host_state = @ptrCast(&state),
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    inline for (spike.subscribers) |sub| {
        if (sub.kind == .render) publr.native.runRender(sub, &ctx, &buf);
    }

    const expected =
        "posts: 2\n" ++
        "- p1: First Post\n" ++
        "- p2: Second Post\n";
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "spike plugin handles empty content list" {
    const allocator = std.testing.allocator;

    var state: FixtureState = .{ .posts = &.{} };

    publr.registerHost(.{
        .content_list = mockContentList,
    });

    var ctx: Context = .{
        .path = "/",
        .method = "GET",
        .plugin_name = "spike",
        .allocator = allocator,
        .host_state = @ptrCast(&state),
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    inline for (spike.subscribers) |sub| {
        if (sub.kind == .render) publr.native.runRender(sub, &ctx, &buf);
    }

    try std.testing.expectEqualStrings("posts: 0\n", buf.items);
}
