//! Schema-driven form rendering: main editor form + sidebar.

const std = @import("std");
const cms = @import("cms");
const field_mod = @import("field");
const content_type_mod = @import("content_type");
const tpl = @import("tpl");
const views = @import("views");
const pu = @import("plugin_utils");
const _p = @import("_platform.zig");

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

/// Fallback renderer for fields loaded from the DB (parseFields assigns
/// a noopRender stub — see db_types.zig). Mirrors the comptime builders'
/// HTML shape but ignores per-field options (max_length, rows, etc.) that
/// don't round-trip through the DB schema yet.
fn renderDefaultField(
    w: std.io.AnyWriter,
    fd: field_mod.FieldDef,
    ctx: field_mod.RenderContext,
) !void {
    try field_mod.writeFieldLabelRow(w, ctx, .label_with_for);
    const value = ctx.value orelse "";
    const required_attr: []const u8 = if (ctx.required) " required" else "";

    if (std.mem.eql(u8, fd.field_type_id, "text") or std.mem.eql(u8, fd.field_type_id, "richtext")) {
        try w.print(
            "  <textarea class=\"form-control\" id=\"{s}\" name=\"{s}\" rows=\"5\"{s}>{s}</textarea>\n</div>\n",
            .{ ctx.name, ctx.name, required_attr, value },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "boolean")) {
        const checked: []const u8 = if (std.mem.eql(u8, value, "true")) " checked" else "";
        try w.print(
            "  <label class=\"switch-label\"><input type=\"checkbox\" class=\"switch-input\" id=\"{s}\" name=\"{s}\" value=\"true\"{s} /><span class=\"switch-track\" role=\"switch\"><span class=\"switch-thumb\"></span></span></label>\n</div>\n",
            .{ ctx.name, ctx.name, checked },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "datetime")) {
        try w.print(
            "  <input type=\"datetime-local\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"{s} />\n</div>\n",
            .{ ctx.name, ctx.name, value, required_attr },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "integer") or std.mem.eql(u8, fd.field_type_id, "number")) {
        const step: []const u8 = if (std.mem.eql(u8, fd.field_type_id, "integer")) "1" else "any";
        try w.print(
            "  <input type=\"number\" step=\"{s}\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"{s} />\n</div>\n",
            .{ step, ctx.name, ctx.name, value, required_attr },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "email")) {
        try w.print(
            "  <input type=\"email\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"{s} />\n</div>\n",
            .{ ctx.name, ctx.name, value, required_attr },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "url")) {
        try w.print(
            "  <input type=\"url\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"{s} />\n</div>\n",
            .{ ctx.name, ctx.name, value, required_attr },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "image")) {
        try w.print(
            "  <div data-widget=\"media-picker\" data-name=\"{s}\" data-value=\"{s}\">\n" ++
                "    <input type=\"hidden\" name=\"{s}\" value=\"{s}\" />\n" ++
                "    <button type=\"button\" class=\"btn btn-sm\">Select image</button>\n" ++
                "  </div>\n</div>\n",
            .{ ctx.name, value, ctx.name, value },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "reference")) {
        try w.print(
            "  <input type=\"text\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\" placeholder=\"Entry ID\"{s} />\n</div>\n",
            .{ ctx.name, ctx.name, value, required_attr },
        );
    } else if (std.mem.eql(u8, fd.field_type_id, "taxonomy")) {
        const tax = fd.taxonomy_id orelse fd.name;
        const many: []const u8 = if (fd.multi) "true" else "false";
        try w.print(
            "  <div data-widget=\"taxonomy-picker\" data-taxonomy=\"{s}\" data-many=\"{s}\" data-name=\"{s}\" data-value=\"{s}\">\n" ++
                "    <input type=\"hidden\" name=\"{s}\" value=\"{s}\" />\n" ++
                "    <button type=\"button\" class=\"btn btn-sm\">Select {s}</button>\n" ++
                "  </div>\n</div>\n",
            .{ tax, many, ctx.name, value, ctx.name, value, fd.display_name },
        );
    } else {
        // string, slug, select, and any unknown type fall back to a text input.
        try w.print(
            "  <input type=\"text\" class=\"form-control\" id=\"{s}\" name=\"{s}\" value=\"{s}\"{s} />\n</div>\n",
            .{ ctx.name, ctx.name, value, required_attr },
        );
    }
}

