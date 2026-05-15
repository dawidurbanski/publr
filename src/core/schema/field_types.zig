//! Field-type operations indexed by `field_type_id`.
//!
//! Today the `FieldDef` descriptor still carries `validate` and `render`
//! function pointers — this module provides the *lookup-table* equivalents so
//! runtime-loaded descriptors (DB-defined types in task 03, WASM plugins
//! later) can find a default validator / renderer for a given
//! `field_type_id` without inheriting comptime function pointers from a
//! compile-in builder.
//!
//! Comptime descriptors keep getting their per-instance closures (so config
//! like `max_length`, `min`/`max`, regex etc. is honored). The lookup table
//! is the fallback path for descriptors that were never built through a Zig
//! field builder.

const std = @import("std");

const field = @import("field.zig");

const FieldDef = field.FieldDef;
const RenderContext = field.RenderContext;

/// Operations a runtime field type must support.
pub const FieldTypeOps = struct {
    validate: *const fn (fd: FieldDef, value: []const u8) ?[]const u8,
    render: *const fn (fd: FieldDef, writer: std.io.AnyWriter, ctx: RenderContext) anyerror!void,
};

fn validatePassthrough(fd: FieldDef, value: []const u8) ?[]const u8 {
    if (fd.required and value.len == 0) return "This field is required";
    return null;
}

fn renderUnsupported(_: FieldDef, writer: std.io.AnyWriter, _: RenderContext) !void {
    try writer.writeAll("<!-- runtime renderer not yet implemented -->");
}

const default_ops: FieldTypeOps = .{
    .validate = validatePassthrough,
    .render = renderUnsupported,
};

const entries = [_]struct { []const u8, FieldTypeOps }{
    .{ "string", default_ops },
    .{ "text", default_ops },
    .{ "slug", default_ops },
    .{ "select", default_ops },
    .{ "richtext", default_ops },
    .{ "email", default_ops },
    .{ "url", default_ops },
    .{ "boolean", default_ops },
    .{ "integer", default_ops },
    .{ "number", default_ops },
    .{ "datetime", default_ops },
    .{ "image", default_ops },
    .{ "reference", default_ops },
    .{ "taxonomy", default_ops },
    .{ "group", default_ops },
    .{ "repeater", default_ops },
};

pub const ops_by_type_id = std.StaticStringMap(FieldTypeOps).initComptime(entries);

/// Look up the runtime ops for a given `field_type_id`. Returns null for
/// unknown ids — callers that hold a FieldDef with comptime function
/// pointers should prefer those (this lookup is the fallback for descriptors
/// created at runtime).
pub fn opsFor(field_type_id: []const u8) ?FieldTypeOps {
    return ops_by_type_id.get(field_type_id);
}

test "opsFor returns ops for known field types" {
    try std.testing.expect(opsFor("string") != null);
    try std.testing.expect(opsFor("group") != null);
    try std.testing.expect(opsFor("repeater") != null);
}

test "opsFor returns null for unknown field type" {
    try std.testing.expect(opsFor("not_a_real_type") == null);
}
