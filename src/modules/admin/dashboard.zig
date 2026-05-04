//! Dashboard plugin - main admin overview page

const std = @import("std");
const admin = @import("admin_api");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const views = @import("views");
const registry = @import("registry");
const auth_middleware = @import("auth_middleware");
const csrf = @import("csrf");
const gravatar = @import("gravatar");
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

pub const page_v2 = admin.registerPage(.{
    .id = "dashboard-v2",
    .title = "Dashboard v2",
    .path = "/dashboard-v2",
    .icon = .home,
    .position = 11,
    .setup = setupV2,
});

fn setupV2(app: *admin.PageApp) void {
    app.render(handleDashboardV2);
}

fn handleDashboardV2(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else null;

    const media_count_num: u32 = if (db) |d| media.countMedia(d, .{}) catch 0 else 0;
    const media_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{media_count_num}) catch "0";

    const Post = struct { id: []const u8, title: []const u8, status: []const u8, date: []const u8 };
    const posts: []const Post = &.{};

    // dashboard_v2 is a self-contained page (its own <html>/<head>/<body>),
    // so we render it directly without registry.renderPage — no admin shell.
    const csrf_token = csrf.ensureToken(ctx);
    const user_email = auth_middleware.getUserEmail(ctx) orelse "";
    const gravatar_url = gravatar.url(user_email, 32);

    const content = tpl.render(views.admin.dashboard_v2.DashboardV2, .{.{
        .posts_count = "0",
        .pages_count = "0",
        .media_count = media_count_str,
        .users_count = "0",
        .has_posts = false,
        .recent_posts = posts,
        .user_gravatar_url = gravatar_url.slice(),
        .csrf_token = csrf_token,
    }});

    ctx.html(content);
}
