const std = @import("std");
const sdk = @import("../sdk.zig");
const auth = @import("../lib/auth.zig");
const identity_module = @import("rest/identity.zig");
const http = @import("../lib/http.zig");
const Site = @import("../app/site.zig").Site;
const auth_pages = @import("admin/auth.zig");
const types_pages = @import("admin/types.zig");
const content_pages = @import("admin/content.zig");
const revision_pages = @import("admin/revisions.zig");

pub const Request = http.Request;
pub const Response = http.Response;
pub const Context = http.Context;
pub const Error = http.Error;
pub const Status = http.Status;
pub const Form = http.Form;

/// A POST that may change something: a signed-in session, a parseable form, from our own
/// page (same origin, valid CSRF token). `accept` answers null after responding otherwise.
pub const Post = struct { session: Session, form: Form };

pub fn accept(request: *Request, response: *Response, ctx: *Context, back: []const u8) Error!?Post {
    std.debug.assert(request.method() == .post);
    std.debug.assert(back.len > 0);

    const session = try require(request, response, ctx) orelse return null;
    const form = Form.parse(ctx.arena, request.body) orelse {
        try fail(&session, error.BadForm, back);

        return null;
    };

    if (!session.guard(&form)) {
        try fail(&session, error.RefusedCrossSite, back);

        return null;
    }

    return .{ .session = session, .form = form };
}

/// A route parameter that must be there; answers null after a not-found page otherwise.
pub fn param(session: *const Session, name: []const u8, back: []const u8) Error!?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(back.len > 0);

    return session.request.param(name) orelse {
        try fail(session, error.NotFound, back);

        return null;
    };
}

/// One query-string parameter, decoded; null when absent or empty.
pub fn query_param(session: *const Session, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(session.request.query().len <= 64 << 10);

    return Form.query_param(session.arena, session.request.query(), name);
}

pub const Page = @import("admin/page.zig").Page;

pub const form_pairs_max = Form.pairs_max;
pub const page_bytes_max: u32 = 4 << 20;
pub const routes_count: u32 = 21;

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < 256 - routes_count);

    const before = router.routes_len;

    router.get("/admin", &auth_pages.home);
    router.get("/admin/setup", &auth_pages.setup_page);
    router.post("/admin/setup", &auth_pages.setup);
    router.get("/admin/login", &auth_pages.login_page);
    router.post("/admin/login", &auth_pages.login);
    router.post("/admin/logout", &auth_pages.logout);
    router.get("/admin/types", &types_pages.list);
    router.get("/admin/types/new", &types_pages.new_page);
    router.post("/admin/types/create", &types_pages.create);
    router.get("/admin/types/:handle", &types_pages.edit_page);
    router.post("/admin/types/:handle/update", &types_pages.update);
    router.post("/admin/types/:handle/delete", &types_pages.delete);
    router.get("/admin/content", &content_pages.list);
    router.get("/admin/content/new", &content_pages.new_page);
    router.post("/admin/content/create", &content_pages.create);
    router.get("/admin/content/:id", &content_pages.edit);
    router.post("/admin/content/:id/save", &content_pages.save);
    router.post("/admin/content/:id/action", &content_pages.action);
    router.get("/admin/content/:id/revisions", &revision_pages.list);
    router.get("/admin/content/:id/revisions/:seq", &revision_pages.show);
    router.post("/admin/content/:id/restore", &revision_pages.restore);

    std.debug.assert(router.routes_len == before + routes_count);
}

