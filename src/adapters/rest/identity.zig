//! Who is making an HTTP request, and how the answer travels: the session cookie, the
//! CSRF guard for writes, and the `Ctx` a handler dispatches with.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const session_module = @import("../../store/sessions.zig");
const user_module = @import("../../store/users.zig");
const csrf = @import("../../lib/auth.zig").csrf;
const http = @import("../../lib/http.zig");
const Site = @import("../../app/site.zig").Site;

const Error = http.Error;
const Caller = sdk.Caller;

pub const cookie_name = "publr_session";
pub const csrf_header = "x-csrf-token";

pub const Identity = struct {
    caller: Caller = .anonymous,
    session: ?session_module.Session = null,
    token: ?[]const u8 = null,

    pub fn csrf_token(
        identity: *const Identity,
        site: *const Site,
        out: *[csrf.token_len]u8,
    ) ?[]const u8 {
        std.debug.assert(out.len == csrf.token_len);

        const session = identity.session orelse return null;
        std.debug.assert(session.id.len == session_module.id_len);

        return csrf.token(site.auth.secret, session.id, out);
    }
};

pub fn identify(
    request: *const http.Request,
    arena: std.mem.Allocator,
    site: *const Site,
) Identity {
    std.debug.assert(site.connection.transaction_depth == 0);

    const cookie_header = request.header("cookie") orelse return .{};
    const token = cookie_value(cookie_header, cookie_name) orelse return .{};
    const now_ms = sdk.context.wall_clock_ms(site.io);

    std.debug.assert(now_ms > 0);

    const connection = site.connection;
    const session = session_module.validate(connection, arena, token, now_ms) catch return .{};
    const found = user_module.find_by_id(connection, arena, session.user_id) catch return .{};
    const credentials = found orelse return .{};

    return .{
        .caller = .{ .user = .{ .id = credentials.user.id, .role = credentials.user.role } },
        .session = session,
        .token = token,
    };
}

pub fn cookie_value(header: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(header.len <= 64 << 10);

    var pairs = std.mem.splitScalar(u8, header, ';');

    while (pairs.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;

        if (std.mem.eql(u8, trimmed[0..equals], name)) {
            return trimmed[equals + 1 ..];
        }
    }

    return null;
}

pub fn origin_of(request: *const http.Request) csrf.Origin {
    std.debug.assert(request.path().len > 0);
    std.debug.assert(csrf.header_len_max > 0);

    const host = request.header("host");
    const origin = request.header("origin");

    return csrf.origin_of(host, origin, request.header("referer"));
}

pub fn guard(
    request: *const http.Request,
    response: *http.Response,
    site: *const Site,
    identity: *const Identity,
) Error!bool {
    std.debug.assert(request.method() != .get and request.method() != .head);
    std.debug.assert(site.connection.transaction_depth == 0);

    const origin = origin_of(request);

    if (origin == .foreign) {
        try response.json(.forbidden, .{ .@"error" = "cross_origin" });

        return false;
    }

    const session = identity.session orelse return true;

    if (origin == .absent) {
        try response.json(.forbidden, .{ .@"error" = "origin_required" });

        return false;
    }

    const provided = request.header(csrf_header) orelse "";

    if (!csrf.verify(site.auth.secret, session.id, provided)) {
        try response.json(.forbidden, .{ .@"error" = "csrf_token_invalid" });

        return false;
    }

    return true;
}

pub fn set_session_cookie(
    request: *const http.Request,
    response: *http.Response,
    arena: std.mem.Allocator,
    token: []const u8,
    expires_at: i64,
    now_ms: i64,
) Error!void {
    std.debug.assert(token.len == session_module.token_len);
    std.debug.assert(expires_at > now_ms);

    const max_age = @divTrunc(expires_at - now_ms, std.time.ms_per_s);
    const template = "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}{s}";
    const value = std.fmt.allocPrint(arena, template, .{
        cookie_name,
        token,
        max_age,
        secure_suffix(request),
    }) catch return error.OutOfMemory;

    try response.set_header("Set-Cookie", value);
}

pub fn clear_session_cookie(
    request: *const http.Request,
    response: *http.Response,
    arena: std.mem.Allocator,
) Error!void {
    std.debug.assert(cookie_name.len > 0);
    std.debug.assert(request.path().len > 0);

    const template = "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0{s}";
    const value = std.fmt.allocPrint(arena, template, .{
        cookie_name,
        secure_suffix(request),
    }) catch return error.OutOfMemory;

    try response.set_header("Set-Cookie", value);
}

fn secure_suffix(request: *const http.Request) []const u8 {
    const proto = request.header("x-forwarded-proto") orelse "";
    const secure = std.ascii.eqlIgnoreCase(proto, "https");

    std.debug.assert(proto.len <= 8 << 10);
    std.debug.assert(!secure or proto.len == 5);

    return if (secure) "; Secure" else "";
}

pub fn context(site: *const Site, arena: std.mem.Allocator, caller: Caller) sdk.Ctx {
    std.debug.assert(site.connection.transaction_depth == 0);
    std.debug.assert(site.auth.secret.len == csrf.secret_len);

    return sdk.Ctx.init(.{
        .caller = caller,
        .db = site.connection,
        .io = site.io,
        .arena = arena,
        .auth = site.auth,
        .now_ms = sdk.context.wall_clock_ms(site.io),
    });
}

test "cookie parsing" {
    const mixed = cookie_value("a=1; publr_session=abc; b=2", cookie_name).?;
    try std.testing.expectEqualStrings("abc", mixed);
    try std.testing.expectEqualStrings("abc", cookie_value("publr_session=abc", cookie_name).?);
    try std.testing.expect(cookie_value("a=1; b=2", cookie_name) == null);
    try std.testing.expect(cookie_value("", cookie_name) == null);
}
