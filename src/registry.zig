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
const zsx_admin_layout = @import("zsx_admin_layout");
const auth_middleware = @import("auth_middleware");
const gravatar = @import("gravatar");

// Import all plugins
const dashboard = @import("plugin_dashboard");
const posts = @import("plugin_posts");
const media_plugin = @import("plugin_media");
const users = @import("plugin_users");
const settings = @import("plugin_settings");
const components = @import("plugin_components");
const design_system = @import("plugin_design_system");
const icons = @import("icons");

/// All registered admin pages, sorted by position
pub const pages: []const admin.Page = &[_]admin.Page{
    dashboard.page,
    posts.page,
    media_plugin.page,
    users.page,
    users.page_profile,
    settings.page,
    components.page,
    design_system.page,
};

/// Pages excluded from main navigation (accessed via other means)
const hidden_from_nav = [_][]const u8{ "settings", "users", "components", "design_system" };

fn isHiddenFromNav(page_id: []const u8) bool {
    for (hidden_from_nav) |hidden_id| {
        if (std.mem.eql(u8, page_id, hidden_id)) return true;
    }
    return false;
}

/// Get all top-level navigation items (pages without parent, excluding hidden)
pub fn getNavItems() []const admin.Page {
    comptime {
        var count: usize = 0;
        for (pages) |page| {
            if (page.parent == null and !isHiddenFromNav(page.id)) count += 1;
        }

        var items: [count]admin.Page = undefined;
        var i: usize = 0;
        for (pages) |page| {
            if (page.parent == null and !isHiddenFromNav(page.id)) {
                items[i] = page;
                i += 1;
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

/// Generate navigation HTML for a specific current page
pub fn renderNav(comptime current_id: []const u8) []const u8 {
    @setEvalBranchQuota(10000);
    comptime {
        var buf: [16384]u8 = undefined;
        var len: usize = 0;

        // Check if current page is in users section
        const current_page = findById(current_id);
        const in_users = if (current_page) |p| blk: {
            if (std.mem.eql(u8, p.id, "users")) break :blk true;
            if (p.parent) |pid| {
                break :blk std.mem.eql(u8, pid, "users");
            }
            break :blk false;
        } else false;

        // Start nav slider
        const slider_class = if (in_users) "nav-slider submenu-open" else "nav-slider";
        const nav_start = "<div class=\"" ++ slider_class ++ "\">\n<div class=\"nav-panel nav-panel-main\" data-publr-part=\"main\">\n";
        @memcpy(buf[len..][0..nav_start.len], nav_start);
        len += nav_start.len;

        // Render top-level nav items
        const nav_items = getNavItems();
        for (nav_items) |page| {
            const is_active = std.mem.eql(u8, page.id, current_id) or
                (if (current_page) |p| if (p.parent) |pid| std.mem.eql(u8, pid, page.id) else false else false);

            const has_sub = hasSubPages(page.id);
            const page_path = admin.resolvePagePath(page, pages);

            if (has_sub) {
                // Link with submenu - navigates AND opens submenu on page load
                const active_class = if (is_active) " active" else "";
                const link_start = "<a href=\"" ++ page_path ++ "\" class=\"nav-item has-submenu" ++ active_class ++ "\" data-publr-part=\"trigger\" data-publr-submenu=\"" ++ page.id ++ "\">\n";
                @memcpy(buf[len..][0..link_start.len], link_start);
                len += link_start.len;

                const icon_html = "<span class=\"nav-icon\">" ++ page.icon ++ "</span>\n";
                @memcpy(buf[len..][0..icon_html.len], icon_html);
                len += icon_html.len;

                @memcpy(buf[len..][0..page.title.len], page.title);
                len += page.title.len;

                const chevron = "\n<span class=\"nav-chevron\">" ++ icons.chevron_right ++ "</span>\n</a>\n";
                @memcpy(buf[len..][0..chevron.len], chevron);
                len += chevron.len;
            } else {
                // Simple link
                const active_class = if (is_active) " active" else "";
                const link_start = "<a href=\"" ++ page_path ++ "\" class=\"nav-item" ++ active_class ++ "\">\n";
                @memcpy(buf[len..][0..link_start.len], link_start);
                len += link_start.len;

                const icon_html = "<span class=\"nav-icon\">" ++ page.icon ++ "</span>\n";
                @memcpy(buf[len..][0..icon_html.len], icon_html);
                len += icon_html.len;

                @memcpy(buf[len..][0..page.title.len], page.title);
                len += page.title.len;

                const link_end = "\n</a>\n";
                @memcpy(buf[len..][0..link_end.len], link_end);
                len += link_end.len;
            }
        }

        // Close main panel
        const main_end = "</div>\n";
        @memcpy(buf[len..][0..main_end.len], main_end);
        len += main_end.len;

        // Render submenus for pages that have them
        for (nav_items) |page| {
            if (!hasSubPages(page.id)) continue;

            const sub_start = "<div class=\"nav-panel nav-panel-sub\" data-publr-part=\"submenu\" data-publr-submenu=\"" ++ page.id ++ "\">\n";
            @memcpy(buf[len..][0..sub_start.len], sub_start);
            len += sub_start.len;

            // Back button
            const back_btn = "<button type=\"button\" class=\"nav-back\" data-publr-part=\"back\">\n<span class=\"nav-back-icon\">" ++ icons.chevron_right ++ "</span>\n<span class=\"nav-back-title\">" ++ page.title ++ "</span>\n</button>\n<div class=\"nav-submenu-items\">\n";
            @memcpy(buf[len..][0..back_btn.len], back_btn);
            len += back_btn.len;

            // Subpage links
            const sub_pages = getSubPages(page.id);
            for (sub_pages) |sub| {
                const sub_active = std.mem.eql(u8, sub.id, current_id);
                const sub_class = if (sub_active) " active" else "";
                const sub_path = admin.resolvePagePath(sub, pages);
                const sub_link = "<a href=\"" ++ sub_path ++ "\" class=\"nav-subitem" ++ sub_class ++ "\">" ++ sub.title ++ "</a>\n";
                @memcpy(buf[len..][0..sub_link.len], sub_link);
                len += sub_link.len;
            }

            const sub_end = "</div>\n</div>\n";
            @memcpy(buf[len..][0..sub_end.len], sub_end);
            len += sub_end.len;
        }

        // Close slider
        const slider_end = "</div>";
        @memcpy(buf[len..][0..slider_end.len], slider_end);
        len += slider_end.len;

        const result = buf[0..len].*;
        return &result;
    }
}

// Re-export plugin modules for handlers that need them
pub const dashboard_plugin = dashboard;
pub const posts_plugin = posts;
pub const media_plugin_ref = media_plugin;
pub const users_plugin = users;
pub const settings_plugin = settings;
pub const components_plugin = components;
pub const design_system_plugin = design_system;

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
    const csrf_token = csrf.ensureToken(ctx);
    const nav_html = comptime renderNav(pg.id);
    const user_email = auth_middleware.getUserEmail(ctx) orelse "";
    const gravatar_url = gravatar.url(user_email, 32);
    return tpl.render(zsx_admin_layout.Layout, .{.{
        .title = pg.title,
        .content = content,
        .nav_html = nav_html,
        .csrf_token = csrf_token,
        .user_gravatar_url = gravatar_url.slice(),
        .subtitle = subtitle,
    }});
}

// =============================================================================
// Tests
// =============================================================================

test "getNavItems returns top-level pages" {
    const items = getNavItems();
    try std.testing.expect(items.len > 0);
    // First item should be dashboard (position 10)
    try std.testing.expectEqualStrings("dashboard", items[0].id);
}

test "getSubPages returns child pages" {
    const user_subs = getSubPages("users");
    try std.testing.expect(user_subs.len >= 2); // At least new and profile
}

test "findById returns correct page" {
    const page = findById("posts");
    try std.testing.expect(page != null);
}

test "hasSubPages identifies parents" {
    try std.testing.expect(hasSubPages("users"));
    try std.testing.expect(!hasSubPages("dashboard"));
}
