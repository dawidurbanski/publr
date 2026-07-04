const std = @import("std");
const mw = @import("middleware");
const tpl = @import("tpl");
const Context = mw.Context;
const NextFn = mw.NextFn;

// Generated ZSX views
const views = @import("views");

/// Module-level dev mode flag (set during init)
var dev_mode: bool = false;

/// Initialize error handling module
pub fn init(is_dev_mode: bool) void {
    dev_mode = is_dev_mode;
}

/// Wrap content in base layout (error pages have no CSS/JS)
fn wrapWithBase(content: []const u8) []const u8 {
    return tpl.render(views.base.Base, .{.{
        .title = "Error - Publr",
        .content = content,
        .css = &[_][]const u8{},
        .js = &[_][]const u8{},
    }});
}

/// Error middleware - catches unhandled errors and renders error pages
pub fn errorMiddleware(ctx: *Context, next: NextFn) anyerror!void {
    next(ctx) catch |err| {
        const trace = @errorReturnTrace();

        // Log error server-side (always, regardless of mode)
        std.debug.print("Error: {}\n", .{err});
        if (trace) |t| {
            std.debug.dumpStackTrace(t.*);
        }

        ctx.response.setStatus("500 Internal Server Error");
        if (dev_mode) {
            ctx.html(render500Dev(err, trace));
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
        ctx.html(wrapWithBase(content));
    }
}

/// Render 404 page content using ZSX template
fn render404() []const u8 {
    return tpl.render(views.@"error".error_404.Error404, .{.{
        .status_code = "404",
        .title = "Page Not Found",
        .message = "The page you're looking for doesn't exist or has been moved.",
    }});
}

/// Render 500 page for production (no error details)
fn render500Prod() []const u8 {
    return wrapWithBase(tpl.renderStatic(views.@"error".error_500.Error500));
}

/// Render 500 page for dev mode (with error details and stack trace)
const Frame = struct { symbol: ?[]const u8, location: ?[]const u8, raw: ?[]const u8 };

fn render500Dev(err: anyerror, trace: ?*std.builtin.StackTrace) []const u8 {
    const error_name = @errorName(err);

    // Arena for symbol lookup + frame strings. Must outlive tpl.render below
    // (frames hold pointers into it), so it lives at function scope.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build the stack-trace frames as data; the ZSX component renders the HTML.
    var frames: std.ArrayListUnmanaged(Frame) = .{};
    const has_trace = trace != null;

    if (trace) |t| {
        const debug_info = std.debug.getSelfDebugInfo() catch null;
        const addrs = t.instruction_addresses[0..@min(t.index, t.instruction_addresses.len)];

        for (addrs) |addr| {
            var handled = false;
            if (debug_info) |di| {
                if (di.getModuleForAddress(addr)) |module| {
                    if (module.getSymbolAtAddress(alloc, addr)) |symbol| {
                        const location: ?[]const u8 = if (symbol.source_location) |loc|
                            (std.fmt.allocPrint(alloc, "{s}:{d}", .{ loc.file_name, loc.line }) catch null)
                        else
                            null;
                        frames.append(alloc, .{ .symbol = symbol.name, .location = location, .raw = null }) catch {};
                        handled = true;
                    } else |_| {}
                } else |_| {}
            }
            if (!handled) {
                const raw = std.fmt.allocPrint(alloc, "0x{x:0>16}", .{addr}) catch continue;
                frames.append(alloc, .{ .symbol = null, .location = null, .raw = raw }) catch {};
            }
        }
    }

    const content = tpl.render(views.@"error".error_500_dev.Error500Dev, .{.{
        .error_name = error_name,
        .has_trace = has_trace,
        .frames = frames.items,
    }});

    return wrapWithBase(content);
}

// Tests
test "render404 returns valid HTML" {
    const html = render404();
    try std.testing.expect(std.mem.indexOf(u8, html, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Page Not Found") != null);
}

test "render500Prod returns valid HTML without error details" {
    const html = render500Prod();
    try std.testing.expect(std.mem.indexOf(u8, html, "500") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Something Went Wrong") != null);
}

test "render500Dev returns HTML with error name" {
    const html = render500Dev(error.OutOfMemory, null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Internal Server Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "OutOfMemory") != null);
}

test "init sets dev_mode" {
    init(true);
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

    try std.testing.expect(std.mem.indexOf(u8, ctx.response.body, "SomeSpecificError") != null);
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
