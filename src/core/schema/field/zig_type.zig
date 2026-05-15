//! Comptime type derivation for fields. `zigTypeFor` and `GenerateSubStruct`
//! are how the schema system bridges from data descriptors to first-class Zig
//! types (used by ContentType for the top-level Data struct, and by Group /
//! Repeater for nested struct types).

const std = @import("std");
const def = @import("def.zig");

const FieldDef = def.FieldDef;

/// Resolve the Zig type for a field at comptime.
///
/// Scalar field types map to fixed Zig types (`string` -> `[]const u8`,
/// `integer` -> `?i64`, ...). Containers (`group`, `repeater`) recurse on
/// `sub_fields`. The `multi` flag on `reference` / `taxonomy` selects a
/// slice-of-slices instead of a single slice.
pub fn zigTypeFor(comptime f: FieldDef) type {
    const id = f.field_type_id;
    if (comptime std.mem.eql(u8, id, "string")) return []const u8;
    if (comptime std.mem.eql(u8, id, "text")) return []const u8;
    if (comptime std.mem.eql(u8, id, "slug")) return []const u8;
    if (comptime std.mem.eql(u8, id, "select")) return []const u8;
    if (comptime std.mem.eql(u8, id, "richtext")) return []const u8;
    if (comptime std.mem.eql(u8, id, "email")) return []const u8;
    if (comptime std.mem.eql(u8, id, "url")) return []const u8;
    if (comptime std.mem.eql(u8, id, "boolean")) return bool;
    if (comptime std.mem.eql(u8, id, "integer")) return ?i64;
    if (comptime std.mem.eql(u8, id, "number")) return ?f64;
    if (comptime std.mem.eql(u8, id, "datetime")) return ?i64;
    if (comptime std.mem.eql(u8, id, "image")) return ?[]const u8;
    if (comptime std.mem.eql(u8, id, "reference")) {
        return if (f.multi) []const []const u8 else []const u8;
    }
    if (comptime std.mem.eql(u8, id, "taxonomy")) {
        return if (f.multi) []const []const u8 else []const u8;
    }
    if (comptime std.mem.eql(u8, id, "group")) return GenerateSubStruct(f.sub_fields);
    if (comptime std.mem.eql(u8, id, "repeater")) return []const GenerateSubStruct(f.sub_fields);
    @compileError("Unknown field_type_id: " ++ id);
}

/// Generate a struct type from field definitions at comptime.
pub fn GenerateSubStruct(comptime fields: []const FieldDef) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, 0..) |f, i| {
        const is_repeater = comptime std.mem.eql(u8, f.field_type_id, "repeater");
        const RawType = zigTypeFor(f);

        // Repeater uses raw slice type (not optional) — empty slice is the "absent" state.
        const FieldType = if (f.required or is_repeater)
            RawType
        else if (@typeInfo(RawType) == .optional)
            RawType
        else
            ?RawType;

        struct_fields[i] = .{
            .name = f.name ++ "",
            .type = FieldType,
            .default_value_ptr = if (f.required)
                null
            else if (is_repeater)
                @as(?*const anyopaque, @ptrCast(&@as(FieldType, &.{})))
            else
                @as(?*const anyopaque, @ptrCast(&@as(FieldType, null))),
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Convert a std.json.Value to a string for field rendering.
pub fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch null,
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}) catch null,
        .bool => |b| if (b) "true" else "false",
        .null => null,
        .object, .array => blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            buf.writer(allocator).print("{f}", .{std.json.fmt(value, .{})}) catch break :blk null;
            break :blk buf.toOwnedSlice(allocator) catch null;
        },
        .number_string => |s| s,
    };
}
