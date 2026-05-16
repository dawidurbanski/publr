//! Taxonomy field — categorical data stored in entry_terms.

const std = @import("std");
const def = @import("def.zig");

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
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                \\  <div data-widget="taxonomy-picker" data-taxonomy="{s}" data-many="{s}"
                \\       data-name="{s}" data-value="{s}">
                \\    <input type="hidden" name="{s}" value="{s}" />
                \\    <button type="button" class="btn btn-sm">Select {s}</button>
                \\  </div>
                \\</div>
            , .{
                taxonomy_id,
                if (opts.many) "true" else "false",
                ctx.name,
                ctx.value orelse "",
                ctx.name,
                ctx.value orelse "",
                humanized_taxonomy,
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
