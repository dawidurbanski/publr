//! Version preview, compare, flow audit, and restore handlers.

const std = @import("std");
const db_mod = @import("db");
const cms = @import("cms");
const csrf = @import("csrf");
const auth_middleware = @import("auth_middleware");
const content_type_mod = @import("content_type");
const tpl = @import("tpl");
const views = @import("views");
const registry = @import("registry");
const gravatar = @import("gravatar");
const pu = @import("plugin_utils");
const Context = @import("middleware").Context;

const editor_json = @import("editor_json.zig");
const render = @import("render.zig");

const Allocator = std.mem.Allocator;
const Db = db_mod.Db;
const ContentTypeDef = content_type_mod.ContentTypeDef;
const redirect = pu.redirect;

fn baseUrlFor(allocator: Allocator, def: *const ContentTypeDef) []const u8 {
    return std.fmt.allocPrint(allocator, "/admin/content/{s}", .{def.type_id}) catch "/admin/content";
}

pub fn handleVersionPreview(ctx: *Context) !void {
    const schema_registry = @import("schema_registry");
    const type_id = ctx.params.get("type") orelse return render.notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return render.notFound(ctx);
    return versionPreviewRedirectFor(def, ctx);
}

pub fn handleVersionCompare(ctx: *Context) !void {
    const schema_registry = @import("schema_registry");
    const type_id = ctx.params.get("type") orelse return render.notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return render.notFound(ctx);
    return versionCompareFor(def, ctx);
}

pub fn handleVersionFlow(ctx: *Context) !void {
    const schema_registry = @import("schema_registry");
    const type_id = ctx.params.get("type") orelse return render.notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return render.notFound(ctx);
    return versionFlowFor(def, ctx);
}

pub fn versionPreviewRedirectFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };
    const version_id = ctx.param("vid") orelse {
        redirect(ctx, base_url);
        return;
    };
    const compare_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/versions/{s}/compare", .{ base_url, entry_id, version_id }) catch base_url;
    redirect(ctx, compare_url);
}

