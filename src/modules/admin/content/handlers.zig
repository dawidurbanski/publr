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
const editors = @import("editors");

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
        ctx.html(admin.renderWithLayoutTyped(PAGE_ID, def.display_name, ctx, content, "", def.type_id, ""));
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

    ctx.html(admin.renderWithLayoutTyped(PAGE_ID, def.display_name, ctx, content, "", def.type_id, ""));
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
    // Non-form editors dispatch through the editor registry. The "form"
    // editor keeps the existing per-field rendering path inline below —
    // task-03 leaves the form path hardcoded since no non-form content
    // type exists yet. Task-05+ will register Gutenberg via the registry.
    if (!std.mem.eql(u8, def.editor, "form")) {
        return editForViaRegistry(def, ctx);
    }

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
    const icon_str = def.icon orelse "bookmark";
    const icon_enum: registry.IconName = std.meta.stringToEnum(registry.IconName, icon_str) orelse .bookmark;
    ctx.html(registry.renderEditPage(root.page, ctx, display_title, form_html, .{
        .back_url = base_url,
        .back_label = def.display_name,
        .sidebar = sidebar_html,
        .content_type_label = def.display_name,
        .content_type_url = base_url,
        .content_type_icon = icon_enum,
    }));
}

/// Edit-page dispatch for non-form editors. Looks up `def.editor` in the
/// registry, calls the editor's `bootstrap` to produce the main-pane HTML,
/// and wraps it in admin chrome including the same sidebar (publish/discard
/// buttons, sidebar fields, version history, releases) as the form editor.
/// Unknown editor id → 404.
fn editForViaRegistry(def: *const ContentTypeDef, ctx: *Context) !void {
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

    const editor = editors.get(def.editor) orelse {
        // Unknown editor id declared on the content type. Surface a 404 —
        // the schema-side validation should be tightened later to fail at
        // build time, but for v0 a clear runtime error is enough.
        return render.notFound(ctx);
    };

    // Mirror the same chrome setup the form editor uses so the sidebar
    // (publish/discard/sidebar-fields/history/releases) renders identically.
    // The only thing that changes is the main pane — editor's bootstrap.
    const csrf_token = csrf.ensureToken(ctx);
    const delete_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/delete", .{ base_url, entry.id }) catch base_url;

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

    // Bootstrap writes the editor's main-pane HTML — must produce a form
    // with id="entry-form" and the same hidden inputs the form path emits,
    // so the sidebar's `form="entry-form"` buttons (publish/discard) work.
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(ctx.allocator);
    try editor.bootstrap(
        .{ .def = def, .ctx = ctx, .entry_id = entry.id },
        buf.writer(ctx.allocator).any(),
    );

    const display_title = if (entry.title.len > 0) entry.title else "Untitled";
    const icon_str = def.icon orelse "bookmark";
    const icon_enum: registry.IconName = std.meta.stringToEnum(registry.IconName, icon_str) orelse .bookmark;
    ctx.html(registry.renderEditPage(root.page, ctx, display_title, buf.items, .{
        .back_url = base_url,
        .back_label = def.display_name,
        .sidebar = sidebar_html,
        .content_type_label = def.display_name,
        .content_type_url = base_url,
        .content_type_icon = icon_enum,
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
    const base_path: []const u8 = "/admin/content";

    // ── Filter parsing ──────────────────────────────────────────────────
    const type_filter: ?*const ContentTypeDef = blk: {
        const raw = pu.queryParam(ctx.query, "type") orelse break :blk null;
        if (raw.len == 0) break :blk null;
        break :blk schema_registry.findById(raw);
    };
    const me_id = auth_middleware.getUserId(ctx);
    const recent = pu.queryParam(ctx.query, "recent") != null;
    const created_by_me = blk: {
        const v = pu.queryParam(ctx.query, "author") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "me");
    };
    const updated_by_me = blk: {
        const v = pu.queryParam(ctx.query, "editor") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "me");
    };
    const status_filter: ?[]const u8 = blk: {
        const v = pu.queryParam(ctx.query, "status") orelse break :blk null;
        if (v.len == 0) break :blk null;
        break :blk v;
    };

    // Active sidebar view — first match wins.
    const active_content_view: []const u8 = blk: {
        if (recent) break :blk "recent";
        if (created_by_me) break :blk "created_by_me";
        if (updated_by_me) break :blk "updated_by_me";
        if (status_filter) |s| break :blk std.fmt.allocPrint(ctx.allocator, "status_{s}", .{s}) catch "all";
        break :blk "all";
    };

    // ── WHERE builder shared by COUNT + SELECT ──────────────────────────
    // Slot ?1 is LIMIT, ?2 is OFFSET for the row query (unused in COUNT,
    // but kept off-limits to make the indexing simple). Slot ?3 onward is
    // for filter binds, in declaration order below.
    var where: std.ArrayList(u8) = .{};
    defer where.deinit(ctx.allocator);
    const ww = where.writer(ctx.allocator);

    const Bind = union(enum) { text: []const u8, int: i64 };
    var binds: std.ArrayListUnmanaged(Bind) = .{};
    defer binds.deinit(ctx.allocator);

    // Archived: by default exclude; for ?status=archived include only.
    const archived_only = if (status_filter) |s| std.mem.eql(u8, s, "archived") else false;
    if (archived_only) {
        try ww.writeAll(" AND e.archived = 1");
    } else {
        try ww.writeAll(" AND e.archived = 0");
    }

    if (type_filter) |d| {
        try ww.print(" AND e.content_type_id = ?{d}", .{binds.items.len + 3});
        try binds.append(ctx.allocator, .{ .text = d.type_id });
    }

    if (recent) {
        const seven_days_ago = std.time.timestamp() - 7 * 86400;
        try ww.print(" AND e.updated_at >= ?{d}", .{binds.items.len + 3});
        try binds.append(ctx.allocator, .{ .int = seven_days_ago });
    }

    if (created_by_me) if (me_id) |uid| {
        try ww.print(
            \\ AND EXISTS (SELECT 1 FROM content_versions cv
            \\             WHERE cv.entry_id = e.id
            \\             AND cv.version_type = 'created'
            \\             AND cv.author_id = ?{d})
        , .{binds.items.len + 3});
        try binds.append(ctx.allocator, .{ .text = uid });
    };

    if (updated_by_me) if (me_id) |uid| {
        try ww.print(
            \\ AND EXISTS (SELECT 1 FROM content_versions cv
            \\             WHERE cv.entry_id = e.id
            \\             AND cv.version_type IN ('updated','published')
            \\             AND cv.author_id = ?{d})
        , .{binds.items.len + 3});
        try binds.append(ctx.allocator, .{ .text = uid });
    };

    if (status_filter) |s| if (!archived_only) {
        try ww.print(" AND e.status = ?{d}", .{binds.items.len + 3});
        try binds.append(ctx.allocator, .{ .text = s });
    };

    const where_sql = where.items;

    // ── Type-picker dropdown ────────────────────────────────────────────
    // Each item links back to this page with the `type` query param flipped.
    const TypeOption = views.admin.content.list.TypeOption;
    const type_options: []const TypeOption = blk: {
        const buf = ctx.allocator.alloc(TypeOption, defs.len + 1) catch break :blk &[_]TypeOption{};
        buf[0] = .{ .label = "Any", .href = base_path };
        for (defs, 0..) |def, i| {
            buf[i + 1] = .{
                .label = def.display_name,
                .href = std.fmt.allocPrint(ctx.allocator, "{s}?type={s}", .{ base_path, def.type_id }) catch base_path,
            };
        }
        break :blk buf;
    };

    const current_type_label: []const u8 = if (type_filter) |d| d.display_name else "Any";

    // "Add entry" becomes a dropdown — one item per type.
    const new_options: []const TypeOption = blk: {
        const buf = ctx.allocator.alloc(TypeOption, defs.len) catch break :blk &[_]TypeOption{};
        for (defs, 0..) |def, i| {
            buf[i] = .{
                .label = std.fmt.allocPrint(ctx.allocator, "Add {s}", .{def.display_name}) catch def.display_name,
                .href = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/new", .{ base_path, def.type_id }) catch base_path,
            };
        }
        break :blk buf;
    };

    // ── COUNT (binds shifted by -2 since LIMIT/OFFSET are skipped) ──────
    const total_count: u32 = blk: {
        var count_sql: std.ArrayList(u8) = .{};
        defer count_sql.deinit(ctx.allocator);
        const cw = count_sql.writer(ctx.allocator);
        cw.writeAll("SELECT COUNT(*) FROM content_entries e WHERE 1=1") catch break :blk 0;
        cw.writeAll(where_sql) catch break :blk 0;
        var stmt = db.prepare(count_sql.items) catch break :blk 0;
        defer stmt.deinit();
        for (binds.items, 0..) |b, i| switch (b) {
            .text => |t| stmt.bindText(@intCast(i + 3), t) catch break :blk 0,
            .int => |n| stmt.bindInt(@intCast(i + 3), n) catch break :blk 0,
        };
        if (stmt.step() catch false) break :blk @intCast(stmt.columnInt(0));
        break :blk 0;
    };
    const pag = pagination.Paginator.init(ctx.query, total_count, 20);

    const Row = struct {
        id: []const u8,
        type_id: []const u8,
        title: []const u8,
        status: []const u8,
        updated_at: i64,
    };

    var rows: std.ArrayListUnmanaged(Row) = .{};
    if (total_count > 0) row_block: {
        var sel_sql: std.ArrayList(u8) = .{};
        defer sel_sql.deinit(ctx.allocator);
        const sw = sel_sql.writer(ctx.allocator);
        sw.writeAll(
            \\SELECT e.id, e.content_type_id, e.title, e.status, e.updated_at
            \\FROM content_entries e WHERE 1=1
        ) catch break :row_block;
        sw.writeAll(where_sql) catch break :row_block;
        sw.writeAll(" ORDER BY e.updated_at DESC LIMIT ?1 OFFSET ?2") catch break :row_block;

        var stmt = db.prepare(sel_sql.items) catch break :row_block;
        defer stmt.deinit();
        stmt.bindInt(1, @intCast(pag.items_per_page)) catch break :row_block;
        stmt.bindInt(2, @intCast(pag.offset())) catch break :row_block;
        for (binds.items, 0..) |b, i| switch (b) {
            .text => |t| stmt.bindText(@intCast(i + 3), t) catch break :row_block,
            .int => |n| stmt.bindInt(@intCast(i + 3), n) catch break :row_block,
        };
        while (stmt.step() catch false) {
            const id = stmt.columnText(0) orelse continue;
            const type_id = stmt.columnText(1) orelse continue;
            const title = stmt.columnText(2) orelse "";
            const status = stmt.columnText(3) orelse "draft";
            rows.append(ctx.allocator, .{
                .id = ctx.allocator.dupe(u8, id) catch continue,
                .type_id = ctx.allocator.dupe(u8, type_id) catch continue,
                .title = ctx.allocator.dupe(u8, title) catch "",
                .status = ctx.allocator.dupe(u8, status) catch "draft",
                .updated_at = stmt.columnInt(4),
            }) catch break;
        }
    }

    // Resolve authors for the page's entries.
    const entry_ids: []const []const u8 = blk: {
        const buf = ctx.allocator.alloc([]const u8, rows.items.len) catch break :blk &[_][]const u8{};
        for (rows.items, 0..) |r, i| buf[i] = r.id;
        break :blk buf;
    };
    const all_authors = authors.resolveEntryAuthors(ctx.allocator, db, entry_ids);

    const view_entries: []const ViewEntry = blk_ve: {
        const buf = ctx.allocator.alloc(ViewEntry, rows.items.len) catch break :blk_ve &[_]ViewEntry{};
        for (rows.items, 0..) |r, i| {
            const def_opt = schema_registry.findById(r.type_id);
            const type_label: []const u8 = if (def_opt) |d| d.display_name else r.type_id;
            const icon_str: []const u8 = if (def_opt) |d| (d.icon orelse "bookmark") else "bookmark";

            const author_list = authors.findAuthorsForEntry(all_authors, r.id);
            const last_author: ?AuthorInfo = if (author_list.len > 0) author_list[author_list.len - 1] else null;
            const author_label: []const u8 = if (last_author) |a| a.label() else "Unknown";
            const avatar_url: []const u8 = if (last_author) |a| gravatar.url(a.email, 24).slice() else "";

            buf[i] = .{
                .id = r.id,
                .name = if (r.title.len > 0) r.title else "(untitled)",
                .content_type_label = type_label,
                .content_type_icon = icon_str,
                .updated_relative = cms.formatRelativeTime(ctx.allocator, r.updated_at) catch "Unknown",
                .author_name = author_label,
                .author_avatar_url = avatar_url,
                .status = r.status,
                .edit_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/{s}", .{ base_path, r.type_id, r.id }) catch base_path,
            };
        }
        break :blk_ve buf;
    };

    // Preserve all active filters in the pagination/search URL so they
    // survive page jumps and search submits.
    const pag_base = blk: {
        var qs: std.ArrayList(u8) = .{};
        const qw = qs.writer(ctx.allocator);
        qw.writeAll(base_path) catch break :blk base_path;
        var first = true;
        const append = struct {
            fn f(buf: *std.ArrayList(u8), alloc: Allocator, is_first: *bool, kv: []const u8) void {
                buf.appendSlice(alloc, if (is_first.*) "?" else "&") catch return;
                buf.appendSlice(alloc, kv) catch return;
                is_first.* = false;
            }
        }.f;
        if (type_filter) |d| {
            const kv = std.fmt.allocPrint(ctx.allocator, "type={s}", .{d.type_id}) catch break :blk base_path;
            append(&qs, ctx.allocator, &first, kv);
        }
        if (recent) append(&qs, ctx.allocator, &first, "recent=1");
        if (created_by_me) append(&qs, ctx.allocator, &first, "author=me");
        if (updated_by_me) append(&qs, ctx.allocator, &first, "editor=me");
        if (status_filter) |s| {
            const kv = std.fmt.allocPrint(ctx.allocator, "status={s}", .{s}) catch break :blk base_path;
            append(&qs, ctx.allocator, &first, kv);
        }
        break :blk qs.toOwnedSlice(ctx.allocator) catch base_path;
    };
    const page_urls = pag.buildTruncatedPageUrls(ctx.allocator, pag_base);
    const total_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{total_count}) catch "0";

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

    const search_query = pu.queryParam(ctx.query, "q") orelse "";

    const content = tpl.render(views.admin.content.list.List, .{.{
        .page_title = "All Content",
        .new_url = base_path,
        .new_label = "Add entry",
        .new_options = new_options,
        .is_type_locked = false,
        .current_type_label = current_type_label,
        .type_options = type_options,
        .search_query = search_query,
        .search_action = base_path,
        .has_entries = view_entries.len > 0,
        .entries = view_entries,
        .total_count = total_count_str,
        .total_pages = pag.total_pages,
        .prev_page_url = page_urls.prev_url,
        .next_page_url = page_urls.next_url,
        .page_urls = tpl_page_urls,
    }});

    // The `?type=` filter on /admin/content is a dropdown refinement of the
    // "All content" view, not a navigation to the type's own list — so the
    // sidebar's content-type item stays inactive here. Only the path-based
    // /admin/content/<type> route (handled by `listFor`) lights it up.
    ctx.html(admin.renderWithLayoutTyped(PAGE_ID, "All Content", ctx, content, "", "", active_content_view));
}
