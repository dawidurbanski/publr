//! Dashboard plugin - main admin overview page

const std = @import("std");
const admin = @import("admin_api");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const views = @import("views");
const registry = @import("registry");
const auth_middleware = @import("auth_middleware");
const media = @import("media");

pub const page = admin.registerPage(.{
    .id = "dashboard",
    .title = "Dashboard",
    .path = "/",
    .icon = .home,
    .position = 10,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleDashboard);
}

fn handleDashboard(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else null;

    // Get real media count from database
    const media_count_num: u32 = if (db) |d| media.countMedia(d, .{}) catch 0 else 0;
    const media_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{media_count_num}) catch "0";

    // Mock stats for now (other counts still hardcoded)
    const Post = struct { id: []const u8, title: []const u8, status: []const u8, date: []const u8 };
    const posts: []const Post = &.{};

    const content = tpl.render(views.admin.dashboard.Dashboard, .{.{
        .posts_count = "0",
        .pages_count = "0",
        .media_count = media_count_str,
        .users_count = "0",
        .has_posts = false,
        .recent_posts = posts,
    }});

    ctx.html(registry.renderPage(page, ctx, content));
}
