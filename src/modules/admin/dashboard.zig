//! Dashboard plugin - main admin overview page

const admin = @import("admin_api");
const views = @import("views");

pub const page = admin.registerPage(.{
    .id = "dashboard",
    .title = "Dashboard",
    .path = "/",
    .icon = .home,
    .position = 10,
    .view = views.admin.dashboard.Dashboard,
    .loader = load,
});

fn load(_: *admin.Context) !views.admin.dashboard.Props {
    return .{
        .posts_count = "127",
        .posts_delta = "+8 this week",
        .drafts_count = "12",
        .drafts_delta = "+2",
        .views_count = "12,438",
        .views_delta = "↑ 8.2%",
        .subscribers_count = "1,204",
        .subscribers_delta = "↑ 1.4%",
        .has_posts = true,
        .recent_posts = &.{
            .{ .id = "/admin/content/post", .title = "Why Zig is the right call", .status = "published", .date = "2h ago" },
            .{ .id = "/admin/content/post", .title = "Single binary deploys", .status = "draft", .date = "Yesterday" },
            .{ .id = "/admin/content/post", .title = "The case against npm", .status = "published", .date = "3d ago" },
            .{ .id = "/admin/content/post", .title = "OKLCH for design tokens", .status = "published", .date = "5d ago" },
        },
        .activities = &.{
            .{ .who = "Dawid", .what = "published", .obj = "Single binary deploys", .time = "2h ago" },
            .{ .who = "Dawid", .what = "edited", .obj = "Why Zig is the right call", .time = "4h ago" },
            .{ .who = "system", .what = "synced", .obj = "12 posts to CDN", .time = "6h ago", .is_system = true },
            .{ .who = "Dawid", .what = "uploaded", .obj = "hero.png", .time = "1d ago" },
        },
    };
}
