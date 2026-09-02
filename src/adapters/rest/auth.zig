//! The sign-in endpoints: `/api/auth/sign-in`, `sign-out`, `set-password`, `session`.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../app/registry.zig");
const sign_in_operations = @import("../../operations/sign_in.zig");
const user_operations = @import("../../operations/user.zig");
const csrf = @import("../../lib/auth.zig").csrf;
const identity_module = @import("identity.zig");
const http = @import("../../lib/http.zig");
const Site = @import("../../app/site.zig").Site;

const Error = http.Error;
const Request = http.Request;
const Response = http.Response;
const Context = http.Context;
const identify = identity_module.identify;
const guard = identity_module.guard;
const context = identity_module.context;
const set_session_cookie = identity_module.set_session_cookie;
const clear_session_cookie = identity_module.clear_session_cookie;

pub const body_bytes_max: u32 = 16 << 10;

pub fn sign_in(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const site = Site.of(ctx);
    const identity = identify(request, ctx.arena, site);

    if (!try guard(request, response, site, &identity)) {
        return;
    }

    const in = parse_body(sign_in_operations.SignIn.In, ctx.arena, request.body) orelse {
        return response.json(.bad_request, .{ .@"error" = "invalid_body" });
    };
    var sdk_ctx = context(site, ctx.arena, .anonymous);
    const out = registry.SDK.dispatch(&sdk_ctx, sign_in_operations.SignIn, in) catch |err| {
        return respond_error(response, err);
    };

    try set_session_cookie(request, response, ctx.arena, out.token, out.expires_at, sdk_ctx.now_ms);

    var csrf_buffer: [csrf.token_len]u8 = undefined;
    const session_id = out.token[0..sign_in_operations.session_id_len];

    try response.json(.ok, .{
        .user_id = out.user_id,
        .expires_at = out.expires_at,
        .csrf = csrf.token(site.auth.secret, session_id, &csrf_buffer),
    });
}

pub fn set_password(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const site = Site.of(ctx);
    const identity = identify(request, ctx.arena, site);

    if (!try guard(request, response, site, &identity)) {
        return;
    }

    const in = parse_body(user_operations.SetPassword.In, ctx.arena, request.body) orelse {
        return response.json(.bad_request, .{ .@"error" = "invalid_body" });
    };
    var sdk_ctx = context(site, ctx.arena, .anonymous);
    const out = registry.SDK.dispatch(&sdk_ctx, user_operations.SetPassword, in) catch |err| {
        return respond_error(response, err);
    };

    try response.json(.ok, .{ .user_id = out.user_id });
}

pub fn sign_out(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const site = Site.of(ctx);
    const identity = identify(request, ctx.arena, site);

    if (!try guard(request, response, site, &identity)) {
        return;
    }

    if (identity.token) |token| {
        var sdk_ctx = context(site, ctx.arena, identity.caller);
        const sign_out_operation = sign_in_operations.SignOut;
        _ = registry.SDK.dispatch(&sdk_ctx, sign_out_operation, .{ .token = token }) catch |err| {
            return respond_error(response, err);
        };
    }

    try clear_session_cookie(request, response, ctx.arena);
    try response.json(.ok, .{ .signed_out = identity.token != null });
}

pub fn whoami(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    const site = Site.of(ctx);
    const identity = identify(request, ctx.arena, site);
    var csrf_buffer: [csrf.token_len]u8 = undefined;

    try response.json(.ok, .{
        .authenticated = identity.session != null,
        .user_id = identity.caller.user_id(),
        .role = identity.caller.role(),
        .csrf = identity.csrf_token(site, &csrf_buffer),
    });
}

fn parse_body(comptime In: type, arena: std.mem.Allocator, body: []const u8) ?In {
    std.debug.assert(@typeInfo(In) == .@"struct");
    std.debug.assert(body_bytes_max > 0);

    if (body.len == 0 or body.len > body_bytes_max) {
        return null;
    }

    const options: std.json.ParseOptions = .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    };

    return std.json.parseFromSliceLeaky(In, arena, body, options) catch null;
}

