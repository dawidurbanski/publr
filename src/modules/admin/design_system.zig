//! Design System plugin - design tokens and documentation

const admin = @import("admin_api");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const views = @import("views");
const registry = @import("registry");

pub const page = admin.registerPage(.{
    .id = "design_system",
    .title = "Design System",
    .path = "/design-system",
    .icon = .file,
    .position = 60,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleDesignSystem);
}

fn handleDesignSystem(ctx: *Context) !void {
    const content = tpl.renderStatic(views.admin.design_system.DesignSystem);
    ctx.html(registry.renderPage(page, ctx, content));
}
