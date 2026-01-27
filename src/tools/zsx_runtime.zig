const std = @import("std");

/// HTML-escape a string for safe output
pub fn escape(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#x27;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Render an integer (no escaping needed)
pub fn renderInt(writer: anytype, value: anytype) !void {
    try writer.print("{d}", .{value});
}

/// Render a value based on its type
pub fn render(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);

    // Handle []const u8 (strings) directly
    if (T == []const u8) {
        try escape(writer, value);
        return;
    }

    // Handle *const [N]u8 (string literals)
    const info = @typeInfo(T);
    switch (info) {
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .pointer => |ptr| {
            // Check for pointer to u8 array (string literal type)
            const child_info = @typeInfo(ptr.child);
            if (child_info == .array and child_info.array.child == u8) {
                try escape(writer, value);
            } else if (ptr.size == .one) {
                try render(writer, value.*);
            } else {
                try writer.print("{s}", .{value});
            }
        },
        .optional => {
            if (value) |v| {
                try render(writer, v);
            }
        },
        else => try writer.print("{any}", .{value}),
    }
}

// Tests
test "escape basic HTML chars" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try escape(fbs.writer(), "<script>alert('xss')</script>");
    try std.testing.expectEqualStrings(
        "&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;",
        fbs.getWritten(),
    );
}

test "escape ampersand" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try escape(fbs.writer(), "a & b");
    try std.testing.expectEqualStrings("a &amp; b", fbs.getWritten());
}

test "escape quotes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try escape(fbs.writer(), "He said \"hello\"");
    try std.testing.expectEqualStrings("He said &quot;hello&quot;", fbs.getWritten());
}

test "render integer" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), @as(u64, 42));
    try std.testing.expectEqualStrings("42", fbs.getWritten());
}

test "render bool" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), true);
    try std.testing.expectEqualStrings("true", fbs.getWritten());
}

test "render string escapes HTML" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), "<b>bold</b>");
    try std.testing.expectEqualStrings("&lt;b&gt;bold&lt;/b&gt;", fbs.getWritten());
}
