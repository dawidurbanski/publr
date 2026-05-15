//! Generic Content Admin Plugin
//!
//! Schema-driven CRUD for ANY registered content type, with full versioning,
//! publishing, autosave, releases, and multi-user editing support.
//!
//! Registering a content type (via `schema_registry.register` — through
//! `publr starter add`, a plugin, or admin UI) automatically creates:
//! - A sidebar nav item with the content type's display name
//! - Full CRUD routes at /admin/content/{type_id}
//! - Schema-driven form rendering and parsing
//! - Version history, publish/unpublish, autosave, releases
//!
//! Routes (per content type):
//!   GET  /admin/content/{type_id}                        — list entries
//!   GET  /admin/content/{type_id}/new                    — create new entry
//!   GET  /admin/content/{type_id}/:id                    — edit entry form
//!   GET  /admin/content/{type_id}/:id/versions/:vid/compare — version comparison
//!   GET  /admin/content/{type_id}/:id/versions/:vid/flow — version flow audit
//!   POST /admin/content/{type_id}                        — save new entry
//!   POST /admin/content/{type_id}/autosave               — autosave create
//!   POST /admin/content/{type_id}/:id                    — update existing entry
//!   POST /admin/content/{type_id}/:id/autosave           — autosave update
//!   POST /admin/content/{type_id}/:id/delete             — delete entry
//!   POST /admin/content/{type_id}/:id/publish            — publish entry
//!   POST /admin/content/{type_id}/:id/unpublish          — unpublish entry
//!   POST /admin/content/{type_id}/:id/discard            — discard to published
//!   POST /admin/content/{type_id}/:id/versions/:vid/restore — restore version

const std = @import("std");
const admin = @import("admin_api");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const csrf = @import("csrf");
const cms = @import("cms");
const schema_registry = @import("schema_registry");
const views = @import("views");
const registry = @import("registry");
const auth_middleware = @import("auth_middleware");
const pagination = @import("pagination");
const pu = @import("plugin_utils");
const field_mod = @import("field");
const content_type_mod = @import("content_type");
const gravatar = @import("gravatar");

const Allocator = std.mem.Allocator;
const Db = @import("db").Db;
const ContentTypeDef = content_type_mod.ContentTypeDef;
const FieldDef = field_mod.FieldDef;
const redirect = pu.redirect;
const writeJsonEscaped = pu.writeJsonEscaped;

const websocket = if (@import("builtin").target.os.tag != .wasi) @import("websocket") else struct {
    pub const Connection = struct {};
};
const presence = if (@import("builtin").target.os.tag != .wasi) @import("presence") else struct {
    pub fn getLockTimeoutMs() u32 {
        return 60_000;
    }
    pub fn getHeartbeatIntervalMs() u32 {
        return 10_000;
    }
    pub fn notifyLockAcquired(_: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) void {}
    pub fn notifyLocksReleased(_: []const u8, _: []const []const u8) void {}
    pub fn broadcastEntryMessage(_: []const u8, _: []const u8, _: []const u8) void {}
    pub fn getConnEntryId(_: u64) ?[]const u8 {
        return null;
    }
    pub fn checkTakeoverAllowed(_: []const u8, _: []const u8, _: []const u8) bool {
        return false;
    }
    pub fn registerTakeover(_: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) void {}
    pub const OverrideCheck = enum { none, owner, not_owner };
    pub fn checkOwnershipOverride(_: []const u8, _: []const u8, _: []const u8) OverrideCheck {
        return .none;
    }
    pub fn clearOwnershipOverrides(_: []const u8, _: []const []const u8) void {}
};

// =============================================================================
// Generic Content Page
// =============================================================================
//
// One admin page registers all content routes. The `:type` URL param is
// resolved via `schema_registry.findById` and the per-CT impls
// (`listFor`, `editFor`, …) take `*const ContentTypeDef` directly.
//
// POST routes live here as path-keyed `/:type/.../verb` endpoints.

pub const page = admin.registerPage(.{
    .id = "content",
    .title = "Content",
    .path = "/content",
    .icon = .bookmark,
    .position = 15,
    .section = "content",
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    // GET routes only — the 8 POST verbs (create/update/delete/publish/
    // unpublish/autosave/discard/restore) live in content_actions.zig and
    // are dispatched through /admin/action with hidden `action=content.<verb>`,
    // `type=<handle>`, `entry_id=<id>` fields.
    app.get("/", handleAll);
    app.get("/:type", handleList);
    app.get("/:type/new", handleNew);
    app.get("/:type/:id", handleEdit);
    app.get("/:type/:id/versions/:vid", handleVersionPreview);
    app.get("/:type/:id/versions/:vid/compare", handleVersionCompare);
    app.get("/:type/:id/versions/:vid/flow", handleVersionFlow);
}

fn handleAll(ctx: *Context) !void {
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
        ctx.html(admin.renderWithLayout(page.id, "All Content", ctx, content, ""));
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
    ctx.html(admin.renderWithLayout(page.id, "All Content", ctx, content, ""));
}

fn handleList(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return notFound(ctx);
    return listFor(def, ctx);
}

fn handleNew(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return notFound(ctx);
    return newFor(def, ctx);
}

fn handleEdit(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return notFound(ctx);
    return editFor(def, ctx);
}

fn handleVersionPreview(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return notFound(ctx);
    return versionPreviewRedirectFor(def, ctx);
}

fn handleVersionCompare(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return notFound(ctx);
    return versionCompareFor(def, ctx);
}

fn handleVersionFlow(ctx: *Context) !void {
    const type_id = ctx.params.get("type") orelse return notFound(ctx);
    const def = schema_registry.findById(type_id) orelse return notFound(ctx);
    return versionFlowFor(def, ctx);
}

/// Build the admin base URL for a given content type.
fn baseUrlFor(allocator: Allocator, def: *const ContentTypeDef) []const u8 {
    return std.fmt.allocPrint(allocator, "/admin/content/{s}", .{def.type_id}) catch "/admin/content";
}

// =============================================================================
// CRUD Handlers
// =============================================================================

const AuthorInfo = struct {
    id: []const u8,
    display_name: []const u8,
    email: []const u8,

    fn label(self: AuthorInfo) []const u8 {
        return if (self.display_name.len > 0) self.display_name else self.email;
    }
};

const AuthorOption = struct {
    value: []const u8,
    label: []const u8,
    selected: bool,
};

const ViewEntry = views.admin.content.list.Entry;

fn listFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const base_path = baseUrlFor(ctx.allocator, def);
    const new_url = std.fmt.allocPrint(ctx.allocator, "{s}/new", .{base_path}) catch base_path;
    const new_label = std.fmt.allocPrint(ctx.allocator, "Add {s}", .{def.display_name}) catch def.display_name;
    const icon_str: []const u8 = def.icon orelse "bookmark";

    // Author filter (treat empty string as no filter)
    const author_filter: ?[]const u8 = if (pu.queryParam(ctx.query, "author")) |af| (if (af.len > 0) af else null) else null;
    const filtered_entry_ids: ?[]const []const u8 = if (author_filter) |af| blk: {
        const ids = getEntryIdsByAuthor(ctx.allocator, db, af, def.type_id);
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
        ctx.html(admin.renderWithLayout(page.id, def.display_name, ctx, content, ""));
        return;
    };

    // Resolve authors for all entries on this page
    var entry_ids = ctx.allocator.alloc([]const u8, entries.len) catch {
        ctx.html("Error allocating memory");
        return;
    };
    for (entries, 0..) |entry, i| {
        entry_ids[i] = entry.id;
    }
    const all_authors = resolveEntryAuthors(ctx.allocator, db, entry_ids);

    var view_entries = ctx.allocator.alloc(ViewEntry, entries.len) catch {
        ctx.html("Error allocating memory");
        return;
    };

    for (entries, 0..) |entry, i| {
        const authors = findAuthorsForEntry(all_authors, entry.id);
        // Most recent author = last in the slice (resolveEntryAuthors orders
        // by created_at ASC).
        const last_author: ?AuthorInfo = if (authors.len > 0) authors[authors.len - 1] else null;
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

    // Build pagination URLs (preserve author filter)
    const base_url = if (author_filter) |af|
        std.fmt.allocPrint(ctx.allocator, "{s}?author={s}", .{ base_path, af }) catch base_path
    else
        base_path;
    const page_urls = pag.buildTruncatedPageUrls(ctx.allocator, base_url);
    const total_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{total_count}) catch "0";

    // Suggested filter chips — visual placeholders. Each chip's `href` will
    // wire up an actual filter query param once the filter system grows past
    // the existing single-value `author` filter.
    const SF = views.admin.content.list.SuggestedFilter;
    const suggested = [_]SF{
        .{ .label = "Created by me" },
        .{ .label = "Tags is one of" },
        .{ .label = "Taxonomy" },
        .{ .label = "Status is" },
        .{ .label = "Locale" },
    };

    const search_query = pu.queryParam(ctx.query, "q") orelse "";

    // Convert `pagination.PageUrl` slice into the template's local `PageUrl`
    // type. Fields are structurally identical; the mapping is needed because
    // ZSX's defaults-merge path field-copies through the prop type.
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

    ctx.html(admin.renderWithLayout(page.id, def.display_name, ctx, content, ""));
}

