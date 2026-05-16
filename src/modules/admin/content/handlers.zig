//! CRUD + lifecycle + autosave handlers. All `*For(def, ctx)` functions are
//! `pub` because they're invoked from content_actions.zig via the
//! `/admin/action` dispatcher.

const std = @import("std");
const admin = @import("admin_api");
const db_mod = @import("db");
const cms = @import("cms");
const csrf = @import("csrf");
const schema_registry = @import("schema_registry");
const auth_middleware = @import("auth_middleware");
const content_type_mod = @import("content_type");
const tpl = @import("tpl");
const views = @import("views");
const registry = @import("registry");
const gravatar = @import("gravatar");
const pagination = @import("pagination");
const pu = @import("plugin_utils");
const Context = @import("middleware").Context;

const authors = @import("authors.zig");
const parse = @import("parse.zig");
const render = @import("render.zig");
const editor_json = @import("editor_json.zig");
const presence_bridge = @import("presence_bridge.zig");
const _p = @import("_platform.zig");

const Allocator = std.mem.Allocator;
const Db = db_mod.Db;
const ContentTypeDef = content_type_mod.ContentTypeDef;
const ViewEntry = views.admin.content.list.Entry;
const RejectedField = parse.RejectedField;
const presence = _p.presence;
const redirect = pu.redirect;
const AuthorInfo = authors.AuthorInfo;

// Page id is hardcoded to avoid a circular import with the aggregator's
// `pub const page = admin.registerPage(...)`.
const PAGE_ID = "content";

/// Build the admin base URL for a given content type.
pub fn baseUrlFor(allocator: Allocator, def: *const ContentTypeDef) []const u8 {
    return std.fmt.allocPrint(allocator, "/admin/content/{s}", .{def.type_id}) catch "/admin/content";
}

