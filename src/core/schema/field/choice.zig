//! Choice builders: Select (fixed options), Boolean (checkbox switch),
//! and DateTime (datetime-local input).

const std = @import("std");
const def = @import("def.zig");

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
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                "  <select class=\"form-control\" id=\"{s}\" name=\"{s}\"",
                .{ ctx.name, ctx.name },
            );
            if (ctx.required) try writer.writeAll(" required");
            try writer.writeAll(">\n");

            if (!ctx.required) {
                try writer.writeAll("    <option value=\"\">-- Select --</option>\n");
            }

            const current = ctx.value orelse opts.default_value orelse "";
            inline for (opts.options) |opt| {
                const selected = if (std.mem.eql(u8, current, opt)) " selected" else "";
                try writer.print("    <option value=\"{s}\"{s}>{s}</option>\n", .{ opt, selected, opt });
            }

            try writer.writeAll("  </select>\n</div>\n");
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

            try def.writeFieldLabelRow(writer, ctx, .span);
            try writer.print(
                \\  <label class="form-check">
                \\    <input type="checkbox" class="form-check-input" name="{s}" value="true"{s} />
                \\    <span class="form-check-label">{s}</span>
                \\  </label>
                \\</div>
            , .{
                ctx.name,
                if (checked) " checked" else "",
                ctx.display_name,
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
            try def.writeFieldLabelRow(writer, ctx, .label_with_for);
            try writer.print(
                "  <input type=\"datetime-local\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"",
                .{ ctx.name, ctx.name, ctx.value orelse "" },
            );
            if (ctx.required) try writer.writeAll(" required");
            try writer.writeAll(" />\n</div>\n");
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