pub fn newFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const base_url = baseUrlFor(ctx.allocator, def);
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, base_url);
        return;
    };

    const data_json = defaultDataJson(ctx.allocator, def) catch "{}";
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

fn editFor(def: *const ContentTypeDef, ctx: *Context) !void {
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
        return notFound(ctx);
    };
    defer entry.deinit(ctx.allocator);

    const csrf_token = csrf.ensureToken(ctx);
    const action_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry.id }) catch base_url;
    const delete_url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/delete", .{ base_url, entry.id }) catch base_url;

    // Get published data for smart change detection
    const published_data = cms.getPublishedData(ctx.allocator, db, entry.id) catch null;

    // Build field editors JSON (multi-user editing indicators)
    const current_user_id = auth_middleware.getUserId(ctx) orelse "";
    const field_editors_json = buildFieldEditorsJson(ctx.allocator, db, entry.id, current_user_id) catch "{}";

    // Build per-field release info JSON
    const release_field_info = cms.getEntryPendingReleaseFields(ctx.allocator, db, entry.id) catch &.{};
    const fields_in_releases_json = buildFieldsInReleasesJson(ctx.allocator, release_field_info) catch "[]";

    // Render main editor fields (position = .main)
    const form_html = renderFieldsHtml(def, ctx.allocator, &entry.data, csrf_token, action_url, .main, .{
        .entry_id = entry.id,
        .status = entry.status,
        .published_data = published_data,
        .fields_in_releases = fields_in_releases_json,
        .field_editors = field_editors_json,
    });

    // Build version history HTML
    const history_html = buildVersionHistoryHtml(ctx.allocator, db, entry.id, base_url) catch "";

    // Build release menu HTML via ZSX template
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

    // Render sidebar
    const sidebar_html = renderSidebarHtml(def, ctx.allocator, &entry.data, csrf_token, delete_url, entry.status, .{
        .entry_id = entry.id,
        .history_html = history_html,
        .release_html = release_html,
        .base_url = base_url,
    });

    const display_title = if (entry.title.len > 0) entry.title else "Untitled";
    ctx.html(registry.renderEditPage(page, ctx, display_title, form_html, .{
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

    const data_json = parseFormDataJson(ctx.allocator, def, ctx, null) catch "{}";
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

    // Fetch existing entry
    var entry = cms.query.getEntry(ctx.allocator, db, def.type_id, entry_id) catch {
        redirect(ctx, base_url);
        return;
    } orelse {
        redirect(ctx, base_url);
        return;
    };
    defer entry.deinit(ctx.allocator);

    // Get field ownership for hard lock validation
    const owners = getFieldOwnership(ctx.allocator, db, entry_id) catch null;

    // Parse form with ownership validation
    var rejected: std.ArrayListUnmanaged(RejectedField) = .{};
    var newly_acquired: std.ArrayListUnmanaged([]const u8) = .{};
    const data_json = parseFormDataWithValidation(ctx.allocator, def, ctx, &entry.data, author_id, entry_id, owners, &rejected, &newly_acquired) catch "{}";
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

    // Broadcast lock_acquired for newly acquired fields
    if (newly_acquired.items.len > 0) {
        const user_email = auth_middleware.getUserEmail(ctx) orelse "";
        const user_name = getUserDisplayName(ctx.allocator, db, author_id) orelse user_email;
        const avatar = gravatar.url(user_email, 24);
        for (newly_acquired.items) |field_name| {
            presence.notifyLockAcquired(entry_id, field_name, author_id orelse "", user_name, avatar.slice());
        }
    }

    // Handle release actions
    if (std.mem.eql(u8, action, "add_to_release")) {
        const release_id = ctx.formValue("release_id") orelse "";
        if (release_id.len > 0) {
            cms.addToRelease(db, release_id, entry_id, fields_json) catch {};
        }
        broadcastReleaseUpdate(ctx.allocator, db, entry_id);
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
        broadcastReleaseUpdate(ctx.allocator, db, entry_id);
        const url = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_url, entry_id }) catch base_url;
        redirect(ctx, url);
        return;
    }

    // Handle publish-on-save
    if (std.mem.eql(u8, status, "published")) {
        cms.publishEntry(ctx.allocator, db, entry_id, author_id, fields_json) catch {};
        notifyPublishedFieldsReleased(ctx.allocator, db, entry_id, fields_json);
        broadcastPublishedState(ctx.allocator, db, entry_id);
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

// =============================================================================
// Publish / Unpublish / Discard
// =============================================================================

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
    notifyPublishedFieldsReleased(ctx.allocator, db, entry_id, fields_json);
    broadcastPublishedState(ctx.allocator, db, entry_id);

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

// =============================================================================
// Autosave
// =============================================================================

pub fn autosaveCreateFor(def: *const ContentTypeDef, ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"not authenticated\"}");
        return;
    };

    const data_json = parseFormDataJson(ctx.allocator, def, ctx, null) catch "{}";
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

    // Get field ownership for hard lock validation
    const owners = getFieldOwnership(ctx.allocator, db, entry_id) catch null;

    // Parse with ownership validation
    var rejected: std.ArrayListUnmanaged(RejectedField) = .{};
    var newly_acquired: std.ArrayListUnmanaged([]const u8) = .{};
    const data_json = parseFormDataWithValidation(ctx.allocator, def, ctx, &entry.data, author_id, entry_id, owners, &rejected, &newly_acquired) catch "{}";
    defer if (data_json.len > 2) ctx.allocator.free(data_json);

    // Status: drafts stay draft; published/changed become "changed"
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

    // Broadcast lock_acquired for newly acquired fields
    if (newly_acquired.items.len > 0) {
        const user_email = auth_middleware.getUserEmail(ctx) orelse "";
        const user_name = getUserDisplayName(ctx.allocator, db, author_id) orelse user_email;
        const avatar = gravatar.url(user_email, 24);
        for (newly_acquired.items) |field_name| {
            presence.notifyLockAcquired(entry_id, field_name, author_id orelse "", user_name, avatar.slice());
        }
    }

    // Detect released locks
    if (owners != null) {
        const new_owners = getFieldOwnership(ctx.allocator, db, entry_id) catch null;
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

    const json = buildAutosaveResponse(ctx.allocator, status, rejected.items) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"format failed\"}");
        return;
    };

    ctx.response.setHeader("Content-Type", "application/json");
    ctx.response.setBody(json);
}

