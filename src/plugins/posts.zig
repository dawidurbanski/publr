//! Posts plugin - content management pages
//!
//! Uses the CMS module for database operations with the Post content type.

const std = @import("std");
const time_util = @import("time_util");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const csrf = @import("csrf");
const cms = @import("cms");
const schemas = @import("schemas");
const views = @import("views");
const registry = @import("registry");
const auth_middleware = @import("auth_middleware");
const gravatar = @import("gravatar");
const websocket = if (@import("builtin").target.os.tag != .wasi) @import("websocket") else struct {
    pub const Connection = struct {};
};
const presence = if (@import("builtin").target.os.tag != .wasi) @import("presence") else struct {
    pub fn notifyLockAcquired(_: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) void {}
    pub fn notifyLocksReleased(_: []const u8, _: []const []const u8) void {}
    pub fn broadcastEntryMessage(_: []const u8, _: []const u8, _: []const u8) void {}
    pub fn getConnEntryId(_: u64) ?[]const u8 { return null; }
    pub fn checkTakeoverAllowed(_: []const u8, _: []const u8, _: []const u8) bool { return false; }
    pub fn registerTakeover(_: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) void {}
    pub const OverrideCheck = enum { none, owner, not_owner };
    pub fn checkOwnershipOverride(_: []const u8, _: []const u8, _: []const u8) OverrideCheck { return .none; }
    pub fn clearOwnershipOverrides(_: []const u8, _: []const []const u8) void {}
};

const Post = schemas.Post;
const pagination = @import("pagination");

/// Posts list page (shows in nav)
pub const page = admin.registerPage(.{
    .id = "posts",
    .title = "Posts",
    .path = "/posts",
    .icon = icons.bookmark,
    .position = 20,
    .section = "content",
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleList);
    app.get("/new", handleNew);
    app.get("/:id", handleEdit);
    app.get("/:id/versions/:vid", handleVersionPreview);
    app.post(handleCreate);
    app.postAt("/autosave", handleAutosaveCreate);
    app.postAt("/:id", handleUpdate);
    app.postAt("/:id/autosave", handleAutosaveUpdate);
    app.postAt("/:id/delete", handleDelete);
    app.postAt("/:id/publish", handlePublish);
    app.postAt("/:id/unpublish", handleUnpublish);
    app.postAt("/:id/discard", handleDiscard);
    app.postAt("/:id/versions/:vid/restore", handleRestore);
}

// =============================================================================
// Handlers
// =============================================================================

const AuthorOption = struct {
    value: []const u8,
    label: []const u8,
    selected: bool,
};

fn handleList(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const ViewPost = struct {
        id: []const u8,
        title: []const u8,
        authors_html: []const u8,
        status: []const u8,
        date: []const u8,
        edit_url: []const u8,
        preview_url: []const u8,
    };

    // Author filter (treat empty string as no filter)
    const author_filter: ?[]const u8 = if (pu.queryParam(ctx.query, "author")) |af| (if (af.len > 0) af else null) else null;
    const filtered_entry_ids: ?[]const []const u8 = if (author_filter) |af|
        blk: {
            const ids = getEntryIdsByAuthor(ctx.allocator, db, af, Post.type_id);
            break :blk if (ids.len > 0) ids else null;
        }
    else
        null;

    // Pagination — when filtered, count matching entries
    const total_count: u32 = if (author_filter != null) blk: {
        if (filtered_entry_ids) |ids| break :blk @intCast(ids.len) else break :blk 0;
    } else cms.countEntries(Post, db, .{}) catch 0;
    const pag = pagination.Paginator.init(ctx.query, total_count, 20);

    // Fetch posts from database
    const entries = cms.listEntries(Post, ctx.allocator, db, .{
        .limit = pag.items_per_page,
        .offset = pag.offset(),
        .order_by = "created_at",
        .order_dir = .desc,
        .entry_ids = filtered_entry_ids,
    }) catch |err| {
        std.debug.print("Error listing posts: {}\n", .{err});
        const empty_pag = pagination.Paginator.init(null, 0, 20);
        const empty_urls = empty_pag.buildTruncatedPageUrls(ctx.allocator, "/admin/posts");
        const content = tpl.render(views.admin.posts.list.List, .{.{
            .has_posts = false,
            .posts = &[_]ViewPost{},
            .total_count = "0",
            .total_pages = @as(u32, 1),
            .prev_page_url = "",
            .next_page_url = "",
            .page_urls = empty_urls.items,
            .available_authors = &[_]AuthorOption{},
            .active_author_filter = "",
        }});
        ctx.html(registry.renderPage(page, ctx, content));
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

    // Convert to view format
    var posts = ctx.allocator.alloc(ViewPost, entries.len) catch {
        ctx.html("Error allocating memory");
        return;
    };

    for (entries, 0..) |entry, i| {
        const authors = findAuthorsForEntry(all_authors, entry.id);
        posts[i] = .{
            .id = entry.id,
            .title = entry.title,
            .authors_html = renderAuthorCell(ctx.allocator, authors),
            .status = entry.status,
            .date = formatDate(entry.created_at, ctx.allocator) catch "Unknown",
            .edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{entry.id}) catch "/admin/posts",
            .preview_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}/preview", .{entry.id}) catch "/admin/posts",
        };
    }

    // Build pagination URLs (preserve author filter in URL)
    const base_url = if (author_filter) |af|
        std.fmt.allocPrint(ctx.allocator, "/admin/posts?author={s}", .{af}) catch "/admin/posts"
    else
        "/admin/posts";
    const page_urls = pag.buildTruncatedPageUrls(ctx.allocator, base_url);

    const total_count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{total_count}) catch "0";

    // Get available authors for filter dropdown
    const raw_authors = getAvailableAuthors(ctx.allocator, db, Post.type_id);
    const author_options: []const AuthorOption = blk: {
        if (raw_authors.len == 0) break :blk &[_]AuthorOption{};
        const opts = ctx.allocator.alloc(AuthorOption, raw_authors.len) catch break :blk &[_]AuthorOption{};
        for (raw_authors, 0..) |a, i| {
            opts[i] = .{
                .value = a.id,
                .label = a.label(),
                .selected = if (author_filter) |af| std.mem.eql(u8, a.id, af) else false,
            };
        }
        break :blk opts;
    };

    const content = tpl.render(views.admin.posts.list.List, .{.{
        .has_posts = posts.len > 0,
        .posts = posts,
        .total_count = total_count_str,
        .total_pages = pag.total_pages,
        .prev_page_url = page_urls.prev_url,
        .next_page_url = page_urls.next_url,
        .page_urls = page_urls.items,
        .available_authors = author_options,
        .active_author_filter = author_filter orelse "",
    }});

    const add_btn =
        \\<a href="/admin/posts/new" class="btn btn-primary">Add new</a>
    ;

    ctx.html(registry.renderPageFull(page, ctx, content, "", "", add_btn));
}

