const std = @import("std");
const admin_api = @import("admin_api");
const Router = @import("router").Router;
const modules = @import("modules");

const plugin_dashboard = @import("plugin_dashboard");
const plugin_content = @import("plugin_content");
const plugin_media = @import("plugin_media");
const plugin_users = @import("plugin_users");
const plugin_settings = @import("plugin_settings");
const plugin_components = @import("plugin_components");
const plugin_design_system = @import("plugin_design_system");
const plugin_releases = @import("plugin_releases");

/// All registered admin pages.
const all_pages = [_]admin_api.Page{
    plugin_dashboard.page,
} ++ plugin_content.content_pages ++ [_]admin_api.Page{
    plugin_releases.page,
    plugin_media.page,
    plugin_users.page_profile,
    plugin_users.page,
    plugin_settings.page,
    plugin_components.page,
    plugin_design_system.page,
};

pub const module: modules.Module = .{
    .name = "admin",
    .setup = setup,
};

fn setup(ctx: *modules.ModuleContext) void {
    registerPluginRoutes(ctx.router, ctx.allocator);
}

fn registerPluginRoutes(router: *Router, allocator: std.mem.Allocator) void {
    const registrar = admin_api.RouteRegistrar{
        .ctx = router,
        .register_get = routerRegisterGet,
        .register_post = routerRegisterPost,
    };

    inline for (all_pages) |page| {
        const base_path = admin_api.resolvePagePath(page, &all_pages);
        var app = admin_api.PageApp{
            .base_path = base_path,
            .page = page,
            .registrar = registrar,
            .allocator = allocator,
        };
        page.setup(&app);
    }
}

fn routerRegisterGet(ctx: *anyopaque, path: []const u8, handler: admin_api.Handler) void {
    const router: *Router = @ptrCast(@alignCast(ctx));
    router.get(path, handler) catch {};
}

fn routerRegisterPost(ctx: *anyopaque, path: []const u8, handler: admin_api.Handler) void {
    const router: *Router = @ptrCast(@alignCast(ctx));
    router.post(path, handler) catch {};
}