// =============================================================================
// Version Preview & Restore
// =============================================================================

fn versionPreviewRedirectFor(def: *const ContentTypeDef, ctx: *Context) !void {
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

fn versionCompareFor(def: *const ContentTypeDef, ctx: *Context) !void {
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

    // Get entry title
    const entry_title = blk: {
        var t_stmt = try db.prepare("SELECT title FROM content_entries WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, entry_id);
        if (!try t_stmt.step()) break :blk "Untitled";
        break :blk try ctx.allocator.dupe(u8, t_stmt.columnText(0) orelse "Untitled");
    };

    // Get current version data
    const current_version_id = blk: {
        var cur_stmt = try db.prepare("SELECT current_version_id FROM content_entries WHERE id = ?1");
        defer cur_stmt.deinit();
        try cur_stmt.bindText(1, entry_id);
        _ = try cur_stmt.step();
        break :blk try ctx.allocator.dupe(u8, cur_stmt.columnText(0) orelse "");
    };
    const current_data = cms.getVersion(ctx.allocator, db, current_version_id) catch null;
    const current_json = if (current_data) |cd| cd.data else "{}";

    // Get structured field comparison
    var empty_fields = [_]cms.FieldComparison{};
    const fields = cms.compareVersionFields(ctx.allocator, version.data, current_json) catch &empty_fields;
    cms.populateFieldAuthors(ctx.allocator, db, fields, current_version_id, version_id);

    var changed_count: u32 = 0;
    for (fields) |f| {
        if (f.changed) changed_count += 1;
    }

    const time_str = cms.formatRelativeTime(ctx.allocator, version.created_at) catch "Unknown";
    const author_str = version.authorLabel();
    // Render comparison
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

    // Header row
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
        try writeCollaboratorAvatars(w, ctx.allocator, cd.collaborators, cd.author_email, cd.authorLabel());
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

    // Toolbar
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

    // Field rows
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

        // Old value cell
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

        // Current value cell
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

        try w.writeAll("</div>"); // row
    }

    try w.writeAll("</div>"); // fields

    // Actions
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

    // Build sidebar
    const history_html = buildVersionHistoryHtml(ctx.allocator, db, entry_id, base_url) catch "";
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

    ctx.html(registry.renderEditPage(page, ctx, entry_title, preview_content, .{
        .back_url = back_url,
        .back_label = "Back",
        .sidebar = sidebar_html,
    }));
}

fn versionFlowFor(def: *const ContentTypeDef, ctx: *Context) !void {
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

    const flow_html_opt = buildVersionFlowAuditHtml(ctx.allocator, db, entry_id, version_id) catch null;
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

    const history_html = buildVersionHistoryHtml(ctx.allocator, db, entry_id, base_url) catch "";
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

    ctx.html(registry.renderEditPage(page, ctx, entry_title, flow_content, .{
        .back_url = back_url,
        .back_label = "Back",
        .sidebar = sidebar_html,
    }));
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

    // Check if partial restore
    const is_partial = ctx.formValue("_partial") != null;

    if (is_partial) {
        // Partial merge: build merged JSON from selected fields
        const version = cms.getVersion(ctx.allocator, db, version_id) catch {
            redirect(ctx, edit_url);
            return;
        } orelse {
            redirect(ctx, edit_url);
            return;
        };

        // Get current entry data
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

        // Build merged object
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
        // Full restore
        cms.restoreVersion(ctx.allocator, db, entry_id, version_id, author_id) catch {};
    }

    redirect(ctx, edit_url);
}

// =============================================================================
// Schema-Driven Form Rendering
// =============================================================================

const FormOptions = struct {
    entry_id: []const u8 = "",
    status: []const u8 = "",
    published_data: ?[]const u8 = null,
    fields_in_releases: []const u8 = "[]",
    field_editors: []const u8 = "{}",
};

/// Escape a string for safe use in an HTML attribute value.
fn htmlAttrEscape(allocator: Allocator, input: []const u8) []const u8 {
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
fn renderFieldsHtml(
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
            fd.render(w.any(), .{
                .name = fd.name,
                .display_name = fd.display_name,
                .value = value,
                .required = fd.required,
                .allocator = allocator,
            }) catch {};
        }
    }

    if (position == .main) {
        w.writeAll("</form>") catch {};
    }

    return buf.toOwnedSlice(allocator) catch "";
}

/// Extract a string representation of a FieldMap value for form rendering.
fn fieldMapValueToString(allocator: Allocator, map: cms.query.FieldMap, name: []const u8) ?[]const u8 {
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

const SidebarOptions = struct {
    entry_id: []const u8 = "",
    history_html: []const u8 = "",
    release_html: []const u8 = "",
    base_url: []const u8 = "",
};

/// Render the sidebar HTML with all sections.
fn renderSidebarHtml(
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

    // --- Actions section ---
    w.writeAll(
        \\<div class="edit-sidebar-section">
        \\  <div class="edit-sidebar-actions">
        \\    <div class="autosave-status" id="autosave-status"></div>
    ) catch return "";

    // Publish button (JS-driven — same as posts plugin)
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

    // Discard button (JS handles the submit)
    if (!is_draft) {
        w.print(
            \\    <button type="button" class="{s}" id="discard-btn">Discard Changes</button>
        , .{if (is_changed) "btn btn-ghost btn-full" else "btn btn-ghost btn-full hidden"}) catch {};
    }

    // Release menu
    if (opts.release_html.len > 0) {
        w.writeAll(opts.release_html) catch {};
    }

    w.writeAll(
        \\  </div>
        \\</div>
    ) catch {};

    // --- Side-positioned fields ---
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
                var field_buf: std.ArrayListUnmanaged(u8) = .{};
                const fw = field_buf.writer(allocator);
                fd.render(fw.any(), .{
                    .name = fd.name,
                    .display_name = fd.display_name,
                    .value = value,
                    .required = fd.required,
                    .allocator = allocator,
                }) catch {};
                const field_html = field_buf.toOwnedSlice(allocator) catch "";
                const patched = injectFormAttr(allocator, field_html, "entry-form");
                w.writeAll(patched) catch {};
            }
        }

        w.writeAll("</div>") catch {};
    }

    // --- Version history ---
    if (opts.history_html.len > 0) {
        w.writeAll(opts.history_html) catch {};
    }

    // --- Delete button ---
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

// =============================================================================
// Schema-Driven Form Parsing
// =============================================================================

