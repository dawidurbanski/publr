//! Settings plugin - site configuration

const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const registry = @import("registry");

pub const page = admin.registerPage(.{
    .id = "settings",
    .title = "Settings",
    .path = "/settings",
    .icon = icons.settings,
    .position = 40,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleSettings);
}

fn handleSettings(ctx: *Context) !void {
    const content =
        \\<div class="empty-state">
        \\    <p>Settings feature coming soon.</p>
        \\</div>
    ;
    ctx.html(registry.renderPage(page, ctx, content, ""));
}
