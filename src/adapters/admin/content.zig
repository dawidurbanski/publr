const std = @import("std");
const admin = @import("../admin.zig");
const fields = @import("fields.zig");
const registry = @import("../../app/registry.zig");
const model = @import("../../model.zig");
const types = @import("../../operations/content_type.zig");
const record_operations = @import("../../operations/record.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Page = admin.Page;
const Form = admin.Form;
const Session = admin.Session;
const Def = model.content_type.Def;

const back = "/admin/content";
const slug_field_of = @import("../../model/document.zig").slug_field_of;

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{}) catch |err| {
        return admin.fail(&session, err, "/admin");
    };
    const wanted = admin.query_param(&session, "type") orelse
        (if (listed.types.len > 0) listed.types[0].handle else null);
    var page = try Page.begin(session.arena, "Content", &session);

    try page.raw("<p>");

    for (listed.types) |summary| {
        try page.raw("<a href=\"/admin/content?type=");
        try page.text(summary.handle);
        try page.raw("\">");
        try page.text(summary.name_plural);
        try page.raw("</a> ");
    }

    try page.raw("</p>\n");

    if (wanted) |handle| {
        try render_type(&page, &session, handle);
    } else {
        try page.raw("<p>No content types yet. <a href=\"/admin/types\">Create one</a>.</p>\n");
    }

    try page.send(response, .ok);
}

fn render_type(page: *Page, session: *Session, handle: []const u8) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{ .type = handle }) catch |err| {
        return admin.fail(session, err, back);
    };
    const status = admin.query_param(session, "status");
    const listed = registry.SDK.dispatch(&session.ctx, record_operations.List, .{
        .type = handle,
        .status = status,
        .limit = record_operations.list_max,
    }) catch |err| return admin.fail(session, err, back);

    try page.raw("<h2>");
    try page.text(got.definition.name_plural);
    try page.raw("</h2>\n<p><a href=\"/admin/content/new?type=");
    try page.text(handle);
    try page.raw("\">New ");
    try page.text(got.definition.name);
    try page.raw("</a></p>\n<p>Status:");

    for (registry.Statuses.all, 0..) |candidate, index| {
        try page.raw(if (index == 0) " " else " | ");
        try page.raw("<a href=\"/admin/content?type=");
        try page.text(handle);
        try page.raw("&status=");
        try page.text(candidate.id);
        try page.raw("\">");
        try page.text(candidate.label);
        try page.raw("</a>");
    }

    try page.raw("</p>\n");

    if (slug_field_of(got.definition) == null) {
        try page.raw("<p><em>This type has no slug field; add one of kind <code>slug</code> in " ++
            "the <a href=\"/admin/types/");
        try page.text(handle);
        try page.raw("\">type editor</a> and existing records get theirs.</em></p>\n");
    }

    try page.raw("<table border=\"1\" cellpadding=\"4\">\n<tr><th>Title</th><th>Slug</th>" ++
        "<th>Status</th><th>Updated</th></tr>\n");

    for (listed.records) |summary| {
        try page.raw("<tr><td><a href=\"/admin/content/");
        try page.text(summary.id);
        try page.raw("\">");
        try page.text(if (summary.title.len > 0) summary.title else summary.id);
        try page.raw("</a></td><td>");
        try page.text(summary.slug orelse "");
        try page.raw("</td><td>");
        try page.text(summary.status);
        try page.raw(if (summary.changed) " <em>(changed)</em>" else "");
        try page.print("</td><td>{d}</td></tr>\n", .{summary.updated_at});
    }

    try page.raw("</table>\n");
}

pub fn new_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const handle = admin.query_param(&session, "type") orelse {
        return admin.fail(&session, error.NotFound, back);
    };
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{ .type = handle }) catch |err| {
        return admin.fail(&session, err, back);
    };
    const title = std.fmt.allocPrint(session.arena, "New {s}", .{got.definition.name}) catch {
        return error.OutOfMemory;
    };
    var page = try Page.begin(session.arena, title, &session);

    try page.raw("<p><a href=\"/admin/content?type=");
    try page.text(handle);
    try page.raw("\">Back to ");
    try page.text(got.definition.name_plural);
    try page.raw("</a></p>\n<form method=\"post\" action=\"/admin/content/create\">\n");
    try page.csrf(&session);
    try page.raw("<input type=\"hidden\" name=\"type\" value=\"");
    try page.text(handle);
    try page.raw("\">\n");
    try fields.render(&page, got.definition.fields, null);
    try page.raw("<p><button>Create</button></p>\n</form>\n");
    try page.send(response, .ok);
}

