//! Plugin Registry API
//!
//! Provides page rendering (bound API) and page lookups (static).
//!
//! Views are responsible for their own header chrome (use the PageHeader
//! component). The framework provides the surrounding shell — sidebar, topbar,
//! and an optional sticky bottom bar.
//!
//! Bound API example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! fn handle(ctx: *publr.Context) !void {
//!     const content = publr.template.render(views.admin.my_page.MyPage, .{...});
//!     ctx.html(publr.registry(ctx).render(page, content));
//! }
//! ```

const registry = @import("registry");
const admin = @import("admin_api");
const Context = @import("middleware").Context;

/// Create a bound registry API for the current request context.
pub fn init(ctx: *Context) RegistryApi {
    return .{ .ctx = ctx };
}

pub const RegistryApi = struct {
    ctx: *Context,

    // =========================================================================
    // Page Rendering (bound — needs request context for CSRF, auth, nav)
    // =========================================================================

    /// Render content inside the admin shell. The view owns its own header
    /// (use the PageHeader component).
    pub fn render(self: @This(), comptime pg: admin.Page, content: []const u8) []const u8 {
        return admin.renderWithLayout(pg.id, pg.title, self.ctx, content, "");
    }

    /// Render content with a sticky bottom bar (e.g. multi-select toolbars).
    pub fn renderWithBottomBar(self: @This(), comptime pg: admin.Page, content: []const u8, bottom_bar: []const u8) []const u8 {
        return admin.renderWithLayout(pg.id, pg.title, self.ctx, content, bottom_bar);
    }

    /// Render an edit page layout with back navigation and optional sidebar.
    pub fn renderEditPage(self: @This(), comptime pg: admin.Page, title: []const u8, content: []const u8, opts: EditOpts) []const u8 {
        return registry.renderEditPage(pg, self.ctx, title, content, opts);
    }
};

// =========================================================================
// Types
// =========================================================================

pub const EditOpts = registry.EditOpts;

// =========================================================================
// Page Lookups (static — no request context needed)
// =========================================================================

/// All registered admin pages.
pub const pages = registry.pages;

/// Get subpages for a parent page ID.
pub const getSubPages = registry.getSubPages;

/// Check if a page has subpages.
pub const hasSubPages = registry.hasSubPages;

/// Find a page by its ID (comptime).
pub const findById = registry.findById;

/// Find a page by its path (runtime).
pub const findByPath = registry.findByPath;
