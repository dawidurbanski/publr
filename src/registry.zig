//! Plugin Registry - Auto-discovers and registers admin pages
//!
//! This module aggregates all admin pages from plugins in src/plugins/.
//! To add a new admin page, create a plugin file and add it here.
//!
//! Example: Adding a new "Reports" page:
//! 1. Create src/plugins/reports.zig with pub const page = admin.registerPage(...)
//! 2. Add `const reports = @import("plugin_reports");` below
//! 3. Add reports.page to the pages array
//!
//! The build system handles wiring up the imports.

const std = @import("std");
const admin = @import("admin_api");
const mw = @import("middleware");
const csrf = @import("csrf");
const tpl = @import("tpl");
const views = @import("views");
const auth_middleware = @import("auth_middleware");
const gravatar = @import("gravatar");

// Import all plugins
const dashboard = @import("plugin_dashboard");
const content_plugin_mod = @import("plugin_content");
const media_plugin = @import("plugin_media");
const users = @import("plugin_users");
const settings = @import("plugin_settings");
const components = @import("plugin_components");
const design_system = @import("plugin_design_system");
const content_types = @import("plugin_content_types");
const releases = @import("plugin_releases");
const icons = @import("icons");
const schemas = @import("schemas");

/// All registered admin pages, sorted by position.
/// Content type pages are auto-generated from schemas.content_types.
const pages_arr = [_]admin.Page{
    dashboard.page,
} ++ content_plugin_mod.content_pages ++ [_]admin.Page{
    releases.page,
    content_types.page,
    media_plugin.page,
    users.page,
    users.page_profile,
    settings.page,
    components.page,
    design_system.page,
};

pub const pages: []const admin.Page = &pages_arr;

/// Get subpages for a parent page
pub fn getSubPages(comptime parent_id: []const u8) []const admin.Page {
    comptime {
        var count: usize = 0;
        for (pages) |page| {
            if (page.parent) |pid| {
                if (std.mem.eql(u8, pid, parent_id)) count += 1;
            }
        }

        var items: [count]admin.Page = undefined;
        var i: usize = 0;
        for (pages) |page| {
            if (page.parent) |pid| {
                if (std.mem.eql(u8, pid, parent_id)) {
                    items[i] = page;
                    i += 1;
                }
            }
        }

        // Sort by position
        for (0..count) |j| {
            for (j + 1..count) |k| {
                if (items[k].position < items[j].position) {
                    const tmp = items[j];
                    items[j] = items[k];
                    items[k] = tmp;
                }
            }
        }

        const result = items;
        return &result;
    }
}

/// Check if a page has subpages
pub fn hasSubPages(comptime page_id: []const u8) bool {
    return getSubPages(page_id).len > 0;
}

/// Find a page by its ID
pub fn findById(comptime page_id: []const u8) ?admin.Page {
    for (pages) |page| {
        if (std.mem.eql(u8, page.id, page_id)) return page;
    }
    return null;
}

/// Find a page by its path (runtime version)
pub fn findByPath(path: []const u8) ?admin.Page {
    for (pages) |page| {
        const full_path = admin.resolvePagePath(page, pages);
        if (std.mem.eql(u8, full_path, path)) return page;
    }
    return null;
}

// =============================================================================
// Topbar Navigation
// =============================================================================

const NavItem = struct {
    label: []const u8,
    path: []const u8,
    icon: []const u8,
    is_active: bool,
};

/// Topbar nav entries: label, path, section key, icon
const topbar_entries = [_]struct {
    label: []const u8,
    path: []const u8,
    section: []const u8,
    icon: []const u8,
}{
    .{ .label = "Content", .path = "/admin/content/" ++ schemas.content_types[0].type_id, .section = "content", .icon = icons.bookmark },
    .{ .label = "Releases", .path = "/admin/releases", .section = "releases", .icon = icons.copy },
    .{ .label = "Content Types", .path = "/admin/content-types", .section = "content_types", .icon = icons.package },
    .{ .label = "Media", .path = "/admin/media", .section = "media", .icon = icons.image },
};

/// Compute topbar nav items with active state for the given page
fn topbarNavItems(comptime current_id: []const u8) []const NavItem {
    comptime {
        const current_page = findById(current_id);
        const current_section: []const u8 = if (current_page) |p| p.section orelse "" else "";

        var items: [topbar_entries.len]NavItem = undefined;
        for (topbar_entries, 0..) |entry, i| {
            items[i] = .{
                .label = entry.label,
                .path = entry.path,
                .icon = entry.icon,
                .is_active = std.mem.eql(u8, current_section, entry.section),
            };
        }
        const result = items;
        return &result;
    }
}