pub fn listFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const base_path = baseUrlFor(ctx.allocator, def);
    const new_url = std.fmt.allocPrint(ctx.allocator, "{s}/new", .{base_path}) catch base_path;
    const new_label = std.fmt.allocPrint(ctx.allocator, "Add {s}", .{def.display_name}) catch def.display_name;
    const icon_str: []const u8 = def.icon orelse "bookmark";

    const author_filter: ?[]const u8 = if (pu.queryParam(ctx.query, "author")) |af| (if (af.len > 0) af else null) else null;
    const filtered_entry_ids: ?[]const []const u8 = if (author_filter) |af| blk: {
        const ids = authors.getEntryIdsByAuthor(ctx.allocator, db, af, def.type_id);
        break :blk if (ids.len > 0) ids else null;
    } else null;

    const total_count: u32 = if (author_filter != null) blk: {
        if (filtered_entry_ids) |ids| break :blk @intCast(ids.len) else break :blk 0;
    } else cms.query.countEntries(db, def.type_id, .{}) catch 0;
    const pag = pagination.Paginator.init(ctx.query, total_count, 20);

    const entries = cms.query.listEntries(ctx.allocator, db, def.type_id, .{
        .limit = pag.items_per_page,
        .offset = pag.offset(),
        .order_by = "updated_at",
        .order_dir = .desc,
        .entry_ids = filtered_entry_ids,
    }) catch {
        const content = tpl.render(views.admin.content.list.List, .{.{
            .page_title = def.display_name,
            .new_url = new_url,
            .new_label = new_label,
            .is_type_locked = true,
            .locked_type_label = def.display_name,
            .search_query = "",
            .search_action = base_path,
            .has_entries = false,
            .entries = &[_]ViewEntry{},
            .total_count = "0",
            .total_pages = @as(u32, 1),
            .prev_page_url = "",
            .next_page_url = "",
            .page_urls = &[_]views.admin.content.list.PageUrl{},
        }});
        ctx.html(admin.renderWithLayout(PAGE_ID, def.display_name, ctx, content, ""));
        return;
    };

    var entry_ids = ctx.allocator.alloc([]const u8, entries.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (entries, 0..) |entry, i| {
        entry_ids[i] = entry.id;
    }
    const all_authors = authors.resolveEntryAuthors(ctx.allocator, db, entry_ids);

    var view_entries = ctx.allocator.alloc(ViewEntry, entries.len) catch {
        ctx.html("Error allocating memory");
        return;
    };

    for (entries, 0..) |entry, i| {
        const author_list = authors.findAuthorsForEntry(all_authors, entry.id);
        const last_author: ?AuthorInfo = if (author_list.len > 0) author_list[author_list.len - 1] else null;
        const author_label: []const u8 = if (last_author) |a| a.label() else "Unknown";
        const avatar_url: []const u8 = if (last_author) |a|
            gravatar.url(a.email, 24).slice()
        else
            "";

        view_entries[i] = .{
            .id = entry.id,
            .name = if (entry.title.len > 0) entry.title else "(untitled)",
            .content_type_label = def.display_name,
            .content_type_icon = icon_str,
            .updated_relative = cms.formatRelativeTime(ctx.allocator, entry.updated_at) catch "Unknown",
            .author_name = author_label,
            .author_avatar_url = avatar_url,
            .status = entry.status,
            .edit_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_path, entry.id }) catch base_path,
        };
    }

    const base_url = if (author_filter) |af|
        std.fmt.allocPrint(ctx.allocator, "{s}?author={s}", .{ base_path, af }) catch base_path
    else
        base_path;
    const page_urls = pag.buildTruncatedPageUrls(ctx.allocator, base_url);
    const total_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{total_count}) catch "0";

    const SF = views.admin.content.list.SuggestedFilter;
    const suggested = [_]SF{
        .{ .label = "Created by me" },
        .{ .label = "Tags is one of" },
        .{ .label = "Taxonomy" },
        .{ .label = "Status is" },
        .{ .label = "Locale" },
    };

    const search_query = pu.queryParam(ctx.query, "q") orelse "";

    const TplPageUrl = views.admin.content.list.PageUrl;
    const tpl_page_urls = blk: {
        const buf = ctx.allocator.alloc(TplPageUrl, page_urls.items.len) catch break :blk &[_]TplPageUrl{};
        for (page_urls.items, 0..) |pu_item, i| {
            buf[i] = .{
                .page_num = pu_item.page_num,
                .url = pu_item.url,
                .is_current = pu_item.is_current,
                .is_ellipsis = pu_item.is_ellipsis,
            };
        }
        break :blk @as([]const TplPageUrl, buf);
    };

    const content = tpl.render(views.admin.content.list.List, .{.{
        .page_title = def.display_name,
        .new_url = new_url,
        .new_label = new_label,
        .is_type_locked = true,
        .locked_type_label = def.display_name,
        .search_query = search_query,
        .search_action = base_path,
        .suggested_filters = &suggested,
        .has_entries = view_entries.len > 0,
        .entries = view_entries,
        .total_count = total_count_str,
        .total_pages = pag.total_pages,
        .prev_page_url = page_urls.prev_url,
        .next_page_url = page_urls.next_url,
        .page_urls = tpl_page_urls,
    }});

    ctx.html(admin.renderWithLayout(PAGE_ID, def.display_name, ctx, content, ""));
}

pub fn newFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const data_json = render.defaultDataJson(ctx.allocator, def) catch "{}";
    defer if (data_json.len > 0 and !std.mem.eql(u8, data_json, "{}")) ctx.allocator.free(data_json);
    const author_id = auth_middleware.getUserId(ctx);

    var entry = cms.saveEntry(ctx.allocator, db, def.type_id, null, data_json, .{
        .author_id = author_id,
    }) catch {
        redirect(ctx, base_url);
        return;
    };
    defer entry.deinit(ctx.allocator);

    const edit_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry.id }) catch base_url;
    redirect(ctx, edit_url);
}

