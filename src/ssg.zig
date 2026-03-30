//! Static Site Generation — renders theme pages to HTML files on disk.
//!
//! Tracks dependencies during render so that on publish, only affected
//! pages are rebuilt (surgical regeneration).

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Db = @import("db").Db;
const template_context = @import("template_context");
const TemplateContext = template_context.TemplateContext;
const SsgParams = template_context.SsgParams;
const DepsCollector = template_context.DepsCollector;
const theme_routes = @import("theme_routes");
const theme_static = @import("theme_static");
const cms = @import("cms");
const schemas = @import("schemas");

pub const BuildSummary = struct {
    pages: u32,
    assets: u32,
    total_bytes: u64,
};

pub fn buildSite(allocator: Allocator, db: *Db, output_dir: []const u8) !BuildSummary {
    var summary = BuildSummary{ .pages = 0, .assets = 0, .total_bytes = 0 };

    fs.cwd().makePath(output_dir) catch {};

    // Create .deps directory
    const deps_dir = try std.fmt.allocPrint(allocator, "{s}/.deps", .{output_dir});
    defer allocator.free(deps_dir);
    fs.cwd().makePath(deps_dir) catch {};

    // 1. Render static routes (with dependency tracking)
    inline for (theme_routes.route_table) |route| {
        if (route.kind == .static) {
            const bytes = try renderPageWithDeps(allocator, db, route.page, output_dir, route.pattern, .{});
            summary.pages += 1;
            summary.total_bytes += bytes;
        }
    }

    // 2. Render dynamic routes (arena for entry queries)
    inline for (theme_routes.route_table) |route| {
        if (route.kind == .dynamic) {
            if (route.content_type_id) |ct_id| {
                inline for (schemas.content_types) |CT| {
                    if (comptime std.mem.eql(u8, CT.handle, ct_id)) {
                        var entry_arena = std.heap.ArenaAllocator.init(allocator);
                        defer entry_arena.deinit();
                        const ea = entry_arena.allocator();
                        const entries = cms.listEntries(CT, ea, db, .{
                            .status = "published",
                            .limit = 10000,
                        }) catch &.{};
                        for (entries) |entry| {
                            if (entry.slug) |slug| {
                                if (substituteParams(allocator, route.pattern, slug)) |url| {
                                    defer allocator.free(url);
                                    const params = SsgParams{
                                        .keys = &.{"slug"},
                                        .values = &.{slug},
                                    };
                                    if (renderPageWithDeps(allocator, db, route.page, output_dir, url, params)) |bytes| {
                                        summary.pages += 1;
                                        summary.total_bytes += bytes;
                                    } else |_| {}
                                } else |_| {}
                            }
                        }
                    }
                }
            }
        }
    }

    // 3. Copy theme static assets
    for (theme_static.files) |file| {
        const dest = try fs.path.join(allocator, &.{ output_dir, "theme", file.path });
        defer allocator.free(dest);
        if (fs.path.dirname(dest)) |dir| fs.cwd().makePath(dir) catch {};
        var out = try fs.cwd().createFile(dest, .{});
        defer out.close();
        try out.writeAll(file.data);
        summary.assets += 1;
        summary.total_bytes += file.data.len;
    }

    // 4. Generate sitemap
    try regenerateSitemap(allocator, db, output_dir);

    return summary;
}

/// Render a page and write its dependency manifest.
fn renderPageWithDeps(
    allocator: Allocator,
    db: *Db,
    comptime Page: type,
    output_dir: []const u8,
    output_url: []const u8,
    params: SsgParams,
) !u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var deps = DepsCollector{ .allocator = alloc };

    const tpl_ctx = TemplateContext{
        .allocator = alloc,
        .db = db,
        .ssg_params = params,
        .deps = &deps,
    };

    // Render
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(alloc);
    try Page.render(writer, &tpl_ctx);

    // Write HTML
    const file_path = try patternToFilePath(alloc, output_url);
    const full_path = try fs.path.join(alloc, &.{ output_dir, file_path });
    if (fs.path.dirname(full_path)) |dir| fs.cwd().makePath(dir) catch {};
    {
        var out = try fs.cwd().createFile(full_path, .{});
        defer out.close();
        try out.writeAll(buf.items);
    }

    // Write dependency manifest
    const deps_json = try deps.toJson(alloc);
    const deps_path = try depsManifestPath(alloc, output_dir, output_url);
    if (fs.path.dirname(deps_path)) |dir| fs.cwd().makePath(dir) catch {};
    {
        var out = try fs.cwd().createFile(deps_path, .{});
        defer out.close();
        try out.writeAll(deps_json);
    }

    return @intCast(buf.items.len);
}

