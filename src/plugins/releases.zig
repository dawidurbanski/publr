//! Releases plugin - batch release management pages
//!
//! Provides UI for creating, viewing, and managing batch releases.
//! Releases group multiple entry changes and publish them atomically.

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const csrf = @import("csrf");
const cms = @import("cms");
const views = @import("views");
const registry = @import("registry");
const auth_middleware = @import("auth_middleware");

/// Releases list page (shows in content sidebar)
pub const page = admin.registerPage(.{
    .id = "releases",
    .title = "Releases",
    .path = "/releases",
    .icon = icons.package,
    .position = 25,
    .section = "releases",
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleList);
    app.get("/new", handleNew);
    app.post(handleCreate);
    app.get("/:id", handleDetail);
    app.postAt("/:id/publish", handlePublish);
    app.postAt("/:id/revert", handleRevert);
    app.postAt("/:id/re-release", handleReRelease);
    app.postAt("/:id/archive", handleArchive);
    app.postAt("/:id/remove/:eid", handleRemoveItem);
}

// =============================================================================
// Handlers
// =============================================================================

fn handleList(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        ctx.html("Database not initialized");
        return;
    };

    const ViewRelease = struct {
        id: []const u8,
        name: []const u8,
        status: []const u8,
        item_count: []const u8,
        author: []const u8,
        date: []const u8,
        detail_url: []const u8,
    };

    const releases = cms.listReleases(ctx.allocator, db, .{ .limit = 50 }) catch |err| {
        std.log.err("releases: listReleases failed: {s}", .{@errorName(err)});
        ctx.html("Error loading releases");
        return;
    };

    var view_releases = ctx.allocator.alloc(ViewRelease, releases.len) catch {
        ctx.html("Error loading releases");
        return;
    };

    for (releases, 0..) |rel, i| {
        view_releases[i] = .{
            .id = rel.id,
            .name = rel.name,
            .status = rel.status,
            .item_count = std.fmt.allocPrint(ctx.allocator, "{d}", .{rel.item_count}) catch "0",
            .author = rel.author_email orelse "System",
            .date = cms.formatRelativeTime(ctx.allocator, rel.created_at) catch "Unknown",
            .detail_url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}", .{rel.id}) catch "/admin/releases",
        };
    }

    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.render(views.admin.releases.list.List, .{.{
        .has_releases = releases.len > 0,
        .releases = view_releases,
        .csrf_token = csrf_token,
    }});

    const create_btn = "<a href=\"/admin/releases/new\" class=\"btn btn-primary btn-sm\">New Release</a>";
    ctx.html(registry.renderPageFull(page, ctx, content, "", "", create_btn));
}

fn handleNew(ctx: *Context) !void {
    _ = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);

    const content = std.fmt.allocPrint(ctx.allocator,
        \\<form method="POST" action="/admin/releases" class="form" style="max-width: 480px">
        \\  <input type="hidden" name="_csrf" value="{s}" />
        \\  <div class="form-group">
        \\    <label for="name">Release Name</label>
        \\    <input type="text" id="name" name="name" class="form-control" required="" placeholder="e.g. Sprint 42, Holiday Update" />
        \\  </div>
        \\  <div class="form-group">
        \\    <button type="submit" class="btn btn-primary">Create Release</button>
        \\    <a href="/admin/releases" class="btn">Cancel</a>
        \\  </div>
        \\</form>
    , .{csrf_token}) catch {
        redirect(ctx, "/admin/releases");
        return;
    };

    ctx.html(registry.renderPageWith(page, ctx, content, "New Release"));
}

fn handleCreate(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const name = ctx.formValue("name") orelse "";
    if (name.len == 0) {
        redirect(ctx, "/admin/releases/new");
        return;
    }

    const author_id = auth_middleware.getUserId(ctx);

    const rel_id = cms.createPendingRelease(db, name, author_id) catch {
        redirect(ctx, "/admin/releases");
        return;
    };

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}", .{&rel_id}) catch "/admin/releases";
    redirect(ctx, url);
}