pub fn create(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;

    const handle = form.text("type") orelse return admin.fail(session, error.Invalid, back);
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{ .type = handle }) catch |err| {
        return admin.fail(session, err, back);
    };
    const document = fields.document_of(session.arena, got.definition.fields, form) orelse {
        return admin.fail(session, error.Invalid, back);
    };
    const created = registry.SDK.dispatch(&session.ctx, record_operations.Create, .{
        .type = handle,
        .document = document,
    }) catch |err| return problems(session, err, handle, document, back);
    const location = std.fmt.allocPrint(session.arena, "/admin/content/{s}", .{created.id}) catch {
        return error.OutOfMemory;
    };

    try response.redirect(.see_other, location);
}

pub fn edit(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const full = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = id,
        .purpose = .edit,
    }) catch |err| return admin.fail(&session, err, back);
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = full.record.type,
    }) catch |err| return admin.fail(&session, err, back);
    const document = std.json.parseFromSliceLeaky(
        std.json.Value,
        session.arena,
        full.document,
        .{},
    ) catch return admin.fail(&session, error.Invalid, back);
    const title = if (full.record.title.len > 0) full.record.title else full.record.id;
    var page = try Page.begin(session.arena, title, &session);

    try page.raw("<p><a href=\"/admin/content?type=");
    try page.text(full.record.type);
    try page.raw("\">Back to ");
    try page.text(got.definition.name_plural);
    const changed_note: []const u8 = if (full.record.changed) " with unpublished changes" else "";

    try page.print("</a> | <a href=\"/admin/content/{s}/revisions\">Versions</a></p>\n" ++
        "<p>Status: <strong>{s}</strong>{s}, id {s}</p>\n", .{
        full.record.id,
        full.record.status,
        changed_note,
        full.record.id,
    });
    try render_actions(&page, &session, full);
    try page.raw("<form method=\"post\" action=\"/admin/content/");
    try page.text(full.record.id);
    try page.raw("/save\">\n");
    try page.csrf(&session);
    try page.print("<input type=\"hidden\" name=\"expected_version\" value=\"{d}\">\n", .{
        full.record.version,
    });
    try fields.render(&page, got.definition.fields, document);

    const parks = full.record.changed or registry.Statuses.is_live(full.record.status);

    try page.raw(if (parks)
        "<p><button>Save as pending changes</button> " ++
            "(the live version stays until you publish)</p>\n"
    else
        "<p><button>Save</button></p>\n");
    try page.raw("</form>\n");
    try page.send(response, .ok);
}

fn render_actions(
    page: *Page,
    session: *const Session,
    full: record_operations.Get.Out,
) Error!void {
    std.debug.assert(full.record.id.len > 0);
    std.debug.assert(full.record.status.len > 0);

    const live = registry.Statuses.is_live(full.record.status);

    try page.raw("<p>");

    if (live and full.record.changed) {
        try action_form(page, session, full, "do", "publish", "Publish changes");
    } else if (!live and registry.Statuses.allows(full.record.status, "published")) {
        try action_form(page, session, full, "do", "publish", "Publish");
    }

    if (full.record.changed) {
        try action_form(page, session, full, "do", "discard", "Discard changes");
    }

    for (registry.Statuses.all_transitions) |transition| {
        const from_here = std.mem.eql(u8, transition.from, "*") or
            std.mem.eql(u8, transition.from, full.record.status);
        const to_live = registry.Statuses.is_live(transition.to);

        if (!from_here or to_live or std.mem.eql(u8, transition.to, full.record.status)) {
            continue;
        }

        try action_form(page, session, full, "to", transition.to, transition.label);
    }

    if (session.identity.caller.role() == .admin) {
        try action_form(page, session, full, "do", "purge", "Purge for good");
    }

    try page.raw("</p>\n");
}