/// Build a JSON string from form values, iterating the descriptor's fields.
/// Handles scalar fields, group fields (dot-notation keys), and repeater
/// fields (indexed-prefix keys). Array fields default to empty when no
/// existing value is present.
fn parseFormDataJson(
    allocator: Allocator,
    def: *const ContentTypeDef,
    ctx: *Context,
    existing: ?cms.query.FieldMap,
) ![]u8 {
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

        if (std.mem.eql(u8, fd.field_type_id, "repeater")) {
            try writeRepeaterJson(w, allocator, fd.sub_fields, fd.name, ctx);
        } else if (fd.sub_fields.len > 0) {
            try writeGroupJson(w, allocator, fd.sub_fields, fd.name, ctx);
        } else if (fd.multi) {
            if (existing) |em| {
                try writeFieldMapValueJson(w, em.get(fd.name));
            } else {
                try w.writeAll("[]");
            }
        } else {
            const raw = ctx.formValue(fd.name) orelse "";
            try writeFieldJson(w, fd.field_type_id, raw);
        }
    }
    try w.writeByte('}');

    return buf.toOwnedSlice(allocator);
}

fn writeGroupJson(
    w: anytype,
    allocator: Allocator,
    sub_fields: []const FieldDef,
    prefix: []const u8,
    ctx: *Context,
) anyerror!void {
    try w.writeByte('{');
    var first = true;
    for (sub_fields) |sf| {
        if (!first) try w.writeByte(',');
        first = false;
        const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, sf.name });
        defer allocator.free(key);

        try w.writeByte('"');
        try writeJsonEscaped(w, sf.name);
        try w.writeAll("\":");

        if (std.mem.eql(u8, sf.field_type_id, "repeater")) {
            try writeRepeaterJson(w, allocator, sf.sub_fields, key, ctx);
        } else if (sf.sub_fields.len > 0) {
            try writeGroupJson(w, allocator, sf.sub_fields, key, ctx);
        } else if (sf.multi) {
            try w.writeAll("[]");
        } else {
            const raw = ctx.formValue(key) orelse "";
            try writeFieldJson(w, sf.field_type_id, raw);
        }
    }
    try w.writeByte('}');
}

fn writeRepeaterJson(
    w: anytype,
    allocator: Allocator,
    sub_fields: []const FieldDef,
    prefix: []const u8,
    ctx: *Context,
) anyerror!void {
    const count_key = try std.fmt.allocPrint(allocator, "{s}._count", .{prefix});
    defer allocator.free(count_key);
    const count_str = ctx.formValue(count_key) orelse "0";
    const count = std.fmt.parseInt(usize, count_str, 10) catch 0;

    try w.writeByte('[');
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        const item_prefix = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ prefix, i });
        defer allocator.free(item_prefix);
        try writeGroupJson(w, allocator, sub_fields, item_prefix, ctx);
    }
    try w.writeByte(']');
}

/// Serialize a single form value to JSON, coercing by `field_type_id`.
fn writeFieldJson(w: anytype, field_type_id: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, field_type_id, "boolean")) {
        const is_truthy = std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "on");
        try w.writeAll(if (is_truthy) "true" else "false");
        return;
    }
    if (std.mem.eql(u8, field_type_id, "integer")) {
        if (raw.len == 0) {
            try w.writeAll("null");
        } else if (std.fmt.parseInt(i64, raw, 10)) |_| {
            try w.writeAll(raw);
        } else |_| {
            try w.writeAll("null");
        }
        return;
    }
    if (std.mem.eql(u8, field_type_id, "number") or std.mem.eql(u8, field_type_id, "real")) {
        if (raw.len == 0) {
            try w.writeAll("null");
        } else if (std.fmt.parseFloat(f64, raw)) |_| {
            try w.writeAll(raw);
        } else |_| {
            try w.writeAll("null");
        }
        return;
    }
    try w.writeByte('"');
    try writeJsonEscaped(w, raw);
    try w.writeByte('"');
}

fn writeFieldMapValueJson(w: anytype, val: ?cms.query.FieldValue) !void {
    const v = val orelse {
        try w.writeAll("null");
        return;
    };
    switch (v) {
        .text => |s| {
            try w.writeByte('"');
            try writeJsonEscaped(w, s);
            try w.writeByte('"');
        },
        .int => |n| try w.print("{d}", .{n}),
        .real => |n| try w.print("{d}", .{n}),
        .bool_ => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |t| try w.print("{d}", .{t}),
        .json => |j| try w.print("{f}", .{std.json.fmt(j, .{})}),
        .null_ => try w.writeAll("null"),
    }
}

/// Parse form data with field ownership validation. Builds a JSON string
/// using new form values, falling back to the existing entry's value when
/// a field is locked by another user. Tracks rejected and newly-acquired
/// fields for collaboration UI.
fn parseFormDataWithValidation(
    allocator: Allocator,
    def: *const ContentTypeDef,
    ctx: *Context,
    existing: *const cms.query.FieldMap,
    author_id: ?[]const u8,
    entry_id: []const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    rejected: *std.ArrayListUnmanaged(RejectedField),
    newly_acquired: *std.ArrayListUnmanaged([]const u8),
) ![]u8 {
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

        // Owner check
        const field_rejected = checkFieldOwnership(fd.name, author_id, owners, rejected, allocator);

        if (std.mem.eql(u8, fd.field_type_id, "repeater")) {
            if (field_rejected) {
                try writeFieldMapValueJson(w, existing.get(fd.name));
            } else {
                try writeRepeaterJson(w, allocator, fd.sub_fields, fd.name, ctx);
                trackIfChanged(fd.name, owners, newly_acquired, allocator);
            }
        } else if (fd.sub_fields.len > 0) {
            if (field_rejected) {
                try writeFieldMapValueJson(w, existing.get(fd.name));
            } else {
                try writeGroupJson(w, allocator, fd.sub_fields, fd.name, ctx);
                trackIfChanged(fd.name, owners, newly_acquired, allocator);
            }
        } else if (fd.multi) {
            try writeFieldMapValueJson(w, existing.get(fd.name));
        } else {
            const existing_value = existing.get(fd.name);
            const existing_str: []const u8 = if (existing_value) |v| switch (v) {
                .text => |s| s,
                else => "",
            } else "";
            const validated = validateField(ctx, existing_str, fd.name, fd.name, author_id, entry_id, owners, rejected, newly_acquired);
            try writeFieldJson(w, fd.field_type_id, validated);
        }
    }
    try w.writeByte('}');

    return buf.toOwnedSlice(allocator);
}

fn checkFieldOwnership(
    name: []const u8,
    author_id: ?[]const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    rejected: *std.ArrayListUnmanaged(RejectedField),
    allocator: Allocator,
) bool {
    if (owners == null) return false;
    const own = owners.?;
    const field_info = own.get(name) orelse return false;
    const owner_id = field_info.changed_by_id orelse return false;
    const aid = author_id orelse return false;
    if (std.mem.eql(u8, owner_id, aid)) return false;
    rejected.append(allocator, .{
        .field = name,
        .owner_name = field_info.changed_by orelse "another user",
    }) catch {};
    return true;
}

