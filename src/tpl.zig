const std = @import("std");

/// Global dev mode flag - set at startup
var dev_mode: bool = false;

/// Initialize template system with mode
pub fn init(is_dev_mode: bool) void {
    dev_mode = is_dev_mode;
}

/// Thread-local rotating buffers for template rendering
/// Uses 4 buffers in round-robin to avoid aliasing when composing templates
threadlocal var render_buffers: [4][65536]u8 = undefined;
threadlocal var render_index: usize = 0;

/// Render a ZSX function to a slice.
/// Pass args as a tuple matching the function params (writer is prepended automatically).
/// Result is valid until 4 more calls to renderFnToSlice on this thread.
pub fn renderFnToSlice(comptime func: anytype, args: anytype) []const u8 {
    @setEvalBranchQuota(10000);
    const buf = &render_buffers[render_index % render_buffers.len];
    render_index +%= 1;

    var fbs = std.io.fixedBufferStream(buf);
    @call(.auto, func, .{fbs.writer()} ++ args) catch return "";
    return fbs.getWritten();
}

// Tests
test "renderFnToSlice with params" {
    const mockFn = struct {
        fn render(writer: anytype, name: anytype) !void {
            try writer.writeAll("Hello ");
            try writer.writeAll(name);
        }
    }.render;

    const result = renderFnToSlice(mockFn, .{"ZSX"});
    try std.testing.expectEqualStrings("Hello ZSX", result);
}

test "renderFnToSlice no params" {
    const mockFn = struct {
        fn render(writer: anytype) !void {
            try writer.writeAll("No params!");
        }
    }.render;

    const result = renderFnToSlice(mockFn, .{});
    try std.testing.expectEqualStrings("No params!", result);
}

test "renderFnToSlice multiple params" {
    const mockFn = struct {
        fn render(writer: anytype, greeting: anytype, name: anytype) !void {
            try writer.writeAll(greeting);
            try writer.writeAll(" ");
            try writer.writeAll(name);
        }
    }.render;

    const result = renderFnToSlice(mockFn, .{ "Hi", "World" });
    try std.testing.expectEqualStrings("Hi World", result);
}
