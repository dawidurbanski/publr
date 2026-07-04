//! Schema-driven form rendering: main editor form + sidebar.

const std = @import("std");
const cms = @import("cms");
const kv = @import("kv");
const field_mod = @import("field");
const content_type_mod = @import("content_type");
const tpl = @import("tpl");
const views = @import("views");
const pu = @import("plugin_utils");
const _p = @import("_platform.zig");
const auth_middleware = @import("auth_middleware");
const field_render = @import("field_render.zig");

const Allocator = std.mem.Allocator;
const ContentTypeDef = content_type_mod.ContentTypeDef;
const presence = _p.presence;
const writeJsonEscaped = pu.writeJsonEscaped;

pub const FormOptions = struct {
    entry_id: []const u8 = "",
    status: []const u8 = "",
    published_data: ?[]const u8 = null,
    fields_in_releases: []const u8 = "[]",
    field_editors: []const u8 = "{}",
};

pub const SidebarOptions = struct {
    entry_id: []const u8 = "",
    history_html: []const u8 = "",
    release_html: []const u8 = "",
    base_url: []const u8 = "",
};

/// Render fields HTML for a given position (main editor or sidebar).
pub fn renderFieldsHtml(
    def: *const ContentTypeDef,
    allocator: Allocator,
    data: *const cms.query.FieldMap,
    csrf_token: []const u8,
    action_url: []const u8,
    position: field_mod.Position,
    opts: FormOptions,
) []const u8 {
    _ = action_url;

    // Buffer this position's fields (each via its ZSX component render; a
    // DB-loaded stub falls through to the field_render registry).
    var fields: std.ArrayListUnmanaged(u8) = .{};
    const fw = fields.writer(allocator);
    for (def.fields) |fd| {
        if (fd.position == position) {
            const value = fieldMapValueToString(allocator, data.*, fd.name);
            const ctx = field_mod.RenderContext{
                .name = fd.name,
                .display_name = fd.display_name,
                .value = value,
                .required = fd.required,
                .allocator = allocator,
            };
            const before = fields.items.len;
            fd.render(fw.any(), ctx) catch {};
            if (fields.items.len == before) {
                field_render.renderField(fw.any(), fd, ctx) catch {};
            }
        }
    }

    // Non-main positions carry no form chrome — return just the fields.
    if (position != .main) return fields.items;

    // KV picker vars (auth-gated); the component renders the script tags.
    var vars_json: ?[]const u8 = null;
    if (auth_middleware.auth) |a| {
        vars_json = kv.pickerVarsJson(allocator, a.db, "", 40) catch "[]";
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    views.components.entry_form.EntryForm(out.writer(allocator).any(), .{
        .type_id = def.type_id,
        .entry_id = opts.entry_id,
        .entry_id_attr = if (opts.entry_id.len > 0) opts.entry_id else null,
        .status_attr = if (opts.status.len > 0) opts.status else null,
        .published_state = opts.published_data,
        .fields_in_releases = opts.fields_in_releases,
        .field_editors = opts.field_editors,
        .lock_timeout_ms = presence.getLockTimeoutMs(),
        .heartbeat_interval_ms = presence.getHeartbeatIntervalMs(),
        .csrf_token = csrf_token,
        .fields_html = fields.items,
        .vars_json = vars_json,
    }) catch return "";
    return out.toOwnedSlice(allocator) catch "";
}

/// Extract a string representation of a FieldMap value for form rendering.
pub fn fieldMapValueToString(allocator: Allocator, map: cms.query.FieldMap, name: []const u8) ?[]const u8 {
    const v = map.get(name) orelse return null;
    return switch (v) {
        .text => |s| s,
        .int => |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch null,
        .real => |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch null,
        .bool_ => |b| if (b) "true" else "false",
        .datetime => |t| std.fmt.allocPrint(allocator, "{d}", .{t}) catch null,
        .json => |j| blk: {
            var list: std.ArrayList(u8) = .{};
            errdefer list.deinit(allocator);
            list.writer(allocator).print("{f}", .{std.json.fmt(j, .{})}) catch break :blk null;
            break :blk list.toOwnedSlice(allocator) catch null;
        },
        .null_ => null,
    };
}

/// Render the sidebar HTML with all sections.
pub fn renderSidebarHtml(
    def: *const ContentTypeDef,
    allocator: Allocator,
    data: *const cms.query.FieldMap,
    csrf_token: []const u8,
    delete_url: []const u8,
    status: []const u8,
    opts: SidebarOptions,
) []const u8 {
    _ = delete_url;

    const is_draft = std.mem.eql(u8, status, "draft") or status.len == 0;
    const is_published = std.mem.eql(u8, status, "published");
    const is_changed = std.mem.eql(u8, status, "changed");

    const publish_label: ?[]const u8 = if (is_draft)
        "Publish"
    else if (is_changed)
        "Publish Changes"
    else if (is_published)
        "Published"
    else
        null;

    var has_side_fields = false;
    for (def.fields) |fd| {
        if (fd.position == .side) {
            has_side_fields = true;
            break;
        }
    }

    // Buffer the .side fields, each patched with form="entry-form" so its
    // controls submit to the main editor form.
    var side_fields: std.ArrayListUnmanaged(u8) = .{};
    if (has_side_fields) {
        const sw = side_fields.writer(allocator);
        for (def.fields) |fd| {
            if (fd.position == .side) {
                const value = fieldMapValueToString(allocator, data.*, fd.name);
                const ctx = field_mod.RenderContext{
                    .name = fd.name,
                    .display_name = fd.display_name,
                    .value = value,
                    .required = fd.required,
                    .allocator = allocator,
                };
                var field_buf: std.ArrayListUnmanaged(u8) = .{};
                const fbw = field_buf.writer(allocator);
                fd.render(fbw.any(), ctx) catch {};
                if (field_buf.items.len == 0) {
                    field_render.renderField(fbw.any(), fd, ctx) catch {};
                }
                sw.writeAll(injectFormAttr(allocator, field_buf.items, "entry-form")) catch {};
            }
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    views.components.entry_sidebar.EntrySidebar(out.writer(allocator).any(), .{
        .publish_label = publish_label,
        .publish_disabled = is_published,
        .show_discard = !is_draft,
        .discard_hidden = !is_changed,
        .release_html = opts.release_html,
        .has_side_fields = has_side_fields,
        .side_fields_html = side_fields.items,
        .history_html = opts.history_html,
        .entry_id = opts.entry_id,
        .csrf_token = csrf_token,
        .type_id = def.type_id,
        .display_name = def.display_name,
    }) catch return "";
    return out.toOwnedSlice(allocator) catch "";
}

pub fn injectFormAttr(allocator: Allocator, html: []const u8, form_id: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const w = buf.writer(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<' and i + 1 < html.len and html[i + 1] != '/') {
            const rest = html[i..];
            const is_input = std.mem.startsWith(u8, rest, "<input ");
            const is_select = std.mem.startsWith(u8, rest, "<select ");
            const is_textarea = std.mem.startsWith(u8, rest, "<textarea ");
            const is_button = std.mem.startsWith(u8, rest, "<button ");

            if (is_input or is_select or is_textarea or is_button) {
                const space_pos = std.mem.indexOfScalar(u8, rest, ' ') orelse {
                    w.writeByte(html[i]) catch {};
                    i += 1;
                    continue;
                };
                w.writeAll(rest[0 .. space_pos + 1]) catch {};
                w.print("form=\"{s}\" ", .{form_id}) catch {};
                i += space_pos + 1;
                continue;
            }
        }
        w.writeByte(html[i]) catch {};
        i += 1;
    }
    return buf.toOwnedSlice(allocator) catch html;
}

pub fn defaultDataJson(allocator: Allocator, def: *const ContentTypeDef) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var first = true;
    for (def.fields) |fd| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('"');
        try writeJsonEscaped(w, fd.name);
        try w.writeAll("\":");

        if (std.mem.eql(u8, fd.field_type_id, "repeater") or fd.multi) {
            try w.writeAll("[]");
        } else if (fd.sub_fields.len > 0) {
            try w.writeAll("{}");
        } else if (std.mem.eql(u8, fd.field_type_id, "boolean")) {
            try w.writeAll("false");
        } else if (std.mem.eql(u8, fd.field_type_id, "integer") or
            std.mem.eql(u8, fd.field_type_id, "number") or
            std.mem.eql(u8, fd.field_type_id, "real"))
        {
            try w.writeAll("null");
        } else {
            try w.writeAll("\"\"");
        }
    }
    try w.writeByte('}');

    return buf.toOwnedSlice(allocator);
}

pub fn formatDate(timestamp: i64, allocator: Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
}

const Context = @import("middleware").Context;

/// Render the same styled 404 as `error.notFoundHandler`.
pub fn notFound(ctx: *Context) anyerror!void {
    ctx.response.setStatus("404 Not Found");
    const content = tpl.render(views.@"error".error_404.Error404, .{.{
        .status_code = "404",
        .title = "Page Not Found",
        .message = "The page you're looking for doesn't exist or has been moved.",
    }});
    if (ctx.isPartial()) {
        ctx.html(content);
    } else {
        ctx.html(tpl.render(views.base.Base, .{.{
            .title = "Error - Publr",
            .content = content,
            .css = &[_][]const u8{},
            .js = &[_][]const u8{},
        }}));
    }
}