fn trackIfChanged(
    name: []const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    newly_acquired: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
) void {
    const is_unowned = owners == null or !owners.?.contains(name);
    if (is_unowned) {
        newly_acquired.append(allocator, name) catch {};
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn injectFormAttr(allocator: Allocator, html: []const u8, form_id: []const u8) []const u8 {
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

fn defaultDataJson(allocator: Allocator, def: *const ContentTypeDef) ![]u8 {
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

fn formatDate(timestamp: i64, allocator: Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
}

/// Render the same styled 404 as `error.notFoundHandler` — inlined here so
/// the plugin doesn't need to reach back across module boundaries to import
/// `src/error.zig`. Wraps the content in the base layout for full requests
/// and returns just the content for X-Partial requests, matching the
/// behavior in `error.zig`.
fn notFound(ctx: *Context) anyerror!void {
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

// =============================================================================
// Version History & Comparison Helpers
// =============================================================================

/// Build version history HTML for the edit sidebar
fn buildVersionHistoryHtml(allocator: Allocator, db: *Db, entry_id: []const u8, base_url: []const u8) ![]const u8 {
    const versions = try cms.listVersions(allocator, db, entry_id, .{ .limit = 20 });

    if (versions.len == 0) return try allocator.dupe(u8, "");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(
        \\<div class="edit-sidebar-section">
        \\  <h3 class="edit-sidebar-title">Version History</h3>
        \\  <div class="version-list">
    );

    for (versions) |v| {
        const time_opt = cms.formatRelativeTime(allocator, v.created_at) catch null;
        defer if (time_opt) |ts| allocator.free(ts);
        const time_str = time_opt orelse "Unknown";

        const compare_url_opt = std.fmt.allocPrint(allocator, "{s}/{s}/versions/{s}/compare", .{ base_url, entry_id, v.id }) catch null;
        defer if (compare_url_opt) |url| allocator.free(url);
        const compare_url = compare_url_opt orelse "";

        const flow_url_opt = std.fmt.allocPrint(allocator, "{s}/{s}/versions/{s}/flow", .{ base_url, entry_id, v.id }) catch null;
        defer if (flow_url_opt) |url| allocator.free(url);
        const flow_url = flow_url_opt orelse "";

        try w.writeAll("<div class=\"version-item version-history-item");
        if (v.is_current) try w.writeAll(" version-current");
        try w.writeAll("\">");

        // Avatars
        try writeCollaboratorAvatars(w, allocator, v.collaborators, v.author_email, v.authorLabel());

        // Info
        try w.writeAll("<span class=\"version-info\">");
        try w.writeAll("<span class=\"version-type\">");
        try w.writeAll(v.version_type);
        try w.writeAll("</span>");
        if (v.release_name) |rn| {
            try w.writeAll("<span class=\"version-release\">");
            try cms.writeEscaped(w, rn);
            try w.writeAll("</span>");
        }
        try w.writeAll("<span class=\"version-time\">");
        try w.writeAll(time_str);
        try w.writeAll("</span>");
        try w.writeAll("</span>");

        try w.writeAll("<span class=\"version-item-actions\">");
        if (!v.is_current) {
            try w.writeAll("<a href=\"");
            try w.writeAll(compare_url);
            try w.writeAll("\" class=\"version-action\">Compare</a>");
        }
        try w.writeAll("<a href=\"");
        try w.writeAll(flow_url);
        try w.writeAll("\" class=\"version-action\">Flow</a>");
        if (v.is_current) {
            try w.writeAll("<span class=\"version-badge\">current</span>");
        }
        try w.writeAll("</span></div>");
    }

    try w.writeAll("</div></div>");
    return buf.toOwnedSlice(allocator);
}

fn buildVersionFlowAuditHtml(allocator: Allocator, db: *Db, entry_id: []const u8, version_id: []const u8) ![]const u8 {
    var stmt = try db.prepare(
        \\SELECT h.action,
        \\       COALESCE(u.display_name, ''),
        \\       COALESCE(u.email, ''),
        \\       h.created_at,
        \\       COALESCE(datetime(h.created_at, 'unixepoch'), ''),
        \\       h.from_step,
        \\       h.to_step,
        \\       h.details
        \\FROM entry_flow_history h
        \\LEFT JOIN users u ON u.id = h.user_id
        \\WHERE h.anchor_id = ?1
        \\  AND h.version_id = ?2
        \\ORDER BY h.created_at ASC, h.id ASC
        \\LIMIT 20
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    try stmt.bindText(2, version_id);

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var has_rows = false;
    while (try stmt.step()) {
        if (!has_rows) {
            has_rows = true;
            try w.writeAll("<div class=\"version-flow-audit\">");
        }

        const action = stmt.columnText(0) orelse "event";
        const display_name = stmt.columnText(1) orelse "";
        const email = stmt.columnText(2) orelse "";
        const actor = if (display_name.len > 0) display_name else if (email.len > 0) email else "System";
        const created_at = stmt.columnInt(3);
        const timestamp_utc = stmt.columnText(4) orelse "";
        const details = stmt.columnText(7);
        const relative_opt = cms.formatRelativeTime(allocator, created_at) catch null;
        defer if (relative_opt) |r| allocator.free(r);
        const relative = relative_opt orelse timestamp_utc;

        try w.writeAll("<div class=\"version-flow-event\">");
        try w.writeAll("<span class=\"version-flow-action\">");

        if (std.mem.eql(u8, action, "flow_entered")) {
            var flow_label: []const u8 = "Flow Entered";
            var owns_flow_label = false;
            if (details) |d| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                if (parsed) |p| {
                    if (p.value == .object) {
                        if (p.value.object.get("flow_id")) |f| {
                            if (f == .string and f.string.len > 0) {
                                flow_label = try std.fmt.allocPrint(allocator, "Flow Entered ({s})", .{f.string});
                                owns_flow_label = true;
                            }
                        }
                    }
                }
            }
            defer if (owns_flow_label) allocator.free(flow_label);
            try cms.writeEscaped(w, flow_label);
        } else if (std.mem.eql(u8, action, "step_started")) {
            try w.writeAll("Step Started");
        } else if (std.mem.eql(u8, action, "step_completed")) {
            try w.writeAll("Step Completed");
        } else if (std.mem.eql(u8, action, "terminal_action")) {
            var terminal_label: []const u8 = "Terminal Action";
            var owns_terminal_label = false;
            if (details) |d| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                if (parsed) |p| {
                    if (p.value == .object) {
                        if (p.value.object.get("terminal_action")) |t| {
                            if (t == .string and t.string.len > 0) {
                                terminal_label = try std.fmt.allocPrint(allocator, "Terminal: {s}", .{t.string});
                                owns_terminal_label = true;
                            }
                        }
                    }
                }
            }
            defer if (owns_terminal_label) allocator.free(terminal_label);
            try cms.writeEscaped(w, terminal_label);
        } else if (std.mem.eql(u8, action, "flow_completed")) {
            try w.writeAll("Flow Completed");
        } else {
            try cms.writeEscaped(w, action);
        }
        try w.writeAll("</span>");

        if (!stmt.columnIsNull(5)) {
            const from_step = stmt.columnInt(5);
            if (!stmt.columnIsNull(6)) {
                const to_step = stmt.columnInt(6);
                try w.print("<span class=\"version-flow-step\">Step {d} -> {d}</span>", .{ from_step, to_step });
            } else {
                try w.print("<span class=\"version-flow-step\">Step {d}</span>", .{from_step});
            }
        }

        try w.writeAll("<span class=\"version-flow-time\" title=\"");
        try cms.writeEscaped(w, timestamp_utc);
        try w.writeAll(" UTC\">");
        try cms.writeEscaped(w, relative);
        try w.writeAll(" · ");
        try cms.writeEscaped(w, actor);
        try w.writeAll("</span>");
        try w.writeAll("</div>");
    }

    if (!has_rows) return try allocator.dupe(u8, "");
    try w.writeAll("</div>");
    return buf.toOwnedSlice(allocator);
}

/// Render collaborator avatar stack from a JSON array of {email, name} objects.
fn writeCollaboratorAvatars(
    w: anytype,
    allocator: Allocator,
    collab_json: ?[]const u8,
    author_email: ?[]const u8,
    author_label: []const u8,
) !void {
    if (collab_json) |json| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch null;
        defer if (parsed) |p| p.deinit();

        if (parsed) |p| {
            if (p.value == .array and p.value.array.items.len > 0) {
                try w.writeAll("<span class=\"version-avatars\">");
                const items = p.value.array.items;
                const max_show: usize = 3;
                const show_count = @min(items.len, max_show);
                for (items[0..show_count]) |item| {
                    if (item == .object) {
                        if (item.object.get("email")) |email_val| {
                            if (email_val == .string) {
                                const avatar = gravatar.url(email_val.string, 24);
                                const name_val = if (item.object.get("name")) |n| (if (n == .string and n.string.len > 0) n.string else email_val.string) else email_val.string;
                                try w.writeAll("<img src=\"");
                                try w.writeAll(avatar.slice());
                                try w.writeAll("\" alt=\"\" title=\"");
                                try cms.writeEscaped(w, name_val);
                                try w.writeAll("\" class=\"version-avatar version-avatar-stacked\" />");
                            }
                        }
                    }
                }
                if (items.len > max_show) {
                    try w.print("<span class=\"version-avatar version-avatar-overflow\">+{d}</span>", .{items.len - max_show});
                }
                try w.writeAll("</span>");
                return;
            }
        }
        try w.writeAll("<span class=\"version-avatar version-avatar-system\">S</span>");
        return;
    }

    if (author_email) |email| {
        const avatar = gravatar.url(email, 24);
        try w.writeAll("<img src=\"");
        try w.writeAll(avatar.slice());
        try w.writeAll("\" alt=\"\" title=\"");
        try cms.writeEscaped(w, author_label);
        try w.writeAll("\" class=\"version-avatar\" />");
    } else {
        try w.writeAll("<span class=\"version-avatar version-avatar-system\">S</span>");
    }
}

/// Build JSON mapping field keys to their last editor info.
fn buildFieldEditorsJson(allocator: Allocator, db: *Db, entry_id: []const u8, current_user_id: []const u8) ![]const u8 {
    var ver_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1",
    );
    defer ver_stmt.deinit();
    try ver_stmt.bindText(1, entry_id);
    if (!try ver_stmt.step()) return try allocator.dupe(u8, "{}");

    const current_vid = ver_stmt.columnText(0) orelse return try allocator.dupe(u8, "{}");
    const published_vid = ver_stmt.columnText(1) orelse return try allocator.dupe(u8, "{}");
    if (std.mem.eql(u8, current_vid, published_vid)) return try allocator.dupe(u8, "{}");

    const cur_vid = try allocator.dupe(u8, current_vid);
    defer allocator.free(cur_vid);
    const pub_vid = try allocator.dupe(u8, published_vid);
    defer allocator.free(pub_vid);

    const published_data = try cms.getPublishedData(allocator, db, entry_id) orelse return try allocator.dupe(u8, "{}");
    defer allocator.free(published_data);

    var data_stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
    defer data_stmt.deinit();
    try data_stmt.bindText(1, cur_vid);
    if (!try data_stmt.step()) return try allocator.dupe(u8, "{}");
    const current_data = try allocator.dupe(u8, data_stmt.columnText(0) orelse "{}");
    defer allocator.free(current_data);

    const fields = try cms.compareVersionFields(allocator, published_data, current_data);
    defer allocator.free(fields);
    cms.populateFieldAuthors(allocator, db, fields, cur_vid, pub_vid);

    var user_stmt = try db.prepare("SELECT email FROM users WHERE id = ?1");
    defer user_stmt.deinit();
    try user_stmt.bindText(1, current_user_id);
    const current_email = if (try user_stmt.step())
        user_stmt.columnText(0) orelse ""
    else
        "";

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('{');
    var first = true;
    for (fields) |f| {
        if (!f.changed) continue;
        const editor_email = f.changed_by_email orelse continue;
        if (current_email.len > 0 and std.mem.eql(u8, editor_email, current_email)) continue;

        if (!first) try w.writeByte(',');
        first = false;

        try w.writeByte('"');
        try writeJsonEscaped(w, f.key);
        try w.writeAll("\":{\"name\":\"");
        try writeJsonEscaped(w, f.changed_by orelse editor_email);
        try w.writeAll("\",\"avatar\":\"");
        const avatar = gravatar.url(editor_email, 20);
        try w.writeAll(avatar.slice());
        try w.writeAll("\"}");
    }
    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

/// Build JSON for fields-in-releases data attribute.
fn buildFieldsInReleasesJson(allocator: Allocator, items: []const cms.EntryReleaseFieldInfo) ![]const u8 {
    if (items.len == 0) return try allocator.dupe(u8, "[]");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try w.writeAll(item.release_id);
        try w.writeAll("\",\"name\":");
        try w.writeByte('"');
        for (item.release_name) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            }
        }
        try w.writeByte('"');
        try w.writeAll(",\"fields\":");
        if (item.fields) |f| {
            try w.writeAll(f);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"scheduled_for\":");
        if (item.scheduled_for) |sf| {
            try w.print("{d}", .{sf});
        } else {
            try w.writeAll("null");
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(allocator);
}

// =============================================================================
// Hard Lock / Field Ownership
// =============================================================================

const RejectedField = struct {
    field: []const u8,
    owner_name: []const u8,
};

/// Get field ownership for an entry: field key -> owner info.
fn getFieldOwnership(allocator: Allocator, db: *Db, entry_id: []const u8) !?std.StringHashMapUnmanaged(cms.FieldComparison) {
    var ver_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1",
    );
    defer ver_stmt.deinit();
    try ver_stmt.bindText(1, entry_id);
    if (!try ver_stmt.step()) return null;

    const current_vid_raw = ver_stmt.columnText(0) orelse return null;
    const published_vid_raw = ver_stmt.columnText(1) orelse return null;
    if (std.mem.eql(u8, current_vid_raw, published_vid_raw)) return null;

    const cur_vid = try allocator.dupe(u8, current_vid_raw);
    defer allocator.free(cur_vid);
    const pub_vid = try allocator.dupe(u8, published_vid_raw);
    defer allocator.free(pub_vid);

    const published_data = try cms.getPublishedData(allocator, db, entry_id) orelse return null;
    defer allocator.free(published_data);

    var data_stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
    defer data_stmt.deinit();
    try data_stmt.bindText(1, cur_vid);
    if (!try data_stmt.step()) return null;
    const current_data = try allocator.dupe(u8, data_stmt.columnText(0) orelse "{}");
    defer allocator.free(current_data);

    const fields = try cms.compareVersionFields(allocator, published_data, current_data);
    cms.populateFieldAuthors(allocator, db, fields, cur_vid, pub_vid);

    var map: std.StringHashMapUnmanaged(cms.FieldComparison) = .{};
    for (fields) |f| {
        if (f.changed and f.changed_by_id != null) {
            map.put(allocator, f.key, f) catch continue;
        }
    }
    return map;
}

/// Validate a single field against ownership. Returns the value to use.
fn validateField(
    ctx: *Context,
    existing_value: []const u8,
    form_name: []const u8,
    json_key: []const u8,
    author_id: ?[]const u8,
    entry_id: []const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    rejected: *std.ArrayListUnmanaged(RejectedField),
    newly_acquired: *std.ArrayListUnmanaged([]const u8),
) []const u8 {
    const submitted = ctx.formValue(form_name) orelse return existing_value;

    // Check takeover ownership override first
    if (author_id) |aid| {
        switch (presence.checkOwnershipOverride(entry_id, json_key, aid)) {
            .owner => return submitted,
            .not_owner => {
                rejected.append(ctx.allocator, .{
                    .field = json_key,
                    .owner_name = "another user",
                }) catch {};
                return existing_value;
            },
            .none => {},
        }
    }

    if (owners) |own| {
        if (own.get(json_key)) |field_info| {
            if (author_id) |aid| {
                if (field_info.changed_by_id) |owner_id| {
                    if (!std.mem.eql(u8, owner_id, aid)) {
                        rejected.append(ctx.allocator, .{
                            .field = json_key,
                            .owner_name = field_info.changed_by orelse "another user",
                        }) catch {};
                        return existing_value;
                    }
                }
            }
            return submitted;
        }
    }

    // Field is unowned — accept and track if value actually changes
    if (!std.mem.eql(u8, submitted, existing_value)) {
        newly_acquired.append(ctx.allocator, json_key) catch {};
    }
    return submitted;
}

/// Build autosave JSON response with optional rejected_fields info.
fn buildAutosaveResponse(allocator: Allocator, status: []const u8, rejected: []const RejectedField) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\"status\":\"");
    try w.writeAll(status);
    try w.writeAll("\",\"saved\":true");

    if (rejected.len > 0) {
        try w.writeAll(",\"rejected_fields\":[");
        for (rejected, 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"field\":\"");
            try writeJsonEscaped(w, r.field);
            try w.writeAll("\",\"owner\":\"");
            try writeJsonEscaped(w, r.owner_name);
            try w.writeAll("\"}");
        }
        try w.writeByte(']');
    }

    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

