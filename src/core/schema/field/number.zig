//! Numeric inputs: Integer (i64) and Number (f64).

const std = @import("std");
const def = @import("def.zig");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;

/// Integer number input.
pub fn Integer(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    min: ?i64 = null,
    max: ?i64 = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            if (value.len > 0) {
                const parsed = std.fmt.parseInt(i64, value, 10) catch {
                    return "Must be a valid integer";
                };
                if (opts.min) |min| {
                    if (parsed < min) return "Value is too small";
                }
                if (opts.max) |max| {
                    if (parsed > max) return "Value is too large";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                "  <input type=\"number\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"",
                .{ ctx.name, ctx.name, ctx.value orelse "" },
            );
            if (opts.min) |min| {
                try writer.print(" min=\"{}\"", .{min});
            }
            if (opts.max) |max| {
                try writer.print(" max=\"{}\"", .{max});
            }
            if (ctx.required) try writer.writeAll(" required");
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "integer",
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .int,
        .filterable = opts.filterable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Floating-point number input.
pub fn Number(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            if (value.len > 0) {
                const parsed = std.fmt.parseFloat(f64, value) catch {
                    return "Must be a valid number";
                };
                if (opts.min) |min| {
                    if (parsed < min) return "Value is too small";
                }
                if (opts.max) |max| {
                    if (parsed > max) return "Value is too large";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                "  <input type=\"number\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"",
                .{ ctx.name, ctx.name, ctx.value orelse "" },
            );
            if (opts.min) |min| {
                try writer.print(" min=\"{d}\"", .{min});
            }
            if (opts.max) |max| {
                try writer.print(" max=\"{d}\"", .{max});
            }
            if (opts.step) |step| {
                try writer.print(" step=\"{d}\"", .{step});
            } else {
                try writer.writeAll(" step=\"any\"");
            }
            if (ctx.required) try writer.writeAll(" required");
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "number",
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .real,
        .filterable = opts.filterable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}