/// One admin request: who is calling, where the answer goes, and a context to dispatch
/// operations with.
pub const Session = struct {
    request: *Request,
    response: *Response,
    arena: std.mem.Allocator,
    site: *Site,
    identity: identity_module.Identity,
    ctx: sdk.Ctx,
    csrf: [auth.csrf.token_len]u8 = undefined,

    pub fn open(request: *Request, response: *Response, ctx: *Context) Session {
        std.debug.assert(ctx.user_data != null);

        const site = Site.of(ctx);
        const identity = identity_module.identify(request, ctx.arena, site);
        var session: Session = .{
            .request = request,
            .response = response,
            .arena = ctx.arena,
            .site = site,
            .identity = identity,
            .ctx = identity_module.context(site, ctx.arena, identity.caller),
        };

        _ = identity.csrf_token(site, &session.csrf);

        std.debug.assert(session.ctx.now_ms > 0);

        return session;
    }

    pub fn signed_in(session: *const Session) bool {
        std.debug.assert(session.ctx.now_ms > 0);
        std.debug.assert(session.site.connection.transaction_depth == 0);

        return session.identity.session != null;
    }

    pub fn csrf_token(session: *const Session) []const u8 {
        std.debug.assert(session.signed_in());
        std.debug.assert(session.csrf.len == auth.csrf.token_len);

        return &session.csrf;
    }

    /// Same-origin and, when signed in, a valid `csrf` form field.
    pub fn guard(session: *const Session, form: *const Form) bool {
        std.debug.assert(session.request.method() == .post);
        std.debug.assert(form.len <= form_pairs_max);

        const origin = identity_module.origin_of(session.request);
        const identity_session = session.identity.session orelse return origin != .foreign;

        if (origin != .same) {
            return false;
        }

        const provided = form.get("csrf") orelse "";

        return auth.csrf.verify(session.site.auth.secret, identity_session.id, provided);
    }
};

/// Sign-in required: answers null after redirecting to the login page.
pub fn require(request: *Request, response: *Response, ctx: *Context) Error!?Session {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(response.headers_len == 0);

    const session = Session.open(request, response, ctx);

    if (!session.signed_in()) {
        try response.redirect(.see_other, "/admin/login");

        return null;
    }

    return session;
}

/// A one-line failure page with a way back.
pub fn fail(session: *const Session, err: anyerror, back: []const u8) Error!void {
    std.debug.assert(back.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    var page = try Page.begin(session.arena, "Something went wrong", null);

    try page.raw("<p>");
    try page.text(@errorName(err));
    try page.raw("</p><p><a href=\"");
    try page.text(back);
    try page.raw("\">Back</a></p>\n");
    try page.send(session.response, .ok);
}

const registry = @import("../app/registry.zig");
const routes = @import("../app/routes.zig");

const Flow = struct {
    inner: routes.testing.Flow,
    cookie: []const u8 = "",

    fn call(
        flow: *Flow,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) !http.Response {
        std.debug.assert(method.len > 0);
        std.debug.assert(path.len > 0);

        const head_text = try std.fmt.allocPrint(
            flow.inner.arena,
            "{s} {s} HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\nCookie: {s}\r\n" ++
                "Content-Length: 0\r\n\r\n",
            .{ method, path, flow.cookie },
        );
        const response = try flow.inner.call(head_text, body);

        if (response.header("Set-Cookie")) |cookie| {
            flow.cookie = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];
        }

        return response;
    }

    fn csrf_of(flow: *Flow, html: []const u8) []const u8 {
        std.debug.assert(html.len > 0);
        std.debug.assert(flow.cookie.len > 0);

        const marker = "name=\"csrf\" value=\"";
        const at = std.mem.indexOf(u8, html, marker).? + marker.len;

        return html[at .. at + auth.csrf.token_len];
    }
};

