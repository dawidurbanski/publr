//! Container builders: Group (nested object) and Repeater (array of objects).

const std = @import("std");
const def = @import("def.zig");
const zt = @import("zig_type.zig");
const views = @import("views");

const FieldDef = def.FieldDef;
const RenderContext = def.RenderContext;
const Position = def.Position;
const TranslatableMode = def.TranslatableMode;

/// Group of fields — produces a nested JSON object.
pub fn Group(comptime name: []const u8, comptime config: struct {
    required: bool = false,
    label: ?[]const u8 = null,
    position: Position = .main,
    translatable_mode: TranslatableMode = .independent,
}, comptime sub_fields: []const FieldDef) FieldDef {
    const S = struct {
        pub fn validate(_: []const u8) ?[]const u8 {
            // Group-level validation is a no-op; sub-field validation runs
            // during form parsing.
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const alloc = ctx.allocator orelse return;

            var obj: ?std.json.ObjectMap = null;
            var parsed_result: ?std.json.Parsed(std.json.Value) = null;
            if (ctx.value) |json_str| {
                if (json_str.len > 2) {
                    if (std.json.parseFromSlice(std.json.Value, alloc, json_str, .{})) |result| {
                        parsed_result = result;
                        if (result.value == .object) {
                            obj = result.value.object;
                        }
                    } else |_| {}
                }
            }
            defer if (parsed_result) |*pr| pr.deinit();

            // Buffer the sub-fields' HTML (rendered through each field's ZSX
            // component), then hand it to FieldGroup as `{@raw children}`. The
            // `{name}.{sub}` name contract stays here — it's data, not HTML.
            var children: std.ArrayListUnmanaged(u8) = .{};
            defer children.deinit(alloc);

            inline for (sub_fields) |sf| {
                const sub_value: ?[]const u8 = if (obj) |o| blk: {
                    if (o.get(sf.name)) |v| {
                        break :blk zt.jsonValueToString(alloc, v);
                    }
                    break :blk null;
                } else null;

                const dotted = std.fmt.allocPrint(alloc, "{s}.{s}", .{ ctx.name, sf.name }) catch sf.name;
                sf.render(children.writer(alloc).any(), .{
                    .name = dotted,
                    .display_name = sf.display_name,
                    .value = sub_value,
                    .required = sf.required,
                    .allocator = alloc,
                }) catch {};
            }

            try views.components.fields.field_group.FieldGroup(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .children = children.items,
            });
        }
    };

    return .{
        .name = name,
        .display_name = config.label orelse def.humanize(name),
        .field_type_id = "group",
        .required = config.required,
        .position = config.position,
        .translatable_mode = config.translatable_mode,
        .sub_fields = sub_fields,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Repeater of fields — produces a JSON array of objects.
pub fn Repeater(comptime name: []const u8, comptime config: struct {
    required: bool = false,
    label: ?[]const u8 = null,
    min: ?usize = null,
    max: ?usize = null,
    max_depth: usize = 2,
    position: Position = .main,
    translatable_mode: TranslatableMode = .independent,
}, comptime sub_fields: []const FieldDef) FieldDef {
    // Enforce max_depth: count Repeater nesting in children + 1 for self
    const child_depth = computeRepeaterDepth(sub_fields);
    if (child_depth + 1 > config.max_depth) {
        @compileError("Repeater nesting exceeds max_depth of " ++ std.fmt.comptimePrint("{d}", .{config.max_depth}));
    }

    const S = struct {
        pub fn validate(_: []const u8) ?[]const u8 {
            // Repeater-level validation is a no-op; per-item + min/max
            // count validation runs at form parsing time.
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const alloc = ctx.allocator orelse return;

            var arr: ?std.json.Array = null;
            var parsed_result: ?std.json.Parsed(std.json.Value) = null;
            if (ctx.value) |json_str| {
                if (json_str.len > 1) {
                    if (std.json.parseFromSlice(std.json.Value, alloc, json_str, .{})) |result| {
                        parsed_result = result;
                        if (result.value == .array) {
                            arr = result.value.array;
                        }
                    } else |_| {}
                }
            }
            defer if (parsed_result) |*pr| pr.deinit();

            const item_count = if (arr) |a| a.items.len else 0;
            const min_str: ?[]const u8 = if (config.min) |m| std.fmt.comptimePrint("{d}", .{m}) else null;
            const max_str: ?[]const u8 = if (config.max) |m| std.fmt.comptimePrint("{d}", .{m}) else null;

            // Buffer the existing items: each item's sub-fields (with the
            // `{name}.{idx}.{sub}` name contract) wrapped in a RepeaterItem.
            var items: std.ArrayListUnmanaged(u8) = .{};
            defer items.deinit(alloc);
            if (arr) |a| {
                for (a.items, 0..) |item, idx| {
                    var sub: std.ArrayListUnmanaged(u8) = .{};
                    defer sub.deinit(alloc);
                    writeItemSubFields(sub.writer(alloc).any(), alloc, ctx.name, item, idx);
                    views.components.fields.repeater.RepeaterItem(
                        items.writer(alloc).any(),
                        .{ .children = sub.items },
                    ) catch {};
                }
            }

            // Buffer the blank <template> item (`{name}.__INDEX__.{sub}` names).
            var tsub: std.ArrayListUnmanaged(u8) = .{};
            defer tsub.deinit(alloc);
            writeTemplateSubFields(tsub.writer(alloc).any(), alloc, ctx.name);
            var titem: std.ArrayListUnmanaged(u8) = .{};
            defer titem.deinit(alloc);
            views.components.fields.repeater.RepeaterItem(
                titem.writer(alloc).any(),
                .{ .children = tsub.items },
            ) catch {};

            try views.components.fields.repeater.Repeater(writer, .{
                .name = ctx.name,
                .display_name = ctx.display_name,
                .required = ctx.required,
                .item_count = item_count,
                .min = min_str,
                .max = max_str,
                .items_html = items.items,
                .template_html = titem.items,
                .errors = ctx.errors orelse &.{},
            });
        }

        fn writeItemSubFields(writer: std.io.AnyWriter, alloc: std.mem.Allocator, base_name: []const u8, item_value: std.json.Value, idx: usize) void {
            var obj: ?std.json.ObjectMap = null;
            if (item_value == .object) obj = item_value.object;

            inline for (sub_fields) |sf| {
                const sub_value: ?[]const u8 = if (obj) |o| blk: {
                    if (o.get(sf.name)) |v| {
                        break :blk zt.jsonValueToString(alloc, v);
                    }
                    break :blk null;
                } else null;

                const field_name = std.fmt.allocPrint(alloc, "{s}.{d}.{s}", .{ base_name, idx, sf.name }) catch sf.name;
                sf.render(writer, .{
                    .name = field_name,
                    .display_name = sf.display_name,
                    .value = sub_value,
                    .required = sf.required,
                    .allocator = alloc,
                }) catch {};
            }
        }

        fn writeTemplateSubFields(writer: std.io.AnyWriter, alloc: std.mem.Allocator, base_name: []const u8) void {
            inline for (sub_fields) |sf| {
                const field_name = std.fmt.allocPrint(alloc, "{s}.__INDEX__.{s}", .{ base_name, sf.name }) catch sf.name;
                sf.render(writer, .{
                    .name = field_name,
                    .display_name = sf.display_name,
                    .value = null,
                    .required = sf.required,
                    .allocator = alloc,
                }) catch {};
            }
        }
    };

    return .{
        .name = name,
        .display_name = config.label orelse def.humanize(name),
        .field_type_id = "repeater",
        .required = config.required,
        .position = config.position,
        .translatable_mode = config.translatable_mode,
        .sub_fields = sub_fields,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Compute the maximum Repeater nesting depth in a field tree.
/// Returns 0 if no nested Repeaters, 1 if one level of Repeater children, etc.
/// Groups pass through without counting toward depth.
fn computeRepeaterDepth(comptime fields: []const FieldDef) usize {
    var max: usize = 0;
    for (fields) |f| {
        if (comptime std.mem.eql(u8, f.field_type_id, "repeater")) {
            const depth = 1 + computeRepeaterDepth(f.sub_fields);
            if (depth > max) max = depth;
        } else if (f.sub_fields.len > 0) {
            const depth = computeRepeaterDepth(f.sub_fields);
            if (depth > max) max = depth;
        }
    }
    return max;
}
