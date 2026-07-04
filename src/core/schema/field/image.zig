//! Image media reference. Renders an image picker widget bound to the
//! media library.

const std = @import("std");
const def = @import("def.zig");
const views = @import("views");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;
const TranslatableMode = def.TranslatableMode;

pub fn Image(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    translatable_mode: TranslatableMode = .synced,
    position: Position = .side,
}) FieldDef {
    const resolved_mode = opts.translatable_mode;

    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            // Media IDs should be m_xxx format
            if (value.len > 0 and !std.mem.startsWith(u8, value, "m_")) {
                return "Invalid media reference";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const value = ctx.value orelse "";
            try views.components.fields.image.Image(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = value,
                .has_value = value.len > 0,
                .required = ctx.required,
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "image",
        .required = opts.required,
        .translatable_mode = resolved_mode,
        .storage = .data_only,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}
