const std = @import("std");
const mw = @import("middleware.zig");
const layout = @import("layout.zig");
const Context = mw.Context;
const NextFn = mw.NextFn;

/// Module-level dev mode flag (set during init)
var dev_mode: bool = false;

/// Initialize error handling module
pub fn init(is_dev_mode: bool) void {
    dev_mode = is_dev_mode;
}

/// Error layout options (minimal styling, no external deps)
const error_layout = layout.LayoutOptions{
    .title = "Error - Minizen",
    .css = &[_][]const u8{},
    .js = &[_][]const u8{},
};

/// Error middleware - catches unhandled errors and renders error pages
pub fn errorMiddleware(ctx: *Context, next: NextFn) anyerror!void {
    next(ctx) catch |err| {
        // Log error server-side
        std.debug.print("Error: {}\n", .{err});

        ctx.response.setStatus("500 Internal Server Error");
        if (dev_mode) {
            ctx.html(render500Dev(err));
        } else {
            ctx.html(render500Prod());
        }
    };
}

/// 404 handler - set as router fallback
pub fn notFoundHandler(ctx: *Context) !void {
    ctx.response.setStatus("404 Not Found");
    const content = render404();
    if (ctx.isPartial()) {
        ctx.html(content);
    } else {
        ctx.html(layout.wrapLayout(content, error_layout));
    }
}

/// Render 404 page content
fn render404() []const u8 {
    return 
    \\<div style="text-align: center; padding: 60px 20px; font-family: system-ui, -apple-system, sans-serif;">
    \\    <h1 style="font-size: 72px; margin: 0; color: #e74c3c;">404</h1>
    \\    <h2 style="margin: 20px 0; color: #2c3e50;">Page Not Found</h2>
    \\    <p style="color: #7f8c8d; margin-bottom: 30px;">The page you're looking for doesn't exist or has been moved.</p>
    \\    <div>
    \\        <a href="/" style="color: #3498db; text-decoration: none; margin-right: 20px;">← Home</a>
    \\        <a href="/admin" style="color: #3498db; text-decoration: none;">Admin →</a>
    \\    </div>
    \\</div>
    ;
}

/// Render 500 page for production (no error details)
fn render500Prod() []const u8 {
    const content =
        \\<div style="text-align: center; padding: 60px 20px; font-family: system-ui, -apple-system, sans-serif;">
        \\    <h1 style="font-size: 72px; margin: 0; color: #e74c3c;">500</h1>
        \\    <h2 style="margin: 20px 0; color: #2c3e50;">Something Went Wrong</h2>
        \\    <p style="color: #7f8c8d; margin-bottom: 30px;">We're sorry, but something went wrong on our end. Please try again later.</p>
        \\    <div>
        \\        <a href="/" style="color: #3498db; text-decoration: none;">← Back to Home</a>
        \\    </div>
        \\</div>
    ;
    return layout.wrapLayout(content, error_layout);
}

/// Render 500 page for dev mode (with error details)
fn render500Dev(err: anyerror) []const u8 {
    const S = struct {
        var buf: [8192]u8 = undefined;
    };

    const error_name = @errorName(err);

    const content_template =
        \\<div style="padding: 40px 20px; font-family: system-ui, -apple-system, sans-serif; max-width: 800px; margin: 0 auto;">
        \\    <div style="background: #fdf2f2; border: 1px solid #e74c3c; border-radius: 8px; padding: 20px; margin-bottom: 20px;">
        \\        <h1 style="font-size: 24px; margin: 0 0 10px 0; color: #c0392b;">⚠ Internal Server Error</h1>
        \\        <p style="margin: 0; color: #7f8c8d; font-size: 14px;">Development mode - this page shows error details</p>
        \\    </div>
        \\    <div style="background: #f8f9fa; border: 1px solid #dee2e6; border-radius: 8px; padding: 20px;">
        \\        <h2 style="font-size: 16px; margin: 0 0 10px 0; color: #495057;">Error</h2>
        \\        <pre style="background: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 4px; overflow-x: auto; margin: 0;">error.{s}</pre>
        \\    </div>
        \\    <div style="margin-top: 30px; text-align: center;">
        \\        <a href="/" style="color: #3498db; text-decoration: none;">← Back to Home</a>
        \\    </div>
        \\</div>
    ;

    const len = std.fmt.bufPrint(&S.buf, content_template, .{error_name}) catch {
        return render500Prod();
    };

    return layout.wrapLayout(len, error_layout);
}

// Tests
test "render404 returns valid HTML" {
    const html = render404();
    try std.testing.expect(std.mem.indexOf(u8, html, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Page Not Found") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/admin\"") != null);
}

test "render500Prod returns valid HTML without error details" {
    const html = render500Prod();
    try std.testing.expect(std.mem.indexOf(u8, html, "500") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Something Went Wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/\"") != null);
    // Should NOT contain error details
    try std.testing.expect(std.mem.indexOf(u8, html, "error.") == null);
}

test "render500Dev returns HTML with error name" {
    const html = render500Dev(error.OutOfMemory);
    try std.testing.expect(std.mem.indexOf(u8, html, "Internal Server Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "error.OutOfMemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Development mode") != null);
}

test "init sets dev_mode" {
    init(true);
    // Can't directly test the private var, but we can test the middleware behavior
    init(false);
}

test "notFoundHandler sets 404 status" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/nonexistent");
    defer ctx.deinit();

    try notFoundHandler(&ctx);

    try std.testing.expectEqualStrings("404 Not Found", ctx.response.status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "404") != null);
}

test "notFoundHandler returns partial for X-Partial request" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/nonexistent");
    defer ctx.deinit();

    ctx.addRequestHeader("X-Partial", "true");
    try notFoundHandler(&ctx);

    // Partial response should NOT have DOCTYPE (full layout wrapper)
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "<!DOCTYPE") == null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "404") != null);
}

test "notFoundHandler returns full page for regular request" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/nonexistent");
    defer ctx.deinit();

    try notFoundHandler(&ctx);

    // Full response should have DOCTYPE
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "<!DOCTYPE") != null);
}

test "errorMiddleware catches errors and sets 500 status" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    init(false); // Production mode

    const failing_handler = struct {
        fn call(_: *Context) anyerror!void {
            return error.TestError;
        }
    }.call;

    try errorMiddleware(&ctx, failing_handler);

    try std.testing.expectEqualStrings("500 Internal Server Error", ctx.response.status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "500") != null);
}

test "errorMiddleware shows error details in dev mode" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    init(true); // Dev mode

    const failing_handler = struct {
        fn call(_: *Context) anyerror!void {
            return error.SomeSpecificError;
        }
    }.call;

    try errorMiddleware(&ctx, failing_handler);

    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "error.SomeSpecificError") != null);
}

test "errorMiddleware passes through on success" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    const success_handler = struct {
        fn call(c: *Context) anyerror!void {
            c.html("<h1>Success</h1>");
        }
    }.call;

    try errorMiddleware(&ctx, success_handler);

    try std.testing.expectEqualStrings("200 OK", ctx.response.status);
    try std.testing.expectEqualStrings("<h1>Success</h1>", ctx.response.body);
}