fn handleNew(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    // Create empty draft entry immediately so it has an ID for releases
    const data = Post.Data{
        .title = "",
        .slug = "",
        .body = "",
        .author = null,
        .category = null,
        .tag = null,
        .published_at = null,
        .featured = false,
        .featured_image = null,
        .meta_description = null,
    };

    const author_id = auth_middleware.getUserId(ctx);
    const entry = cms.saveEntry(Post, ctx.allocator, db, null, data, .{
        .author_id = author_id,
        .status = "draft",
    }) catch {
        redirect(ctx, "/admin/posts");
        return;
    };

    const edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{entry.id}) catch "/admin/posts";
    redirect(ctx, edit_url);
}

fn handleEdit(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);
    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    // Fetch post from database
    const entry = cms.getEntry(Post, ctx.allocator, db, post_id) catch {
        redirect(ctx, "/admin/posts");
        return;
    } orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    const PostData = struct {
        title: []const u8,
        slug: []const u8,
        content: []const u8,
        date: []const u8,
        status: []const u8,
        is_draft: bool,
        is_published: bool,
        is_changed: bool,
        featured_image: []const u8,
        featured_image_url: []const u8,
        entry_id: []const u8,
        published_data: []const u8,
    };

    const edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
    const delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}/delete", .{post_id}) catch "";

    // Get featured image URL if set
    const featured_image_id = entry.data.featured_image orelse "";
    const featured_image_url = if (featured_image_id.len > 0)
        std.fmt.allocPrint(ctx.allocator, "/admin/media/picker/thumb/{s}", .{featured_image_id}) catch ""
    else
        "";

    // Get published version data for smart change detection
    const published_data = cms.getPublishedData(ctx.allocator, db, post_id) catch null;

    // Build per-field release info JSON for the edit form
    const release_field_info = cms.getEntryPendingReleaseFields(ctx.allocator, db, post_id) catch &.{};
    const fields_in_releases_json = buildFieldsInReleasesJson(ctx.allocator, release_field_info) catch "[]";

    // Build field editors JSON: who last changed each field (for multi-user editing)
    const current_user_id = auth_middleware.getUserId(ctx) orelse "";
    const field_editors_json = buildFieldEditorsJson(ctx.allocator, db, post_id, current_user_id) catch "{}";

    const post_data = PostData{
        .title = entry.title,
        .slug = entry.slug orelse "",
        .content = entry.data.body,
        .date = formatDate(entry.created_at, ctx.allocator) catch "Unknown",
        .status = entry.status,
        .is_draft = entry.isDraft(),
        .is_published = entry.isPublished(),
        .is_changed = entry.isChanged(),
        .featured_image = featured_image_id,
        .featured_image_url = featured_image_url,
        .entry_id = post_id,
        .published_data = published_data orelse "",
    };

    const content = tpl.render(views.admin.posts.edit.Edit, .{.{
        .post = post_data,
        .csrf_token = csrf_token,
        .action = edit_url,
        .fields_in_releases = fields_in_releases_json,
        .field_editors = field_editors_json,
    }});

    // Build version history HTML for sidebar
    const history_html = buildVersionHistoryHtml(ctx.allocator, db, post_id) catch "";

    // Build "Add to Release" dropdown with current membership info
    const pending_releases = cms.listPendingReleases(ctx.allocator, db) catch &.{};
    const entry_rel_ids = cms.getEntryPendingReleaseIds(ctx.allocator, db, post_id) catch &.{};

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

    const sidebar = tpl.render(views.admin.posts.edit.EditSidebar, .{.{
        .post = post_data,
        .csrf_token = csrf_token,
        .delete_url = delete_url,
        .history_html = history_html,
        .release_html = release_html,
    }});

    const display_title = if (entry.title.len > 0) entry.title else "Untitled";
    ctx.html(registry.renderEditPage(page, ctx, display_title, content, .{
        .back_url = "/admin/posts",
        .back_label = "Posts",
        .sidebar = sidebar,
    }));
}

