//! Admin Page Registration API
//!
//! Single entry point for registering admin pages. Three modes:
//!
//! **Declarative + data:** view + loader. Framework wires up routing, calls
//! loader, renders view with the props.
//!
//! ```zig
//! pub const page = admin.registerPage(.{
//!     .id = "dashboard",
//!     .title = "Dashboard",
//!     .path = "/",
//!     .icon = .home,
//!     .view = views.admin.dashboard.Dashboard,
//!     .loader = load,
//! });
//! fn load(ctx: *admin.Context) !views.admin.dashboard.Props { ... }
//! ```
//!
//! **Declarative static:** view only. For pages with no dynamic data.
//!
//! ```zig
//! pub const page = admin.registerPage(.{
//!     .id = "about",
//!     .title = "About",
//!     .path = "/about",
//!     .view = views.admin.about.About,
//! });
//! ```
//!
//! **Manual:** Provide a setup function for cases that don't fit the declarative
//! shape (multiple routes per page, POST handlers, etc).
//!
//! ```zig
//! pub const page = admin.registerPage(.{
//!     .id = "posts",
//!     .title = "Posts",
//!     .path = "/posts",
//!     .setup = setup,
//! });
//!
//! fn setup(app: *admin.PageApp) void {
//!     app.render(renderList);
//!     app.get("/:id", renderEdit);
//!     app.post("/:id", handleUpdate);
//! }
//! ```

const std = @import("std");
const mw = @import("middleware");
const publr_ui = @import("publr_ui");
const tpl = @import("tpl");
const views = @import("views");
const csrf = @import("csrf");
const auth_middleware = @import("auth_middleware");
const gravatar = @import("gravatar");
const registry = @import("registry");
const actions = @import("actions");
const content_type = @import("content_type");
const schemas = @import("schemas");
const schema_registry = @import("schema_registry");

/// Handler function type - matches the router's handler signature
pub const Handler = mw.Handler;

/// Action handler — re-exported from the action dispatcher module.
pub const ActionHandler = actions.ActionHandler;

/// Re-export of `content_type.ContentType` under the spec-mandated name.
/// Use either form when declaring a schema:
///
/// ```zig
/// pub const Post = admin.registerContentType("post", .{
///     .name = "Blog Post",
///     .handle = "posts",
///     .http_hooks = .{ .on_publish = postPublishHook },
/// }, &.{ … });
/// ```
///
/// Note: schemas in `src/schemas/*.zig` currently import `content_type`
/// directly to avoid the `schemas → admin_api → registry → schemas` cycle.
/// External plugins (which don't get imported by `registry`) are free to
/// import `admin_api` and use this alias.
pub const registerContentType = content_type.ContentType;

/// Value-returning content type factory. Returns a pure-data
/// `ContentTypeDef` for the runtime registry. Companion to the
/// type-returning `registerContentType` above.
pub const contentType = content_type.contentType;
pub const ContentTypeDef = content_type.ContentTypeDef;
pub const HttpHooks = content_type.HttpHooks;
pub const ContentActionHookFn = content_type.ContentActionHookFn;

/// Context type - the middleware Context
pub const Context = mw.Context;

/// Icon name enum, re-exported from design system
pub const IconName = publr_ui.icon.Name;

