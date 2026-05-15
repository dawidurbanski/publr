//! Image media reference. Renders an image picker widget bound to the
//! media library.

const std = @import("std");
const def = @import("def.zig");

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
            const has_value = value.len > 0;

            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                \\  <div class="image-picker" data-publr-component="image-picker" data-publr-state="{s}">
                \\    <input type="hidden" name="{s}" value="{s}" data-publr-part="value" />
                \\    <div class="image-picker-preview" data-publr-part="preview">
            , .{
                if (has_value) "selected" else "empty",
                ctx.name,
                value,
            });

            if (has_value) {
                try writer.print(
                    \\      <img src="/admin/media/picker/thumb/{s}" alt="" class="image-picker-thumb" />
                , .{value});
            } else {
                try writer.writeAll(
                    \\      <div class="image-picker-placeholder">
                    \\        <svg class="icon" viewBox="0 0 24 24" fill="none"><path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                    \\        <span>No image selected</span>
                    \\      </div>
                );
            }

            try writer.print(
                \\    </div>
                \\    <div class="image-picker-actions">
                \\      <button type="button" class="btn btn-sm" data-publr-part="trigger">
                \\        {s}
                \\      </button>
                \\      <button type="button" class="btn btn-sm btn-ghost{s}" data-publr-part="remove">
                \\        Remove
                \\      </button>
                \\    </div>
                \\    <div class="image-picker-alt" data-publr-part="alt"></div>
                \\  </div>
                \\</div>
            , .{
                if (has_value) "Change Image" else "Select Image",
                if (has_value) "" else " hidden",
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