// =============================================================================
// Presence & Release Notifications
// =============================================================================

/// Notify presence system that published fields had their hard locks released.
fn notifyPublishedFieldsReleased(allocator: Allocator, db: *Db, entry_id: []const u8, fields_json: ?[]const u8) void {
    if (fields_json) |fj| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, fj, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;

        var names: std.ArrayListUnmanaged([]const u8) = .{};
        defer names.deinit(allocator);
        for (parsed.value.array.items) |item| {
            if (item == .string) names.append(allocator, item.string) catch continue;
        }
        if (names.items.len > 0) {
            presence.notifyLocksReleased(entry_id, names.items);
            presence.clearOwnershipOverrides(entry_id, names.items);
        }
    } else {
        var stmt = db.prepare("SELECT data FROM content_entries WHERE id = ?1") catch return;
        defer stmt.deinit();
        stmt.bindText(1, entry_id) catch return;
        if (!(stmt.step() catch return)) return;
        const data_str = stmt.columnText(0) orelse return;

        const data_parsed = std.json.parseFromSlice(std.json.Value, allocator, data_str, .{}) catch return;
        defer data_parsed.deinit();
        if (data_parsed.value != .object) return;

        var names: std.ArrayListUnmanaged([]const u8) = .{};
        defer names.deinit(allocator);
        var iter = data_parsed.value.object.iterator();
        while (iter.next()) |kv| {
            names.append(allocator, kv.key_ptr.*) catch continue;
        }
        if (names.items.len > 0) {
            presence.notifyLocksReleased(entry_id, names.items);
            presence.clearOwnershipOverrides(entry_id, names.items);
        }
    }
}

