const std = @import("std");
const builtin = @import("builtin");

pub const message_len_max: u32 = 1024;

const red_bold = "\x1b[1;31m";
const reset = "\x1b[0m";
const fence = "=" ** 72;

pub fn err(comptime format: []const u8, args: anytype) void {
    var buffer: [message_len_max]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch &buffer;

    std.debug.assert(message.len > 0);
    std.debug.assert(message.len <= message_len_max);

    if (stderr_is_terminal()) {
        std.debug.print("\n{s}{s}\nERROR: {s}\n{s}{s}\n\n", .{
            red_bold,
            fence,
            message,
            fence,
            reset,
        });
    } else {
        std.debug.print("\n{s}\nERROR: {s}\n{s}\n\n", .{ fence, message, fence });
    }
}

pub fn err_text(message: []const u8) void {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len <= message_len_max);

    err("{s}", .{message});
}

fn stderr_is_terminal() bool {
    std.debug.assert(fence.len == 72);
    std.debug.assert(red_bold.len > 0);

    if (builtin.os.tag == .wasi) {
        return false;
    }

    return std.c.isatty(2) == 1;
}