pub fn editFor(def: *const ContentTypeDef, ctx: *Context) !void {
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

    var entry = cms.query.getEntry(ctx.allocator, db, def.type_id, entry_id) catch {
        redirect(ctx, base_url);
        return;
    } orelse {
        return render.notFound(ctx);
    };
    defer entry.deinit(ctx.allocator);

    const csrf_token = csrf.ensureToken(ctx);
    const action_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry.id }) catch base_url;
    const delete_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/delete", .{ base_url, entry.id }) catch base_url;

    const published_data = cms.getPublishedData(ctx.allocator, db, entry.id) catch null;

    const current_user_id = auth_middleware.getUserId(ctx) orelse "";
    const field_editors_json = editor_json.buildFieldEditorsJson(ctx.allocator, db, entry.id, current_user_id) catch "{}";

    const release_field_info = cms.getEntryPendingReleaseFields(ctx.allocator, db, entry.id) catch &.{};
    const fields_in_releases_json = editor_json.buildFieldsInReleasesJson(ctx.allocator, release_field_info) catch "[]";

    const form_html = render.renderFieldsHtml(def, ctx.allocator, &entry.data, csrf_token, action_url, .main, .{
        .entry_id = entry.id,
        .status = entry.status,
        .published_data = published_data,
        .fields_in_releases = fields_in_releases_json,
        .field_editors = field_editors_json,
    });

    const history_html = editor_json.buildVersionHistoryHtml(ctx.allocator, db, entry.id, base_url) catch "";

    const pending_releases = cms.listPendingReleases(ctx.allocator, db) catch &.{};
    const entry_rel_ids = cms.getEntryPendingReleaseIds(ctx.allocator, db, entry.id) catch &.{};

    const ReleaseViewOption = struct {
        id: []const u8,
        name: []const u8,
        is_added: bool,
    };
    const release_opts = ctx.allocator.alloc(ReleaseViewOption, pending_releases.len) catch
        @as([]ReleaseViewOption, &.{});
    for (pending_releases, 0..) |rel, i| {
        var added = false;
        for (entry_rel_ids) |rid| {
            if (std.mem.eql(u8, rid, rel.id)) {
                added = true;
                break;
            }
        }
        release_opts[i] = .{
            .id = rel.id,
            .name = rel.name,
            .is_added = added,
        };
    }

    const release_html = tpl.render(views.admin.posts.release_menu.ReleaseMenu, .{.{
        .releases = release_opts,
    }});

    const sidebar_html = render.renderSidebarHtml(def, ctx.allocator, &entry.data, csrf_token, delete_url, entry.status, .{
        .entry_id = entry.id,
        .history_html = history_html,
        .release_html = release_html,
        .base_url = base_url,
    });

    const display_title = if (entry.title.len > 0) entry.title else "Untitled";
    ctx.html(registry.renderEditPage(root.page, ctx, display_title, form_html, .{
        .back_url = base_url,
        .back_label = def.display_name,
        .sidebar = sidebar_html,
    }));
}

pub fn createFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const data_json = parse.parseFormDataJson(ctx.allocator, def, ctx, null) catch "{}";
    defer if (data_json.len > 2) ctx.allocator.free(data_json);
    const author_id = auth_middleware.getUserId(ctx);

    var saved = cms.saveEntry(ctx.allocator, db, def.type_id, null, data_json, .{
        .author_id = author_id,
    }) catch {
        redirect(ctx, base_url);
        return;
    };
    saved.deinit(ctx.allocator);

    redirect(ctx, base_url);
}

