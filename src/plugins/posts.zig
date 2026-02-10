//! Posts plugin - content management pages
//!
//! Uses the CMS module for database operations with the Post content type.

const std = @import("std");
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

const Post = schemas.Post;

/// Posts list page (shows in nav)
pub const page = admin.registerPage(.{
    .id = "posts",
    .title = "Posts",
    .path = "/posts",
    .icon = icons.edit,
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

fn handleList(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const ViewPost = struct {
        id: []const u8,
        title: []const u8,
        author: []const u8,
        status: []const u8,
        date: []const u8,
        edit_url: []const u8,
        preview_url: []const u8,
    };

    // Fetch posts from database
    const entries = cms.listEntries(Post, ctx.allocator, db, .{
        .limit = 50,
        .order_by = "created_at",
        .order_dir = .desc,
    }) catch |err| {
        std.debug.print("Error listing posts: {}\n", .{err});
        // Fall back to empty list on error
        const content = tpl.render(views.admin.posts.list.List, .{.{
            .has_posts = false,
            .posts = &[_]ViewPost{},
        }});
        ctx.html(registry.renderPage(page, ctx, content));
        return;
    };

    // Convert to view format
    var posts = ctx.allocator.alloc(ViewPost, entries.len) catch {
        ctx.html("Error allocating memory");
        return;
    };

    for (entries, 0..) |entry, i| {
        posts[i] = .{
            .id = entry.id,
            .title = entry.title,
            .author = "Admin", // TODO: resolve author reference
            .status = entry.status,
            .date = formatDate(entry.created_at, ctx.allocator) catch "Unknown",
            .edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{entry.id}) catch "/admin/posts",
            .preview_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}/preview", .{entry.id}) catch "/admin/posts",
        };
    }

    const content = tpl.render(views.admin.posts.list.List, .{.{
        .has_posts = posts.len > 0,
        .posts = posts,
    }});

    ctx.html(registry.renderPage(page, ctx, content));
}

