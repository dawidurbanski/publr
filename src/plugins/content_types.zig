//! Content Types plugin — placeholder for content type management
//!
//! Provides an empty state page at /admin/content-types.

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const views = @import("views");
const registry = @import("registry");

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

fn handleList(ctx: *Context) !void {
    const content = tpl.render(views.admin.content_types.ContentTypes, .{.{}});
    ctx.html(registry.renderPage(page, ctx, content));
}
