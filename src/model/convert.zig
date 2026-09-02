const std = @import("std");
const field = @import("field.zig");

const Kind = field.Kind;
const Value = std.json.Value;

pub const Error = error{ NotConvertible, DataDoesNotFit, OutOfMemory };

pub fn allowed(from: Kind, to: Kind) bool {
    std.debug.assert(@intFromEnum(from) <= 14);
    std.debug.assert(@intFromEnum(to) <= 14);

    if (from == to) {
        return true;
    }

    return switch (from) {
        .string => to == .text or to == .richtext or to == .slug or to == .email or to == .url or
            to == .select or to == .integer or to == .number,
        .text => to == .richtext,
        .richtext => to == .text,
        .slug, .email, .url, .select => to == .string or to == .text,
        .integer => to == .number or to == .string,
        .number => to == .string or to == .integer,
        .boolean => to == .string,
        .datetime => to == .integer,
        .reference, .image, .group, .repeater => false,
    };
}

pub fn convert(arena: std.mem.Allocator, from: field.Def, to: field.Def, value: Value) Error!Value {
    std.debug.assert(allowed(from.kind, to.kind));
    std.debug.assert(std.mem.eql(u8, from.name, to.name));

    if (from.many and !to.many) {
        if (value != .array) {
            return value;
        }

        if (value.array.items.len > 1) {
            return error.DataDoesNotFit;
        }

        return if (value.array.items.len == 1) value.array.items[0] else .null;
    }

    if (!from.many and to.many) {
        var array = std.json.Array.init(arena);
        array.append(value) catch return error.OutOfMemory;

        return .{ .array = array };
    }

    return convert_scalar(from.kind, to, value);
}

fn convert_scalar(from: Kind, to: field.Def, value: Value) Error!Value {
    std.debug.assert(allowed(from, to.kind));
    std.debug.assert(field.is_leaf(to.kind) or from == to.kind);

    if (from == to.kind) {
        return value;
    }

    return switch (to.kind) {
        .integer => switch (value) {
            .string => |text| .{
                .integer = std.fmt.parseInt(i64, text, 10) catch return error.DataDoesNotFit,
            },
            .float => |number| if (number == @trunc(number))
                .{ .integer = @intFromFloat(number) }
            else
                error.DataDoesNotFit,
            .integer => value,
            else => error.DataDoesNotFit,
        },
        .number => switch (value) {
            .string => |text| .{
                .float = std.fmt.parseFloat(f64, text) catch return error.DataDoesNotFit,
            },
            .integer => |number| .{ .float = @floatFromInt(number) },
            else => value,
        },
        .string, .text, .richtext, .slug, .email, .url => switch (value) {
            .string => value,
            .integer => |number| .{ .integer = number },
            .float => value,
            .bool => |flag| .{ .string = if (flag) "true" else "false" },
            else => error.DataDoesNotFit,
        },
        .select => switch (value) {
            .string => |text| if (contains(
                to.options.choices,
                text,
            )) value else error.DataDoesNotFit,
            else => error.DataDoesNotFit,
        },
        else => error.NotConvertible,
    };
}

fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(list.len <= field.choices_max);
    std.debug.assert(item.len <= 64 << 10);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

test "conversion table: widening allowed, shape changes refused" {
    try std.testing.expect(allowed(.string, .text));
    try std.testing.expect(allowed(.string, .integer));
    try std.testing.expect(allowed(.integer, .number));
    try std.testing.expect(allowed(.datetime, .integer));
    try std.testing.expect(!allowed(.text, .string));
    try std.testing.expect(!allowed(.reference, .string));
    try std.testing.expect(!allowed(.string, .reference));
    try std.testing.expect(!allowed(.repeater, .group));
}

test "values convert when they fit and are refused when they do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text: field.Def = .{ .name = "n", .label = "N", .kind = .string };
    const integer: field.Def = .{ .name = "n", .label = "N", .kind = .integer };
    const select: field.Def = .{
        .name = "n",
        .label = "N",
        .kind = .select,
        .options = .{ .choices = &.{"a"} },
    };

    const forty_two = try convert(arena, text, integer, .{ .string = "42" });
    try std.testing.expectEqual(@as(i64, 42), forty_two.integer);
    try std.testing.expectError(
        error.DataDoesNotFit,
        convert(arena, text, integer, .{ .string = "x" }),
    );
    try std.testing.expectError(
        error.DataDoesNotFit,
        convert(arena, text, select, .{ .string = "b" }),
    );

    const one: field.Def = .{ .name = "r", .label = "R", .kind = .reference };
    const many: field.Def = .{ .name = "r", .label = "R", .kind = .reference, .many = true };
    const wrapped = try convert(arena, one, many, .{ .string = "t1" });
    try std.testing.expectEqual(@as(usize, 1), wrapped.array.items.len);

    var two = std.json.Array.init(arena);
    try two.append(.{ .string = "a" });
    try two.append(.{ .string = "b" });
    try std.testing.expectError(error.DataDoesNotFit, convert(arena, many, one, .{ .array = two }));
}
