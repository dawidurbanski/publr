//! Tag management handlers — create and delete tags.

const std = @import("std");
const Context = @import("middleware").Context;
const media = @import("media");
const auth_middleware = @import("auth_middleware");

const h = @import("helpers.zig");

pub fn handleCreateTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const name = ctx.formValue("tag_name") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    if (name.len == 0) {
        h.redirect(ctx, "/admin/media");
        return;
    }

    _ = media.createTerm(ctx.allocator, db, media.tax_media_tags, name, null) catch |err| {
        std.debug.print("Error creating tag: {}\n", .{err});
    };

    h.redirect(ctx, "/admin/media");
}

pub fn handleDeleteTag(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    media.deleteTerm(db, term_id) catch |err| {
        std.debug.print("Error deleting tag: {}\n", .{err});
    };

    h.redirect(ctx, "/admin/media");
}

test "admin media tags: unauthenticated branches" {
    var create_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/tags/create");
    defer create_ctx.deinit();
    try handleCreateTag(&create_ctx);
    try std.testing.expectEqualStrings("303 See Other", create_ctx.response.status);

    var delete_ctx = Context.init(std.heap.page_allocator, .POST, "/admin/media/tags/delete");
    defer delete_ctx.deinit();
    try handleDeleteTag(&delete_ctx);
    try std.testing.expectEqualStrings("303 See Other", delete_ctx.response.status);
}

test "admin media tags: public API coverage" {
    _ = handleCreateTag;
    _ = handleDeleteTag;
}
