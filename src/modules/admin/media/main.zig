//! Media plugin — file management pages
//!
//! Provides the media library UI at /admin/media with list, upload,
//! edit, and delete functionality. Uses the media CRUD API for
//! database operations and storage backend for file management.

const admin = @import("admin_api");
const media = @import("media");
const auth_middleware = @import("auth_middleware");

const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32;

// Conditional imports: media_handler uses filesystem APIs
const media_handler = if (is_wasm) struct {
    pub const FocalPoint = struct { x: u8, y: u8 };
    pub const FocalPointFn = *const fn ([]const u8) ?FocalPoint;
    pub fn setFocalPointLookup(_: FocalPointFn) void {}
} else @import("media_handler");

const list = @import("list.zig");
const crud = @import("crud.zig");
const folders = @import("folders.zig");
const tags = @import("tags.zig");
const bulk = @import("bulk.zig");
const api = @import("api.zig");

/// Media list page (shows in nav at position 25, between Posts and Users)
pub const page = admin.registerPage(.{
    .id = "media",
    .title = "Media",
    .path = "/media",
    .icon = .image,
    .position = 25,
    .section = "media",
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(list.handleList);
    app.get("/:id", crud.handleEdit);
    app.get("/picker/list", api.handlePickerList);
    app.get("/picker/thumb/:id", api.handlePickerThumb);
    app.post(crud.handleUpload);
    if (!is_wasm) {
        app.postAt("/sync", api.handleSync);
        app.postAt("/scan", api.handleScan);
    }
    app.postAt("/folders", folders.handleCreateFolder);
    app.postAt("/folders/delete", folders.handleDeleteFolder);
    app.postAt("/folders/rename", folders.handleRenameFolder);
    app.postAt("/folders/move", folders.handleMoveFolder);
    app.postAt("/tags", tags.handleCreateTag);
    app.postAt("/tags/delete", tags.handleDeleteTag);
    app.postAt("/bulk/delete", bulk.handleBulkDelete);
    app.postAt("/bulk/add-tag", bulk.handleBulkAddTag);
    app.postAt("/bulk/remove-tag", bulk.handleBulkRemoveTag);
    app.postAt("/bulk/move-folder", bulk.handleBulkMoveFolder);
    app.postAt("/:id", crud.handleUpdate);
    app.postAt("/:id/delete", crud.handleDelete);
    app.postAt("/:id/toggle-visibility", crud.handleToggleVisibility);

    // Wire up focal point DB fallback for image cropping
    media_handler.setFocalPointLookup(lookupFocalPoint);
}

/// Look up focal point from DB by storage key (fallback when fp= param absent).
fn lookupFocalPoint(storage_key: []const u8) ?media_handler.FocalPoint {
    const db = if (auth_middleware.auth) |a| a.db else return null;
    const fp = media.getFocalPoint(db, storage_key) orelse return null;
    return .{ .x = fp.x, .y = fp.y };
}
