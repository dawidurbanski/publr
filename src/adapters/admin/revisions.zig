const std = @import("std");
const admin = @import("../admin.zig");
const fields = @import("fields.zig");
const registry = @import("../../app/registry.zig");
const types = @import("../../operations/content_type.zig");
const record_operations = @import("../../operations/record.zig");
const snapshots = @import("../../operations/snapshot.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Page = admin.Page;
const Form = admin.Form;
const Session = admin.Session;

const back = "/admin/content";

/// Every snapshot of a record, newest first, with the revision's title where it has one.
pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const full = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = id,
    }) catch |err| return admin.fail(&session, err, back);
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = full.record.type,
    }) catch |err| return admin.fail(&session, err, back);
    const listed = registry.SDK.dispatch(&session.ctx, snapshots.List, .{
        .id = id,
        .limit = 1000,
    }) catch |err| return admin.fail(&session, err, back);
    const title = std.fmt.allocPrint(session.arena, "Versions of {s}", .{
        if (full.record.title.len > 0) full.record.title else full.record.id,
    }) catch return error.OutOfMemory;
    var page = try Page.begin(session.arena, title, &session);

    try page.raw("<p><a href=\"/admin/content/");
    try page.text(full.record.id);
    try page.raw("\">Back to the record</a></p>\n" ++
        "<table border=\"1\" cellpadding=\"4\">\n<tr><th>#</th><th>Kind</th>" ++
        "<th>Title</th><th>Taken</th><th>By</th></tr>\n<tr><td><strong>current</strong></td><td>");
    try page.text(full.record.status);
    try page.raw(if (full.record.changed) " (live; pending changes aside)" else "");
    try page.raw("</td><td>");
    try page.text(full.record.title);
    try page.print("</td><td>{d}</td><td>", .{full.record.updated_at});
    try page.text(full.record.updated_by orelse "");
    try page.raw("</td></tr>\n");

    var index = listed.snapshots.len;

    while (index > 0) : (index -= 1) {
        const item = listed.snapshots[index - 1];

        try page.print("<tr><td><a href=\"/admin/content/{s}/revisions/{d}\">{d}</a></td><td>", .{
            full.record.id,
            item.seq,
            item.seq,
        });
        try page.text(item.kind);
        try page.raw("</td><td>");
        try page.text(title_of(session.arena, item.document, got.definition.title_field));
        try page.print("</td><td>{d}</td><td>", .{item.at});
        try page.text(item.by orelse "");
        try page.raw("</td></tr>\n");
    }

    try page.raw("</table>\n");

    if (listed.snapshots.len == 0) {
        try page.raw("<p>No previous versions yet: one is kept every time the live document is " ++
            "replaced.</p>\n");
    }

    try page.send(response, .ok);
}

/// One snapshot, field by field, with a way to bring it back.
pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const seq = seq_param(&session) orelse return admin.fail(&session, error.NotFound, back);
    const full = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = id,
    }) catch |err| return admin.fail(&session, err, back);
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = full.record.type,
    }) catch |err| return admin.fail(&session, err, back);
    const item = registry.SDK.dispatch(&session.ctx, snapshots.Get, .{
        .id = id,
        .seq = seq,
    }) catch |err| return admin.fail(&session, err, back);
    const document = std.json.parseFromSliceLeaky(
        std.json.Value,
        session.arena,
        item.document,
        .{},
    ) catch return admin.fail(&session, error.Invalid, back);
    const title = std.fmt.allocPrint(session.arena, "Version {d} of {s}", .{
        seq,
        if (full.record.title.len > 0) full.record.title else full.record.id,
    }) catch return error.OutOfMemory;
    var page = try Page.begin(session.arena, title, &session);

    try page.print("<p><a href=\"/admin/content/{s}/revisions\">All versions</a> | " ++
        "<a href=\"/admin/content/{s}\">The record</a></p>\n<p>Kind: ", .{
        full.record.id,
        full.record.id,
    });
    try page.text(item.kind);
    try page.print(", taken {d} by ", .{item.at});
    try page.text(item.by orelse "nobody");
    try page.raw("</p>\n<table border=\"1\" cellpadding=\"4\">\n" ++
        "<tr><th>Field</th><th>Value</th></tr>\n");

    for (got.definition.fields) |def| {
        const value = document.object.get(def.name);

        try page.raw("<tr><td>");
        try page.text(def.label);
        try page.raw("</td><td><pre>");

        if (value) |present| {
            const text = std.json.Stringify.valueAlloc(session.arena, present, .{
                .whitespace = .indent_2,
            }) catch return error.OutOfMemory;

            try page.text(text);
        }

        try page.raw("</pre></td></tr>\n");
    }

    try page.raw("</table>\n<form method=\"post\" action=\"/admin/content/");
    try page.text(full.record.id);
    try page.raw("/restore\">\n");
    try page.csrf(&session);
    try page.print("<input type=\"hidden\" name=\"seq\" value=\"{d}\">" ++
        "<input type=\"hidden\" name=\"expected_version\" value=\"{d}\">\n", .{
        seq,
        full.record.version,
    });
    try page.raw("<p><button>Restore this version</button> (a normal save: parked as pending " ++
        "changes when the record is live)</p>\n</form>\n");
    try page.send(response, .ok);
}

/// Restore = the snapshot's document written back through `record save`.
pub fn restore(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const id = try admin.param(session, "id", back) orelse return;

    const location = std.fmt.allocPrint(session.arena, "/admin/content/{s}", .{id}) catch {
        return error.OutOfMemory;
    };
    const seq = number_field(form, "seq") orelse {
        return admin.fail(session, error.Invalid, location);
    };
    const expected = number_field(form, "expected_version") orelse {
        return admin.fail(session, error.Invalid, location);
    };
    _ = registry.SDK.dispatch(&session.ctx, snapshots.Restore, .{
        .id = id,
        .seq = seq,
        .expected_version = expected,
    }) catch |err| return admin.fail(session, err, location);

    try response.redirect(.see_other, location);
}

fn seq_param(session: *const Session) ?i64 {
    std.debug.assert(session.request.path().len > 0);
    std.debug.assert(session.ctx.now_ms > 0);

    const text = session.request.param("seq") orelse return null;

    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn number_field(form: *const Form, name: []const u8) ?i64 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    const text = form.text(name) orelse return null;

    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn title_of(arena: std.mem.Allocator, document: []const u8, title_field: []const u8) []const u8 {
    std.debug.assert(title_field.len > 0);
    std.debug.assert(fields.json_bytes_max > 0);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, document, .{}) catch {
        return "";
    };

    if (parsed != .object) {
        return "";
    }

    const title = parsed.object.get(title_field) orelse return "";

    return if (title == .string) title.string else "";
}