pub fn respond_error(response: *Response, err: sdk.Error) Error!void {
    std.debug.assert(@errorName(err).len > 0);
    std.debug.assert(response.headers_len <= 32);

    const status: http.Status = switch (err) {
        error.BadCredentials => .unauthorized,
        error.Throttled => .too_many_requests,
        error.Denied => .forbidden,
        error.Invalid => .unprocessable_content,
        error.NotFound => .not_found,
        error.Conflict => .conflict,
        error.Vetoed => .forbidden,
        error.OutOfMemory,
        error.Busy,
        error.Constraint,
        error.ReadOnly,
        error.Sqlite,
        => .internal_server_error,
    };

    try response.json(status, .{ .@"error" = @errorName(err) });
}

const routes = @import("../../app/routes.zig");

test "auth over http: login sets the cookie, session reports the user, csrf guards logout" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: routes.testing.Flow = undefined;
    flow.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);

    const anonymous = try flow.call("GET /api/auth/session HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expect(std.mem.indexOf(u8, anonymous.body, "\"authenticated\":false") != null);

    const login_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const wrong_body = "{\"email\":\"admin@example.com\",\"password\":\"nope nope nope\"}";
    const wrong = try flow.call(login_head, wrong_body);
    try std.testing.expectEqual(@as(u16, 401), wrong.status.code());

    const foreign_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://evil\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const foreign = try flow.call(foreign_head, "{}");
    try std.testing.expectEqual(@as(u16, 403), foreign.status.code());

    const right_body = "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}";
    const right = try flow.call(login_head, right_body);
    try std.testing.expectEqual(@as(u16, 200), right.status.code());
    const cookie = right.header("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, cookie, "publr_session="));
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly; SameSite=Lax") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Secure") == null);

    const cookie_end = std.mem.indexOfScalar(u8, cookie, ';').?;
    const cookie_pair = cookie[0..cookie_end];
    const csrf_at = std.mem.indexOf(u8, right.body, "\"csrf\":\"").? + 8;
    const csrf_token = right.body[csrf_at .. csrf_at + csrf.token_len];

    const whoami_template = "GET /api/auth/session HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n";
    const whoami_head = try flow.head(whoami_template, .{cookie_pair});
    const me = try flow.call(whoami_head, "");
    try std.testing.expect(std.mem.indexOf(u8, me.body, "\"authenticated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, me.body, "\"role\":\"admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, me.body, csrf_token) != null);

    const health_template = "GET /api/health HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n";
    const health_head = try flow.head(health_template, .{cookie_pair});
    const health_body = (try flow.call(health_head, "")).body;
    try std.testing.expect(std.mem.indexOf(u8, health_body, "\"caller\":\"anonymous\"") == null);

    const logout_template = "POST /api/auth/sign-out HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Cookie: {s}\r\nX-Csrf-Token: {s}\r\nContent-Length: 0\r\n\r\n";
    const no_csrf_head = try flow.head(logout_template, .{ cookie_pair, "nope" });
    const no_csrf = try flow.call(no_csrf_head, "");
    try std.testing.expectEqual(@as(u16, 403), no_csrf.status.code());

    const logout_head = try flow.head(logout_template, .{ cookie_pair, csrf_token });
    const out = try flow.call(logout_head, "");
    try std.testing.expectEqual(@as(u16, 200), out.status.code());
    try std.testing.expect(std.mem.indexOf(u8, out.header("Set-Cookie").?, "Max-Age=0") != null);

    const after = try flow.call(whoami_head, "");
    try std.testing.expect(std.mem.indexOf(u8, after.body, "\"authenticated\":false") != null);

    system.now_ms = sdk.context.wall_clock_ms(std.testing.io);
    const invited = try registry.SDK.dispatch(&system, user_operations.Create, .{
        .email = "new@example.com",
        .display_name = "New",
        .password_link = true,
    });
    const token = invited.link.?.path[user_operations.set_password_path.len + 7 ..];
    const set_head = "POST /api/auth/set-password HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const set_template = "{{\"token\":\"{s}\",\"password\":\"correct horse battery\"}}";
    const set_body = try std.fmt.allocPrint(flow.arena, set_template, .{token});
    const set = try flow.call(set_head, set_body);
    try std.testing.expectEqual(@as(u16, 200), set.status.code());
    try std.testing.expectEqual(@as(u16, 404), (try flow.call(set_head, set_body)).status.code());

    const new_body = "{\"email\":\"new@example.com\",\"password\":\"correct horse battery\"}";
    const new_login = try flow.call(login_head, new_body);
    try std.testing.expectEqual(@as(u16, 200), new_login.status.code());
}