test "admin over http: setup, login, types and content through plain forms" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    const fresh = try flow.call("GET", "/admin", "");
    try std.testing.expectEqualStrings("/admin/setup", fresh.header("Location").?);

    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    const created = try flow.call("POST", "/admin/setup", setup_body);
    try std.testing.expectEqualStrings("/admin/content", created.header("Location").?);
    try std.testing.expect(std.mem.startsWith(u8, flow.cookie, "publr_session="));

    const types_page = try flow.call("GET", "/admin/types", "");
    try std.testing.expect(std.mem.indexOf(u8, types_page.body, "<h1>Content types</h1>") != null);
    const csrf_token = flow.csrf_of(types_page.body);

    const type_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&handle=post&name=Post&name_plural=Posts&public=1&title_field=title" ++
            "&field_0_name=title&field_0_label=Title&field_0_kind=string&field_0_required=1" ++
            "&field_1_name=body&field_1_kind=text",
        .{csrf_token},
    );
    const type_created = try flow.call("POST", "/admin/types/create", type_body);
    try std.testing.expectEqualStrings("/admin/types/post", type_created.header("Location").?);
    const type_editor = try flow.call("GET", "/admin/types/post", "");
    try std.testing.expect(std.mem.indexOf(u8, type_editor.body, "value=\"body\"") != null);
    const new_entry_page = try flow.call("GET", "/admin/content/new?type=post", "");
    try std.testing.expect(std.mem.indexOf(u8, new_entry_page.body, "name=\"title\"") != null);

    const no_csrf = try flow.call("POST", "/admin/content/create", "type=post&title=Nope");
    try std.testing.expect(std.mem.indexOf(u8, no_csrf.body, "RefusedCrossSite") != null);

    const arena = flow.inner.arena;
    const entry_body = try std.fmt.allocPrint(arena, "csrf={s}&type=post&title=Hello", .{
        csrf_token,
    });
    const entry_created = try flow.call("POST", "/admin/content/create", entry_body);
    const location = entry_created.header("Location").?;
    try std.testing.expect(std.mem.startsWith(u8, location, "/admin/content/"));

    const edit_page = try flow.call("GET", location, "");
    try std.testing.expect(std.mem.indexOf(u8, edit_page.body, "value=\"Hello\"") != null);
    const publish_button = "<button>Publish</button>";
    try std.testing.expect(std.mem.indexOf(u8, edit_page.body, publish_button) != null);

    const publish_path = try std.fmt.allocPrint(arena, "{s}/action", .{location});
    const publish_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&do=publish&expected_version=1",
        .{csrf_token},
    );
    _ = try flow.call("POST", publish_path, publish_body);
    const published = try flow.call("GET", location, "");
    const published_marker = "<strong>published</strong>";
    try std.testing.expect(std.mem.indexOf(u8, published.body, published_marker) != null);

    const save_path = try std.fmt.allocPrint(arena, "{s}/save", .{location});
    const parked_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&title=Hello+again&expected_version=2",
        .{csrf_token},
    );
    _ = try flow.call("POST", save_path, parked_body);
    const changed = try flow.call("GET", location, "");
    try std.testing.expect(std.mem.indexOf(u8, changed.body, "with unpublished changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed.body, "value=\"Hello again\"") != null);
    const revisions_path = try std.fmt.allocPrint(arena, "{s}/revisions", .{location});
    const versions = try flow.call("GET", revisions_path, "");
    try std.testing.expect(std.mem.indexOf(u8, versions.body, "<td>revision</td>") == null);
    _ = try flow.call("GET", location, "");

    const publish_changes = "<button>Publish changes</button>";
    const discard_changes = "<button>Discard changes</button>";
    try std.testing.expect(std.mem.indexOf(u8, changed.body, publish_changes) != null);
    try std.testing.expect(std.mem.indexOf(u8, changed.body, discard_changes) != null);

    const invalid_body = try std.fmt.allocPrint(arena, "csrf={s}&type=post", .{csrf_token});
    const invalid = try flow.call("POST", "/admin/content/create", invalid_body);
    const problem_marker = "<code>title</code>: required";
    try std.testing.expect(std.mem.indexOf(u8, invalid.body, problem_marker) != null);

    const apply_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&do=publish&expected_version=3",
        .{csrf_token},
    );
    _ = try flow.call("POST", publish_path, apply_body);
    const with_versions = try flow.call("GET", revisions_path, "");
    try std.testing.expect(std.mem.indexOf(u8, with_versions.body, "<td>revision</td>") != null);
    const first_version = try std.fmt.allocPrint(arena, "{s}/revisions/1", .{location});
    const shown = try flow.call("GET", first_version, "");
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "&quot;Hello&quot;") != null);
    const restore_path = try std.fmt.allocPrint(arena, "{s}/restore", .{location});
    const restore_body = try std.fmt.allocPrint(arena, "csrf={s}&seq=1&expected_version=4", .{
        csrf_token,
    });
    const restored = try flow.call("POST", restore_path, restore_body);
    try std.testing.expectEqualStrings(location, restored.header("Location").?);
    const after_restore = try flow.call("GET", location, "");
    try std.testing.expect(std.mem.indexOf(u8, after_restore.body, "value=\"Hello\"") != null);
    const parked_note = "with unpublished changes";
    try std.testing.expect(std.mem.indexOf(u8, after_restore.body, parked_note) != null);

    const logout_body = try std.fmt.allocPrint(arena, "csrf={s}", .{csrf_token});
    _ = try flow.call("POST", "/admin/logout", logout_body);
    const after = try flow.call("GET", "/admin/content", "");
    try std.testing.expectEqualStrings("/admin/login", after.header("Location").?);
}