/// Compute section sidebar items for the "content" section.
/// Content type pages (content.post, content.page, etc.) are included
/// automatically — they're in the pages array with section="content".
/// The old "posts" page is excluded (replaced by content.post).
fn sectionSidebarItems(comptime current_id: []const u8) []const NavItem {
    comptime {
        const current_page = findById(current_id);
        const current_section: []const u8 = if (current_page) |p| p.section orelse "" else "";

        if (!std.mem.eql(u8, current_section, "content")) return &.{};

        // Count content section pages
        var page_count: usize = 0;
        for (pages) |pg| {
            const pg_section = pg.section orelse continue;
            if (!std.mem.eql(u8, pg_section, "content")) continue;
            if (pg.parent != null) continue;
            page_count += 1;
        }

        var items: [page_count]NavItem = undefined;
        var i: usize = 0;

        for (pages) |pg| {
            const pg_section = pg.section orelse continue;
            if (!std.mem.eql(u8, pg_section, "content")) continue;
            if (pg.parent != null) continue;

            const is_active = std.mem.eql(u8, pg.id, current_id) or
                (if (current_page) |p| if (p.parent) |pid| std.mem.eql(u8, pid, pg.id) else false else false);

            items[i] = .{
                .label = pg.title,
                .path = admin.resolvePagePath(pg, pages),
                .icon = pg.icon,
                .is_active = is_active,
            };
            i += 1;
        }
        const result = items;
        return &result;
    }
}

// Re-export plugin modules for handlers that need them
pub const dashboard_plugin = dashboard;
pub const content_plugin = content_plugin_mod;
pub const media_plugin_ref = media_plugin;
pub const users_plugin = users;
pub const settings_plugin = settings;
pub const components_plugin = components;
pub const design_system_plugin = design_system;
pub const content_types_plugin = content_types;
pub const releases_plugin = releases;

// =============================================================================
// Page Rendering
// =============================================================================

/// Render an admin page with automatic nav generation and CSRF handling.
/// This is the primary API for plugins to render pages - no manual layout wrapping needed.
///
/// Example:
/// ```zig
/// fn handleDashboard(ctx: *Context) !void {
///     const content = tpl.render(zsx_dashboard.Dashboard, .{.{...}});
///     ctx.html(registry.renderPage(page, ctx, content));
/// }
/// ```
pub fn renderPage(comptime pg: admin.Page, ctx: *mw.Context, content: []const u8) []const u8 {
    return renderPageWith(pg, ctx, content, "");
}

pub fn renderPageWith(comptime pg: admin.Page, ctx: *mw.Context, content: []const u8, subtitle: []const u8) []const u8 {
    return renderPageFull(pg, ctx, content, subtitle, "", "");
}

pub fn renderPageFull(comptime pg: admin.Page, ctx: *mw.Context, content: []const u8, subtitle: []const u8, bottom_bar: []const u8, page_title_actions: []const u8) []const u8 {
    const csrf_token = csrf.ensureToken(ctx);
    const topbar_nav_html = tpl.render(views.components.topbar_nav.TopbarNav, .{.{ .items = comptime topbarNavItems(pg.id) }});
    const sidebar_items = comptime sectionSidebarItems(pg.id);
    const section_sidebar_html = if (sidebar_items.len > 0)
        tpl.render(views.components.section_sidebar.SectionSidebar, .{.{ .items = sidebar_items }})
    else
        "";
    const user_email = auth_middleware.getUserEmail(ctx) orelse "";
    const gravatar_url = gravatar.url(user_email, 32);
    return tpl.render(views.admin.layout.Layout, .{.{
        .title = pg.title,
        .content = content,
        .topbar_nav_html = topbar_nav_html,
        .section_sidebar_html = section_sidebar_html,
        .csrf_token = csrf_token,
        .user_gravatar_url = gravatar_url.slice(),
        .subtitle = subtitle,
        .bottom_bar = bottom_bar,
        .page_title_actions = page_title_actions,
    }});
}

pub const EditOpts = struct {
    back_url: []const u8,
    back_label: []const u8 = "",
    sidebar: []const u8 = "",
};

pub fn renderEditPage(comptime pg: admin.Page, ctx: *mw.Context, title: []const u8, content: []const u8, opts: EditOpts) []const u8 {
    const csrf_token = csrf.ensureToken(ctx);
    const topbar_nav_html = tpl.render(views.components.topbar_nav.TopbarNav, .{.{ .items = comptime topbarNavItems(pg.id) }});
    const user_email = auth_middleware.getUserEmail(ctx) orelse "";
    const gravatar_url = gravatar.url(user_email, 32);
    return tpl.render(views.admin.layout_edit.LayoutEdit, .{.{
        .title = title,
        .content = content,
        .topbar_nav_html = topbar_nav_html,
        .csrf_token = csrf_token,
        .user_gravatar_url = gravatar_url.slice(),
        .back_url = opts.back_url,
        .sidebar = opts.sidebar,
    }});
}

// =============================================================================
// Tests
// =============================================================================

test "getSubPages returns child pages" {
    const user_subs = getSubPages("users");
    try std.testing.expect(user_subs.len >= 2); // At least new and profile
}

test "findById returns correct page" {
    const page = findById("content.post");
    try std.testing.expect(page != null);
}

test "hasSubPages identifies parents" {
    try std.testing.expect(hasSubPages("users"));
    try std.testing.expect(!hasSubPages("dashboard"));
}
