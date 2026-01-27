const std = @import("std");

/// Simple template engine - replaces {name} with data.name
/// Supports {var} for escaped output and {!var} for raw output
/// No loops or conditionals - keep logic in Zig
pub fn Template(comptime source: []const u8) type {
    return struct {
        const Self = @This();

        /// Render template with data to a writer
        pub fn render(writer: anytype, data: anytype) !void {
            @setEvalBranchQuota(source.len * 10);
            comptime var pos: usize = 0;

            inline while (pos < source.len) {
                if (source[pos] == '{') {
                    // Check for raw expression {!...}
                    const is_raw = pos + 1 < source.len and source[pos + 1] == '!';
                    const start = if (is_raw) pos + 2 else pos + 1;

                    // Find closing brace
                    const end = comptime blk: {
                        var i = start;
                        while (i < source.len and source[i] != '}') : (i += 1) {}
                        break :blk i;
                    };

                    const var_name = comptime std.mem.trim(u8, source[start..end], " \t");

                    // Get value from data struct
                    if (@hasField(@TypeOf(data), var_name)) {
                        const value = @field(data, var_name);
                        if (is_raw) {
                            try writer.writeAll(value);
                        } else {
                            try escapeHtml(writer, value);
                        }
                    }

                    pos = end + 1;
                } else {
                    // Find next brace or end
                    const next = comptime blk: {
                        var i = pos;
                        while (i < source.len and source[i] != '{') : (i += 1) {}
                        break :blk i;
                    };

                    try writer.writeAll(source[pos..next]);
                    pos = next;
                }
            }
        }

        /// Render to static buffer
        pub fn renderToBuffer(data: anytype) []const u8 {
            const S = struct {
                var buf: [65536]u8 = undefined;
            };
            var fbs = std.io.fixedBufferStream(&S.buf);
            Self.render(fbs.writer(), data) catch return "";
            return fbs.getWritten();
        }
    };
}

/// HTML escape function
fn escapeHtml(writer: anytype, input: []const u8) !void {
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

// Tests
test "Template basic" {
    const T = Template("Hello {name}!");
    const result = T.renderToBuffer(.{ .name = "World" });
    try std.testing.expectEqualStrings("Hello World!", result);
}

test "Template escaping" {
    const T = Template("{content}");
    const result = T.renderToBuffer(.{ .content = "<script>" });
    try std.testing.expectEqualStrings("&lt;script&gt;", result);
}

test "Template raw" {
    const T = Template("{!html}");
    const result = T.renderToBuffer(.{ .html = "<b>bold</b>" });
    try std.testing.expectEqualStrings("<b>bold</b>", result);
}

test "Template multiple vars" {
    const T = Template("<h1>{title}</h1><p>{message}</p>");
    const result = T.renderToBuffer(.{ .title = "Error", .message = "Not found" });
    try std.testing.expectEqualStrings("<h1>Error</h1><p>Not found</p>", result);
}
