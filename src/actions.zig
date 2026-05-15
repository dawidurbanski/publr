//! Action dispatcher — central POST /admin/action route.
//!
//! Plugins register named handlers via `app.action("plugin.verb", handler)`
//! and forms POST to `/admin/action` with a hidden `action=plugin.verb` field.
//! The dispatcher looks up the handler, runs it, then defaults to a 303
//! redirect (to `redirect_to` form field, Referer, or `/admin`) when the
//! handler didn't already set a 3xx response or render a body.
//!
//! CSRF is enforced by the global `csrfMiddleware` for POST routes — it
//! short-circuits before the dispatcher is reached, so action handlers never
//! need to re-check.

const std = @import("std");
const mw = @import("middleware");
const csrf = @import("csrf");

pub const ActionHandler = mw.Handler;

var registry: std.StringHashMapUnmanaged(ActionHandler) = .{};
var registry_allocator: ?std.mem.Allocator = null;
var not_found_handler: ?mw.Handler = null;

pub const InitOptions = struct {
    not_found: mw.Handler,
};

/// Initialize the dispatcher. Must be called once at process start (native)
/// or once per `cms_init` (WASM) before plugin setup runs.
pub fn init(allocator: std.mem.Allocator, opts: InitOptions) void {
    if (registry_allocator) |alloc| {
        registry.deinit(alloc);
    }
    registry = .{};
    registry_allocator = allocator;
    not_found_handler = opts.not_found;
}

/// Register an action handler by flat name (convention: `<plugin>.<verb>`).
/// Re-registering the same name overwrites and logs a warning.
pub fn register(name: []const u8, handler: ActionHandler) void {
    const alloc = registry_allocator orelse @panic("actions.init must be called before actions.register");
    const gop = registry.getOrPut(alloc, name) catch @panic("OOM registering action");
    if (gop.found_existing) {
        std.log.warn("actions: re-registering '{s}' (last write wins)", .{name});
    }
    gop.value_ptr.* = handler;
}

/// Look up an action handler by name (mainly for tests).
pub fn get(name: []const u8) ?ActionHandler {
    return registry.get(name);
}

/// Dispatch a POST /admin/action request.
///
/// Reads `action` from the form body, looks up the handler, runs it. If the
/// handler didn't set a 3xx status or render a body, redirects to
/// `redirect_to` → Referer → `/admin`.
pub fn dispatch(ctx: *mw.Context) anyerror!void {
    const name = formField(ctx, "action") orelse return runNotFound(ctx);
    const handler = registry.get(name) orelse return runNotFound(ctx);

    try handler(ctx);

    if (isRedirect(ctx.response.status)) return;
    if (ctx.response.body.len > 0) return;

    const target = formField(ctx, "redirect_to") orelse
        ctx.getRequestHeader("Referer") orelse
        "/admin";
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", target);
    ctx.response.setBody("");
}

/// Read a form field from either a URL-encoded body or a multipart/form-data
/// body. Used by the dispatcher so file-upload forms (multipart) can still
/// carry the `action` selector and `redirect_to` hints alongside the file.
fn formField(ctx: *mw.Context, name: []const u8) ?[]const u8 {
    if (ctx.formValue(name)) |v| return v;
    return csrf.multipartFormValue(ctx, name);
}

fn runNotFound(ctx: *mw.Context) anyerror!void {
    if (not_found_handler) |handler| {
        return handler(ctx);
    }
    ctx.response.setStatus("404 Not Found");
    ctx.response.setBody("Not Found");
}

