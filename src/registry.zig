//! Plugin Registry - aggregates pages from auto-discovered plugins.
//!
//! Adding a new plugin (page or otherwise):
//!   1. Create <dir>/<name>.zig (or <dir>/<name>/main.zig) where <dir> is
//!      either src/modules/admin/ (built-in) or plugins/ (project plugin).
//!      For pages, export `pub const page = admin.registerPage(...)` or
//!      `pub const pages = ...`.
//!   2. zig build — auto-discovered.
//!
//! No edits to this file, mod.zig, or build.zig are needed.

const std = @import("std");
const admin = @import("admin_api");
const mw = @import("middleware");
const csrf = @import("csrf");
const tpl = @import("tpl");
const views = @import("views");
const auth_middleware = @import("auth_middleware");
const gravatar = @import("gravatar");
const plugin_registry = @import("plugin_registry");
const publr_ui = @import("publr_ui");

pub const IconName = publr_ui.icon.Name;

/// All registered admin pages, aggregated from auto-discovered plugins.
/// Each plugin may export `pub const page` (single) or `pub const pages` (array).
pub const pages: []const admin.Page = blk: {
    var result: []const admin.Page = &.{};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "page")) {
            result = result ++ &[_]admin.Page{p.mod.page};
        }
        if (@hasDecl(p.mod, "pages")) {
            result = result ++ p.mod.pages;
        }
    }
    break :blk result;
};

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
    icon: admin.IconName,
    is_active: bool,
};

/// Topbar nav entries: label, path, section key, icon
const topbar_entries = [_]struct {
    label: []const u8,
    path: []const u8,
    section: []const u8,
    icon: admin.IconName,
}{
    .{
        .label = "Content",
        .path = "/admin/content",
        .section = "content",
        .icon = .bookmark,
    },
    .{ .label = "Releases", .path = "/admin/releases", .section = "releases", .icon = .copy },
    .{ .label = "Content Types", .path = "/admin/content-types", .section = "content_types", .icon = .package },
    .{ .label = "Media", .path = "/admin/media", .section = "media", .icon = .image },
};

/// Compute topbar nav items with active state for the given page
pub fn topbarNavItems(comptime current_id: []const u8) []const NavItem {
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

// =============================================================================
// Plugins Sidebar Section
// =============================================================================

pub const PluginNavItem = struct {
    id: []const u8,
    label: []const u8,
    href: []const u8,
    icon: admin.IconName,
};

/// Top-level pages with `menu_section == "plugins"`, sorted by position.
/// Rendered in the sidebar's Plugins section by layout.zsx. Child pages
/// (parent != null) are excluded — they live as sub-routes of their parent.
pub fn pluginMenuItems() []const PluginNavItem {
    comptime {
        var count: usize = 0;
        for (pages) |p| {
            if (p.parent != null) continue;
            const sec = p.menu_section orelse continue;
            if (!std.mem.eql(u8, sec, "plugins")) continue;
            count += 1;
        }

        var items: [count]PluginNavItem = undefined;
        var i: usize = 0;
        for (pages) |p| {
            if (p.parent != null) continue;
            const sec = p.menu_section orelse continue;
            if (!std.mem.eql(u8, sec, "plugins")) continue;
            items[i] = .{
                .id = p.id,
                .label = p.title,
                .href = admin.resolvePagePath(p, pages),
                .icon = p.icon,
            };
            i += 1;
        }

        // position sort (lower first)
        for (0..count) |j| {
            for (j + 1..count) |k| {
                const pj = findById(items[j].id).?.position;
                const pk = findById(items[k].id).?.position;
                if (pk < pj) {
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

// =============================================================================
// Page Rendering
// =============================================================================

pub const EditOpts = struct {
    back_url: []const u8,
    back_label: []const u8 = "",
    sidebar: []const u8 = "",
    /// Content-type label for the breadcrumb middle segment. Empty hides
    /// the breadcrumb and falls back to a plain title.
    content_type_label: []const u8 = "",
    /// URL the content-type breadcrumb segment links to (typically the
    /// list of entries of that type).
    content_type_url: []const u8 = "",
    /// Icon rendered next to the content-type breadcrumb segment.
    content_type_icon: IconName = .bookmark,
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
        .content_type_label = opts.content_type_label,
        .content_type_url = opts.content_type_url,
        .content_type_icon = opts.content_type_icon,
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
    const page = findById("content");
    try std.testing.expect(page != null);
}

test "hasSubPages identifies parents" {
    try std.testing.expect(hasSubPages("users"));
    try std.testing.expect(!hasSubPages("dashboard"));
}
