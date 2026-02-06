//! Posts plugin - content management pages

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const csrf = @import("csrf");
const zsx_admin_posts_list = @import("zsx_admin_posts_list");
const zsx_admin_posts_edit = @import("zsx_admin_posts_edit");
const registry = @import("registry");

/// Posts list page (shows in nav)
pub const page = admin.registerPage(.{
    .id = "posts",
    .title = "Posts",
    .path = "/posts",
    .icon = icons.edit,
    .position = 20,
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleList);
    app.get("/new", handleNew);
    app.get("/:id", handleEdit);
    app.postAt("/:id", handleUpdate);
    app.postAt("/:id/delete", handleDelete);
    app.postAt("/:id/publish", handlePublish);
    app.postAt("/:id/unpublish", handleUnpublish);
}

// =============================================================================
// Handlers
// =============================================================================

fn handleList(ctx: *Context) !void {
    const Post = struct {
        id: []const u8,
        title: []const u8,
        author: []const u8,
        status: []const u8,
        date: []const u8,
        edit_url: []const u8,
        preview_url: []const u8,
    };

    // TODO: Fetch from database. For now, use static data with generated URLs.
    const static_posts = [_]struct { id: []const u8, title: []const u8, author: []const u8, status: []const u8, date: []const u8 }{
        .{ .id = "1", .title = "Welcome to Publr", .author = "Admin", .status = "published", .date = "2024-01-15" },
        .{ .id = "2", .title = "Getting Started Guide", .author = "Admin", .status = "draft", .date = "2024-01-14" },
        .{ .id = "3", .title = "Advanced Features", .author = "Admin", .status = "draft", .date = "2024-01-13" },
    };

    var posts: [static_posts.len]Post = undefined;
    for (static_posts, 0..) |p, i| {
        posts[i] = .{
            .id = p.id,
            .title = p.title,
            .author = p.author,
            .status = p.status,
            .date = p.date,
            .edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{p.id}) catch "/admin/posts",
            .preview_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}/preview", .{p.id}) catch "/admin/posts",
        };
    }

    const content = tpl.render(zsx_admin_posts_list.List, .{.{
        .has_posts = true,
        .posts = &posts,
    }});
    const actions = "<a href=\"/admin/posts/new\" class=\"btn btn-primary\">New Post</a>";

    ctx.html(registry.renderPage(page, ctx, content, actions));
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
    };

    const content = tpl.render(zsx_admin_posts_edit.Edit, .{.{
        .post = PostData{
            .title = "",
            .slug = "",
            .content = "",
            .date = "2024-01-15",
            .is_draft = true,
            .is_published = false,
        },
        .csrf_token = csrf_token,
    }});

    ctx.html(registry.renderPage(page, ctx, content, ""));
}

fn handleEdit(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const post_id = ctx.param("id") orelse "1";
    _ = post_id;

    const PostData = struct {
        title: []const u8,
        slug: []const u8,
        content: []const u8,
        date: []const u8,
        is_draft: bool,
        is_published: bool,
    };

    const content = tpl.render(zsx_admin_posts_edit.Edit, .{.{
        .post = PostData{
            .title = "Welcome to Publr",
            .slug = "welcome-to-publr",
            .content = "This is the content of the post...",
            .date = "2024-01-15",
            .is_draft = false,
            .is_published = true,
        },
        .csrf_token = csrf_token,
    }});

    ctx.html(registry.renderPage(page, ctx, content, ""));
}

fn handleUpdate(ctx: *Context) !void {
    // TODO: Save post to database
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/posts");
    ctx.response.setBody("");
}

fn handleDelete(ctx: *Context) !void {
    // TODO: Delete post from database
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/posts");
    ctx.response.setBody("");
}

fn handlePublish(ctx: *Context) !void {
    // TODO: Update post status
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/posts");
    ctx.response.setBody("");
}

fn handleUnpublish(ctx: *Context) !void {
    // TODO: Update post status
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/posts");
    ctx.response.setBody("");
}
