const std = @import("std");
const mw = @import("middleware.zig");
const Context = mw.Context;
const NextFn = mw.NextFn;

/// Request logging middleware for development
/// Logs: [METHOD] /path (status) in Xms
pub fn requestLogger(ctx: *Context, next: NextFn) anyerror!void {
    const start = std.time.milliTimestamp();

    try next(ctx);

    // Skip logging dev ping requests (live reload)
    if (std.mem.startsWith(u8, ctx.path, "/__dev/")) return;

    const elapsed = std.time.milliTimestamp() - start;
    std.debug.print("[{s}] {s} ({s}) {d}ms\n", .{
        @tagName(ctx.method),
        ctx.path,
        ctx.response.status,
        elapsed,
    });
}

test "logger middleware calls next" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const TestState = struct {
        var handler_called: bool = false;
        fn reset() void {
            handler_called = false;
        }
    };
    TestState.reset();

    const handler = struct {
        fn call(_: *Context) !void {
            TestState.handler_called = true;
        }
    }.call;

    try mw.executeChain(&ctx, &[_]mw.Middleware{requestLogger}, &[_]mw.Middleware{}, handler);

    try std.testing.expect(TestState.handler_called);
}
