//! Admin Page Registration API
//!
//! Provides a WordPress-like API for registering admin pages and their routes.
//! Pages define navigation items; setup functions register all routes for that page.
//!
//! Example:
//! ```zig
//! pub const page = admin.registerPage(.{
//!     .id = "posts",
//!     .title = "Posts",
//!     .path = "/posts",        // becomes /admin/posts
//!     .icon = icons.edit,
//!     .position = 20,
//!     .setup = setup,
//! });
//!
//! fn setup(app: *admin.PageApp) void {
//!     app.render(renderList);           // GET /admin/posts
//!     app.get("/:id", renderEdit);      // GET /admin/posts/:id
//!     app.post("/:id", handleUpdate);   // POST /admin/posts/:id
//!     app.postAt("/:id/delete", handleDelete);
//! }
//! ```

const std = @import("std");
const mw = @import("middleware");

/// Handler function type - matches the router's handler signature
pub const Handler = mw.Handler;

/// Context type - the middleware Context
pub const Context = mw.Context;

/// Admin page definition - represents a navigation item and its routes
pub const Page = struct {
    /// Unique identifier (e.g., "posts", "users.new")
    id: []const u8,

    /// Display title for navigation and page header
    title: []const u8,

    /// Path relative to /admin (e.g., "/posts" becomes "/admin/posts")
    /// For child pages, relative to parent (e.g., "/new" with parent "users" becomes "/admin/users/new")
    path: []const u8,

    /// SVG icon markup for navigation
    icon: []const u8 = "",

    /// Sort position in navigation (lower = higher)
    position: u16 = 100,

    /// Parent page ID for submenu items (e.g., "users" for "users.new")
    parent: ?[]const u8 = null,

    /// Setup function that registers routes for this page
    setup: *const fn (*PageApp) void,

    /// Check if this is a child page
    pub fn isChild(self: Page) bool {
        return self.parent != null;
    }
};

/// Route registration function type
pub const RegisterFn = *const fn (ctx: *anyopaque, path: []const u8, handler: Handler) void;

/// Route registrar interface - bridges admin_api to the actual router
/// This allows admin_api to work without directly importing the Router type
pub const RouteRegistrar = struct {
    /// Opaque context pointer (usually *Router)
    ctx: *anyopaque,
    /// Function to register GET routes
    register_get: RegisterFn,
    /// Function to register POST routes
    register_post: RegisterFn,
};