/// Render a page without dependency tracking (used by surgical rebuild).
fn renderPage(
    allocator: Allocator,
    db: *Db,
    comptime Page: type,
    output_dir: []const u8,
    output_url: []const u8,
    params: SsgParams,
) !u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tpl_ctx = TemplateContext{
        .allocator = alloc,
        .db = db,
        .ssg_params = params,
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(alloc);
    try Page.render(writer, &tpl_ctx);

    const file_path = try patternToFilePath(alloc, output_url);
    const full_path = try fs.path.join(alloc, &.{ output_dir, file_path });
    if (fs.path.dirname(full_path)) |dir| fs.cwd().makePath(dir) catch {};

    var out = try fs.cwd().createFile(full_path, .{});
    defer out.close();
    try out.writeAll(buf.items);

    return @intCast(buf.items.len);
}

// =============================================================================
// Surgical rebuild using dependency manifests
// =============================================================================

/// Rebuild pages affected by a changed entry. Uses .deps/ manifests.
/// Falls back to rebuilding all statics if no manifests exist.
pub fn regenerateEntry(allocator: Allocator, db: *Db, output_dir: []const u8, slug: []const u8, content_type_id: ?[]const u8) ?u32 {
    fs.cwd().access(output_dir, .{}) catch return null;

    const deps_dir = std.fmt.allocPrint(allocator, "{s}/.deps", .{output_dir}) catch return null;
    defer allocator.free(deps_dir);

    // Check if manifests exist
    const has_manifests = blk: {
        var dir = fs.cwd().openDir(deps_dir, .{ .iterate = true }) catch break :blk false;
        defer dir.close();
        var it = dir.iterate();
        break :blk (it.next() catch null) != null;
    };

    if (!has_manifests) {
        // No manifests — fall back to rebuilding all statics + the entry's detail page
        return regenerateAllWithSlug(allocator, db, output_dir, slug);
    }

    // Scan manifests for pages that depend on this entry or content type
    var rebuild_urls: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (rebuild_urls.items) |u| allocator.free(u);
        rebuild_urls.deinit(allocator);
    }

    scanDepsDir(allocator, deps_dir, "", slug, content_type_id, &rebuild_urls);

    // Always include the entry's own detail page
    inline for (theme_routes.route_table) |route| {
        if (route.kind == .dynamic) {
            if (substituteParams(allocator, route.pattern, slug)) |url| {
                rebuild_urls.append(allocator, url) catch {};
            } else |_| {}
        }
    }

    // Rebuild matched pages
    var count: u32 = 0;
    for (rebuild_urls.items) |url| {
        // Find the matching route and render
        inline for (theme_routes.route_table) |route| {
            if (route.kind == .static and std.mem.eql(u8, route.pattern, url)) {
                if (renderPageWithDeps(allocator, db, route.page, output_dir, route.pattern, .{})) |_| {
                    count += 1;
                } else |_| {}
            }
            if (route.kind == .dynamic) {
                // Check if this URL matches the route pattern
                if (matchesDynamicRoute(route.pattern, url)) {
                    const params = SsgParams{
                        .keys = &.{"slug"},
                        .values = &.{slug},
                    };
                    if (renderPageWithDeps(allocator, db, route.page, output_dir, url, params)) |_| {
                        count += 1;
                    } else |_| {}
                }
            }
        }
    }

    return count;
}

/// Fallback: rebuild all static pages + one detail page.
fn regenerateAllWithSlug(allocator: Allocator, db: *Db, output_dir: []const u8, slug: []const u8) u32 {
    var count: u32 = 0;
    inline for (theme_routes.route_table) |route| {
        if (route.kind == .static) {
            if (renderPage(allocator, db, route.page, output_dir, route.pattern, .{})) |_| {
                count += 1;
            } else |_| {}
        }
        if (route.kind == .dynamic) {
            if (substituteParams(allocator, route.pattern, slug)) |url| {
                defer allocator.free(url);
                const params = SsgParams{ .keys = &.{"slug"}, .values = &.{slug} };
                if (renderPage(allocator, db, route.page, output_dir, url, params)) |_| {
                    count += 1;
                } else |_| {}
            } else |_| {}
        }
    }
    return count;
}

