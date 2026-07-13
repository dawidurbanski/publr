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

    // POST verbs migrated to the action dispatcher (see content_actions.zig
    // pattern). `media_id` / `folder_id` etc. live as form fields now.
    app.action("media.upload", crud.handleUpload);
    // JSON twin of media.upload for fetch() callers (the block editor's
    // media adapter) — returns the stored record instead of redirecting.
    app.action("media.upload_json", api.handleUploadJson);
    if (!is_wasm) {
        app.action("media.sync", api.handleSync);
        app.action("media.scan", api.handleScan);
    }
    app.action("media.folder_create", folders.handleCreateFolder);
    app.action("media.folder_delete", folders.handleDeleteFolder);
    app.action("media.folder_rename", folders.handleRenameFolder);
    app.action("media.folder_move", folders.handleMoveFolder);
    app.action("media.tag_create", tags.handleCreateTag);
    app.action("media.tag_delete", tags.handleDeleteTag);
    app.action("media.bulk_delete", bulk.handleBulkDelete);
    app.action("media.bulk_add_tag", bulk.handleBulkAddTag);
    app.action("media.bulk_remove_tag", bulk.handleBulkRemoveTag);
    app.action("media.bulk_move_folder", bulk.handleBulkMoveFolder);
    app.action("media.update", crud.handleUpdate);
    app.action("media.delete", crud.handleDelete);
    app.action("media.toggle_visibility", crud.handleToggleVisibility);

    // Wire up focal point DB fallback for image cropping
    media_handler.setFocalPointLookup(lookupFocalPoint);
}

/// Look up focal point from DB by storage key (fallback when fp= param absent).
fn lookupFocalPoint(storage_key: []const u8) ?media_handler.FocalPoint {
    const db = if (auth_middleware.auth) |a| a.db else return null;
    const fp = media.getFocalPoint(db, storage_key) orelse return null;
    return .{ .x = fp.x, .y = fp.y };
}
