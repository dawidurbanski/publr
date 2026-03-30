const std = @import("std");
const fs = std.fs;
const Context = @import("router").Context;
const Router = @import("router").Router;
const error_pages = @import("../error.zig");
const theme_routes = @import("theme_routes");
const auth_middleware = @import("auth_middleware");
const template_context = @import("template_context");
const TemplateContext = template_context.TemplateContext;
const ssg = @import("../ssg.zig");

var is_dev_mode: bool = false;

pub fn setDevMode(dev_mode: bool) void {
    is_dev_mode = dev_mode;
}

/// Register all theme routes on the router.
pub fn registerRoutes(router: *Router) !void {
    inline for (theme_routes.route_table) |route| {
        try router.get(route.pattern, makeThemeHandler(route.page));
    }
}

fn buildTemplateContext(ctx: *Context) ?TemplateContext {
    const db = if (auth_middleware.auth) |a| a.db else return null;
    return .{
        .allocator = ctx.allocator,
        .db = db,
        .router_ctx = ctx,
    };
}

/// Production: serve pre-generated HTML. Dev/fallback: render on-the-fly.
fn makeThemeHandler(comptime Page: type) *const fn (*Context) anyerror!void {
    return struct {
        fn handle(ctx: *Context) !void {
            // Production: try serving pre-generated file
            if (!is_dev_mode) {
                const output_dir = ssg.getOutputDir();
                if (tryServeStatic(ctx, output_dir)) return;
            }

            // Dev mode or no pre-generated file: render on-the-fly
            const tpl_ctx = buildTemplateContext(ctx) orelse return error_pages.notFoundHandler(ctx);

            var buf: std.ArrayListUnmanaged(u8) = .{};
            const writer = buf.writer(ctx.allocator);

            Page.render(writer, &tpl_ctx) catch |err| {
                if (err == error.EntryNotFound) return error_pages.notFoundHandler(ctx);
                return err;
            };

            ctx.html(buf.items);
        }
    }.handle;
}

/// Try to serve a pre-generated HTML file using the actual request path.
fn tryServeStatic(ctx: *Context, output_dir: []const u8) bool {
    var path_buf: [1024]u8 = undefined;
    const file_path = if (ctx.path.len <= 1)
        std.fmt.bufPrint(&path_buf, "{s}/index.html", .{output_dir}) catch return false
    else
        std.fmt.bufPrint(&path_buf, "{s}{s}/index.html", .{ output_dir, ctx.path }) catch return false;

    const content = fs.cwd().readFileAlloc(std.heap.page_allocator, file_path, 10 * 1024 * 1024) catch return false;
    ctx.html(content);
    return true;
}

/// Set the theme's 404 page as the not-found handler (if one exists).
pub fn setNotFoundHandler(router: *Router) bool {
    if (theme_routes.error_404) |Page404| {
        router.setNotFound(make404Handler(Page404));
        return true;
    }
    return false;
}

fn make404Handler(comptime Page: type) *const fn (*Context) anyerror!void {
    return struct {
        fn handle(ctx: *Context) !void {
            const tpl_ctx = buildTemplateContext(ctx) orelse return error_pages.notFoundHandler(ctx);

            var buf: std.ArrayListUnmanaged(u8) = .{};
            const writer = buf.writer(ctx.allocator);

            Page.render(writer, &tpl_ctx) catch {
                return error_pages.notFoundHandler(ctx);
            };

            ctx.response.setStatus("404 Not Found");
            ctx.html(buf.items);
        }
    }.handle;
}
