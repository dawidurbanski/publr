//! Generic Content Admin Plugin — aggregator.
//!
//! Schema-driven CRUD for ANY registered content type, with full versioning,
//! publishing, autosave, releases, and multi-user editing support.
//!
//! Implementation is split across `content/*.zig` submodules; this file
//! registers the admin page and re-exports the public surface that
//! content_actions.zig + WS dispatch consume.
//!
//! Routes (per content type) — GET routes only; POST verbs go through
//! /admin/action and the content_actions.zig dispatcher:
//!   GET  /admin/content                                          — all content (landing)
//!   GET  /admin/content/{type_id}                                — list entries
//!   GET  /admin/content/{type_id}/new                            — create new entry
//!   GET  /admin/content/{type_id}/:id                            — edit entry form
//!   GET  /admin/content/{type_id}/:id/versions/:vid              — version preview redirect
//!   GET  /admin/content/{type_id}/:id/versions/:vid/compare      — version comparison
//!   GET  /admin/content/{type_id}/:id/versions/:vid/flow         — version flow audit

const admin = @import("admin_api");

const handlers = @import("handlers.zig");
const versions_mod = @import("versions.zig");
const takeover_mod = @import("takeover.zig");

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
    app.get("/", handlers.handleAll);
    app.get("/:type", handlers.handleList);
    app.get("/:type/new", handlers.handleNew);
    app.get("/:type/:id", handlers.handleEdit);
    app.get("/:type/:id/versions/:vid", versions_mod.handleVersionPreview);
    app.get("/:type/:id/versions/:vid/compare", versions_mod.handleVersionCompare);
    app.get("/:type/:id/versions/:vid/flow", versions_mod.handleVersionFlow);
}

// Public surface consumed by content_actions.zig (registered as /admin/action handlers).
pub const listFor = handlers.listFor;
pub const newFor = handlers.newFor;
pub const editFor = handlers.editFor;
pub const createFor = handlers.createFor;
pub const updateFor = handlers.updateFor;
pub const deleteFor = handlers.deleteFor;
pub const publishFor = handlers.publishFor;
pub const unpublishFor = handlers.unpublishFor;
pub const discardFor = handlers.discardFor;
pub const autosaveCreateFor = handlers.autosaveCreateFor;
pub const autosaveUpdateFor = handlers.autosaveUpdateFor;
pub const restoreFor = versions_mod.restoreFor;

// Public surface consumed by http.zig WS dispatch.
pub const handleTakeover = takeover_mod.handleTakeover;

test "admin content: public API coverage" {
    _ = handleTakeover;
    _ = createFor;
    _ = updateFor;
}