fn handleVersionPreview(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    const version_id = ctx.param("vid") orelse {
        redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);

    // Fetch the version being compared
    const version = cms.getVersion(ctx.allocator, db, version_id) catch {
        redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
        return;
    } orelse {
        redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
        return;
    };

    // Fetch current entry for title
    const entry = cms.getEntry(Post, ctx.allocator, db, post_id) catch {
        redirect(ctx, "/admin/posts");
        return;
    } orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    // Get current version data
    const current_version_id = blk: {
        var cur_stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = ?1");
        defer cur_stmt.deinit();
        try cur_stmt.bindText(1, post_id);
        _ = try cur_stmt.step();
        break :blk try ctx.allocator.dupe(u8, cur_stmt.columnText(0) orelse "");
    };
    const current_data = cms.getVersion(ctx.allocator, db, current_version_id) catch null;

    const current_json = if (current_data) |cd| cd.data else "{}";

    // Get structured field comparison with per-field author attribution
    var empty_fields = [_]cms.FieldComparison{};
    const fields = cms.compareVersionFields(ctx.allocator, version.data, current_json) catch &empty_fields;
    cms.populateFieldAuthors(ctx.allocator, db, fields, current_version_id, version_id);

    // Count changed fields
    var changed_count: u32 = 0;
    for (fields) |f| {
        if (f.changed) changed_count += 1;
    }

    const time_str = cms.formatRelativeTime(ctx.allocator, version.created_at) catch "Unknown";
    const author_str = version.authorLabel();
    const restore_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}/versions/{s}/restore", .{ post_id, version_id }) catch "";
    const back_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";

    // Render side-by-side comparison
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(ctx.allocator);

    if (version.is_current) {
        // Current version — no comparison needed
        try w.writeAll(
            \\<div class="version-preview">
            \\  <div class="version-preview-header">
            \\    <div class="version-preview-meta">
            \\      <span class="version-preview-author">
        );
        try w.writeAll(author_str);
        try w.writeAll("</span><span class=\"version-preview-time\">");
        try w.writeAll(time_str);
        try w.writeAll(
            \\</span>
            \\    </div>
            \\    <span class="badge-current">Current version</span>
            \\  </div>
            \\</div>
        );
    } else {
        // Side-by-side comparison form
        try w.writeAll("<form method=\"POST\" action=\"");
        try w.writeAll(restore_url);
        try w.writeAll("\" class=\"version-compare\">");
        try w.writeAll("<input type=\"hidden\" name=\"_csrf\" value=\"");
        try w.writeAll(csrf_token);
        try w.writeAll("\"/>");

        // Header row with version info and collaborator avatars
        try w.writeAll(
            \\<div class="version-compare-header">
            \\  <div class="version-compare-col-old">
            \\    <span class="version-compare-col-title">
        );
        // Old version: show avatar + author + time
        if (version.author_email) |email| {
            const old_avatar = gravatar.url(email, 24);
            try w.writeAll("<img src=\"");
            try w.writeAll(old_avatar.slice());
            try w.writeAll("\" alt=\"\" title=\"");
            try cms.writeEscaped(w, version.authorLabel());
            try w.writeAll("\" class=\"version-avatar\" /> ");
        }
        // Show "Published by X" for published versions, otherwise just author
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
        // Current version: show collaborator avatars if available
        if (current_data) |cd| {
            try writeCollaboratorAvatars(w, ctx.allocator, cd.collaborators, cd.author_email, cd.authorLabel());
            try w.writeByte(' ');
        }
        // Show "Published by X" or "Current version" label
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

        // Toolbar with diff toggle
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

            // Field label with "by User" attribution
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

            // Old value cell (left)
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

            // Current value cell (right)
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
    }

    const preview_content = buf.toOwnedSlice(ctx.allocator) catch "";

    // Build sidebar
    const history_html = buildVersionHistoryHtml(ctx.allocator, db, post_id) catch "";
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

    ctx.html(registry.renderEditPage(page, ctx, entry.title, preview_content, .{
        .back_url = back_url,
        .back_label = "Posts",
        .sidebar = sidebar_html,
    }));
}

fn handleRestore(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    const version_id = ctx.param("vid") orelse {
        redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);

    // Check if this is a partial merge (has field_* params)
    const has_field_params = ctx.formValue("field_title") != null or
        ctx.formValue("field_body") != null or
        ctx.formValue("field_slug") != null;

    if (has_field_params) {
        // Partial merge: build merged JSON from selected fields
        const version = cms.getVersion(ctx.allocator, db, version_id) catch |err| {
            std.debug.print("Error getting version: {}\n", .{err});
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        } orelse {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        };

        // Get current entry data
        const current_data_json = blk: {
            const current_vid = cv_blk: {
                var cur_stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = ?1");
                defer cur_stmt.deinit();
                try cur_stmt.bindText(1, post_id);
                if (!try cur_stmt.step()) break :cv_blk null;
                break :cv_blk if (cur_stmt.columnText(0)) |t| try ctx.allocator.dupe(u8, t) else null;
            };
            if (current_vid) |cvid| {
                const cur_ver = cms.getVersion(ctx.allocator, db, cvid) catch null;
                if (cur_ver) |cv| break :blk cv.data;
            }
            break :blk "{}";
        };

        // Parse both as JSON objects
        const old_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, version.data, .{}) catch {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        };
        defer old_parsed.deinit();

        const cur_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, current_data_json, .{}) catch {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        };
        defer cur_parsed.deinit();

        const old_obj = if (old_parsed.value == .object) old_parsed.value.object else {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        };
        const cur_obj = if (cur_parsed.value == .object) cur_parsed.value.object else {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        };

        // Build merged object: for each key, check form param to decide source
        var merged = std.json.ObjectMap.init(ctx.allocator);
        var has_old_selection = false;

        // Process keys from current version
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

        // Process keys only in old version (not in current)
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

        // No old fields selected — nothing to restore
        if (!has_old_selection) {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}/versions/{s}", .{ post_id, version_id }) catch
                std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        }

        // Serialize merged JSON
        const merged_value = std.json.Value{ .object = merged };
        const merged_json = std.json.Stringify.valueAlloc(ctx.allocator, merged_value, .{}) catch {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        };

        cms.restoreVersionWithData(db, post_id, merged_json, author_id) catch |err| {
            std.debug.print("Error restoring version with data: {}\n", .{err});
        };
    } else {
        // Full restore (legacy: no field params)
        cms.restoreVersion(ctx.allocator, db, post_id, version_id, author_id) catch |err| {
            std.debug.print("Error restoring version: {}\n", .{err});
        };
    }

    redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
}

