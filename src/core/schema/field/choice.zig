//! Choice builders: Select (fixed options), Boolean (checkbox switch),
//! and DateTime (datetime-local input).

const std = @import("std");
const def = @import("def.zig");
const views = @import("views");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;

/// Dropdown select with fixed options.
pub fn Select(comptime name: []const u8, comptime opts: struct {
    options: []const []const u8,
    required: bool = false,
    default_value: ?[]const u8 = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            if (value.len > 0) {
                for (opts.options) |opt| {
                    if (std.mem.eql(u8, value, opt)) return null;
                }
                return "Invalid option selected";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try views.components.fields.select.Select(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .current = ctx.value orelse opts.default_value orelse "",
                .required = ctx.required,
                .options = opts.options,
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "select",
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .filterable = opts.filterable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Boolean checkbox. Uses a `span` label kind because the actual input is
/// wrapped in its own `<label class="form-check">`.
pub fn Boolean(comptime name: []const u8, comptime opts: struct {
    default_value: bool = false,
    display: ?[]const u8 = null,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(_: []const u8) ?[]const u8 {
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const checked = if (ctx.value) |v|
                std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on")
            else
                opts.default_value;

            try views.components.fields.checkbox.Checkbox(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .checked = checked,
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "boolean",
        .required = false,
        .storage = .data_only,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Date/time picker.
pub fn DateTime(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            // TODO: validate datetime format
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try views.components.fields.input.Input(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .input_type = "datetime-local",
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "datetime",
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .int,
        .filterable = opts.filterable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}
