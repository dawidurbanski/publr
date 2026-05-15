const std = @import("std");
const admin_api = @import("admin_api");
const Router = @import("router").Router;
const modules = @import("modules");
const plugin_registry = @import("plugin_registry");

/// All registered admin pages, aggregated from auto-discovered plugins.
/// Each plugin may export `pub const page` (single) or `pub const pages` (array).
const all_pages = blk: {
    var result: []const admin_api.Page = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "page")) {
            result = result ++ &[_]admin_api.Page{p.mod.page};
        }
        if (@hasDecl(p.mod, "pages")) {
            result = result ++ p.mod.pages;
        }
    }
    break :blk result;
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
        const base_path = admin_api.resolvePagePath(page, all_pages);
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
