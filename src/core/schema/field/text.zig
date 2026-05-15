//! Text-input builders: String (single line) and Text (multi-line textarea).

const std = @import("std");
const def = @import("def.zig");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;

/// Single-line text input.
pub fn String(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    max_length: ?usize = null,
    min_length: ?usize = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    searchable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            if (opts.min_length) |min| {
                if (value.len > 0 and value.len < min) {
                    return "Value is too short";
                }
            }
            if (opts.max_length) |max| {
                if (value.len > max) {
                    return "Value is too long";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                "  <input type=\"text\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"",
                .{ ctx.name, ctx.name, ctx.value orelse "" },
            );
            if (opts.max_length) |max| {
                try writer.print(" maxlength=\"{}\"", .{max});
            }
            if (ctx.required) try writer.writeAll(" required");
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "string",
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .filterable = opts.filterable,
        .searchable = opts.searchable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Multi-line text input (textarea).
pub fn Text(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    rows: u8 = 5,
    display: ?[]const u8 = null,
    searchable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                "  <textarea class=\"form-control\" id=\"{s}\" name=\"{s}\" rows=\"{}\"",
                .{ ctx.name, ctx.name, opts.rows },
            );
            if (ctx.required) try writer.writeAll(" required");
            try writer.print(">{s}</textarea>\n</div>\n", .{ctx.value orelse ""});
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "text",
        .required = opts.required,
        .storage = .data_only,
        .searchable = opts.searchable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}