fn handleAutosaveCreate(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"not authenticated\"}");
        return;
    };

    const title = ctx.formValue("title") orelse "";
    const slug = ctx.formValue("slug") orelse "";
    const body = ctx.formValue("content") orelse "";
    const featured_image_raw = ctx.formValue("featured_image") orelse "";
    const featured_image: ?[]const u8 = if (featured_image_raw.len > 0) featured_image_raw else null;

    const data = Post.Data{
        .title = title,
        .slug = slug,
        .body = body,
        .author = null,
        .category = null,
        .tag = null,
        .published_at = null,
        .featured = false,
        .featured_image = featured_image,
        .meta_description = null,
    };

    const author_id = auth_middleware.getUserId(ctx);
    const entry = cms.saveEntry(Post, ctx.allocator, db, null, data, .{
        .author_id = author_id,
        .status = "draft",
    }) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"save failed\"}");
        return;
    };

    const json = std.fmt.allocPrint(ctx.allocator, "{{\"entry_id\":\"{s}\",\"status\":\"draft\",\"saved\":true}}", .{entry.id}) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"format failed\"}");
        return;
    };

    ctx.response.setHeader("Content-Type", "application/json");
    ctx.response.setBody(json);
}

fn handleAutosaveUpdate(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"not authenticated\"}");
        return;
    };

    const post_id = ctx.param("id") orelse {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"missing id\"}");
        return;
    };

    // Get current entry to check status
    const entry = cms.getEntry(Post, ctx.allocator, db, post_id) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"entry not found\"}");
        return;
    } orelse {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"entry not found\"}");
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);

    // Get field ownership for hard lock validation
    const owners = getFieldOwnership(ctx.allocator, db, post_id) catch null;

    // Validate each field: reject if owned by another user
    var rejected: std.ArrayListUnmanaged(RejectedField) = .{};
    var newly_acquired: std.ArrayListUnmanaged([]const u8) = .{};

    const title = validateField(ctx, entry.title, "title", "title", author_id, post_id, owners, &rejected, &newly_acquired);
    const slug = validateField(ctx, entry.slug orelse "", "slug", "slug", author_id, post_id, owners, &rejected, &newly_acquired);
    const body = validateField(ctx, entry.data.body, "content", "body", author_id, post_id, owners, &rejected, &newly_acquired);
    const featured_image_raw = validateField(ctx, entry.data.featured_image orelse "", "featured_image", "featured_image", author_id, post_id, owners, &rejected, &newly_acquired);
    const featured_image: ?[]const u8 = if (featured_image_raw.len > 0) featured_image_raw else null;

    // Determine status: drafts stay draft; published/changed become "changed"
    const status: []const u8 = if (entry.isDraft()) "draft" else "changed";

    const data = Post.Data{
        .title = title,
        .slug = slug,
        .body = body,
        .author = null,
        .category = null,
        .tag = null,
        .published_at = null,
        .featured = false,
        .featured_image = featured_image,
        .meta_description = null,
    };

    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data, .{
        .author_id = author_id,
        .autosave = true,
        .status = status,
    }) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"save failed\"}");
        return;
    };

    // Broadcast lock_acquired for newly acquired fields
    if (newly_acquired.items.len > 0) {
        const user_email = auth_middleware.getUserEmail(ctx) orelse "";
        const user_name = getUserDisplayName(ctx.allocator, db, author_id) orelse user_email;
        const avatar = gravatar.url(user_email, 24);
        for (newly_acquired.items) |field_name| {
            presence.notifyLockAcquired(post_id, field_name, author_id orelse "", user_name, avatar.slice());
        }
    }

    // Detect fields that reverted to published value (no longer in ownership) → release hard locks
    if (owners != null) {
        const new_owners = getFieldOwnership(ctx.allocator, db, post_id) catch null;
        var released_fields: std.ArrayListUnmanaged([]const u8) = .{};
        var iter = owners.?.iterator();
        while (iter.next()) |kv| {
            const still_owned = if (new_owners) |new_own| new_own.contains(kv.key_ptr.*) else false;
            if (!still_owned) {
                released_fields.append(ctx.allocator, kv.key_ptr.*) catch {};
            }
        }
        if (released_fields.items.len > 0) {
            presence.notifyLocksReleased(post_id, released_fields.items);
        }
    }

    // Build response with rejected fields info
    const json = buildAutosaveResponse(ctx.allocator, status, rejected.items) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"format failed\"}");
        return;
    };

    ctx.response.setHeader("Content-Type", "application/json");
    ctx.response.setBody(json);
}

