const std = @import("std");
const Allocator = std.mem.Allocator;

/// Decode URL form-encoded string (percent-encoding and + for spaces).
/// Caller owns the returned slice.
pub fn formDecode(allocator: Allocator, input: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, input.len);
    var out_i: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexDigit(input[i + 1]);
            const lo = hexDigit(input[i + 2]);
            if (hi != null and lo != null) {
                output[out_i] = (hi.? << 4) | lo.?;
                out_i += 1;
                i += 3;
                continue;
            }
        }
        if (input[i] == '+') {
            output[out_i] = ' ';
        } else {
            output[out_i] = input[i];
        }
        out_i += 1;
        i += 1;
    }

    return output[0..out_i];
}

/// Decode percent-encoded path segments (e.g. %20 -> space).
/// Does NOT decode '+' as space (path encoding, not form encoding).
/// Returns input unchanged if no '%' present.
pub fn pathDecode(allocator: Allocator, input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null) return input;

    var buf = allocator.alloc(u8, input.len) catch return input;
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexDigit(input[i + 1]);
            const lo = hexDigit(input[i + 2]);
            if (hi != null and lo != null) {
                buf[out] = (hi.? << 4) | lo.?;
                out += 1;
                i += 3;
                continue;
            }
        }
        buf[out] = input[i];
        out += 1;
        i += 1;
    }
    return allocator.realloc(buf, out) catch buf[0..out];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "formDecode basic" {
    const allocator = std.testing.allocator;

    const result = try formDecode(allocator, "hello%20world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "formDecode plus as space" {
    const allocator = std.testing.allocator;

    const result = try formDecode(allocator, "hello+world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "formDecode passthrough" {
    const allocator = std.testing.allocator;

    const result = try formDecode(allocator, "plain");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain", result);
}

test "formDecode special chars" {
    const allocator = std.testing.allocator;

    const result = try formDecode(allocator, "%2F%3A%40");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/:@", result);
}

test "formDecode invalid percent" {
    const allocator = std.testing.allocator;

    const result = try formDecode(allocator, "100%ZZ");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("100%ZZ", result);
}

test "pathDecode does not convert plus" {
    const allocator = std.testing.allocator;

    const result = pathDecode(allocator, "hello+world");
    // '+' stays as '+' in path decoding
    try std.testing.expectEqualStrings("hello+world", result);
}

test "pathDecode percent encoding" {
    const allocator = std.testing.allocator;

    const result = pathDecode(allocator, "hello%20world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "pathDecode no percent returns input" {
    const allocator = std.testing.allocator;
    const input = "no-encoding";
    const result = pathDecode(allocator, input);
    // Should return input pointer directly
    try std.testing.expectEqual(input.ptr, result.ptr);
}
