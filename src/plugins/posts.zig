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
    app.post(handleCreate);
    app.postAt("/:id", handleUpdate);
    app.postAt("/:id/delete", handleDelete);
    app.postAt("/:id/publish", handlePublish);
    app.postAt("/:id/unpublish", handleUnpublish);
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
        is_draft: bool,
        is_published: bool,
        featured_image: []const u8,
        featured_image_url: []const u8,
    };

    const post_data = PostData{
        .title = "",
        .slug = "",
        .content = "",
        .date = formatDate(std.time.timestamp(), ctx.allocator) catch "Unknown",
        .is_draft = true,
        .is_published = false,
        .featured_image = "",
        .featured_image_url = "",
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
        is_draft: bool,
        is_published: bool,
        featured_image: []const u8,
        featured_image_url: []const u8,
    };

    const edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{post_id}) catch "/admin/posts";
    const delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}/delete", .{post_id}) catch "";

    // Get featured image URL if set
    const featured_image_id = entry.data.featured_image orelse "";
    const featured_image_url = if (featured_image_id.len > 0)
        std.fmt.allocPrint(ctx.allocator, "/admin/media/picker/thumb/{s}", .{featured_image_id}) catch ""
    else
        "";

    const post_data = PostData{
        .title = entry.title,
        .slug = entry.slug orelse "",
        .content = entry.data.body,
        .date = formatDate(entry.created_at, ctx.allocator) catch "Unknown",
        .is_draft = entry.isDraft(),
        .is_published = entry.isPublished(),
        .featured_image = featured_image_id,
        .featured_image_url = featured_image_url,
    };

    const content = tpl.render(views.admin.posts.edit.Edit, .{.{
        .post = post_data,
        .csrf_token = csrf_token,
        .action = edit_url,
    }});

    const sidebar = tpl.render(views.admin.posts.edit.EditSidebar, .{.{
        .post = post_data,
        .csrf_token = csrf_token,
        .delete_url = delete_url,
    }});

    ctx.html(registry.renderEditPage(page, ctx, entry.title, content, .{
        .back_url = "/admin/posts",
        .back_label = "Posts",
        .sidebar = sidebar,
    }));
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

    _ = cms.saveEntry(Post, ctx.allocator, db, null, data) catch |err| {
        std.debug.print("Error creating post: {}\n", .{err});
    };

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

    // Parse form data
    const title = ctx.formValue("title") orelse "";
    const slug = ctx.formValue("slug") orelse "";
    const body = ctx.formValue("content") orelse "";
    const status = ctx.formValue("status") orelse "draft";
    const featured_image_raw = ctx.formValue("featured_image") orelse "";
    const featured_image: ?[]const u8 = if (featured_image_raw.len > 0) featured_image_raw else null;

    // Update post
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

    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data) catch |err| {
        std.debug.print("Error updating post: {}\n", .{err});
    };

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

    // Update status to published
    var data = entry.data;
    data.status = "published";

    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data) catch |err| {
        std.debug.print("Error publishing post: {}\n", .{err});
    };

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

    _ = cms.saveEntry(Post, ctx.allocator, db, post_id, data) catch |err| {
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
