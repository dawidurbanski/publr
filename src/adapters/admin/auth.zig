const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../app/registry.zig");
const auth = @import("../../lib/auth.zig");
const site_operations = @import("../../operations/site.zig");
const sign_in_operations = @import("../../operations/sign_in.zig");
const identity_module = @import("../rest/identity.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const Page = admin.Page;
const Form = admin.Form;

pub fn home(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);

    if (!try initialised(&session)) {
        return response.redirect(.see_other, "/admin/setup");
    }

    if (!session.signed_in()) {
        return response.redirect(.see_other, "/admin/login");
    }

    try response.redirect(.see_other, "/admin/content");
}

fn initialised(session: *Session) Error!bool {
    std.debug.assert(session.ctx.now_ms > 0);
    std.debug.assert(site_operations.setup_key.len > 0);

    const status = registry.SDK.dispatch(&session.ctx, site_operations.Status, .{}) catch {
        return error.OutOfMemory;
    };

    return status.initialised;
}

pub fn setup_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);

    if (try initialised(&session)) {
        return response.redirect(.see_other, "/admin/login");
    }

    try render_setup(response, ctx.arena, null);
}

fn render_setup(response: *Response, arena: std.mem.Allocator, problem: ?[]const u8) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(problem == null or problem.?.len > 0);

    var page = try Page.begin(arena, "Set up Publr", null);

    try page.raw("<p>Create the first administrator.</p>\n");

    if (problem) |text| {
        try page.raw("<p><strong>");
        try page.text(text);
        try page.raw("</strong></p>\n");
    }

    try page.raw("<form method=\"post\" action=\"/admin/setup\">\n" ++
        "<p><label>Email <input name=\"email\" type=\"email\" required></label></p>\n" ++
        "<p><label>Name <input name=\"display_name\" required></label></p>\n" ++
        "<p><label>Password <input name=\"password\" type=\"password\" required " ++
        "minlength=\"12\"></label></p>\n" ++
        "<p><button>Create administrator</button></p>\n</form>\n");
    try page.send(response, .ok);
}

pub fn setup(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const arena = ctx.arena;
    const form = Form.parse(arena, request.body) orelse {
        return render_setup(response, arena, "bad form");
    };

    if (!session.guard(&form)) {
        return render_setup(response, arena, "cross-origin request refused");
    }

    const email = form.text("email") orelse {
        return render_setup(response, arena, "email is required");
    };
    const name = form.text("display_name") orelse {
        return render_setup(response, arena, "name is required");
    };
    const password = form.get("password") orelse {
        return render_setup(response, arena, "password is required");
    };

    _ = registry.SDK.dispatch(&session.ctx, site_operations.Init, .{
        .email = email,
        .display_name = name,
        .password = password,
    }) catch |err| return render_setup(response, arena, @errorName(err));

    try start_session(&session, email, password, "/admin/setup");
}

pub fn login_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    const session = Session.open(request, response, ctx);

    if (session.signed_in()) {
        return response.redirect(.see_other, "/admin/content");
    }

    try render_login(response, ctx.arena, null);
}

fn render_login(response: *Response, arena: std.mem.Allocator, problem: ?[]const u8) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(problem == null or problem.?.len > 0);

    var page = try Page.begin(arena, "Log in", null);

    if (problem) |text| {
        try page.raw("<p><strong>");
        try page.text(text);
        try page.raw("</strong></p>\n");
    }

    try page.raw("<form method=\"post\" action=\"/admin/login\">\n" ++
        "<p><label>Email <input name=\"email\" type=\"email\" required></label></p>\n" ++
        "<p><label>Password <input name=\"password\" type=\"password\" required></label></p>\n" ++
        "<p><button>Log in</button></p>\n</form>\n");
    try page.send(response, .ok);
}

pub fn login(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const arena = ctx.arena;
    const form = Form.parse(arena, request.body) orelse {
        return render_login(response, arena, "bad form");
    };

    if (!session.guard(&form)) {
        return render_login(response, arena, "cross-origin request refused");
    }

    const email = form.text("email") orelse {
        return render_login(response, arena, "email is required");
    };
    const password = form.get("password") orelse {
        return render_login(response, arena, "password is required");
    };

    try start_session(&session, email, password, "/admin/login");
}

/// Sign in as the anonymous caller, set the cookie and go to the admin.
fn start_session(
    session: *Session,
    email: []const u8,
    password: []const u8,
    back: []const u8,
) Error!void {
    std.debug.assert(email.len > 0);
    std.debug.assert(back.len > 0);

    var anonymous = identity_module.context(session.site, session.arena, .anonymous);
    const out = registry.SDK.dispatch(&anonymous, sign_in_operations.SignIn, .{
        .email = email,
        .password = password,
    }) catch |err| {
        const problem: []const u8 = if (err == error.BadCredentials)
            "wrong email or password"
        else
            @errorName(err);

        return if (std.mem.eql(u8, back, "/admin/login"))
            render_login(session.response, session.arena, problem)
        else
            render_setup(session.response, session.arena, problem);
    };

    try identity_module.set_session_cookie(
        session.request,
        session.response,
        session.arena,
        out.token,
        out.expires_at,
        anonymous.now_ms,
    );
    try session.response.redirect(.see_other, "/admin/content");
}

pub fn logout(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const form = Form.parse(ctx.arena, request.body) orelse Form{};

    if (!session.guard(&form)) {
        return admin.fail(&session, error.RefusedCrossSite, "/admin");
    }

    if (session.identity.token) |token| {
        const sign_out = sign_in_operations.SignOut;

        _ = registry.SDK.dispatch(&session.ctx, sign_out, .{ .token = token }) catch |err| {
            return admin.fail(&session, err, "/admin");
        };
    }

    try identity_module.clear_session_cookie(request, response, ctx.arena);
    try response.redirect(.see_other, "/admin/login");
}
