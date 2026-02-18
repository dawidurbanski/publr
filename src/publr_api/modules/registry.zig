//! Plugin Registry API
//!
//! Provides page rendering (bound API) and page lookups (static).
//!
//! Bound API example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! fn handle(ctx: *publr.Context) !void {
//!     const content = publr.template.renderStatic(views.admin.my_page.MyPage);
//!     ctx.html(publr.registry(ctx).renderPage(page, content));
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

    /// Render an admin page with automatic nav, CSRF, and layout.
    pub fn renderPage(self: @This(), comptime pg: admin.Page, content: []const u8) []const u8 {
        return registry.renderPage(pg, self.ctx, content);
    }

    /// Render with subtitle.
    pub fn renderPageWith(self: @This(), comptime pg: admin.Page, content: []const u8, subtitle: []const u8) []const u8 {
        return registry.renderPageWith(pg, self.ctx, content, subtitle);
    }

    /// Render with subtitle, bottom bar, and page title actions.
    pub fn renderPageFull(self: @This(), comptime pg: admin.Page, content: []const u8, subtitle: []const u8, bottom_bar: []const u8, page_title_actions: []const u8) []const u8 {
        return registry.renderPageFull(pg, self.ctx, content, subtitle, bottom_bar, page_title_actions);
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