/// Scoped router for a page - provides methods to register routes relative to the page's base path
pub const PageApp = struct {
    /// Resolved full path (e.g., "/admin/users/new")
    base_path: []const u8,

    /// Page metadata
    page: Page,

    /// Route registrar for registering routes
    registrar: RouteRegistrar,

    /// Allocator for path concatenation
    allocator: std.mem.Allocator,

    // =========================================================================
    // Route Registration
    // =========================================================================

    /// Register GET handler for the base path (main page render)
    pub fn render(self: *PageApp, handler: Handler) void {
        self.registrar.register_get(self.registrar.ctx, self.base_path, handler);
    }

    /// Register GET handler for a sub-path
    pub fn get(self: *PageApp, sub_path: []const u8, handler: Handler) void {
        const full_path = self.resolvePath(sub_path);
        self.registrar.register_get(self.registrar.ctx, full_path, handler);
    }

    /// Register POST handler for the base path
    pub fn post(self: *PageApp, handler: Handler) void {
        self.registrar.register_post(self.registrar.ctx, self.base_path, handler);
    }

    /// Register POST handler for a sub-path
    pub fn postAt(self: *PageApp, sub_path: []const u8, handler: Handler) void {
        const full_path = self.resolvePath(sub_path);
        self.registrar.register_post(self.registrar.ctx, full_path, handler);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Resolve a sub-path relative to this page's base path
    fn resolvePath(self: *PageApp, sub_path: []const u8) []const u8 {
        if (sub_path.len == 0 or std.mem.eql(u8, sub_path, "/")) {
            return self.base_path;
        }

        // Determine if we need to add a separator slash
        const base_ends_with_slash = self.base_path[self.base_path.len - 1] == '/';
        const sub_starts_with_slash = sub_path[0] == '/';

        // Calculate total length
        var total_len = self.base_path.len + sub_path.len;
        if (!base_ends_with_slash and !sub_starts_with_slash) {
            total_len += 1; // Need to add a slash
        } else if (base_ends_with_slash and sub_starts_with_slash) {
            total_len -= 1; // Skip duplicate slash
        }

        const buf = self.allocator.alloc(u8, total_len) catch return self.base_path;

        var offset: usize = 0;

        // Copy base path (strip trailing slash if sub_path has leading slash)
        const base_len = if (base_ends_with_slash and sub_starts_with_slash)
            self.base_path.len - 1
        else
            self.base_path.len;
        @memcpy(buf[0..base_len], self.base_path[0..base_len]);
        offset = base_len;

        // Add separator if needed
        if (!base_ends_with_slash and !sub_starts_with_slash) {
            buf[offset] = '/';
            offset += 1;
        }

        // Copy sub_path (including leading slash if present)
        @memcpy(buf[offset..][0..sub_path.len], sub_path);

        return buf;
    }

    /// Get the page title
    pub fn title(self: *PageApp) []const u8 {
        return self.page.title;
    }

    /// Get the page ID
    pub fn id(self: *PageApp) []const u8 {
        return self.page.id;
    }
};

/// Register an admin page with comptime validation
pub fn registerPage(comptime opts: Page) Page {
    // Validate ID
    if (opts.id.len == 0) {
        @compileError("Page id cannot be empty");
    }

    // Validate path
    if (opts.path.len == 0) {
        @compileError("Page path cannot be empty");
    }

    // Path should be relative (not start with /admin)
    if (std.mem.startsWith(u8, opts.path, "/admin")) {
        @compileError("Page path should be relative (e.g., '/posts' not '/admin/posts')");
    }

    return opts;
}

/// Resolve the full path for a page, considering its parent hierarchy
pub fn resolvePagePath(comptime page: Page, comptime pages: []const Page) []const u8 {
    if (page.parent) |parent_id| {
        // Find parent and prepend its path
        inline for (pages) |p| {
            if (comptime std.mem.eql(u8, p.id, parent_id)) {
                const parent_path = comptime resolvePagePath(p, pages);
                // Concatenate: parent_path already has /admin prefix
                if (std.mem.eql(u8, page.path, "/")) {
                    return parent_path; // Root child path = same as parent
                } else if (page.path[0] == '/') {
                    return parent_path ++ page.path;
                } else {
                    return parent_path ++ "/" ++ page.path;
                }
            }
        }
        @compileError("Parent page not found: " ++ parent_id);
    } else {
        // Top-level page
        if (std.mem.eql(u8, page.path, "/")) {
            return "/admin"; // Root path, no trailing slash
        } else if (page.path[0] == '/') {
            return "/admin" ++ page.path;
        } else {
            return "/admin/" ++ page.path;
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "registerPage validates empty id" {
    // This would fail at comptime:
    // _ = registerPage(.{ .id = "", .title = "Test", .path = "/test", .setup = undefined });
}

test "registerPage validates absolute path" {
    // This would fail at comptime:
    // _ = registerPage(.{ .id = "test", .title = "Test", .path = "/admin/test", .setup = undefined });
}

test "resolvePagePath for top-level page" {
    const pages = [_]Page{
        .{ .id = "posts", .title = "Posts", .path = "/posts", .setup = undefined },
    };
    const resolved = resolvePagePath(pages[0], &pages);
    try std.testing.expectEqualStrings("/admin/posts", resolved);
}

test "resolvePagePath for child page" {
    const pages = [_]Page{
        .{ .id = "users", .title = "Users", .path = "/users", .setup = undefined },
        .{ .id = "users.new", .title = "New User", .path = "/new", .parent = "users", .setup = undefined },
    };
    const resolved = resolvePagePath(pages[1], &pages);
    try std.testing.expectEqualStrings("/admin/users/new", resolved);
}
