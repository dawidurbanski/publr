const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../app/registry.zig");
const model = @import("../../model.zig");
const types = @import("../../operations/content_type.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Page = admin.Page;
const Form = admin.Form;
const Session = admin.Session;
const Def = model.content_type.Def;
const FieldDef = model.field.Def;
const Kind = model.field.Kind;

const back = "/admin/types";
const empty_def: Def = .{ .handle = "", .name = "", .name_plural = "", .fields = &.{} };
/// What a new type starts with: a title and a slug generated from it.
const starter_fields = [_]FieldDef{
    .{ .name = "title", .label = "Title", .kind = .string, .required = true },
    .{ .name = "slug", .label = "Slug", .kind = .slug, .options = .{ .source = "title" } },
};
/// Empty rows offered for new fields on every visit of the editor.
pub const blank_rows: u32 = 3;

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{}) catch |err| {
        return admin.fail(&session, err, "/admin");
    };
    var page = try Page.begin(session.arena, "Content types", &session);

    try page.raw("<p><a href=\"/admin/types/new\">New content type</a></p>\n" ++
        "<table border=\"1\" cellpadding=\"4\">\n<tr><th>Name</th><th>Handle</th>" ++
        "<th>Visibility</th><th>Owner</th><th>Fields</th><th>Content</th></tr>\n");

    for (listed.types) |summary| {
        const visibility: []const u8 = if (summary.public) "public" else "private";
        const owner: []const u8 = if (summary.system) summary.owner else "";

        try page.raw("<tr><td><a href=\"/admin/types/");
        try page.text(summary.handle);
        try page.raw("\">");
        try page.text(summary.name_plural);
        try page.raw("</a></td><td>");
        try page.text(summary.handle);
        try page.print("</td><td>{s}</td><td>", .{visibility});
        try page.text(owner);
        try page.raw(if (summary.system) " (system)" else "");
        try page.print("</td><td>{d}</td><td><a href=\"/admin/content?type=", .{summary.fields});
        try page.text(summary.handle);
        try page.raw("\">Manage</a></td></tr>\n");
    }

    try page.raw("</table>\n");
    try page.send(response, .ok);
}

pub fn new_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    try render_editor(&session, null);
}

pub fn edit_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const handle = try admin.param(&session, "handle", back) orelse return;
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{ .type = handle }) catch |err| {
        return admin.fail(&session, err, back);
    };

    try render_editor(&session, got.definition);
}

fn render_editor(session: *Session, existing: ?Def) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.response.body.len == 0);

    const title: []const u8 = if (existing) |def| def.name_plural else "New content type";
    var page = try Page.begin(session.arena, title, session);

    try page.raw("<p><a href=\"/admin/types\">Back to content types</a></p>\n" ++
        "<form method=\"post\" action=\"/admin/types/");

    if (existing) |def| {
        try page.text(def.handle);
        try page.raw("/update\">\n");
    } else {
        try page.raw("create\">\n");
    }

    try page.csrf(session);
    try render_head(&page, existing);
    try render_fields(&page, existing);
    const submit: []const u8 = if (existing != null) "Save type" else "Create type";

    try page.raw("<p><button>");
    try page.raw(submit);
    try page.raw("</button></p>\n</form>\n");

    if (existing) |def| {
        try page.raw("<form method=\"post\" action=\"/admin/types/");
        try page.text(def.handle);
        try page.raw("/delete\">\n");
        try page.csrf(session);
        try page.raw("<p><button>Delete type</button> " ++
            "<label><input type=\"checkbox\" name=\"force\" value=\"1\"> " ++
            "also delete its records</label></p>\n</form>\n");
    }

    try page.send(session.response, .ok);
}