fn handleDiscard(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    _ = auth_middleware.getUserId(ctx);

    // Reset entry to published version without creating history.
    // This is a WIP revert — no trace needed.
    cms.discardToPublished(db, post_id) catch |err| {
        std.debug.print("Error discarding changes: {}\n", .{err});
    };

    redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
}

fn handleCreate(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    // Parse form data
    const title = ctx.formValue("title") orelse "";
    const slug = ctx.formValue("slug") orelse "";
    const body = ctx.formValue("content") orelse "";
    const status = ctx.formValue("status") orelse "draft";
    const featured_image_raw = ctx.formValue("featured_image") orelse "";
    const featured_image: ?[]const u8 = if (featured_image_raw.len > 0) featured_image_raw else null;

    // Create new post
    const data = Post.Data{
        .title = title,
        .slug = slug,
        .body = body,
        .author = null,
        .category = null,
        .tag = null,
        .published_at = null,
        .featured = false,
        .featured_image = featured_image,
        .meta_description = null,
    };

    const author_id = auth_middleware.getUserId(ctx);
    const entry = cms.saveEntry(Post, ctx.allocator, db, null, data, .{
        .author_id = author_id,
        .status = status,
    }) catch |err| {
        std.debug.print("Error creating post: {}\n", .{err});
        redirect(ctx, "/admin/posts");
        return;
    };

    // Publish if requested
    if (std.mem.eql(u8, status, "published")) {
        cms.publishEntry(ctx.allocator, db, entry.id, author_id, null) catch |err| {
            std.debug.print("Error publishing: {}\n", .{err});
        };
    }

    redirect(ctx, "/admin/posts");
}

fn handleUpdate(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    const action = ctx.formValue("action") orelse "";
    const fields_json_raw = ctx.formValue("fields") orelse "";
    const fields_json: ?[]const u8 = if (fields_json_raw.len > 0) fields_json_raw else null;

    // Fetch existing entry to preserve values for absent (disabled) fields
    const entry = cms.getEntry(Post, ctx.allocator, db, post_id) catch {
        redirect(ctx, "/admin/posts");
        return;
    } orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);

    // Get field ownership for hard lock validation
    const owners = getFieldOwnership(ctx.allocator, db, post_id) catch null;

    // Validate each field: reject if owned by another user
    var rejected: std.ArrayListUnmanaged(RejectedField) = .{};
    var newly_acquired: std.ArrayListUnmanaged([]const u8) = .{};

    const title = validateField(ctx, entry.title, "title", "title", author_id, post_id, owners, &rejected, &newly_acquired);
    const slug = validateField(ctx, entry.slug orelse "", "slug", "slug", author_id, post_id, owners, &rejected, &newly_acquired);
    const body = validateField(ctx, entry.data.body, "content", "body", author_id, post_id, owners, &rejected, &newly_acquired);
    const featured_image_raw = validateField(ctx, entry.data.featured_image orelse "", "featured_image", "featured_image", author_id, post_id, owners, &rejected, &newly_acquired);
    const featured_image: ?[]const u8 = if (featured_image_raw.len > 0) featured_image_raw else null;

    // Status: use form value if present (publish button), otherwise preserve existing status
    const status = ctx.formValue("status") orelse entry.status;

    const data = Post.Data{
        .title = title,
        .slug = slug,
        .body = body,
        .author = null,
        .category = null,
        .tag = null,
        .published_at = null,
        .featured = false,
        .featured_image = featured_image,
        .meta_description = null,
    };

    // Save entry (skips version creation if data unchanged)
    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data, .{
        .author_id = author_id,
        .status = status,
    }) catch |err| {
        std.debug.print("Error updating post: {}\n", .{err});
        redirect(ctx, "/admin/posts");
        return;
    };

    // Broadcast lock_acquired for newly acquired fields
    if (newly_acquired.items.len > 0) {
        const user_email = auth_middleware.getUserEmail(ctx) orelse "";
        const user_name = getUserDisplayName(ctx.allocator, db, author_id) orelse user_email;
        const avatar = gravatar.url(user_email, 24);
        for (newly_acquired.items) |field_name| {
            presence.notifyLockAcquired(post_id, field_name, author_id orelse "", user_name, avatar.slice());
        }
    }

    // Handle release actions — addToRelease reads version refs from entries table
    if (std.mem.eql(u8, action, "add_to_release")) {
        const release_id = ctx.formValue("release_id") orelse "";
        if (release_id.len > 0) {
            cms.addToRelease(db, release_id, post_id, fields_json) catch |err| {
                std.debug.print("Error adding to release: {}\n", .{err});
            };
        }
        broadcastReleaseUpdate(ctx.allocator, db, post_id);
        const url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
        redirect(ctx, url);
        return;
    }

    if (std.mem.eql(u8, action, "create_release")) {
        const release_name = ctx.formValue("release_name") orelse "";
        if (release_name.len > 0) {
            const rel_id = cms.createPendingRelease(db, release_name, author_id) catch {
                const url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
                redirect(ctx, url);
                return;
            };
            cms.addToRelease(db, &rel_id, post_id, fields_json) catch {};
        }
        broadcastReleaseUpdate(ctx.allocator, db, post_id);
        const url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
        redirect(ctx, url);
        return;
    }

    // Handle publish
    if (std.mem.eql(u8, status, "published")) {
        cms.publishEntry(ctx.allocator, db, post_id, author_id, fields_json) catch |err| {
            std.debug.print("Error publishing: {}\n", .{err});
        };
        notifyPublishedFieldsReleased(ctx.allocator, db, post_id, fields_json);
    }

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
    redirect(ctx, url);
}

