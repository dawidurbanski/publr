//! Publr Plugin API
//!
//! Single import for all plugin functionality. Provides admin page registration,
//! template rendering, page layout rendering, auth, CSRF, database access,
//! collaboration config, and request context.
//!
//! ```zig
//! const publr = @import("publr_api");
//!
//! pub const page = publr.admin.registerPage(.{ ... });
//!
//! fn handle(ctx: *publr.Context) !void {
//!     const a = publr.auth(ctx);
//!     const csrf_token = a.ensureToken();
//!     const content = publr.template.render(my_view, .{.{ .csrf_token = csrf_token }});
//!     ctx.html(publr.registry(ctx).renderPage(page, content));
//! }
//! ```

// =========================================================================
// Context
// =========================================================================

/// Request/response context passed through the middleware chain.
/// This is the core type that all handler functions receive.
pub const Context = @import("middleware").Context;

// =========================================================================
// Modules
// =========================================================================

/// Admin page registration — registerPage, Page, PageApp, etc.
pub const admin = @import("modules/admin.zig");

/// Template rendering — render, renderStatic, renderFnToSlice.
pub const template = @import("modules/template.zig");

/// Bound registry API — renderPage, renderPageWith, renderPageFull, renderEditPage.
/// Usage: `publr.registry(ctx).renderPage(page, content)`
pub const registry = @import("modules/registry.zig").init;

/// Registry types and static lookups (pages, findById, etc.)
pub const Registry = @import("modules/registry.zig");

/// Bound auth API — getUserId, getUserEmail, ensureToken, cookies.
/// Usage: `publr.auth(ctx).getUserId()`
pub const auth = @import("modules/auth.zig").init;

/// Auth types, constants, middleware, and instance access.
/// Usage: `publr.Auth.instance()`, `publr.Auth.SESSION_COOKIE`
pub const Auth = @import("modules/auth.zig");

/// Collaboration timing config — getLockTimeoutMs, getHeartbeatIntervalMs, etc.
pub const collaboration = @import("modules/collaboration.zig");

/// Database wrapper types — safe subset (no init/deinit/serialize/deserialize).
pub const Db = @import("modules/db.zig").Db;
pub const Statement = @import("modules/db.zig").Statement;
pub const DbError = @import("modules/db.zig").Error;

/// Schema system — field builders, content type metadata, registry queries.
pub const schema = @import("modules/schema.zig");

/// Media CRUD — createMedia, getMedia, updateMedia, deleteMedia, etc.
/// Usage: `publr.media.getMedia(allocator, db, id)`
pub const media = @import("modules/media.zig");

/// Media queries — listMedia, countMedia, date periods, etc.
/// Usage: `publr.media_query.countMedia(db, .{})`
pub const media_query = @import("modules/media_query.zig");

/// Taxonomy — term CRUD, media-term relationships, folder/tag constants.
/// Usage: `publr.taxonomy.listTerms(allocator, db, publr.taxonomy.tax_media_folders)`
pub const taxonomy = @import("modules/taxonomy.zig");

/// Content lifecycle — saveEntry, deleteEntry, archiveEntry, unpublishEntry.
/// Usage: `publr.content.saveEntry(CT, allocator, db, id, data, .{})`
pub const content = @import("modules/content.zig");

/// Entry queries — getEntry, listEntries, countEntries, listWithMeta.
/// Usage: `publr.query.getEntry(CT, allocator, db, id_or_slug)`
pub const query = @import("modules/query.zig");

/// Version history — listVersions, getVersion, restoreVersion, compareVersionFields.
/// Usage: `publr.version.formatRelativeTime(allocator, timestamp)`
pub const version = @import("modules/version.zig");

/// Release management — publishEntry, listReleases, addToRelease, etc.
/// Usage: `publr.release.publishEntry(allocator, db, entry_id, author_id, null)`
pub const release = @import("modules/release.zig");

/// Bound utils API — redirect, queryParam, formatSize, mime, gravatar, etc.
/// Usage: `publr.utils(ctx).redirect("/admin/media")`
pub const utils = @import("modules/utils.zig").init;

/// Utils types and static functions.
/// Usage: `publr.Utils.formatSize(allocator, size)`, `publr.Utils.fromPath(path)`
pub const Utils = @import("modules/utils.zig");