fn action_form(
    page: *Page,
    session: *const Session,
    full: record_operations.Get.Out,
    name: []const u8,
    value: []const u8,
    label: []const u8,
) Error!void {
    std.debug.assert(full.record.id.len > 0);
    std.debug.assert(name.len > 0);

    try page.raw("<form method=\"post\" style=\"display:inline\" action=\"/admin/content/");
    try page.text(full.record.id);
    try page.raw("/action\">");
    try page.csrf(session);
    try page.print("<input type=\"hidden\" name=\"expected_version\" value=\"{d}\">", .{
        full.record.version,
    });
    try page.raw("<input type=\"hidden\" name=\"");
    try page.text(name);
    try page.raw("\" value=\"");
    try page.text(value);
    try page.raw("\"><button>");
    try page.text(label);
    try page.raw("</button></form> ");
}

pub fn save(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const id = try admin.param(session, "id", back) orelse return;

    const full = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = id,
        .purpose = .edit,
    }) catch |err| return admin.fail(session, err, back);
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = full.record.type,
    }) catch |err| return admin.fail(session, err, back);
    const document = fields.document_of(session.arena, got.definition.fields, form) orelse {
        return admin.fail(session, error.Invalid, back);
    };
    const expected = expected_version_of(form) orelse {
        return admin.fail(session, error.Invalid, back);
    };
    const location = std.fmt.allocPrint(session.arena, "/admin/content/{s}", .{id}) catch {
        return error.OutOfMemory;
    };

    _ = registry.SDK.dispatch(&session.ctx, record_operations.Save, .{
        .id = id,
        .document = document,
        .expected_version = expected,
    }) catch |err| return problems(session, err, full.record.type, document, location);

    try response.redirect(.see_other, location);
}

pub fn action(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const id = try admin.param(session, "id", back) orelse return;

    const location = std.fmt.allocPrint(session.arena, "/admin/content/{s}", .{id}) catch {
        return error.OutOfMemory;
    };
    const verb = form.text("do") orelse "transition";
    const expected = expected_version_of(form) orelse {
        return admin.fail(session, error.Invalid, location);
    };

    if (std.mem.eql(u8, verb, "publish")) {
        _ = registry.SDK.dispatch(&session.ctx, record_operations.Publish, .{
            .id = id,
            .expected_version = expected,
        }) catch |err| return admin.fail(session, err, location);
    } else if (std.mem.eql(u8, verb, "discard")) {
        _ = registry.SDK.dispatch(&session.ctx, record_operations.DiscardChanges, .{
            .id = id,
            .expected_version = expected,
        }) catch |err| return admin.fail(session, err, location);
    } else if (std.mem.eql(u8, verb, "purge")) {
        _ = registry.SDK.dispatch(&session.ctx, record_operations.Purge, .{
            .id = id,
        }) catch |err| return admin.fail(session, err, location);

        return response.redirect(.see_other, back);
    } else {
        const to = form.text("to") orelse return admin.fail(session, error.Invalid, location);

        _ = registry.SDK.dispatch(&session.ctx, record_operations.Transition, .{
            .id = id,
            .to = to,
            .expected_version = expected,
        }) catch |err| return admin.fail(session, err, location);
    }

    try response.redirect(.see_other, location);
}

/// The version the form was rendered with; null when missing or malformed.
fn expected_version_of(form: *const Form) ?i64 {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(admin.form_pairs_max > 0);

    const text = form.text("expected_version") orelse return null;

    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// A failed write: list the document's problems when it was the document.
fn problems(
    session: *Session,
    err: anyerror,
    handle: []const u8,
    document: []const u8,
    return_to: []const u8,
) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(return_to.len > 0);

    if (err != error.Invalid) {
        return admin.fail(session, err, return_to);
    }

    const checked = registry.SDK.dispatch(&session.ctx, record_operations.Validate, .{
        .type = handle,
        .document = document,
    }) catch |inner| return admin.fail(session, inner, return_to);
    var page = try Page.begin(session.arena, "The document is not valid", session);

    try page.raw("<ul>\n");

    for (checked.problems) |problem| {
        try page.raw("<li><code>");
        try page.text(problem.path);
        try page.raw("</code>: ");
        try page.text(problem.message);
        try page.raw("</li>\n");
    }

    try page.raw("</ul>\n<p><a href=\"");
    try page.text(return_to);
    try page.raw("\">Back</a></p>\n");
    try page.send(session.response, .ok);
}