/// Recursively scan .deps/ directory for manifests matching the changed entry.
fn scanDepsDir(
    allocator: Allocator,
    deps_base: []const u8,
    rel_prefix: []const u8,
    slug: []const u8,
    content_type_id: ?[]const u8,
    results: *std.ArrayListUnmanaged([]const u8),
) void {
    const full_dir = if (rel_prefix.len > 0)
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ deps_base, rel_prefix }) catch return
    else
        allocator.dupe(u8, deps_base) catch return;
    defer allocator.free(full_dir);

    var dir = fs.cwd().openDir(full_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory) {
            const sub = if (rel_prefix.len > 0)
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name }) catch continue
            else
                allocator.dupe(u8, entry.name) catch continue;
            defer allocator.free(sub);
            scanDepsDir(allocator, deps_base, sub, slug, content_type_id, results);
        } else if (entry.kind == .file and mem.endsWith(u8, entry.name, ".json")) {
            const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_dir, entry.name }) catch continue;
            defer allocator.free(file_path);

            const content = fs.cwd().readFileAlloc(allocator, file_path, 64 * 1024) catch continue;
            defer allocator.free(content);

            if (manifestMatchesEntry(content, slug, content_type_id)) {
                // Convert .deps path to URL: "index.json" → "/", "post/index.json" → "/post"
                const url = depsPathToUrl(allocator, rel_prefix, entry.name) catch continue;
                results.append(allocator, url) catch {};
            }
        }
    }
}

/// Check if a manifest JSON contains a dependency on the given slug or content type.
fn manifestMatchesEntry(json: []const u8, slug: []const u8, content_type_id: ?[]const u8) bool {
    // Check direct entry reference: "slug":"<slug>"
    if (mem.indexOf(u8, json, slug) != null) {
        // Verify it's in the entries array context
        const slug_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"slug\":\"{s}\"", .{slug}) catch return false;
        defer std.heap.page_allocator.free(slug_pattern);
        if (mem.indexOf(u8, json, slug_pattern) != null) return true;
    }

    // Check content type listing dependency
    if (content_type_id) |ct| {
        const ct_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{ct}) catch return false;
        defer std.heap.page_allocator.free(ct_pattern);
        // Check it's in the content_types array
        if (mem.indexOf(u8, json, "\"content_types\":[")) |ct_start| {
            const ct_section = json[ct_start..];
            if (mem.indexOf(u8, ct_section, "]")) |ct_end| {
                if (mem.indexOf(u8, ct_section[0..ct_end], ct_pattern) != null) return true;
            }
        }
    }

    return false;
}

/// Convert a .deps relative path + filename to a URL.
/// ("", "index.json") → "/"
/// ("post", "index.json") → "/post"
/// ("post", "my-slug.json") → "/post/my-slug"
fn depsPathToUrl(allocator: Allocator, rel_prefix: []const u8, filename: []const u8) ![]const u8 {
    const name = filename[0 .. filename.len - 5]; // strip .json
    if (std.mem.eql(u8, name, "index")) {
        if (rel_prefix.len == 0) return try allocator.dupe(u8, "/");
        return try std.fmt.allocPrint(allocator, "/{s}", .{rel_prefix});
    }
    if (rel_prefix.len == 0) return try std.fmt.allocPrint(allocator, "/{s}", .{name});
    return try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ rel_prefix, name });
}

/// Check if a URL matches a dynamic route pattern (e.g. "/post/my-slug" matches "/post/:slug").
fn matchesDynamicRoute(pattern: []const u8, url: []const u8) bool {
    // Simple check: compare static prefix before the first :param
    if (mem.indexOf(u8, pattern, ":")) |colon| {
        const prefix = pattern[0..colon];
        return mem.startsWith(u8, url, prefix);
    }
    return false;
}

/// Path for the dependency manifest file.
fn depsManifestPath(allocator: Allocator, output_dir: []const u8, url: []const u8) ![]const u8 {
    if (url.len <= 1) {
        return try std.fmt.allocPrint(allocator, "{s}/.deps/index.json", .{output_dir});
    }
    const path = if (url[0] == '/') url[1..] else url;
    // Check if it looks like a detail page (has non-path chars suggesting a slug)
    if (mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        const last_segment = path[last_slash + 1 ..];
        // If last segment doesn't look like "index", it's a detail page
        if (!mem.eql(u8, last_segment, "index")) {
            return try std.fmt.allocPrint(allocator, "{s}/.deps/{s}/{s}.json", .{ output_dir, path[0..last_slash], last_segment });
        }
    }
    return try std.fmt.allocPrint(allocator, "{s}/.deps/{s}/index.json", .{ output_dir, path });
}

/// Regenerate all static pages only (fallback when slug is unknown).
pub fn regeneratePages(allocator: Allocator, db: *Db, output_dir: []const u8) ?u32 {
    fs.cwd().access(output_dir, .{}) catch return null;
    var count: u32 = 0;
    inline for (theme_routes.route_table) |route| {
        if (route.kind == .static) {
            if (renderPage(allocator, db, route.page, output_dir, route.pattern, .{})) |_| {
                count += 1;
            } else |_| {}
        }
    }
    return count;
}

// =============================================================================
// Sitemap
// =============================================================================