pub fn updateFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    const action = ctx.formValue("action") orelse "";
    const fields_json_raw = ctx.formValue("fields") orelse "";
    const fields_json: ?[]const u8 = if (fields_json_raw.len > 0) fields_json_raw else null;
    const author_id = auth_middleware.getUserId(ctx);

    var entry = cms.query.getEntry(ctx.allocator, db, def.type_id, entry_id) catch {
        redirect(ctx, base_url);
        return;
    } orelse {
        redirect(ctx, base_url);
        return;
    };
    defer entry.deinit(ctx.allocator);

    const owners = parse.getFieldOwnership(ctx.allocator, db, entry_id) catch null;

    var rejected: std.ArrayListUnmanaged(RejectedField) = .{};
    var newly_acquired: std.ArrayListUnmanaged([]const u8) = .{};
    const data_json = parse.parseFormDataWithValidation(ctx.allocator, def, ctx, &entry.data, author_id, entry_id, owners, &rejected, &newly_acquired) catch "{}";
    defer if (data_json.len > 2) ctx.allocator.free(data_json);

    const status = ctx.formValue("status") orelse entry.status;

    var saved = cms.saveEntry(ctx.allocator, db, def.type_id, entry_id, data_json, .{
        .author_id = author_id,
        .status = status,
    }) catch {
        redirect(ctx, base_url);
        return;
    };
    saved.deinit(ctx.allocator);

    if (newly_acquired.items.len > 0) {
        const user_email = auth_middleware.getUserEmail(ctx) orelse "";
        const user_name = presence_bridge.getUserDisplayName(ctx.allocator, db, author_id) orelse user_email;
        const avatar = gravatar.url(user_email, 24);
        for (newly_acquired.items) |field_name| {
            presence.notifyLockAcquired(entry_id, field_name, author_id orelse "", user_name, avatar.slice());
        }
    }

    if (std.mem.eql(u8, action, "add_to_release")) {
        const release_id = ctx.formValue("release_id") orelse "";
        if (release_id.len > 0) {
            cms.addToRelease(db, release_id, entry_id, fields_json) catch {};
        }
        presence_bridge.broadcastReleaseUpdate(ctx.allocator, db, entry_id);
        const url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;
        redirect(ctx, url);
        return;
    }

    if (std.mem.eql(u8, action, "create_release")) {
        const release_name = ctx.formValue("release_name") orelse "";
        if (release_name.len > 0) {
            const rel_id = cms.createPendingRelease(db, release_name, author_id) catch {
                const url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;
                redirect(ctx, url);
                return;
            };
            cms.addToRelease(db, &rel_id, entry_id, fields_json) catch {};
        }
        presence_bridge.broadcastReleaseUpdate(ctx.allocator, db, entry_id);
        const url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;
        redirect(ctx, url);
        return;
    }

    if (std.mem.eql(u8, status, "published")) {
        cms.publishEntry(ctx.allocator, db, entry_id, author_id, fields_json) catch {};
        presence_bridge.notifyPublishedFieldsReleased(ctx.allocator, db, entry_id, fields_json);
        presence_bridge.broadcastPublishedState(ctx.allocator, db, entry_id);
    }

    const edit_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;
    redirect(ctx, edit_url);
}

pub fn deleteFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    cms.deleteEntry(db, entry_id) catch {};

    redirect(ctx, base_url);
}

pub fn publishFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);
    const fields_json_raw = ctx.formValue("fields") orelse "";
    const fields_json: ?[]const u8 = if (fields_json_raw.len > 0) fields_json_raw else null;

    cms.publishEntry(ctx.allocator, db, entry_id, author_id, fields_json) catch {};
    presence_bridge.notifyPublishedFieldsReleased(ctx.allocator, db, entry_id, fields_json);
    presence_bridge.broadcastPublishedState(ctx.allocator, db, entry_id);

    redirect(ctx, base_url);
}

pub fn unpublishFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    cms.unpublishEntry(db, entry_id) catch {};

    redirect(ctx, base_url);
}

pub fn discardFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const entry_id = ctx.param("id") orelse {
        redirect(ctx, base_url);
        return;
    };

    cms.discardToPublished(db, entry_id) catch {};

    const url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;
    redirect(ctx, url);
}

pub fn autosaveCreateFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"not authenticated\"}");
        return;
    };

    const data_json = parse.parseFormDataJson(ctx.allocator, def, ctx, null) catch "{}";
    defer if (data_json.len > 2) ctx.allocator.free(data_json);
    const author_id = auth_middleware.getUserId(ctx);

    var entry = cms.saveEntry(ctx.allocator, db, def.type_id, null, data_json, .{
        .author_id = author_id,
        .status = "draft",
    }) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"save failed\"}");
        return;
    };
    defer entry.deinit(ctx.allocator);

    const json = std.fmt.allocPrint(ctx.allocator, "{{\"entry_id\":\"{s}\",\"status\":\"draft\",\"saved\":true}}", .{entry.id}) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"format failed\"}");
        return;
    };

    ctx.response.setHeader("Content-Type", "application/json");
    ctx.response.setBody(json);
}