fn render_head(page: *Page, existing: ?Def) Error!void {
    std.debug.assert(page.out.written().len > 0);
    std.debug.assert(blank_rows > 0);

    const def: Def = existing orelse empty_def;

    if (def.system) {
        try page.raw("<p>Declared by the <strong>");
        try page.text(def.owner);
        try page.raw("</strong> plugin: handle <code>");
        try page.text(def.handle);
        const visibility: []const u8 = if (def.public) "public" else "private";

        try page.print("</code>, {s}, title field <code>", .{visibility});
        try page.text(def.title_field);
        try page.raw("</code>. Its declared fields are locked; you can add fields of your own." ++
            "</p>\n");

        return;
    }

    try text_input(page, "handle", "Handle (machine name, [a-z0-9_])", def.handle);
    try text_input(page, "name", "Name", def.name);
    try text_input(page, "name_plural", "Plural name", def.name_plural);
    try text_input(page, "title_field", "Title field (a string field below)", def.title_field);
    try page.raw("<p><label><input type=\"checkbox\" name=\"public\" value=\"1\"");
    try page.raw(if (def.public) " checked> " else "> ");
    try page.raw("Public: anonymous readers see its live records</label></p>\n");
}

fn text_input(page: *Page, name: []const u8, label: []const u8, value: []const u8) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(label.len > 0);

    try page.raw("<p><label>");
    try page.text(label);
    try page.raw("<br><input name=\"");
    try page.text(name);
    try page.raw("\" size=\"40\" value=\"");
    try page.text(value);
    try page.raw("\"></label></p>\n");
}

fn render_fields(page: *Page, existing: ?Def) Error!void {
    std.debug.assert(page.out.written().len > 0);
    std.debug.assert(blank_rows > 0);

    const fields: []const FieldDef = if (existing) |def| def.fields else &starter_fields;

    try page.raw("<h2>Fields</h2>\n<table border=\"1\" cellpadding=\"4\">\n" ++
        "<tr><th>Name</th><th>Label</th><th>Kind</th><th>Required</th><th>Remove</th></tr>\n");

    for (fields, 0..) |def, index| {
        try render_field_row(page, @intCast(index), def);
    }

    var blank: u32 = 0;

    while (blank < blank_rows) : (blank += 1) {
        const index: u32 = @intCast(fields.len + blank);
        const empty: FieldDef = .{ .name = "", .label = "", .kind = .string };

        try render_field_row(page, index, empty);
    }

    try page.raw("</table>\n<p>Leave a name empty to skip a row. Kinds beyond string, text " ++
        "and boolean keep whatever options they already have.</p>\n");
}

fn render_field_row(page: *Page, index: u32, def: FieldDef) Error!void {
    std.debug.assert(index < model.field.fields_max + blank_rows);
    std.debug.assert(page.out.written().len > 0);

    if (def.locked) {
        try page.raw("<tr><td><code>");
        try page.text(def.name);
        try page.raw("</code></td><td>");
        try page.text(def.label);
        try page.raw("</td><td>");
        try page.raw(@tagName(def.kind));
        const required: []const u8 = if (def.required) "yes" else "no";

        try page.print("</td><td>{s}</td><td>locked</td></tr>\n", .{required});

        return;
    }

    try page.print("<tr><td><input name=\"field_{d}_name\" size=\"16\" value=\"", .{index});
    try page.text(def.name);
    try page.print("\"></td><td><input name=\"field_{d}_label\" size=\"20\" value=\"", .{index});
    try page.text(def.label);
    try page.print("\"></td><td><select name=\"field_{d}_kind\">", .{index});

    inline for (std.meta.fields(Kind)) |kind| {
        const selected = std.mem.eql(u8, kind.name, @tagName(def.kind));

        try page.raw(if (selected) "<option selected>" else "<option>");
        try page.raw(kind.name);
        try page.raw("</option>");
    }

    try page.print("</select></td><td><input type=\"checkbox\" name=\"field_{d}_required\" " ++
        "value=\"1\"{s}></td>", .{ index, if (def.required) " checked" else "" });
    try page.print("<td><input type=\"checkbox\" name=\"field_{d}_remove\" value=\"1\"></td>" ++
        "</tr>\n", .{index});
}

pub fn create(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;

    const definition = try definition_of(session.arena, form, null);
    const created = registry.SDK.dispatch(&session.ctx, types.Create, .{
        .definition = definition,
    }) catch |err| return problems(session, err, definition, "/admin/types/new");
    const location = std.fmt.allocPrint(session.arena, "/admin/types/{s}", .{
        created.handle,
    }) catch return error.OutOfMemory;

    try response.redirect(.see_other, location);
}

