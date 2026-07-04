//! Numeric inputs: Integer (i64) and Number (f64).

const std = @import("std");
const def = @import("def.zig");
const views = @import("views");

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
            const min_str: ?[]const u8 = if (opts.min) |m| std.fmt.comptimePrint("{d}", .{m}) else null;
            const max_str: ?[]const u8 = if (opts.max) |m| std.fmt.comptimePrint("{d}", .{m}) else null;
            try views.components.fields.input.Input(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .input_type = "number",
                .min = min_str,
                .max = max_str,
                .errors = ctx.errors orelse &.{},
            });
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
            const min_str: ?[]const u8 = if (opts.min) |m| std.fmt.comptimePrint("{d}", .{m}) else null;
            const max_str: ?[]const u8 = if (opts.max) |m| std.fmt.comptimePrint("{d}", .{m}) else null;
            const step_str: []const u8 = if (opts.step) |s| std.fmt.comptimePrint("{d}", .{s}) else "any";
            try views.components.fields.input.Input(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .input_type = "number",
                .min = min_str,
                .max = max_str,
                .step = step_str,
                .errors = ctx.errors orelse &.{},
            });
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