pub fn regenerateSitemap(allocator: Allocator, db: *Db, output_dir: []const u8) !void {
    fs.cwd().access(output_dir, .{}) catch return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try generateSitemapContent(alloc, db);
    const path = try fs.path.join(alloc, &.{ output_dir, "sitemap.xml" });
    var out = try fs.cwd().createFile(path, .{});
    defer out.close();
    try out.writeAll(content);
}

pub fn generateSitemapContent(allocator: Allocator, db: *Db) ![]const u8 {
    const base_url = blk: {
        const cfg = @import("publr_config");
        break :blk if (@hasField(@TypeOf(cfg), "url")) cfg.url else "http://localhost:8080";
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const w = buf.writer(allocator);

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.writeAll("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    inline for (theme_routes.route_table) |route| {
        if (route.kind == .static) {
            try writeSitemapUrl(w, base_url, route.pattern, if (route.pattern.len <= 1) "1.0" else "0.8");
        }
    }

    inline for (theme_routes.route_table) |route| {
        if (route.kind == .dynamic) {
            if (route.content_type_id) |ct_id| {
                inline for (schemas.content_types) |CT| {
                    if (comptime std.mem.eql(u8, CT.handle, ct_id)) {
                        var sm_arena = std.heap.ArenaAllocator.init(allocator);
                        defer sm_arena.deinit();
                        const sma = sm_arena.allocator();
                        const entries = cms.listEntries(CT, sma, db, .{
                            .status = "published",
                            .limit = 10000,
                        }) catch &.{};
                        for (entries) |entry| {
                            if (entry.slug) |s| {
                                if (substituteParams(sma, route.pattern, s)) |url| {
                                    writeSitemapUrl(w, base_url, url, "0.6") catch {};
                                } else |_| {}
                            }
                        }
                    }
                }
            }
        }
    }

    try w.writeAll("</urlset>\n");
    return buf.items;
}

fn writeSitemapUrl(w: anytype, base_url: []const u8, path: []const u8, priority: []const u8) !void {
    try w.writeAll("  <url>\n    <loc>");
    try w.writeAll(base_url);
    try w.writeAll(path);
    try w.writeAll("</loc>\n    <priority>");
    try w.writeAll(priority);
    try w.writeAll("</priority>\n  </url>\n");
}

// =============================================================================
// Helpers
// =============================================================================

fn substituteParams(allocator: Allocator, pattern: []const u8, slug: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    const w = result.writer(allocator);
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == ':') {
            i += 1;
            while (i < pattern.len and (std.ascii.isAlphanumeric(pattern[i]) or pattern[i] == '_')) : (i += 1) {}
            try w.writeAll(slug);
        } else {
            try w.writeByte(pattern[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

pub fn getOutputDir() []const u8 {
    const publr_config = @import("publr_config");
    return if (@hasField(@TypeOf(publr_config), "output"))
        publr_config.output
    else
        "output";
}

fn patternToFilePath(allocator: Allocator, pattern: []const u8) ![]const u8 {
    if (pattern.len <= 1) return try allocator.dupe(u8, "index.html");
    const path = if (pattern[0] == '/') pattern[1..] else pattern;
    return try std.fmt.allocPrint(allocator, "{s}/index.html", .{path});
}

// =============================================================================
// Tests
// =============================================================================

test "patternToFilePath: root" {
    const r = try patternToFilePath(std.testing.allocator, "/");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("index.html", r);
}

test "patternToFilePath: simple" {
    const r = try patternToFilePath(std.testing.allocator, "/about");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("about/index.html", r);
}

test "substituteParams" {
    const r = try substituteParams(std.testing.allocator, "/post/:slug", "my-post");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("/post/my-post", r);
}

test "manifestMatchesEntry: direct slug" {
    const json = "{\"entries\":[{\"type\":\"post\",\"slug\":\"my-post\"}],\"content_types\":[],\"taxonomies\":[]}";
    try std.testing.expect(manifestMatchesEntry(json, "my-post", null));
    try std.testing.expect(!manifestMatchesEntry(json, "other-post", null));
}

test "manifestMatchesEntry: content type listing" {
    const json = "{\"entries\":[],\"content_types\":[\"post\"],\"taxonomies\":[]}";
    try std.testing.expect(manifestMatchesEntry(json, "anything", "post"));
    try std.testing.expect(!manifestMatchesEntry(json, "anything", "page"));
}

test "depsPathToUrl" {
    const a = std.testing.allocator;
    {
        const r = try depsPathToUrl(a, "", "index.json");
        defer a.free(r);
        try std.testing.expectEqualStrings("/", r);
    }
    {
        const r = try depsPathToUrl(a, "post", "index.json");
        defer a.free(r);
        try std.testing.expectEqualStrings("/post", r);
    }
    {
        const r = try depsPathToUrl(a, "post", "my-slug.json");
        defer a.free(r);
        try std.testing.expectEqualStrings("/post/my-slug", r);
    }
}