/// Broadcast the new published state to all subscribers of an entry.
/// Other users update their publishedFields to reflect what was just published.
fn broadcastPublishedState(allocator: Allocator, db: *Db, entry_id: []const u8) void {
    const published_data = cms.getPublishedData(allocator, db, entry_id) catch return orelse return;

    // Get current entry status
    var stmt = db.prepare("SELECT status FROM content_entries WHERE id = ?1") catch return;
    defer stmt.deinit();
    stmt.bindText(1, entry_id) catch return;
    const status = if (stmt.step() catch return)
        (stmt.columnText(0) orelse "published")
    else
        "published";

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"published_state\":") catch return;
    w.writeAll(published_data) catch return;
    w.writeAll(",\"status\":\"") catch return;
    w.writeAll(status) catch return;
    w.writeAll("\"}") catch return;

    presence.broadcastEntryMessage(entry_id, "published_state", buf.items);
}

/// Broadcast updated fieldsInReleases to all subscribers of an entry.
fn broadcastReleaseUpdate(allocator: Allocator, db: *Db, entry_id: []const u8) void {
    const release_field_info = cms.getEntryPendingReleaseFields(allocator, db, entry_id) catch return;
    const json = buildFieldsInReleasesJson(allocator, release_field_info) catch return;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"fields_in_releases\":") catch return;
    w.writeAll(json) catch return;
    w.writeByte('}') catch return;

    presence.broadcastEntryMessage(entry_id, "release_updated", buf.items);
}

/// Get a user's display_name from the DB.
fn getUserDisplayName(allocator: Allocator, db: *Db, user_id: ?[]const u8) ?[]const u8 {
    const uid = user_id orelse return null;
    var stmt = db.prepare("SELECT display_name FROM users WHERE id = ?1") catch return null;
    defer stmt.deinit();
    stmt.bindText(1, uid) catch return null;
    if (!(stmt.step() catch return null)) return null;
    const dn = stmt.columnText(0) orelse return null;
    if (dn.len == 0) return null;
    return allocator.dupe(u8, dn) catch null;
}

// =============================================================================
// Author resolution helpers
// =============================================================================

const EntryAuthors = struct {
    entry_id: []const u8,
    authors: []const AuthorInfo,
};