pub fn versionCompareFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const root = @import("main.zig");
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    const entry_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;

    const version_id = ctx.param("vid") orelse {
        redirect(ctx, entry_url);
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);

    const version = cms.getVersion(ctx.allocator, db, version_id) catch {
        redirect(ctx, entry_url);
        return;
    } orelse {
        redirect(ctx, entry_url);
        return;
    };
    if (version.is_current) {
        const flow_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/versions/{s}/flow", .{ base_url, entry_id, version_id }) catch entry_url;
        redirect(ctx, flow_url);
        return;
    }

    const back_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;

    const entry_title = blk: {
        var t_stmt = try db.prepare("SELECT title FROM content_entries WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, entry_id);
        if (!try t_stmt.step()) break :blk "Untitled";
        break :blk try ctx.allocator.dupe(u8, t_stmt.columnText(0) orelse "Untitled");
    };

    const current_version_id = blk: {
        var cur_stmt = try db.prepare("SELECT current_version_id FROM content_entries WHERE id = ?1");
        defer cur_stmt.deinit();
        try cur_stmt.bindText(1, entry_id);
        _ = try cur_stmt.step();
        break :blk try ctx.allocator.dupe(u8, cur_stmt.columnText(0) orelse "");
    };
    const current_data = cms.getVersion(ctx.allocator, db, current_version_id) catch null;
    const current_json = if (current_data) |cd| cd.data else "{}";

    var empty_fields = [_]cms.FieldComparison{};
    const fields = cms.compareVersionFields(ctx.allocator, version.data, current_json) catch &empty_fields;
    cms.populateFieldAuthors(ctx.allocator, db, fields, current_version_id, version_id);

    var changed_count: u32 = 0;
    for (fields) |f| {
        if (f.changed) changed_count += 1;
    }

    const time_str = cms.formatRelativeTime(ctx.allocator, version.created_at) catch "Unknown";
    const author_str = version.authorLabel();
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(ctx.allocator);

    try w.writeAll("<form method=\"POST\" action=\"/admin/action\" class=\"version-compare\">");
    try w.writeAll("<input type=\"hidden\" name=\"_csrf\" value=\"");
    try w.writeAll(csrf_token);
    try w.writeAll("\"/>");
    try w.writeAll("<input type=\"hidden\" name=\"action\" value=\"content.restore\"/>");
    try w.writeAll("<input type=\"hidden\" name=\"type\" value=\"");
    try w.writeAll(def.type_id);
    try w.writeAll("\"/>");
    try w.writeAll("<input type=\"hidden\" name=\"entry_id\" value=\"");
    try w.writeAll(entry_id);
    try w.writeAll("\"/>");
    try w.writeAll("<input type=\"hidden\" name=\"version_id\" value=\"");
    try w.writeAll(version_id);
    try w.writeAll("\"/>");
    try w.writeAll("<input type=\"hidden\" name=\"_partial\" value=\"1\"/>");

    try w.writeAll(
        \\<div class="version-compare-header">
        \\  <div class="version-compare-col-old">
        \\    <span class="version-compare-col-title">
    );
    if (version.author_email) |email| {
        const old_avatar = gravatar.url(email, 24);
        try w.writeAll("<img src=\"");
        try w.writeAll(old_avatar.slice());
        try w.writeAll("\" alt=\"\" title=\"");
        try cms.writeEscaped(w, version.authorLabel());
        try w.writeAll("\" class=\"version-avatar\" /> ");
    }
    if (std.mem.eql(u8, version.version_type, "published")) {
        try w.writeAll("Published by ");
    }
    try w.writeAll(author_str);
    try w.writeAll(" &middot; ");
    try w.writeAll(time_str);
    try w.writeAll(
        \\</span>
        \\    <a href="#" id="select-all-old" class="version-compare-select-all">Select all from this version</a>
        \\  </div>
        \\  <div class="version-compare-col-current">
        \\    <span class="version-compare-col-title">
    );
    if (current_data) |cd| {
        try editor_json.writeCollaboratorAvatars(w, ctx.allocator, cd.collaborators, cd.author_email, cd.authorLabel());
        try w.writeByte(' ');
    }
    if (current_data) |cd| {
        if (std.mem.eql(u8, cd.version_type, "published")) {
            try w.writeAll("Published by ");
            try cms.writeEscaped(w, cd.authorLabel());
        } else {
            try w.writeAll("Current version");
        }
    } else {
        try w.writeAll("Current version");
    }
    try w.writeAll(
        \\</span>
        \\  </div>
        \\</div>
    );

    try w.writeAll(
        \\<div class="version-compare-toolbar">
        \\  <label class="version-compare-toggle">
        \\    <input type="checkbox" id="show-diff-only" />
        \\    Show only differences (
    );
    try w.print("{d}", .{changed_count});
    try w.writeAll(
        \\)
        \\  </label>
        \\</div>
    );

    try w.writeAll("<div class=\"version-compare-fields\" id=\"version-compare-fields\">");

    for (fields) |f| {
        const status_attr: []const u8 = if (f.changed) "changed" else "unchanged";

        try w.writeAll("<div class=\"version-compare-row\" data-field-status=\"");
        try w.writeAll(status_attr);
        try w.writeAll("\">");

        try w.writeAll("<div class=\"version-compare-label\">");
        try cms.writeEscaped(w, f.key);
        if (f.changed) {
            try w.writeAll(" <span class=\"version-compare-badge\">changed</span>");
            if (f.changed_by) |email| {
                try w.writeAll(" <span class=\"version-compare-author\">by ");
                try cms.writeEscaped(w, email);
                try w.writeAll("</span>");
            }
        }
        try w.writeAll("</div>");

        try w.writeAll("<div class=\"version-compare-cell version-compare-cell-old\">");
        try w.writeAll("<label class=\"version-compare-radio\">");
        try w.writeAll("<input type=\"radio\" name=\"field_");
        try cms.writeEscaped(w, f.key);
        try w.writeAll("\" value=\"old\"");
        if (!f.changed) try w.writeAll(" disabled");
        try w.writeAll(" />");
        try w.writeAll("<span class=\"version-compare-value");
        if (f.changed) try w.writeAll(" version-compare-value-old");
        try w.writeAll("\">");
        if (f.old_value.len > 0) {
            try cms.writeEscaped(w, f.old_value);
        } else {
            try w.writeAll("<em class=\"version-compare-empty\">(empty)</em>");
        }
        try w.writeAll("</span></label></div>");

        try w.writeAll("<div class=\"version-compare-cell version-compare-cell-current\">");
        try w.writeAll("<label class=\"version-compare-radio\">");
        try w.writeAll("<input type=\"radio\" name=\"field_");
        try cms.writeEscaped(w, f.key);
        try w.writeAll("\" value=\"current\" checked");
        if (!f.changed) try w.writeAll(" disabled");
        try w.writeAll(" />");
        try w.writeAll("<span class=\"version-compare-value");
        if (f.changed) try w.writeAll(" version-compare-value-current");
        try w.writeAll("\">");
        if (f.new_value.len > 0) {
            try cms.writeEscaped(w, f.new_value);
        } else {
            try w.writeAll("<em class=\"version-compare-empty\">(empty)</em>");
        }
        try w.writeAll("</span></label></div>");

        try w.writeAll("</div>");
    }

    try w.writeAll("</div>");

    try w.writeAll(
        \\<div class="version-compare-actions">
        \\  <a href="
    );
    try w.writeAll(back_url);
    try w.writeAll(
        \\" class="btn">Cancel</a>
        \\  <button type="submit" class="btn btn-primary" id="apply-changes-btn" disabled>Apply changes</button>
        \\</div>
        \\</form>
    );

    const preview_content = buf.toOwnedSlice(ctx.allocator) catch "";

    const history_html = editor_json.buildVersionHistoryHtml(ctx.allocator, db, entry_id, base_url) catch "";
    const sidebar_html = blk: {
        var sb: std.ArrayList(u8) = .{};
        const sw = sb.writer(ctx.allocator);
        try sw.writeAll(
            \\<div class="edit-sidebar-section">
            \\  <div class="edit-sidebar-actions">
            \\    <a href="
        );
        try sw.writeAll(back_url);
        try sw.writeAll(
            \\" class="btn btn-full">Back to Editor</a>
            \\  </div>
            \\</div>
        );
        try sw.writeAll(history_html);
        break :blk sb.toOwnedSlice(ctx.allocator) catch "";
    };

    ctx.html(registry.renderEditPage(root.page, ctx, entry_title, preview_content, .{
        .back_url = back_url,
        .back_label = "Back",
        .sidebar = sidebar_html,
    }));
}

