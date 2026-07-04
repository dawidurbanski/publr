//! Taxonomy field — categorical data stored in entry_terms.

const std = @import("std");
const def = @import("def.zig");
const views = @import("views");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;

pub fn Taxonomy(comptime taxonomy_id: []const u8, comptime opts: struct {
    required: bool = false,
    many: bool = true,
    display: ?[]const u8 = null,
    position: Position = .side,
}) FieldDef {
    const humanized_taxonomy = comptime def.humanize(taxonomy_id);

    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try views.components.fields.taxonomy.Taxonomy(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .value = ctx.value orelse "",
                .required = ctx.required,
                .taxonomy_id = taxonomy_id,
                .many = opts.many,
                .label = humanized_taxonomy,
                .errors = ctx.errors orelse &.{},
            });
        }
    };

    return .{
        .name = taxonomy_id,
        .display_name = opts.display orelse def.humanize(taxonomy_id),
        .field_type_id = "taxonomy",
        .required = opts.required,
        .storage = .taxonomy,
        .multi = opts.many,
        .taxonomy_id = taxonomy_id,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}
