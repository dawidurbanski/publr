//! Text-input builders: String (single line) and Text (multi-line textarea).

const std = @import("std");
const def = @import("def.zig");
const views = @import("views");

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
            const max_str: ?[]const u8 = if (opts.max_length) |m|
                std.fmt.comptimePrint("{d}", .{m})
            else
                null;
            try views.components.fields.input.Input(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .input_type = "text",
                .maxlength = max_str,
                .errors = ctx.errors orelse &.{},
            });
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
            try views.components.fields.text.TextArea(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .rows = opts.rows,
                .errors = ctx.errors orelse &.{},
            });
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