/// Escape a string for safe use in an HTML attribute value.
pub fn htmlAttrEscape(allocator: Allocator, input: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const w = buf.writer(allocator);
    for (input) |c| {
        switch (c) {
            '"' => w.writeAll("&quot;") catch return "",
            '&' => w.writeAll("&amp;") catch return "",
            '<' => w.writeAll("&lt;") catch return "",
            '>' => w.writeAll("&gt;") catch return "",
            '\'' => w.writeAll("&#39;") catch return "",
            else => w.writeByte(c) catch return "",
        }
    }
    return buf.toOwnedSlice(allocator) catch "";
}

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
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const w = buf.writer(allocator);

    if (position == .main) {
        _ = action_url;
        w.print(
            \\<form method="POST" action="/admin/action" id="entry-form" class="form"
            \\ data-base-url="/admin/content/{s}"
        , .{def.type_id}) catch return "";

        if (opts.entry_id.len > 0) {
            w.print(
                \\ data-entry-id="{s}"
            , .{opts.entry_id}) catch {};
        }
        if (opts.status.len > 0) {
            w.print(
                \\ data-entry-status="{s}"
            , .{opts.status}) catch {};
        }
        if (opts.published_data) |pd| {
            const escaped = htmlAttrEscape(allocator, pd);
            w.print(
                \\ data-published-state="{s}"
            , .{escaped}) catch {};
        }

        const fir_escaped = htmlAttrEscape(allocator, opts.fields_in_releases);
        const fe_escaped = htmlAttrEscape(allocator, opts.field_editors);
        w.print(
            \\ data-fields-in-releases="{s}"
            \\ data-field-editors="{s}"
        , .{ fir_escaped, fe_escaped }) catch {};
        w.print(
            \\ data-lock-timeout-ms="{d}"
            \\ data-heartbeat-interval-ms="{d}"
        , .{
            presence.getLockTimeoutMs(),
            presence.getHeartbeatIntervalMs(),
        }) catch {};

        w.writeAll(">") catch return "";

        w.print(
            \\  <input type="hidden" name="_csrf" value="{s}" />
            \\  <input type="hidden" name="action" value="content.update" />
            \\  <input type="hidden" name="type" value="{s}" />
            \\  <input type="hidden" name="entry_id" value="{s}" />
            \\  <input type="hidden" name="fields" id="publish-fields" value="" />
        , .{ csrf_token, def.type_id, opts.entry_id }) catch return "";
    }

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
            const before = buf.items.len;
            fd.render(w.any(), ctx) catch {};
            if (buf.items.len == before) {
                // The field's render fn produced nothing — typically a
                // db-loaded FieldDef with a stub renderer. Fall back to
                // a field_type_id-dispatched default.
                renderDefaultField(w.any(), fd, ctx) catch {};
            }
        }
    }

    if (position == .main) {
        w.writeAll("</form>") catch {};
    }

    return buf.toOwnedSlice(allocator) catch "";
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
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const w = buf.writer(allocator);

    const is_draft = std.mem.eql(u8, status, "draft") or status.len == 0;
    const is_published = std.mem.eql(u8, status, "published");
    const is_changed = std.mem.eql(u8, status, "changed");

    w.writeAll(
        \\<div class="edit-sidebar-section">
        \\  <div class="edit-sidebar-actions">
        \\    <div class="autosave-status" id="autosave-status"></div>
    ) catch return "";

    if (is_draft) {
        w.writeAll(
            \\    <button type="submit" form="entry-form" name="status" value="published" class="btn btn-primary btn-full" id="publish-btn">Publish</button>
        ) catch {};
    } else if (is_changed) {
        w.writeAll(
            \\    <button type="submit" form="entry-form" name="status" value="published" class="btn btn-primary btn-full" id="publish-btn">Publish Changes</button>
        ) catch {};
    } else if (is_published) {
        w.writeAll(
            \\    <button type="submit" form="entry-form" name="status" value="published" class="btn btn-primary btn-full" id="publish-btn" disabled>Published</button>
        ) catch {};
    }

    if (!is_draft) {
        w.print(
            \\    <button type="button" class="{s}" id="discard-btn">Discard Changes</button>
        , .{if (is_changed) "btn btn-ghost btn-full" else "btn btn-ghost btn-full hidden"}) catch {};
    }

    if (opts.release_html.len > 0) {
        w.writeAll(opts.release_html) catch {};
    }

    w.writeAll(
        \\  </div>
        \\</div>
    ) catch {};

    var has_side_fields = false;
    for (def.fields) |fd| {
        if (fd.position == .side) {
            has_side_fields = true;
            break;
        }
    }

    if (has_side_fields) {
        w.writeAll(
            \\<div class="edit-sidebar-section">
            \\  <h3 class="edit-sidebar-title">Details</h3>
        ) catch {};

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
                const fw = field_buf.writer(allocator);
                fd.render(fw.any(), ctx) catch {};
                if (field_buf.items.len == 0) {
                    renderDefaultField(fw.any(), fd, ctx) catch {};
                }
                const field_html = field_buf.toOwnedSlice(allocator) catch "";
                const patched = injectFormAttr(allocator, field_html, "entry-form");
                w.writeAll(patched) catch {};
            }
        }

        w.writeAll("</div>") catch {};
    }

    if (opts.history_html.len > 0) {
        w.writeAll(opts.history_html) catch {};
    }

    _ = delete_url;
    if (opts.entry_id.len > 0) {
        w.print(
            \\<div class="edit-sidebar-section edit-sidebar-danger">
            \\  <form method="POST" action="/admin/action" onsubmit="return confirm('Delete this {s} permanently?')">
            \\    <input type="hidden" name="_csrf" value="{s}" />
            \\    <input type="hidden" name="action" value="content.delete" />
            \\    <input type="hidden" name="type" value="{s}" />
            \\    <input type="hidden" name="entry_id" value="{s}" />
            \\    <button type="submit" class="btn btn-danger btn-sm btn-full">Delete</button>
            \\  </form>
            \\</div>
        , .{ def.display_name, csrf_token, def.type_id, opts.entry_id }) catch {};
    }

    return buf.toOwnedSlice(allocator) catch "";
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
