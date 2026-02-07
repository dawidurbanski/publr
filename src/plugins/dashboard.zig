//! Dashboard plugin - main admin overview page

const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const zsx_admin_dashboard = @import("zsx_admin_dashboard");
const registry = @import("registry");

pub const page = admin.registerPage(.{
    .id = "dashboard",
    .title = "Dashboard",
    .path = "/",
    .icon = icons.home,
    .position = 10,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleDashboard);
}

fn handleDashboard(ctx: *Context) !void {
    // Mock stats for now
    const Post = struct { id: []const u8, title: []const u8, status: []const u8, date: []const u8 };
    const posts: []const Post = &.{};

    const content = tpl.render(zsx_admin_dashboard.Dashboard, .{.{
        .posts_count = "0",
        .pages_count = "0",
        .media_count = "0",
        .users_count = "0",
        .has_posts = false,
        .recent_posts = posts,
    }});

    ctx.html(registry.renderPage(page, ctx, content));
}