/// Admin page definition - represents a navigation item and its routes
pub const Page = struct {
    /// Unique identifier (e.g., "posts", "users.new")
    id: []const u8,

    /// Display title for navigation and page header
    title: []const u8,

    /// Path relative to /admin (e.g., "/posts" becomes "/admin/posts")
    /// For child pages, relative to parent (e.g., "/new" with parent "users" becomes "/admin/users/new")
    path: []const u8,

    /// Icon for navigation (from design system icon set)
    icon: IconName = .home,

    /// Sort position in navigation (lower = higher)
    position: u16 = 100,

    /// Parent page ID for submenu items (e.g., "users" for "users.new")
    parent: ?[]const u8 = null,

    /// Topbar section: "content", "content_types", "media"
    section: ?[]const u8 = null,

    /// Which sidebar group this page belongs to. Today only "plugins" is
    /// honored — pages with `menu_section = "plugins"` render in the
    /// sidebar's Plugins section (built-in pages are hardcoded in
    /// layout.zsx and ignore this field).
    menu_section: ?[]const u8 = null,

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

    /// Register a named action handler. Action names are flat strings
    /// (convention: `<plugin>.<verb>`); two plugins can register the same name
    /// (last write wins, with a warning). The page id is not used — actions
    /// are decoupled from page paths so plugins without pages can still
    /// register them.
    pub fn action(self: *PageApp, name: []const u8, handler: ActionHandler) void {
        _ = self;
        actions.register(name, handler);
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

/// Render a view's output inside the admin shell (sidebar, topbar, scroll area).
/// The view is responsible for its own header (via PageHeader); the layout only
/// provides the surrounding chrome.
pub fn renderWithLayout(
    comptime page_id: []const u8,
    page_title: []const u8,
    ctx: *mw.Context,
    content: []const u8,
    bottom_bar: []const u8,
) []const u8 {
    return renderWithLayoutTyped(page_id, page_title, ctx, content, bottom_bar, "", "");
}

/// Variant of `renderWithLayout` that takes the sidebar's active state so
/// the matching item (content type and/or saved view) lights up. Pass
/// empty strings to disable.
///
/// - `active_content_type_id` — id of a content type when viewing
///   `/admin/content/<id>` or `/admin/content?type=<id>`.
/// - `active_content_view` — one of `"all"`, `"recent"`, `"created_by_me"`,
///   `"updated_by_me"`, or `"status_<value>"` for sidebar saved-view
///   filters under the Content section.
pub fn renderWithLayoutTyped(
    comptime page_id: []const u8,
    page_title: []const u8,
    ctx: *mw.Context,
    content: []const u8,
    bottom_bar: []const u8,
    active_content_type_id: []const u8,
    active_content_view: []const u8,
) []const u8 {
    const csrf_token = csrf.ensureToken(ctx);
    const topbar_nav_html = tpl.render(views.components.topbar_nav.TopbarNav, .{.{ .items = comptime registry.topbarNavItems(page_id) }});
    const user_email = auth_middleware.getUserEmail(ctx) orelse "";
    const user_name = auth_middleware.getUserDisplayName(ctx) orelse "";
    const gravatar_url = gravatar.url(user_email, 40);

    // Build the sidebar's "Content type" entries from the runtime registry.
    // Reads from `schema_registry.all()` so DB-defined and WASM-loaded
    // types show up alongside compile-in ones.
    const Nav = views.admin.layout.ContentTypeNav;
    const registered = schema_registry.all();
    const nav_items: []const Nav = blk: {
        const buf = ctx.allocator.alloc(Nav, registered.len) catch break :blk &[_]Nav{};
        for (registered, 0..) |def, i| {
            buf[i] = .{
                .href = std.fmt.allocPrint(ctx.allocator, "/admin/content/{s}", .{def.type_id}) catch "/admin/content",
                .label = def.display_name,
                .type_id = def.type_id,
            };
        }
        break :blk buf;
    };

    // Plugin pages rendered in the sidebar's "Plugins" section. Comptime-
    // collected from `registry.pluginMenuItems()`; we materialize the
    // matching nav-item shape for the layout component.
    const PluginNav = views.admin.layout.PluginNav;
    const plugin_items_src = comptime registry.pluginMenuItems();
    const plugin_pages = comptime blk: {
        var arr: [plugin_items_src.len]PluginNav = undefined;
        for (plugin_items_src, 0..) |it, i| {
            arr[i] = .{
                .id = it.id,
                .href = it.href,
                .label = it.label,
                .icon = it.icon,
            };
        }
        const out = arr;
        break :blk &out;
    };

    return tpl.render(views.admin.layout.Layout, .{.{
        .title = page_title,
        .content = content,
        .topbar_nav_html = topbar_nav_html,
        .csrf_token = csrf_token,
        .user_gravatar_url = gravatar_url.slice(),
        .user_email = user_email,
        .user_name = user_name,
        .current_section = page_id,
        .bottom_bar = bottom_bar,
        .content_types = nav_items,
        .active_content_type_id = active_content_type_id,
        .active_content_view = active_content_view,
        .plugin_pages = plugin_pages,
    }});
}

/// Register an admin page. Handles two modes:
///   - Declarative: pass `.view + .loader` — framework generates setup.
///   - Manual: pass `.setup` — caller registers their own routes.
///
/// Required: .id, .title, .path. One of (.view + .loader) or .setup.
/// Optional: .icon, .position, .parent, .section.
pub fn registerPage(comptime opts: anytype) Page {
    const T = @TypeOf(opts);

    if (!@hasField(T, "id")) @compileError("registerPage: .id required");
    if (!@hasField(T, "title")) @compileError("registerPage: .title required");
    if (!@hasField(T, "path")) @compileError("registerPage: .path required");
    if (opts.id.len == 0) @compileError("Page id cannot be empty");
    if (opts.path.len == 0) @compileError("Page path cannot be empty");
    if (std.mem.startsWith(u8, opts.path, "/admin")) {
        @compileError("Page path should be relative (e.g., '/posts' not '/admin/posts')");
    }

    const setup_fn = blk: {
        if (@hasField(T, "view")) {
            const Setup = struct {
                fn run(app: *PageApp) void {
                    app.render(handle);
                }
                fn handle(ctx: *mw.Context) !void {
                    const content = if (comptime @hasField(T, "loader")) inner: {
                        const props = try opts.loader(ctx);
                        break :inner tpl.render(opts.view, .{props});
                    } else tpl.renderStatic(opts.view);
                    ctx.html(renderWithLayout(opts.id, opts.title, ctx, content, ""));
                }
            };
            break :blk Setup.run;
        } else if (@hasField(T, "setup")) {
            break :blk opts.setup;
        } else {
            @compileError("registerPage: must have either .view (with optional .loader) OR .setup");
        }
    };

    return Page{
        .id = opts.id,
        .title = opts.title,
        .path = opts.path,
        .icon = if (@hasField(T, "icon")) opts.icon else .home,
        .position = if (@hasField(T, "position")) opts.position else 100,
        .parent = if (@hasField(T, "parent")) opts.parent else null,
        .section = if (@hasField(T, "section")) opts.section else null,
        .menu_section = if (@hasField(T, "menu_section")) opts.menu_section else null,
        .setup = setup_fn,
    };
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