fn handleDelete(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    cms.deleteEntry(db, post_id) catch |err| {
        std.debug.print("Error deleting post: {}\n", .{err});
    };

    redirect(ctx, "/admin/posts");
}

fn handlePublish(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);
    const fields_json_raw = ctx.formValue("fields") orelse "";
    const fields_json: ?[]const u8 = if (fields_json_raw.len > 0) fields_json_raw else null;

    cms.publishEntry(ctx.allocator, db, post_id, author_id, fields_json) catch |err| {
        std.debug.print("Error publishing: {}\n", .{err});
        redirect(ctx, "/admin/posts");
        return;
    };

    // Broadcast lock_released for published fields
    notifyPublishedFieldsReleased(ctx.allocator, db, post_id, fields_json);

    redirect(ctx, "/admin/posts");
}

fn handleUnpublish(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/posts");
        return;
    };

    const post_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    // Get existing post
    const entry = cms.getEntry(Post, ctx.allocator, db, post_id) catch {
        redirect(ctx, "/admin/posts");
        return;
    } orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    // Update status to draft
    const data = entry.data;

    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data, .{
        .author_id = auth_middleware.getUserId(ctx),
        .status = "draft",
    }) catch |err| {
        std.debug.print("Error unpublishing post: {}\n", .{err});
    };

    redirect(ctx, "/admin/posts");
}

// =============================================================================
// Helpers
// =============================================================================

const pu = @import("plugin_utils");
const redirect = pu.redirect;

fn formatDate(timestamp: i64, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
}

const Db = @import("db").Db;

// =============================================================================
// Hard Lock Helpers
// =============================================================================

const RejectedField = struct {
    field: []const u8,
    owner_name: []const u8,
};

/// Get field ownership for an entry: JSON field key → owner user_id.
/// Returns null if no ownership applies (fresh draft with no published version).
fn getFieldOwnership(allocator: std.mem.Allocator, db: *Db, entry_id: []const u8) !?std.StringHashMapUnmanaged(cms.FieldComparison) {
    var ver_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM entries WHERE id = ?1",
    );
    defer ver_stmt.deinit();
    try ver_stmt.bindText(1, entry_id);
    if (!try ver_stmt.step()) return null;

    const current_vid_raw = ver_stmt.columnText(0) orelse return null;
    const published_vid_raw = ver_stmt.columnText(1) orelse return null; // No published = fresh draft
    if (std.mem.eql(u8, current_vid_raw, published_vid_raw)) return null; // No changes

    const cur_vid = try allocator.dupe(u8, current_vid_raw);
    defer allocator.free(cur_vid);
    const pub_vid = try allocator.dupe(u8, published_vid_raw);
    defer allocator.free(pub_vid);

    // Get published and current data
    const published_data = try cms.getPublishedData(allocator, db, entry_id) orelse return null;
    defer allocator.free(published_data);

    var data_stmt = try db.prepare("SELECT data FROM entry_versions WHERE id = ?1");
    defer data_stmt.deinit();
    try data_stmt.bindText(1, cur_vid);
    if (!try data_stmt.step()) return null;
    const current_data = try allocator.dupe(u8, data_stmt.columnText(0) orelse "{}");
    defer allocator.free(current_data);

    // Compare fields and attribute authors
    const fields = try cms.compareVersionFields(allocator, published_data, current_data);
    cms.populateFieldAuthors(allocator, db, fields, cur_vid, pub_vid);

    // Build map of changed field → FieldComparison (keyed by field name)
    var map: std.StringHashMapUnmanaged(cms.FieldComparison) = .{};
    for (fields) |f| {
        if (f.changed and f.changed_by_id != null) {
            map.put(allocator, f.key, f) catch continue;
        }
    }
    return map;
}