pub fn autosaveUpdateFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"not authenticated\"}");
        return;
    };

    const entry_id = ctx.param("id") orelse {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"missing id\"}");
        return;
    };

    var entry = cms.query.getEntry(ctx.allocator, db, def.type_id, entry_id) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"entry not found\"}");
        return;
    } orelse {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"entry not found\"}");
        return;
    };
    defer entry.deinit(ctx.allocator);

    const author_id = auth_middleware.getUserId(ctx);

    const owners = parse.getFieldOwnership(ctx.allocator, db, entry_id) catch null;

    var rejected: std.ArrayListUnmanaged(RejectedField) = .{};
    var newly_acquired: std.ArrayListUnmanaged([]const u8) = .{};
    const data_json = parse.parseFormDataWithValidation(ctx.allocator, def, ctx, &entry.data, author_id, entry_id, owners, &rejected, &newly_acquired) catch "{}";
    defer if (data_json.len > 2) ctx.allocator.free(data_json);

    const status: []const u8 = if (entry.isDraft()) "draft" else "changed";

    var saved = cms.saveEntry(ctx.allocator, db, def.type_id, entry_id, data_json, .{
        .author_id = author_id,
        .autosave = true,
        .status = status,
    }) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"save failed\"}");
        return;
    };
    saved.deinit(ctx.allocator);

    if (newly_acquired.items.len > 0) {
        const user_email = auth_middleware.getUserEmail(ctx) orelse "";
        const user_name = presence_bridge.getUserDisplayName(ctx.allocator, db, author_id) orelse user_email;
        const avatar = gravatar.url(user_email, 24);
        for (newly_acquired.items) |field_name| {
            presence.notifyLockAcquired(entry_id, field_name, author_id orelse "", user_name, avatar.slice());
        }
    }

    if (owners != null) {
        const new_owners = parse.getFieldOwnership(ctx.allocator, db, entry_id) catch null;
        var released_fields: std.ArrayListUnmanaged([]const u8) = .{};
        var iter = owners.?.iterator();
        while (iter.next()) |kv| {
            const still_owned = if (new_owners) |new_own| new_own.contains(kv.key_ptr.*) else false;
            if (!still_owned) {
                released_fields.append(ctx.allocator, kv.key_ptr.*) catch {};
            }
        }
        if (released_fields.items.len > 0) {
            presence.notifyLocksReleased(entry_id, released_fields.items);
        }
    }

    const json = parse.buildAutosaveResponse(ctx.allocator, status, rejected.items) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"format failed\"}");
        return;
    };

    ctx.response.setHeader("Content-Type", "application/json");
    ctx.response.setBody(json);
}

/// Dispatchers (called from the page's route table) — resolve type id and
/// delegate to the corresponding `*For(def, ctx)` impl.
pub fn handleList(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return render.notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return render.notFound(ctx);
    return listFor(def, ctx);
}

pub fn handleNew(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return render.notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return render.notFound(ctx);
    return newFor(def, ctx);
}

pub fn handleEdit(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return render.notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return render.notFound(ctx);
    return editFor(def, ctx);
}

pub fn handleAll(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const defs = schema_registry.all();
    if (defs.len == 0) {
        const content = tpl.render(views.admin.content.all.AllContent, .{.{
            .has_types = false,
            .types = &[_]views.admin.content.all.TypeCard{},
        }});
        ctx.html(admin.renderWithLayout(PAGE_ID, "All Content", ctx, content, ""));
        return;
    }

    var cards = ctx.allocator.alloc(views.admin.content.all.TypeCard, defs.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (defs, 0..) |def, i| {
        const count = cms.query.countEntries(db, def.type_id, .{}) catch 0;
        const count_label = std.fmt.allocPrint(ctx.allocator, "{d} entries", .{count}) catch "0 entries";
        const list_url = std.fmt.allocPrint(ctx.allocator, "/admin/content/{s}", .{def.type_id}) catch "/admin/content";
        cards[i] = .{
            .type_id = def.type_id,
            .display_name = def.display_name,
            .display_name_plural = def.display_name_plural,
            .icon = def.icon orelse "bookmark",
            .list_url = list_url,
            .entry_count_label = count_label,
        };
    }

    const content = tpl.render(views.admin.content.all.AllContent, .{.{
        .has_types = true,
        .types = cards,
    }});
    ctx.html(admin.renderWithLayout(PAGE_ID, "All Content", ctx, content, ""));
}
