//! Reference builders: Slug (auto-generated URL-friendly identifier) and
//! Ref (typed link to another content entry).

const std = @import("std");
const def = @import("def.zig");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;
const TranslatableMode = def.TranslatableMode;

/// URL-friendly slug, optionally auto-generated from a source field.
pub fn Slug(comptime name: []const u8, comptime opts: struct {
    source: ?[]const u8 = null,
    required: bool = false,
    display: ?[]const u8 = null,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            for (value) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') {
                    return "Slug can only contain letters, numbers, hyphens, and underscores";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                "  <input type=\"text\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"\n" ++
                    "         data-widget=\"slug\"",
                .{ ctx.name, ctx.name, ctx.value orelse "" },
            );
            if (opts.source) |src| {
                try writer.print(" data-source=\"{s}\"", .{src});
            }
            if (ctx.required) try writer.writeAll(" required");
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "slug",
        .required = opts.required,
        .storage = .data_only,
        .position = opts.position,
        .source_field = opts.source,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Reference to another content type entry.
pub fn Ref(comptime name: []const u8, comptime opts: struct {
    to: []const u8,
    many: bool = false,
    required: bool = false,
    display: ?[]const u8 = null,
    translatable_mode: TranslatableMode = .synced,
    position: Position = .main,
}) FieldDef {
    const resolved_mode = opts.translatable_mode;

    if (resolved_mode != .synced) {
        @compileError("Ref fields cannot be translatable — references are locale-independent");
    }
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (def.requiredCheck(opts, value)) |err| return err;
            if (value.len > 0 and !std.mem.startsWith(u8, value, "e_")) {
                return "Invalid entry reference";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                \\  <div data-widget="ref-picker" data-ref-type="{s}" data-ref-many="{s}"
                \\       data-name="{s}" data-value="{s}">
                \\    <input type="hidden" name="{s}" value="{s}" />
                \\    <button type="button" class="btn btn-sm">Select {s}</button>
                \\  </div>
                \\</div>
            , .{
                opts.to,
                if (opts.many) "true" else "false",
                ctx.name,
                ctx.value orelse "",
                ctx.name,
                ctx.value orelse "",
                opts.to,
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse def.humanize(name),
        .field_type_id = "reference",
        .required = opts.required,
        .translatable_mode = .synced,
        .storage = .data_only,
        .multi = opts.many,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}
