//! Components plugin - UI component showcase

const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const zsx_admin_components = @import("zsx_admin_components");
const registry = @import("registry");

pub const page = admin.registerPage(.{
    .id = "components",
    .title = "Components",
    .path = "/components",
    .icon = icons.components,
    .position = 50,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleComponents);
}

fn handleComponents(ctx: *Context) !void {
    const content = tpl.renderStatic(zsx_admin_components.Components);
    ctx.html(registry.renderPage(page, ctx, content));
}