pub fn versionFlowFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const root = @import("main.zig");
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    const entry_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;

    const version_id = ctx.param("vid") orelse {
        redirect(ctx, entry_url);
        return;
    };

    const version = cms.getVersion(ctx.allocator, db, version_id) catch {
        redirect(ctx, entry_url);
        return;
    } orelse {
        redirect(ctx, entry_url);
        return;
    };

    const back_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;
    const compare_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/versions/{s}/compare", .{ base_url, entry_id, version_id }) catch back_url;

    const entry_title = blk: {
        var t_stmt = try db.prepare("SELECT title FROM content_entries WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, entry_id);
        if (!try t_stmt.step()) break :blk "Untitled";
        break :blk try ctx.allocator.dupe(u8, t_stmt.columnText(0) orelse "Untitled");
    };

    const time_opt = cms.formatRelativeTime(ctx.allocator, version.created_at) catch null;
    defer if (time_opt) |t| ctx.allocator.free(t);
    const time_str = time_opt orelse "Unknown";
    const author_str = version.authorLabel();

    const flow_html_opt = editor_json.buildVersionFlowAuditHtml(ctx.allocator, db, entry_id, version_id) catch null;
    defer if (flow_html_opt) |fh| ctx.allocator.free(fh);
    const flow_html = flow_html_opt orelse "";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(ctx.allocator);
    try w.writeAll(
        \\<div class="version-flow-view">
        \\  <div class="version-preview-header">
        \\    <div class="version-preview-meta">
        \\      <span class="version-preview-author">
    );
    try cms.writeEscaped(w, author_str);
    try w.writeAll("</span><span class=\"version-preview-time\">");
    try cms.writeEscaped(w, time_str);
    try w.writeAll(" · ");
    try cms.writeEscaped(w, version.version_type);
    try w.writeAll(
        \\</span>
        \\    </div>
    );
    if (version.is_current) {
        try w.writeAll("<span class=\"badge-current\">Current version</span>");
    } else {
        try w.writeAll("<a href=\"");
        try w.writeAll(compare_url);
        try w.writeAll("\" class=\"btn btn-sm\">Compare</a>");
    }
    try w.writeAll(
        \\  </div>
        \\  <h3 class="version-preview-subtitle">Flow history</h3>
    );
    if (flow_html.len > 0) {
        try w.writeAll(flow_html);
    } else {
        try w.writeAll("<p class=\"diff-error\">No flow events recorded for this version.</p>");
    }
    try w.writeAll("</div>");
    const flow_content = buf.toOwnedSlice(ctx.allocator) catch "";

    const history_html = editor_json.buildVersionHistoryHtml(ctx.allocator, db, entry_id, base_url) catch "";
    const sidebar_html = blk: {
        var sb: std.ArrayList(u8) = .{};
        const sw = sb.writer(ctx.allocator);
        try sw.writeAll(
            \\<div class="edit-sidebar-section">
            \\  <div class="edit-sidebar-actions">
            \\    <a href="
        );
        try sw.writeAll(back_url);
        try sw.writeAll(
            \\" class="btn btn-full">Back to Editor</a>
            \\  </div>
            \\</div>
        );
        try sw.writeAll(history_html);
        break :blk sb.toOwnedSlice(ctx.allocator) catch "";
    };

    ctx.html(registry.renderEditPage(root.page, ctx, entry_title, flow_content, .{
        .back_url = back_url,
        .back_label = "Back",
        .sidebar = sidebar_html,
    }));
    _ = tpl;
    _ = views;
}