fn handleNew(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);

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

    const post_data = PostData{
        .title = "",
        .slug = "",
        .content = "",
        .date = formatDate(std.time.timestamp(), ctx.allocator) catch "Unknown",
        .status = "draft",
        .is_draft = true,
        .is_published = false,
        .is_changed = false,
        .featured_image = "",
        .featured_image_url = "",
        .entry_id = "",
        .published_data = "",
    };

    const content = tpl.render(views.admin.posts.edit.Edit, .{.{
        .post = post_data,
        .csrf_token = csrf_token,
        .action = "/admin/posts",
    }});

    const sidebar = tpl.render(views.admin.posts.edit.EditSidebar, .{.{
        .post = post_data,
        .csrf_token = csrf_token,
        .delete_url = "",
        .history_html = "",
        .release_html = "",
    }});

    ctx.html(registry.renderEditPage(page, ctx, "New Post", content, .{
        .back_url = "/admin/posts",
        .back_label = "Posts",
        .sidebar = sidebar,
    }));
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

    ctx.html(registry.renderEditPage(page, ctx, entry.title, content, .{
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
    const current_data = cms.getVersion(ctx.allocator, db, blk: {
        var cur_stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = ?1");
        defer cur_stmt.deinit();
        try cur_stmt.bindText(1, post_id);
        _ = try cur_stmt.step();
        break :blk try ctx.allocator.dupe(u8, cur_stmt.columnText(0) orelse "");
    }) catch null;

    const current_json = if (current_data) |cd| cd.data else "{}";

    // Get structured field comparison
    const fields = cms.compareVersionFields(ctx.allocator, version.data, current_json) catch &.{};

    // Count changed fields
    var changed_count: u32 = 0;
    for (fields) |f| {
        if (f.changed) changed_count += 1;
    }

    const time_str = cms.formatRelativeTime(ctx.allocator, version.created_at) catch "Unknown";
    const author_str = version.author_email orelse "System";
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

        // Header row with version info
        try w.writeAll(
            \\<div class="version-compare-header">
            \\  <div class="version-compare-col-old">
            \\    <span class="version-compare-col-title">
        );
        try w.writeAll(author_str);
        try w.writeAll(" &middot; ");
        try w.writeAll(time_str);
        try w.writeAll(
            \\</span>
            \\    <a href="#" id="select-all-old" class="version-compare-select-all">Select all from this version</a>
            \\  </div>
            \\  <div class="version-compare-col-current">
            \\    <span class="version-compare-col-title">Current version</span>
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

            // Field label
            try w.writeAll("<div class=\"version-compare-label\">");
            try cms.writeEscaped(w, f.key);
            if (f.changed) {
                try w.writeAll(" <span class=\"version-compare-badge\">changed</span>");
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
        .status = "draft",
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

    const title = ctx.formValue("title") orelse "";
    const slug = ctx.formValue("slug") orelse "";
    const body = ctx.formValue("content") orelse "";
    const featured_image_raw = ctx.formValue("featured_image") orelse "";
    const featured_image: ?[]const u8 = if (featured_image_raw.len > 0) featured_image_raw else null;

    // Determine status: drafts stay draft; published/changed entries
    // check against published version to determine if changed
    var status: []const u8 = "draft";
    if (entry.isDraft()) {
        status = "draft";
    } else {
        // Entry was published or changed — compare against published data
        const published_data = cms.getPublishedData(ctx.allocator, db, post_id) catch null;
        if (published_data) |pd| {
            // Build current data JSON for comparison
            const current_data = Post.Data{
                .title = title,
                .slug = slug,
                .body = body,
                .status = "published", // normalize for comparison
                .author = null,
                .category = null,
                .tag = null,
                .published_at = null,
                .featured = false,
                .featured_image = featured_image,
                .meta_description = null,
            };
            const current_json = Post.stringifyData(ctx.allocator, current_data) catch null;
            if (current_json) |cj| {
                status = if (std.mem.eql(u8, cj, pd)) "published" else "changed";
            } else {
                status = "changed";
            }
        } else {
            // No published version — keep as published (shouldn't happen normally)
            status = "published";
        }
    }

    const data = Post.Data{
        .title = title,
        .slug = slug,
        .body = body,
        .status = status,
        .author = null,
        .category = null,
        .tag = null,
        .published_at = null,
        .featured = false,
        .featured_image = featured_image,
        .meta_description = null,
    };

    const author_id = auth_middleware.getUserId(ctx);
    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data, .{
        .author_id = author_id,
    }) catch {
        ctx.response.setHeader("Content-Type", "application/json");
        ctx.response.setBody("{\"error\":\"save failed\"}");
        return;
    };

    const json = std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"{s}\",\"saved\":true}}", .{status}) catch {
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

    const author_id = auth_middleware.getUserId(ctx);

    // Get published version data
    const published_data = cms.getPublishedData(ctx.allocator, db, post_id) catch null;
    if (published_data) |pd| {
        // Restore to published version's data
        cms.restoreVersionWithData(db, post_id, pd, author_id) catch |err| {
            std.debug.print("Error discarding changes: {}\n", .{err});
        };

        // Set status back to published
        var stmt = db.prepare(
            "UPDATE entries SET status = 'published' WHERE id = ?1",
        ) catch {
            redirect(ctx, std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts");
            return;
        };
        defer stmt.deinit();
        stmt.bindText(1, post_id) catch {};
        _ = stmt.step() catch {};
    }

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
        .status = status,
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
    }) catch |err| {
        std.debug.print("Error creating post: {}\n", .{err});
        redirect(ctx, "/admin/posts");
        return;
    };

    // Create release if publishing
    if (std.mem.eql(u8, status, "published")) {
        const to_version = cms.getEntryVersionId(db, entry.id) catch null;
        defer if (to_version) |v| db.allocator.free(v);
        if (to_version) |tv| {
            cms.createRelease(db, entry.id, null, tv, author_id) catch |err| {
                std.debug.print("Error creating release: {}\n", .{err});
            };
        }
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

    // Parse form data (shared by all actions — release actions now submit through main form)
    const title = ctx.formValue("title") orelse "";
    const slug = ctx.formValue("slug") orelse "";
    const body = ctx.formValue("content") orelse "";
    const status = ctx.formValue("status") orelse "draft";
    const featured_image_raw = ctx.formValue("featured_image") orelse "";
    const featured_image: ?[]const u8 = if (featured_image_raw.len > 0) featured_image_raw else null;

    const data = Post.Data{
        .title = title,
        .slug = slug,
        .body = body,
        .status = status,
        .author = null,
        .category = null,
        .tag = null,
        .published_at = null,
        .featured = false,
        .featured_image = featured_image,
        .meta_description = null,
    };

    const author_id = auth_middleware.getUserId(ctx);

    // Capture version before save
    const from_version = cms.getEntryVersionId(db, post_id) catch null;
    defer if (from_version) |v| db.allocator.free(v);

    // Save entry (skips version creation if data unchanged)
    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data, .{
        .author_id = author_id,
    }) catch |err| {
        std.debug.print("Error updating post: {}\n", .{err});
        redirect(ctx, "/admin/posts");
        return;
    };

    // Capture version after save
    const to_version = cms.getEntryVersionId(db, post_id) catch null;
    defer if (to_version) |v| db.allocator.free(v);

    const version_changed = if (from_version) |fv|
        if (to_version) |tv| !std.mem.eql(u8, fv, tv) else false
    else
        to_version != null;

    // Handle release actions
    if (std.mem.eql(u8, action, "add_to_release")) {
        const release_id = ctx.formValue("release_id") orelse "";
        if (release_id.len > 0 and version_changed) {
            if (to_version) |tv| {
                cms.addToRelease(db, release_id, post_id, from_version, tv) catch |err| {
                    std.debug.print("Error adding to release: {}\n", .{err});
                };
            }
        }
        const url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
        redirect(ctx, url);
        return;
    }

    if (std.mem.eql(u8, action, "create_release")) {
        const release_name = ctx.formValue("release_name") orelse "";
        if (release_name.len > 0 and version_changed) {
            const rel_id = cms.createPendingRelease(db, release_name, author_id) catch {
                const url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
                redirect(ctx, url);
                return;
            };
            if (to_version) |tv| {
                cms.addToRelease(db, &rel_id, post_id, from_version, tv) catch {};
            }
        }
        const url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
        redirect(ctx, url);
        return;
    }

    // Create instant release if publishing and version actually changed
    if (std.mem.eql(u8, status, "published") and version_changed) {
        if (to_version) |tv| {
            cms.createRelease(db, post_id, from_version, tv, author_id) catch |err| {
                std.debug.print("Error creating release: {}\n", .{err});
            };
        }
    }

    redirect(ctx, "/admin/posts");
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

    // Get existing post
    const entry = cms.getEntry(Post, ctx.allocator, db, post_id) catch {
        redirect(ctx, "/admin/posts");
        return;
    } orelse {
        redirect(ctx, "/admin/posts");
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);

    // Capture version before save for release tracking
    const from_version = cms.getEntryVersionId(db, post_id) catch null;
    defer if (from_version) |v| db.allocator.free(v);

    // Update status to published
    var data = entry.data;
    data.status = "published";

    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data, .{
        .author_id = author_id,
    }) catch |err| {
        std.debug.print("Error publishing post: {}\n", .{err});
        redirect(ctx, "/admin/posts");
        return;
    };

    // Create release
    const to_version = cms.getEntryVersionId(db, post_id) catch null;
    defer if (to_version) |v| db.allocator.free(v);
    if (to_version) |tv| {
        const skip = if (from_version) |fv| std.mem.eql(u8, fv, tv) else false;
        if (!skip) {
            cms.createRelease(db, post_id, from_version, tv, author_id) catch |err| {
                std.debug.print("Error creating release: {}\n", .{err});
            };
        }
    }

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
    var data = entry.data;
    data.status = "draft";

    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data, .{
        .author_id = auth_middleware.getUserId(ctx),
    }) catch |err| {
        std.debug.print("Error unpublishing post: {}\n", .{err});
    };

    redirect(ctx, "/admin/posts");
}

// =============================================================================
// Helpers
// =============================================================================

fn redirect(ctx: *Context, location: []const u8) void {
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", location);
    ctx.response.setBody("");
}

fn formatDate(timestamp: i64, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
}

const Db = @import("db").Db;

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

        // Avatar
        if (v.author_email) |email| {
            const avatar = gravatar.url(email, 24);
            try w.writeAll("<img src=\"");
            try w.writeAll(avatar.slice());
            try w.writeAll("\" alt=\"\" class=\"version-avatar\" />");
        } else {
            try w.writeAll("<span class=\"version-avatar version-avatar-system\">S</span>");
        }

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
