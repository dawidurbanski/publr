const std = @import("std");

/// Global dev mode flag - set at startup
var dev_mode: bool = false;

/// Initialize template system with mode
pub fn init(is_dev_mode: bool) void {
    dev_mode = is_dev_mode;
}

/// Thread-local arena allocator for template rendering.
/// All rendered slices are valid until resetArena() is called (end of request).
threadlocal var arena_instance: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Render a ZSX function to a slice.
/// Pass args as a tuple matching the function params (writer is prepended automatically).
/// Result is valid until resetArena() is called at end of request.
pub fn render(comptime func: anytype, args: anytype) []const u8 {
    @setEvalBranchQuota(10000);
    const allocator = arena_instance.allocator();
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);
    @call(.auto, func, .{w} ++ args) catch |err| {
        std.log.err("template render failed: {s}", .{@errorName(err)});
        return "";
    };
    return buf.items;
}

/// Render a ZSX function with no arguments.
/// Shorthand for render(func, .{})
pub inline fn renderStatic(comptime func: anytype) []const u8 {
    return render(func, .{});
}

/// Reset the thread-local arena. Call at the end of each request
/// to free all rendered template memory.
pub fn resetArena() void {
    _ = arena_instance.reset(.retain_capacity);
}

/// Backwards compatibility alias - use render() instead
pub const renderFnToSlice = render;

// Tests
test "render with params" {
    const mockFn = struct {
        fn call(writer: anytype, name: anytype) !void {
            try writer.writeAll("Hello ");
            try writer.writeAll(name);
        }
    }.call;

    const result = render(mockFn, .{"ZSX"});
    try std.testing.expectEqualStrings("Hello ZSX", result);
}

test "render no params" {
    const mockFn = struct {
        fn call(writer: anytype) !void {
            try writer.writeAll("No params!");
        }
    }.call;

    const result = renderStatic(mockFn);
    try std.testing.expectEqualStrings("No params!", result);
}

test "render multiple params" {
    const mockFn = struct {
        fn call(writer: anytype, greeting: anytype, name: anytype) !void {
            try writer.writeAll(greeting);
            try writer.writeAll(" ");
            try writer.writeAll(name);
        }
    }.call;

    const result = render(mockFn, .{ "Hi", "World" });
    try std.testing.expectEqualStrings("Hi World", result);
}

test "render with props struct" {
    const mockFn = struct {
        fn call(writer: anytype, props: anytype) !void {
            try writer.writeAll("Hello ");
            try writer.writeAll(props.name);
            try writer.writeAll(", age ");
            try writer.print("{d}", .{props.age});
        }
    }.call;

    const result = render(mockFn, .{.{ .name = "World", .age = 42 }});
    try std.testing.expectEqualStrings("Hello World, age 42", result);
}