fn resolveEntryAuthors(allocator: Allocator, db: *Db, entry_ids: []const []const u8) []const EntryAuthors {
    if (entry_ids.len == 0) return &.{};

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    w.writeAll(
        \\SELECT DISTINCT ev.entry_id, u.id, u.display_name, u.email
        \\ FROM content_versions ev JOIN users u ON u.id = ev.author_id
        \\ WHERE ev.author_id IS NOT NULL AND ev.version_type IN ('created', 'updated', 'published')
        \\ AND ev.entry_id IN (
    ) catch return &.{};

    for (entry_ids, 0..) |_, i| {
        if (i > 0) w.writeByte(',') catch return &.{};
        w.print("?{d}", .{i + 1}) catch return &.{};
    }
    w.writeAll(") ORDER BY ev.entry_id, ev.created_at ASC") catch return &.{};

    const sql = sql_buf.toOwnedSlice(allocator) catch return &.{};
    defer allocator.free(sql);

    var stmt = db.prepare(sql) catch return &.{};
    defer stmt.deinit();

    for (entry_ids, 0..) |eid, i| {
        stmt.bindText(@intCast(i + 1), eid) catch return &.{};
    }

    var results: std.ArrayListUnmanaged(EntryAuthors) = .{};
    var current_authors: std.ArrayListUnmanaged(AuthorInfo) = .{};
    var current_entry_id: ?[]const u8 = null;

    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        const row_entry_id = stmt.columnText(0) orelse continue;
        const user_id = stmt.columnText(1) orelse continue;
        const display_name = stmt.columnText(2) orelse "";
        const email = stmt.columnText(3) orelse continue;

        if (current_entry_id) |cur| {
            if (!std.mem.eql(u8, cur, row_entry_id)) {
                const authors_slice = current_authors.toOwnedSlice(allocator) catch continue;
                results.append(allocator, .{ .entry_id = cur, .authors = authors_slice }) catch continue;
                current_entry_id = allocator.dupe(u8, row_entry_id) catch continue;
            }
        } else {
            current_entry_id = allocator.dupe(u8, row_entry_id) catch continue;
        }

        var duplicate = false;
        for (current_authors.items) |existing| {
            if (std.mem.eql(u8, existing.id, user_id)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            current_authors.append(allocator, .{
                .id = allocator.dupe(u8, user_id) catch continue,
                .display_name = allocator.dupe(u8, display_name) catch continue,
                .email = allocator.dupe(u8, email) catch continue,
            }) catch continue;
        }
    }

    if (current_entry_id) |cur| {
        const authors_slice = current_authors.toOwnedSlice(allocator) catch return results.toOwnedSlice(allocator) catch &.{};
        results.append(allocator, .{ .entry_id = cur, .authors = authors_slice }) catch {};
    }

    return results.toOwnedSlice(allocator) catch &.{};
}

fn findAuthorsForEntry(all: []const EntryAuthors, entry_id: []const u8) []const AuthorInfo {
    for (all) |ea| {
        if (std.mem.eql(u8, ea.entry_id, entry_id)) return ea.authors;
    }
    return &.{};
}

fn renderAuthorCell(allocator: Allocator, authors: []const AuthorInfo) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    if (authors.len == 0) {
        w.writeAll("<span class=\"text-tertiary\">System</span>") catch return "System";
        return buf.toOwnedSlice(allocator) catch "System";
    }

    if (authors.len == 1) {
        const a = authors[0];
        const avatar = gravatar.url(a.email, 24);
        w.writeAll("<img src=\"") catch return a.label();
        w.writeAll(avatar.slice()) catch return a.label();
        w.writeAll("\" alt=\"\" title=\"") catch return a.label();
        cms.writeEscaped(w, a.label()) catch return a.label();
        w.writeAll("\" class=\"version-avatar\" /> ") catch return a.label();
        cms.writeEscaped(w, a.label()) catch return a.label();
        return buf.toOwnedSlice(allocator) catch a.label();
    }

    w.writeAll("<span class=\"version-avatars\">") catch return "Multiple authors";
    const max_show: usize = 3;
    const show_count = @min(authors.len, max_show);
    for (authors[0..show_count]) |a| {
        const avatar = gravatar.url(a.email, 24);
        w.writeAll("<img src=\"") catch continue;
        w.writeAll(avatar.slice()) catch continue;
        w.writeAll("\" alt=\"\" title=\"") catch continue;
        cms.writeEscaped(w, a.label()) catch continue;
        w.writeAll("\" class=\"version-avatar version-avatar-stacked\" />") catch continue;
    }
    if (authors.len > max_show) {
        w.print("<span class=\"version-avatar version-avatar-overflow\">+{d}</span>", .{authors.len - max_show}) catch {};
    }
    w.writeAll("</span> ") catch {};
    w.print("{d} authors", .{authors.len}) catch {};
    return buf.toOwnedSlice(allocator) catch "Multiple authors";
}

fn getAvailableAuthors(allocator: Allocator, db: *Db, content_type_id: []const u8) []const AuthorInfo {
    var stmt = db.prepare(
        \\SELECT DISTINCT u.id, u.display_name, u.email FROM users u
        \\JOIN content_versions ev ON ev.author_id = u.id
        \\JOIN content_entries e ON e.id = ev.entry_id
        \\WHERE e.content_type_id = ?1 AND ev.version_type IN ('created', 'updated', 'published')
        \\ORDER BY u.display_name, u.email
    ) catch return &.{};
    defer stmt.deinit();
    stmt.bindText(1, content_type_id) catch return &.{};

    var results: std.ArrayListUnmanaged(AuthorInfo) = .{};
    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        results.append(allocator, .{
            .id = allocator.dupe(u8, stmt.columnText(0) orelse continue) catch continue,
            .display_name = allocator.dupe(u8, stmt.columnText(1) orelse "") catch continue,
            .email = allocator.dupe(u8, stmt.columnText(2) orelse continue) catch continue,
        }) catch continue;
    }
    return results.toOwnedSlice(allocator) catch &.{};
}

// =============================================================================
// Takeover — called from WebSocket dispatch (http.zig)
// =============================================================================

/// Handle a takeover request from a WebSocket connection.
/// Checks authorization and transfers field ownership if allowed.
/// Content-type agnostic — works for any entry.
pub fn handleTakeover(conn: *websocket.Connection, field_name: []const u8, user: presence.UserInfo) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db = if (auth_middleware.auth) |a| a.db else return;
    const entry_id = presence.getConnEntryId(conn.id) orelse return;

    // 1. Check field has hard lock by another user
    const owners = getFieldOwnership(allocator, db, entry_id) catch {
        sendTakeoverResult(conn, field_name, false, "internal error");
        return;
    };

    if (owners == null) {
        sendTakeoverResult(conn, field_name, false, "no pending changes on this field");
        return;
    }

    const field_info = owners.?.get(field_name) orelse {
        sendTakeoverResult(conn, field_name, false, "no pending changes on this field");
        return;
    };

    const owner_id = field_info.changed_by_id orelse {
        sendTakeoverResult(conn, field_name, false, "field has no owner");
        return;
    };

    // Can't take over your own field
    if (std.mem.eql(u8, owner_id, user.user_id)) {
        sendTakeoverResult(conn, field_name, false, "you already own this field");
        return;
    }

    // 2. Check presence authorization
    if (!presence.checkTakeoverAllowed(entry_id, owner_id, field_name)) {
        sendTakeoverResult(conn, field_name, false, "user is currently editing this field");
        return;
    }

    // 3. Register takeover (stores override, invalidates soft lock, broadcasts lock_acquired)
    const display_name = if (user.display_name.len > 0) user.display_name else user.email;
    const avatar = gravatar.url(user.email, 24);
    presence.registerTakeover(entry_id, field_name, user.user_id, display_name, avatar.slice());

    // 4. Send success to requester
    sendTakeoverResult(conn, field_name, true, null);
}

fn sendTakeoverResult(conn: *websocket.Connection, field_name: []const u8, success: bool, reason: ?[]const u8) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.heap.page_allocator);
    const w = buf.writer(std.heap.page_allocator);

    w.writeAll("{\"field\":\"") catch return;
    writeJsonEscaped(w, field_name) catch return;
    if (success) {
        w.writeAll("\",\"success\":true}") catch return;
    } else {
        w.writeAll("\",\"success\":false") catch return;
        if (reason) |r| {
            w.writeAll(",\"reason\":\"") catch return;
            writeJsonEscaped(w, r) catch return;
            w.writeByte('"') catch return;
        }
        w.writeByte('}') catch return;
    }

    conn.sendJson("takeover_result", buf.items) catch {};
}

fn getEntryIdsByAuthor(allocator: Allocator, db: *Db, author_id: []const u8, content_type_id: []const u8) []const []const u8 {
    var stmt = db.prepare(
        \\SELECT DISTINCT ev.entry_id FROM content_versions ev
        \\JOIN content_entries e ON e.id = ev.entry_id
        \\WHERE ev.author_id = ?1 AND e.content_type_id = ?2
        \\AND ev.version_type IN ('created', 'updated', 'published')
    ) catch return &.{};
    defer stmt.deinit();
    stmt.bindText(1, author_id) catch return &.{};
    stmt.bindText(2, content_type_id) catch return &.{};

    var results: std.ArrayListUnmanaged([]const u8) = .{};
    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        results.append(allocator, allocator.dupe(u8, stmt.columnText(0) orelse continue) catch continue) catch continue;
    }
    return results.toOwnedSlice(allocator) catch &.{};
}

test "admin content: public API coverage" {
    _ = handleTakeover;
}