fn isRedirect(status: []const u8) bool {
    return status.len >= 3 and status[0] == '3';
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TestState = struct {
    var called_with: ?[]const u8 = null;
    var should_render: bool = false;
    var should_redirect: bool = false;

    fn reset() void {
        called_with = null;
        should_render = false;
        should_redirect = false;
    }
};

fn testHandler(ctx: *mw.Context) anyerror!void {
    TestState.called_with = ctx.formValue("payload");
    if (TestState.should_render) {
        ctx.html("<h1>Rendered</h1>");
    } else if (TestState.should_redirect) {
        ctx.response.setStatus("303 See Other");
        ctx.response.setHeader("Location", "/handler-chose");
        ctx.response.setBody("");
    }
}

fn testNotFound(ctx: *mw.Context) anyerror!void {
    ctx.response.setStatus("404 Not Found");
    ctx.response.setBody("test-404");
}

fn resetForTest() void {
    if (registry_allocator) |alloc| registry.deinit(alloc);
    registry = .{};
    registry_allocator = testing.allocator;
    not_found_handler = testNotFound;
    TestState.reset();
}

test "dispatch by name calls registered handler" {
    resetForTest();
    register("test.echo", testHandler);

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.setBody("action=test.echo&payload=hello");

    try dispatch(&ctx);

    try testing.expectEqualStrings("hello", TestState.called_with.?);
    // Default redirect fires when handler doesn't render/redirect.
    try testing.expectEqualStrings("303 See Other", ctx.response.status);
}

test "dispatch unknown action invokes not-found handler" {
    resetForTest();

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.setBody("action=nope.missing");

    try dispatch(&ctx);

    try testing.expect(TestState.called_with == null);
    try testing.expectEqualStrings("404 Not Found", ctx.response.status);
    try testing.expectEqualStrings("test-404", ctx.response.body);
}

test "dispatch missing action field invokes not-found handler" {
    resetForTest();

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.setBody("other_field=value");

    try dispatch(&ctx);

    try testing.expectEqualStrings("404 Not Found", ctx.response.status);
}

test "dispatch redirect_to form field takes precedence over Referer" {
    resetForTest();
    register("test.echo", testHandler);

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.addRequestHeader("Referer", "/admin/referer-page");
    ctx.setBody("action=test.echo&redirect_to=%2Fadmin%2Fchosen");

    try dispatch(&ctx);

    try testing.expectEqualStrings("303 See Other", ctx.response.status);
    var location: ?[]const u8 = null;
    for (ctx.response.getCustomHeaders()) |maybe_h| {
        if (maybe_h) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Location")) location = h.value;
        }
    }
    try testing.expectEqualStrings("/admin/chosen", location.?);
}

test "dispatch falls back to Referer when redirect_to absent" {
    resetForTest();
    register("test.echo", testHandler);

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.addRequestHeader("Referer", "/admin/back-here");
    ctx.setBody("action=test.echo");

    try dispatch(&ctx);

    var location: ?[]const u8 = null;
    for (ctx.response.getCustomHeaders()) |maybe_h| {
        if (maybe_h) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Location")) location = h.value;
        }
    }
    try testing.expectEqualStrings("/admin/back-here", location.?);
}

test "dispatch falls back to /admin when no redirect_to or Referer" {
    resetForTest();
    register("test.echo", testHandler);

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.setBody("action=test.echo");

    try dispatch(&ctx);

    var location: ?[]const u8 = null;
    for (ctx.response.getCustomHeaders()) |maybe_h| {
        if (maybe_h) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Location")) location = h.value;
        }
    }
    try testing.expectEqualStrings("/admin", location.?);
}

test "dispatch respects handler-set redirect" {
    resetForTest();
    register("test.echo", testHandler);
    TestState.should_redirect = true;

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.addRequestHeader("Referer", "/admin/back-here");
    ctx.setBody("action=test.echo&redirect_to=%2Fadmin%2Fchosen");

    try dispatch(&ctx);

    try testing.expectEqualStrings("303 See Other", ctx.response.status);
    var location: ?[]const u8 = null;
    for (ctx.response.getCustomHeaders()) |maybe_h| {
        if (maybe_h) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Location")) location = h.value;
        }
    }
    try testing.expectEqualStrings("/handler-chose", location.?);
}

test "dispatch leaves handler-rendered HTML untouched" {
    resetForTest();
    register("test.echo", testHandler);
    TestState.should_render = true;

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    ctx.addRequestHeader("Referer", "/admin/back-here");
    ctx.setBody("action=test.echo");

    try dispatch(&ctx);

    try testing.expectEqualStrings("200 OK", ctx.response.status);
    try testing.expectEqualStrings("<h1>Rendered</h1>", ctx.response.body);
}

test "dispatch protected by csrfMiddleware rejects requests without valid token" {
    resetForTest();
    register("test.echo", testHandler);

    var ctx = mw.Context.init(testing.allocator, .POST, "/admin/action");
    defer ctx.deinit();
    // No CSRF cookie, no _csrf field — request must be rejected before the
    // dispatcher runs. We simulate the global middleware chain inline.
    ctx.setBody("action=test.echo");

    try csrf.csrfMiddleware(&ctx, dispatch);

    try testing.expect(TestState.called_with == null);
    try testing.expectEqualStrings("403 Forbidden", ctx.response.status);
}
