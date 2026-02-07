//! Design System plugin - design tokens and documentation

const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const zsx_admin_design_system = @import("zsx_admin_design_system");
const registry = @import("registry");

pub const page = admin.registerPage(.{
    .id = "design_system",
    .title = "Design System",
    .path = "/design-system",
    .icon = icons.file,
    .position = 60,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleDesignSystem);
}

fn handleDesignSystem(ctx: *Context) !void {
    const content = tpl.renderStatic(zsx_admin_design_system.DesignSystem);
    ctx.html(registry.renderPage(page, ctx, content));
}
