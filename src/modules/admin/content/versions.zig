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

    // Old-version column: gravatar avatar + optional "Published by " prefix.
    var old_avatar_url: ?[]const u8 = null;
    var old_avatar_title: []const u8 = "";
    if (version.author_email) |email| {
        old_avatar_url = ctx.allocator.dupe(u8, gravatar.url(email, 24).slice()) catch null;
        old_avatar_title = version.authorLabel();
    }
    const old_prefix: []const u8 = if (std.mem.eql(u8, version.version_type, "published")) "Published by " else "";

    // Current-version column: collaborator avatars (pre-rendered) + title text.
    var current_avatars_html: []const u8 = "";
    if (current_data) |cd| {
        var ab: std.ArrayList(u8) = .{};
        editor_json.writeCollaboratorAvatars(ab.writer(ctx.allocator).any(), ctx.allocator, cd.collaborators, cd.author_email, cd.authorLabel()) catch {};
        ab.append(ctx.allocator, ' ') catch {};
        current_avatars_html = ab.toOwnedSlice(ctx.allocator) catch "";
    }
    var current_title: []const u8 = "Current version";
    if (current_data) |cd| {
        if (std.mem.eql(u8, cd.version_type, "published")) {
            current_title = std.fmt.allocPrint(ctx.allocator, "Published by {s}", .{cd.authorLabel()}) catch "Published by";
        }
    }

    const changed_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{changed_count}) catch "0";

    // Per-field radio rows.
    const Row = struct {
        key: []const u8,
        changed: bool,
        changed_by: ?[]const u8,
        old_value: []const u8,
        new_value: []const u8,
        radio_name: []const u8,
    };
    var rows: std.ArrayList(Row) = .{};
    for (fields) |f| {
        const radio_name = std.fmt.allocPrint(ctx.allocator, "field_{s}", .{f.key}) catch "field_";
        rows.append(ctx.allocator, .{
            .key = f.key,
            .changed = f.changed,
            .changed_by = f.changed_by,
            .old_value = f.old_value,
            .new_value = f.new_value,
            .radio_name = radio_name,
        }) catch {};
    }

    var buf: std.ArrayList(u8) = .{};
    views.components.version_compare.VersionCompare(buf.writer(ctx.allocator).any(), .{
        .csrf_token = csrf_token,
        .type_id = def.type_id,
        .entry_id = entry_id,
        .version_id = version_id,
        .old_avatar_url = old_avatar_url,
        .old_avatar_title = old_avatar_title,
        .old_prefix = old_prefix,
        .author_str = author_str,
        .time_str = time_str,
        .current_avatars_html = current_avatars_html,
        .current_title = current_title,
        .changed_count = changed_count_str,
        .back_url = back_url,
        .entries = rows.items,
    }) catch {};
    const preview_content = buf.toOwnedSlice(ctx.allocator) catch "";

    const history_html = editor_json.buildVersionHistoryHtml(ctx.allocator, db, entry_id, base_url) catch "";
    const sidebar_html = blk: {
        var sb: std.ArrayList(u8) = .{};
        views.components.version_sidebar.VersionSidebar(sb.writer(ctx.allocator).any(), .{
            .back_url = back_url,
            .history_html = history_html,
        }) catch {};
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
    views.components.version_flow.VersionFlow(buf.writer(ctx.allocator).any(), .{
        .author_str = author_str,
        .time_str = time_str,
        .version_type = version.version_type,
        .is_current = version.is_current,
        .compare_url = compare_url,
        .flow_html = flow_html,
    }) catch {};
    const flow_content = buf.toOwnedSlice(ctx.allocator) catch "";

    const history_html = editor_json.buildVersionHistoryHtml(ctx.allocator, db, entry_id, base_url) catch "";
    const sidebar_html = blk: {
        var sb: std.ArrayList(u8) = .{};
        views.components.version_sidebar.VersionSidebar(sb.writer(ctx.allocator).any(), .{
            .back_url = back_url,
            .history_html = history_html,
        }) catch {};
        break :blk sb.toOwnedSlice(ctx.allocator) catch "";
    };

    ctx.html(registry.renderEditPage(root.page, ctx, entry_title, flow_content, .{
        .back_url = back_url,
        .back_label = "Back",
        .sidebar = sidebar_html,
    }));
    _ = tpl;
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