/// Validate a single field against ownership. Returns the value to use.
/// If the field is owned by another user, returns existing value and appends to rejected.
/// If the field is newly acquired (unowned before, user is changing it), appends to newly_acquired.
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
            .owner => return submitted, // Takeover override: this user owns the field
            .not_owner => {
                // Someone else took over this field
                rejected.append(ctx.allocator, .{
                    .field = json_key,
                    .owner_name = "another user",
                }) catch {};
                return existing_value;
            },
            .none => {}, // Fall through to normal check
        }
    }

    if (owners) |own| {
        if (own.get(json_key)) |field_info| {
            // Field is owned by someone
            if (author_id) |aid| {
                if (field_info.changed_by_id) |owner_id| {
                    if (!std.mem.eql(u8, owner_id, aid)) {
                        // Owned by another user — reject
                        rejected.append(ctx.allocator, .{
                            .field = json_key,
                            .owner_name = field_info.changed_by orelse "another user",
                        }) catch {};
                        return existing_value;
                    }
                }
            }
            // Owned by current user — accept
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
fn buildAutosaveResponse(allocator: std.mem.Allocator, status: []const u8, rejected: []const RejectedField) ![]const u8 {
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

/// Get a user's display_name from the DB. Falls back to null.
fn getUserDisplayName(allocator: std.mem.Allocator, db: *Db, user_id: ?[]const u8) ?[]const u8 {
    const uid = user_id orelse return null;
    var stmt = db.prepare("SELECT display_name FROM users WHERE id = ?1") catch return null;
    defer stmt.deinit();
    stmt.bindText(1, uid) catch return null;
    if (!(stmt.step() catch return null)) return null;
    const dn = stmt.columnText(0) orelse return null;
    if (dn.len == 0) return null;
    return allocator.dupe(u8, dn) catch null;
}

const AuthorInfo = struct {
    id: []const u8,
    display_name: []const u8,
    email: []const u8,

    fn label(self: AuthorInfo) []const u8 {
        return if (self.display_name.len > 0) self.display_name else self.email;
    }
};

const EntryAuthors = struct {
    entry_id: []const u8,
    authors: []const AuthorInfo,
};

/// Batch-query all distinct authors for a list of entry IDs.
/// Returns one EntryAuthors per entry that has authors, in entry_id order.
fn resolveEntryAuthors(allocator: std.mem.Allocator, db: *Db, entry_ids: []const []const u8) []const EntryAuthors {
    if (entry_ids.len == 0) return &.{};

    // Build: SELECT DISTINCT ev.entry_id, u.id, u.display_name, u.email
    //        FROM entry_versions ev JOIN users u ON u.id = ev.author_id
    //        WHERE ev.entry_id IN (?1, ?2, ...) AND ev.author_id IS NOT NULL
    //          AND ev.version_type IN ('created', 'updated', 'published')
    //        ORDER BY ev.entry_id, ev.created_at ASC
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    w.writeAll(
        \\SELECT DISTINCT ev.entry_id, u.id, u.display_name, u.email
        \\ FROM entry_versions ev JOIN users u ON u.id = ev.author_id
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

    // Collect rows grouped by entry_id
    var results: std.ArrayListUnmanaged(EntryAuthors) = .{};
    var current_authors: std.ArrayListUnmanaged(AuthorInfo) = .{};
    var current_entry_id: ?[]const u8 = null;

    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        const row_entry_id = stmt.columnText(0) orelse continue;
        const user_id = stmt.columnText(1) orelse continue;
        const display_name = stmt.columnText(2) orelse "";
        const email = stmt.columnText(3) orelse continue;

        // Check if we moved to a new entry
        if (current_entry_id) |cur| {
            if (!std.mem.eql(u8, cur, row_entry_id)) {
                // Flush previous entry
                const authors_slice = current_authors.toOwnedSlice(allocator) catch continue;
                results.append(allocator, .{
                    .entry_id = cur,
                    .authors = authors_slice,
                }) catch continue;
                current_entry_id = allocator.dupe(u8, row_entry_id) catch continue;
            }
        } else {
            current_entry_id = allocator.dupe(u8, row_entry_id) catch continue;
        }

        // Deduplicate by user_id within this entry
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

    // Flush last entry
    if (current_entry_id) |cur| {
        const authors_slice = current_authors.toOwnedSlice(allocator) catch return results.toOwnedSlice(allocator) catch &.{};
        results.append(allocator, .{
            .entry_id = cur,
            .authors = authors_slice,
        }) catch {};
    }

    return results.toOwnedSlice(allocator) catch &.{};
}

/// Find authors for a specific entry from the batch result.
fn findAuthorsForEntry(all: []const EntryAuthors, entry_id: []const u8) []const AuthorInfo {
    for (all) |ea| {
        if (std.mem.eql(u8, ea.entry_id, entry_id)) return ea.authors;
    }
    return &.{};
}

/// Render author avatars + label HTML for a table cell.
fn renderAuthorCell(allocator: std.mem.Allocator, authors: []const AuthorInfo) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    if (authors.len == 0) {
        w.writeAll("<span class=\"text-tertiary\">System</span>") catch return "System";
        return buf.toOwnedSlice(allocator) catch "System";
    }

    if (authors.len == 1) {
        // Single author: avatar + name
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

    // Multiple authors: stacked avatars + "N authors"
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

/// Query all users who have authored at least one version for a content type.
fn getAvailableAuthors(allocator: std.mem.Allocator, db: *Db, content_type_id: []const u8) []const AuthorInfo {
    var stmt = db.prepare(
        \\SELECT DISTINCT u.id, u.display_name, u.email FROM users u
        \\JOIN entry_versions ev ON ev.author_id = u.id
        \\JOIN entries e ON e.id = ev.entry_id
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

/// Query entry IDs that have at least one version by a specific author.
fn getEntryIdsByAuthor(allocator: std.mem.Allocator, db: *Db, author_id: []const u8, content_type_id: []const u8) []const []const u8 {
    var stmt = db.prepare(
        \\SELECT DISTINCT ev.entry_id FROM entry_versions ev
        \\JOIN entries e ON e.id = ev.entry_id
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

/// Notify presence system that published fields had their hard locks released.
/// For partial publish, releases only specified fields. For full publish, releases all data fields.
fn notifyPublishedFieldsReleased(allocator: std.mem.Allocator, db: *Db, entry_id: []const u8, fields_json: ?[]const u8) void {
    if (fields_json) |fj| {
        // Partial publish: parse field names from JSON array
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
        // Full publish: get all field names from entry data
        var stmt = db.prepare("SELECT data FROM entries WHERE id = ?1") catch return;
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

/// Broadcast updated fieldsInReleases to all subscribers of an entry.
fn broadcastReleaseUpdate(allocator: std.mem.Allocator, db: *Db, entry_id: []const u8) void {
    const release_field_info = cms.getEntryPendingReleaseFields(allocator, db, entry_id) catch return;
    const json = buildFieldsInReleasesJson(allocator, release_field_info) catch return;

    // Wrap in {"fields_in_releases": <json>}
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"fields_in_releases\":") catch return;
    w.writeAll(json) catch return;
    w.writeByte('}') catch return;

    presence.broadcastEntryMessage(entry_id, "release_updated", buf.items);
}

/// Build JSON for fields-in-releases data attribute.
/// Output: [{"id":"...","name":"...","fields":["a","b"]},{"id":"...","name":"...","fields":null}]
/// Build JSON mapping field keys to their last editor info, excluding the current user.
/// Returns e.g. {"title":{"name":"John","avatar":"https://gravatar.com/..."}}
fn buildFieldEditorsJson(allocator: std.mem.Allocator, db: *Db, entry_id: []const u8, current_user_id: []const u8) ![]const u8 {
    // Get current and published version IDs
    var ver_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM entries WHERE id = ?1",
    );
    defer ver_stmt.deinit();
    try ver_stmt.bindText(1, entry_id);
    if (!try ver_stmt.step()) return try allocator.dupe(u8, "{}");

    const current_vid = ver_stmt.columnText(0) orelse return try allocator.dupe(u8, "{}");
    const published_vid = ver_stmt.columnText(1) orelse return try allocator.dupe(u8, "{}");
    if (std.mem.eql(u8, current_vid, published_vid)) return try allocator.dupe(u8, "{}");

    // Dupe before the statement is deinitialized
    const cur_vid = try allocator.dupe(u8, current_vid);
    defer allocator.free(cur_vid);
    const pub_vid = try allocator.dupe(u8, published_vid);
    defer allocator.free(pub_vid);

    // Get published and current data for comparison
    const published_data = try cms.getPublishedData(allocator, db, entry_id) orelse return try allocator.dupe(u8, "{}");
    defer allocator.free(published_data);

    // Get current version data
    var data_stmt = try db.prepare("SELECT data FROM entry_versions WHERE id = ?1");
    defer data_stmt.deinit();
    try data_stmt.bindText(1, cur_vid);
    if (!try data_stmt.step()) return try allocator.dupe(u8, "{}");
    const current_data = try allocator.dupe(u8, data_stmt.columnText(0) orelse "{}");
    defer allocator.free(current_data);

    // Compare fields and attribute authors
    const fields = try cms.compareVersionFields(allocator, published_data, current_data);
    defer allocator.free(fields);
    cms.populateFieldAuthors(allocator, db, fields, cur_vid, pub_vid);

    // Find the current user's email for comparison
    var user_stmt = try db.prepare("SELECT email FROM users WHERE id = ?1");
    defer user_stmt.deinit();
    try user_stmt.bindText(1, current_user_id);
    const current_email = if (try user_stmt.step())
        user_stmt.columnText(0) orelse ""
    else
        "";

    // Build JSON with only fields changed by other users
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('{');
    var first = true;
    for (fields) |f| {
        if (!f.changed) continue;
        const editor_email = f.changed_by_email orelse continue;
        // Skip fields changed by the current user
        if (current_email.len > 0 and std.mem.eql(u8, editor_email, current_email)) continue;

        if (!first) try w.writeByte(',');
        first = false;

        // Key
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

const writeJsonEscaped = pu.writeJsonEscaped;

/// Render collaborator avatar stack from a JSON array of {email, name} objects.
/// Used by both version preview and version history sidebar.
/// Falls back to a single author avatar or system icon.
fn writeCollaboratorAvatars(
    w: anytype,
    allocator: std.mem.Allocator,
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
        // Parsed but empty/invalid — fall through to system icon
        try w.writeAll("<span class=\"version-avatar version-avatar-system\">S</span>");
        return;
    }

    // No collaborators JSON — show single author avatar or system icon
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

fn buildFieldsInReleasesJson(allocator: std.mem.Allocator, items: []const cms.EntryReleaseFieldInfo) ![]const u8 {
    if (items.len == 0) return try allocator.dupe(u8, "[]");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        // release_id is system-generated (safe for direct output)
        try w.writeAll("{\"id\":\"");
        try w.writeAll(item.release_id);
        try w.writeAll("\",\"name\":");
        // JSON-escape the release name (user input)
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
            try w.writeAll(f); // Already a JSON array from the database
        } else {
            try w.writeAll("null");
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(allocator);
}

/// Build version history HTML for the edit sidebar
fn buildVersionHistoryHtml(allocator: std.mem.Allocator, db: *Db, entry_id: []const u8) ![]const u8 {
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
        const time_str = cms.formatRelativeTime(allocator, v.created_at) catch "Unknown";
        const version_url = std.fmt.allocPrint(allocator, "/admin/posts/{s}/versions/{s}", .{ entry_id, v.id }) catch "";

        if (v.is_current) {
            try w.writeAll("<div class=\"version-item version-current\">");
        } else {
            try w.writeAll("<a href=\"");
            try w.writeAll(version_url);
            try w.writeAll("\" class=\"version-item\">");
        }

        // Avatars: show collaborators stack for published versions, single avatar otherwise
        try writeCollaboratorAvatars(w, allocator, v.collaborators, v.author_email, v.authorLabel());

        // Info column: type + time + optional release name
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
        try w.writeAll("</span></span>");

        if (v.is_current) {
            try w.writeAll("<span class=\"version-badge\">current</span></div>");
        } else {
            try w.writeAll("</a>");
        }
    }

    try w.writeAll("</div></div>");

    return buf.toOwnedSlice(allocator);
}

// =============================================================================
// Takeover — called from WebSocket dispatch
// =============================================================================

/// Handle a takeover request from a WebSocket connection.
/// Checks authorization and transfers field ownership if allowed.
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
