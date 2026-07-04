//! Web-flavored inputs: RichText (textarea with rich editor widget),
//! Email, and Url.

const std = @import("std");
const def = @import("def.zig");
const views = @import("views");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;

/// Rich text input with editor widget.
pub fn RichText(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
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
                .rows = 12,
                .widget = "richtext",
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "richtext",
        .required = opts.required,
        .storage = .data_only,
        .searchable = opts.searchable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Email input with basic format validation.
pub fn Email(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            if (value.len > 0) {
                const at_pos = std.mem.indexOfScalar(u8, value, '@') orelse {
                    return "Invalid email address";
                };
                if (at_pos == 0) return "Invalid email address";
                const domain = value[at_pos + 1 ..];
                if (domain.len == 0) return "Invalid email address";
                if (std.mem.indexOfScalar(u8, domain, '.') == null) {
                    return "Invalid email address";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try views.components.fields.input.Input(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .input_type = "email",
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "email",
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .filterable = opts.filterable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// URL input with basic format validation.
pub fn Url(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            if (value.len > 0) {
                const has_scheme = std.mem.startsWith(u8, value, "http://") or
                    std.mem.startsWith(u8, value, "https://");
                if (!has_scheme) {
                    return "URL must start with http:// or https://";
                }
                const after_scheme = if (std.mem.startsWith(u8, value, "https://"))
                    value[8..]
                else
                    value[7..];
                if (after_scheme.len == 0) {
                    return "URL must include a host";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try views.components.fields.input.Input(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .input_type = "url",
                .placeholder = "https://",
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "url",
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .filterable = opts.filterable,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}
