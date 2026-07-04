//! Built-in field-type render registry.
//!
//! Comptime field builders bind their own opts-aware render fn into
//! `FieldDef.render`. DB-loaded content types are reconstructed from JSON with a
//! stub renderer, so their `render` writes nothing; `renderFieldsHtml` detects
//! that (zero bytes) and falls back here, dispatching on `field_type_id` to the
//! SAME ZSX field components.
//!
//! DB-loaded descriptors lack the comptime opts (max_length, select options,
//! min/max, ref target, container sub_fields), so these adapters render the
//! generic form of each type — but through the real components, so there is no
//! HTML in Zig and the image/boolean/taxonomy widgets now match the comptime
//! conventions (the deleted `renderDefaultField` string-chain diverged: it
//! emitted a dead `media-picker` and a switch instead of a checkbox).
//!
//! This replaces the if-else HTML string-chain. To add a built-in field type,
//! add an entry to `builtin`; a future plugin API can layer a runtime override.

const std = @import("std");
const field_mod = @import("field");
const views = @import("views");

const FieldDef = field_mod.FieldDef;
const RenderContext = field_mod.RenderContext;
const AnyWriter = std.io.AnyWriter;

const RenderFn = *const fn (AnyWriter, FieldDef, RenderContext) anyerror!void;

const builtin = [_]struct { id: []const u8, render: RenderFn }{
    .{ .id = "text", .render = renderText },
    .{ .id = "richtext", .render = renderRichText },
    .{ .id = "boolean", .render = renderBoolean },
    .{ .id = "datetime", .render = renderDatetime },
    .{ .id = "integer", .render = renderInteger },
    .{ .id = "number", .render = renderNumber },
    .{ .id = "email", .render = renderEmail },
    .{ .id = "url", .render = renderUrl },
    .{ .id = "image", .render = renderImage },
    .{ .id = "reference", .render = renderReference },
    .{ .id = "taxonomy", .render = renderTaxonomy },
};

/// Dispatch a field to its ZSX component by `field_type_id`. Types with no
/// registered renderer (string, slug, select, group, repeater — the last three
/// can't render without comptime data on a DB-loaded descriptor) fall back to a
/// plain text input, matching the old string-chain's default branch.
pub fn renderField(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    for (builtin) |entry| {
        if (std.mem.eql(u8, entry.id, fd.field_type_id)) return entry.render(w, fd, ctx);
    }
    return renderTextInput(w, fd, ctx);
}

fn errs(ctx: RenderContext) []const []const u8 {
    return ctx.errors orelse &.{};
}

fn input(w: AnyWriter, ctx: RenderContext, comptime input_type: []const u8, comptime placeholder: ?[]const u8, comptime step: ?[]const u8) !void {
    try views.components.fields.input.Input(w, .{
        .name = ctx.name,
        .display_name = ctx.display_name,
        .value = ctx.value orelse "",
        .required = ctx.required,
        .input_type = input_type,
        .placeholder = placeholder,
        .step = step,
        .errors = errs(ctx),
    });
}

fn renderTextInput(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try input(w, ctx, "text", null, null);
}

fn renderDatetime(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try input(w, ctx, "datetime-local", null, null);
}

fn renderInteger(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try input(w, ctx, "number", null, null);
}

fn renderNumber(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try input(w, ctx, "number", null, "any");
}

fn renderEmail(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try input(w, ctx, "email", null, null);
}

fn renderUrl(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try input(w, ctx, "url", "https://", null);
}

fn renderReference(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    // No ref target on a DB-loaded descriptor → plain input (matches the old
    // fallback; the ref-picker needs the comptime `to`).
    try input(w, ctx, "text", "Entry ID", null);
}

fn renderText(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try views.components.fields.text.TextArea(w, .{
        .name = ctx.name,
        .display_name = ctx.display_name,
        .value = ctx.value orelse "",
        .required = ctx.required,
        .rows = 5,
        .errors = errs(ctx),
    });
}

fn renderRichText(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    try views.components.fields.text.TextArea(w, .{
        .name = ctx.name,
        .display_name = ctx.display_name,
        .value = ctx.value orelse "",
        .required = ctx.required,
        .rows = 12,
        .widget = "richtext",
        .errors = errs(ctx),
    });
}

fn renderBoolean(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    const checked = std.mem.eql(u8, ctx.value orelse "", "true");
    try views.components.fields.checkbox.Checkbox(w, .{
        .name = ctx.name,
        .display_name = ctx.display_name,
        .checked = checked,
        .errors = errs(ctx),
    });
}

fn renderImage(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    _ = fd;
    const value = ctx.value orelse "";
    try views.components.fields.image.Image(w, .{
        .name = ctx.name,
        .display_name = ctx.display_name,
        .value = value,
        .has_value = value.len > 0,
        .required = ctx.required,
        .errors = errs(ctx),
    });
}

fn renderTaxonomy(w: AnyWriter, fd: FieldDef, ctx: RenderContext) !void {
    try views.components.fields.taxonomy.Taxonomy(w, .{
        .name = ctx.name,
        .display_name = ctx.display_name,
        .value = ctx.value orelse "",
        .required = ctx.required,
        .taxonomy_id = fd.taxonomy_id orelse fd.name,
        .many = fd.multi,
        .label = fd.display_name,
        .errors = errs(ctx),
    });
}