pub fn update(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const handle = try admin.param(session, "handle", back) orelse return;

    const location = std.fmt.allocPrint(session.arena, "/admin/types/{s}", .{handle}) catch {
        return error.OutOfMemory;
    };
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{ .type = handle }) catch |err| {
        return admin.fail(session, err, back);
    };
    const definition = try definition_of(session.arena, form, got.definition);
    const updated = registry.SDK.dispatch(&session.ctx, types.Update, .{
        .type = handle,
        .definition = definition,
        .drop_content = form.get("drop_content") != null,
    }) catch |err| return problems(session, err, definition, location);
    const moved = std.fmt.allocPrint(session.arena, "/admin/types/{s}", .{updated.handle}) catch {
        return error.OutOfMemory;
    };

    try response.redirect(.see_other, moved);
}

/// The form back into a definition: existing fields keep what the form cannot show.
fn definition_of(arena: std.mem.Allocator, form: *const Form, existing: ?Def) Error![]const u8 {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(blank_rows > 0);

    const previous: []const FieldDef = if (existing) |def| def.fields else &.{};
    const shown: u32 = if (existing == null) starter_fields.len else 0;
    var fields: std.ArrayList(FieldDef) = .empty;
    var index: u32 = 0;

    while (index < previous.len + shown + blank_rows) : (index += 1) {
        const before: ?FieldDef = if (index < previous.len) previous[index] else null;
        const parsed = try field_of(arena, form, index, before);

        if (parsed) |def| {
            fields.append(arena, def) catch return error.OutOfMemory;
        }
    }

    const base: Def = existing orelse empty_def;
    var def = base;

    def.fields = fields.items;

    if (!base.system) {
        def.handle = form.text("handle") orelse "";
        def.name = form.text("name") orelse "";
        def.name_plural = form.text("name_plural") orelse "";
        def.public = form.get("public") != null;
        def.title_field = form.text("title_field") orelse "title";
    }

    return model.content_type.encode(arena, def) catch error.OutOfMemory;
}

fn field_of(
    arena: std.mem.Allocator,
    form: *const Form,
    index: u32,
    previous: ?FieldDef,
) Error!?FieldDef {
    std.debug.assert(index < model.field.fields_max + blank_rows);
    std.debug.assert(form.len <= admin.form_pairs_max);

    if (previous != null and previous.?.locked) {
        return previous;
    }

    const name = try form_name(arena, index, "name");
    const label = try form_name(arena, index, "label");
    const kind_name = try form_name(arena, index, "kind");
    const required = try form_name(arena, index, "required");
    const remove = try form_name(arena, index, "remove");

    if (form.get(remove) != null) {
        return null;
    }

    const field_name = form.text(name) orelse return null;
    const kind = std.meta.stringToEnum(Kind, form.text(kind_name) orelse "string") orelse .string;
    var def: FieldDef = previous orelse .{ .name = field_name, .label = field_name, .kind = kind };

    def.name = field_name;
    def.label = form.text(label) orelse field_name;
    def.kind = kind;
    def.required = form.get(required) != null;

    return def;
}

fn form_name(arena: std.mem.Allocator, index: u32, suffix: []const u8) Error![]const u8 {
    std.debug.assert(suffix.len > 0);
    std.debug.assert(index < 1000);

    return std.fmt.allocPrint(arena, "field_{d}_{s}", .{ index, suffix }) catch error.OutOfMemory;
}

pub fn delete(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const handle = try admin.param(session, "handle", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, types.Delete, .{
        .type = handle,
        .force = form.get("force") != null,
    }) catch |err| return admin.fail(session, err, back);

    try response.redirect(.see_other, back);
}

/// A refused definition: list what is wrong with it.
fn problems(
    session: *Session,
    err: anyerror,
    definition: []const u8,
    return_to: []const u8,
) Error!void {
    std.debug.assert(definition.len > 0);
    std.debug.assert(return_to.len > 0);

    if (err != error.Invalid) {
        return admin.fail(session, err, return_to);
    }

    const checked = registry.SDK.dispatch(&session.ctx, types.Validate, .{
        .definition = definition,
    }) catch |inner| return admin.fail(session, inner, return_to);
    var page = try Page.begin(session.arena, "The content type is not valid", session);

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
