//! Content Types plugin — inspect compiled content model metadata.

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const views = @import("views");
const registry = @import("registry");
const schemas = @import("schemas");

pub const page = admin.registerPage(.{
    .id = "content_types",
    .title = "Content Types",
    .path = "/content-types",
    .icon = icons.package,
    .position = 22,
    .section = "content_types",
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleList);
}

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

fn handleList(ctx: *Context) !void {
    const Row = struct {
        id: []const u8,
        name: []const u8,
        name_plural: []const u8,
        icon: []const u8,
        localized: []const u8,
        locales: []const u8,
        workflow: []const u8,
        internal: bool,
        taxonomy: bool,
        fields_count: []const u8,
        synced_count: []const u8,
        fallback_count: []const u8,
        permissions_count: []const u8,
    };

    var rows = ctx.allocator.alloc(Row, schemas.content_types.len) catch {
        ctx.html(registry.renderPage(page, ctx, "Failed to allocate content type rows"));
        return;
    };

    inline for (schemas.content_types, 0..) |CT, i| {
        rows[i] = .{
            .id = CT.type_id,
            .name = CT.display_name,
            .name_plural = CT.display_name_plural,
            .icon = CT.icon,
            .localized = if (CT.localized) "localized" else "single-locale",
            .locales = joinLocales(ctx.allocator, CT.available_locales) catch "en (default)",
            .workflow = CT.workflow orelse "default_publish",
            .internal = CT.internal,
            .taxonomy = CT.is_taxonomy,
            .fields_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{CT.schema.len}) catch "0",
            .synced_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{CT.getSyncedFields().len}) catch "0",
            .fallback_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{CT.getFallbackFields().len}) catch "0",
            .permissions_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{CT.field_permissions.len}) catch "0",
        };
    }

    const content = tpl.render(views.admin.content_types.ContentTypes, .{.{
        .has_types = rows.len > 0,
        .total_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{rows.len}) catch "0",
        .rows = rows,
    }});
    ctx.html(registry.renderPage(page, ctx, content));
}