fn handleDetail(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const release_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/releases");
        return;
    };

    const detail = cms.getRelease(ctx.allocator, db, release_id) catch {
        redirect(ctx, "/admin/releases");
        return;
    } orelse {
        redirect(ctx, "/admin/releases");
        return;
    };

    const csrf_token = csrf.ensureToken(ctx);

    const ViewItem = struct {
        entry_id: []const u8,
        entry_title: []const u8,
        entry_status: []const u8,
        edit_url: []const u8,
        remove_url: []const u8,
    };

    var view_items = ctx.allocator.alloc(ViewItem, detail.items.len) catch {
        redirect(ctx, "/admin/releases");
        return;
    };

    for (detail.items, 0..) |item, i| {
        view_items[i] = .{
            .entry_id = item.entry_id,
            .entry_title = item.entry_title,
            .entry_status = item.entry_status,
            .edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/posts/{s}", .{item.entry_id}) catch "#",
            .remove_url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}/remove/{s}", .{ release_id, item.entry_id }) catch "#",
        };
    }

    const is_pending = std.mem.eql(u8, detail.status, "pending");
    const is_released = std.mem.eql(u8, detail.status, "released");
    const is_reverted = std.mem.eql(u8, detail.status, "reverted");
    const can_archive = !is_pending;

    const content = tpl.render(views.admin.releases.detail.Detail, .{.{
        .name = detail.name,
        .status = detail.status,
        .author = detail.author_email orelse "System",
        .date = cms.formatRelativeTime(ctx.allocator, detail.created_at) catch "Unknown",
        .items = view_items,
        .csrf_token = csrf_token,
        .publish_url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}/publish", .{release_id}) catch "#",
        .revert_url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}/revert", .{release_id}) catch "#",
        .re_release_url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}/re-release", .{release_id}) catch "#",
        .archive_url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}/archive", .{release_id}) catch "#",
        .is_pending = is_pending,
        .is_released = is_released,
        .is_reverted = is_reverted,
        .can_archive = can_archive,
        .error_message = "",
    }});

    ctx.html(registry.renderPageWith(page, ctx, content, detail.name));
}

fn handlePublish(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const release_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/releases");
        return;
    };

    cms.publishBatchRelease(db, release_id) catch |err| {
        std.debug.print("Error publishing release: {}\n", .{err});
    };

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}", .{release_id}) catch "/admin/releases";
    redirect(ctx, url);
}

fn handleRevert(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const release_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/releases");
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);

    cms.revertRelease(db, release_id, author_id) catch |err| {
        std.debug.print("Error reverting release: {}\n", .{err});
    };

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}", .{release_id}) catch "/admin/releases";
    redirect(ctx, url);
}

fn handleReRelease(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const release_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/releases");
        return;
    };

    const author_id = auth_middleware.getUserId(ctx);

    cms.reReleaseReverted(db, release_id, author_id) catch |err| {
        std.debug.print("Error re-releasing: {}\n", .{err});
    };

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}", .{release_id}) catch "/admin/releases";
    redirect(ctx, url);
}

fn handleArchive(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const release_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/releases");
        return;
    };

    cms.archiveRelease(db, release_id) catch |err| {
        std.debug.print("Error archiving release: {}\n", .{err});
    };

    redirect(ctx, "/admin/releases");
}

fn handleRemoveItem(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        redirect(ctx, "/admin/releases");
        return;
    };

    const release_id = ctx.param("id") orelse {
        redirect(ctx, "/admin/releases");
        return;
    };

    const entry_id = ctx.param("eid") orelse {
        const url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}", .{release_id}) catch "/admin/releases";
        redirect(ctx, url);
        return;
    };

    cms.removeFromRelease(db, release_id, entry_id) catch |err| {
        std.debug.print("Error removing item: {}\n", .{err});
    };

    const url = std.fmt.allocPrint(ctx.allocator, "/admin/releases/{s}", .{release_id}) catch "/admin/releases";
    redirect(ctx, url);
}

// =============================================================================
// Helpers
// =============================================================================

fn redirect(ctx: *Context, location: []const u8) void {
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", location);
    ctx.response.setBody("");
}