pub fn restoreFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    const version_id = ctx.param("vid") orelse {
        redirect(ctx, base_url);
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);

    const edit_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;

    const is_partial = ctx.formValue("_partial") != null;

    if (is_partial) {
        const version = cms.getVersion(ctx.allocator, db, version_id) catch {
            redirect(ctx, edit_url);
            return;
        } orelse {
            redirect(ctx, edit_url);
            return;
        };

        const current_data_json = blk: {
            const current_vid = cv_blk: {
                var cur_stmt = try db.prepare("SELECT current_version_id FROM content_entries WHERE id = ?1");
                defer cur_stmt.deinit();
                try cur_stmt.bindText(1, entry_id);
                if (!try cur_stmt.step()) break :cv_blk null;
                break :cv_blk if (cur_stmt.columnText(0)) |t| try ctx.allocator.dupe(u8, t) else null;
            };
            if (current_vid) |cvid| {
                const cur_ver = cms.getVersion(ctx.allocator, db, cvid) catch null;
                if (cur_ver) |cv| break :blk cv.data;
            }
            break :blk "{}";
        };

        const old_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, version.data, .{}) catch {
            redirect(ctx, edit_url);
            return;
        };
        defer old_parsed.deinit();

        const cur_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, current_data_json, .{}) catch {
            redirect(ctx, edit_url);
            return;
        };
        defer cur_parsed.deinit();

        const old_obj = if (old_parsed.value == .object) old_parsed.value.object else {
            redirect(ctx, edit_url);
            return;
        };
        const cur_obj = if (cur_parsed.value == .object) cur_parsed.value.object else {
            redirect(ctx, edit_url);
            return;
        };

        var merged = std.json.ObjectMap.init(ctx.allocator);
        var has_old_selection = false;

        var cur_it = cur_obj.iterator();
        while (cur_it.next()) |entry| {
            const key = entry.key_ptr.*;
            const param_name = std.fmt.allocPrint(ctx.allocator, "field_{s}", .{key}) catch continue;
            const choice = ctx.formValue(param_name) orelse "current";

            if (std.mem.eql(u8, choice, "old")) {
                has_old_selection = true;
                if (old_obj.get(key)) |old_val| {
                    try merged.put(key, old_val);
                } else {
                    try merged.put(key, entry.value_ptr.*);
                }
            } else {
                try merged.put(key, entry.value_ptr.*);
            }
        }

        var old_it = old_obj.iterator();
        while (old_it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!cur_obj.contains(key)) {
                const param_name = std.fmt.allocPrint(ctx.allocator, "field_{s}", .{key}) catch continue;
                const choice = ctx.formValue(param_name) orelse "current";
                if (std.mem.eql(u8, choice, "old")) {
                    has_old_selection = true;
                    try merged.put(key, entry.value_ptr.*);
                }
            }
        }

        if (!has_old_selection) {
            redirect(ctx, edit_url);
            return;
        }

        const merged_value = std.json.Value{ .object = merged };
        const merged_json = std.json.Stringify.valueAlloc(ctx.allocator, merged_value, .{}) catch {
            redirect(ctx, edit_url);
            return;
        };

        cms.restoreVersionWithData(db, entry_id, merged_json, author_id) catch {};
    } else {
        cms.restoreVersion(ctx.allocator, db, entry_id, version_id, author_id) catch {};
    }

    redirect(ctx, edit_url);
}
