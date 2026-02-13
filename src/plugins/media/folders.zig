//! Folder management handlers — create, delete, rename, move folders.

const std = @import("std");
const Context = @import("middleware").Context;
const media = @import("media");
const auth_middleware = @import("auth_middleware");

const h = @import("helpers.zig");

pub fn handleCreateFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const name = ctx.formValue("folder_name") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    if (name.len == 0) {
        h.redirect(ctx, "/admin/media");
        return;
    }

    const parent_id = if (ctx.formValue("parent_id")) |pid| if (pid.len > 0) pid else null else null;

    _ = media.createTerm(ctx.allocator, db, media.tax_media_folders, name, parent_id) catch |err| {
        std.debug.print("Error creating folder: {}\n", .{err});
    };

    h.redirect(ctx, "/admin/media");
}

pub fn handleDeleteFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    media.deleteTermWithReparent(db, term_id) catch |err| {
        std.debug.print("Error deleting folder: {}\n", .{err});
    };

    h.redirect(ctx, "/admin/media");
}

pub fn handleRenameFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };
    const new_name = ctx.formValue("folder_name") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    media.renameTerm(db, term_id, new_name) catch |err| {
        std.debug.print("Error renaming folder: {}\n", .{err});
    };

    h.redirect(ctx, "/admin/media");
}

pub fn handleMoveFolder(ctx: *Context) !void {
    const db = if (auth_middleware.auth) |a| a.db else {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const term_id = ctx.formValue("term_id") orelse {
        h.redirect(ctx, "/admin/media");
        return;
    };

    const parent_id = if (ctx.formValue("parent_id")) |pid| if (pid.len > 0) pid else null else null;

    // Validate: cannot move folder under itself
    if (parent_id) |pid| {
        if (std.mem.eql(u8, pid, term_id)) {
            h.redirect(ctx, "/admin/media");
            return;
        }

        // Validate: cannot create circular reference
        // Walk up from proposed parent to root; if we hit term_id, reject
        {
            var check_id: []const u8 = pid;
            while (true) {
                var anc_stmt = db.prepare(
                    "SELECT parent_id FROM terms WHERE id = ?1",
                ) catch break;
                defer anc_stmt.deinit();
                anc_stmt.bindText(1, check_id) catch break;
                if (!(anc_stmt.step() catch false)) break;
                const next_id = anc_stmt.columnText(0) orelse break;
                if (std.mem.eql(u8, next_id, term_id)) {
                    h.redirect(ctx, "/admin/media");
                    return;
                }
                check_id = ctx.allocator.dupe(u8, next_id) catch break;
            }
        }
    }

    media.moveTermParent(db, term_id, parent_id) catch |err| {
        std.debug.print("Error moving folder: {}\n", .{err});
    };

    h.redirect(ctx, "/admin/media");
}
