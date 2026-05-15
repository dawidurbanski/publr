//! Content Types plugin — inspect registered content types from the
//! runtime registry. Reads compile-in + WASM + DB-defined descriptors
//! through the same `schema_registry.all()` accessor.

const std = @import("std");
const admin = @import("admin_api");
const views = @import("views");
const schema_registry = @import("schema_registry");

pub const page = admin.registerPage(.{
    .id = "content_types",
    .title = "Content Types",
    .path = "/content-types",
    .icon = .package,
    .position = 22,
    .section = "content_types",
    .view = views.admin.content_types.ContentTypes,
    .loader = load,
});

fn joinLocales(allocator: std.mem.Allocator, locales: []const []const u8) ![]const u8 {
    if (locales.len == 0) return allocator.dupe(u8, "en (default)");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    for (locales, 0..) |locale, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, locale);
        if (i == 0) try buf.appendSlice(allocator, " (default)");
    }

    return buf.toOwnedSlice(allocator);
}

fn countByTranslatableMode(fields: []const @import("field").FieldDef, mode: @import("field").TranslatableMode) usize {
    var n: usize = 0;
    for (fields) |f| {
        if (f.translatable_mode == mode) n += 1;
    }
    return n;
}

fn load(ctx: *admin.Context) !views.admin.content_types.Props {
    const types = schema_registry.all();
    const rows = try ctx.allocator.alloc(views.admin.content_types.TypeRow, types.len);

    for (types, 0..) |def, i| {
        const synced = countByTranslatableMode(def.fields, .synced);
        const fallback = countByTranslatableMode(def.fields, .with_fallback);
        rows[i] = .{
            .id = def.type_id,
            .name = def.display_name,
            .name_plural = def.display_name_plural,
            .icon = def.icon orelse "bookmark",
            .localized = if (def.localized) "localized" else "single-locale",
            .locales = joinLocales(ctx.allocator, def.locales) catch "en (default)",
            .workflow = def.workflow orelse "default_publish",
            .internal = def.internal,
            .taxonomy = def.taxonomy != null,
            .fields_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{def.fields.len}) catch "0",
            .synced_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{synced}) catch "0",
            .fallback_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{fallback}) catch "0",
            .permissions_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{def.field_permissions.len}) catch "0",
        };
    }

    return .{
        .has_types = rows.len > 0,
        .total_count = try std.fmt.allocPrint(ctx.allocator, "{d}", .{rows.len}),
        .rows = rows,
    };
}
