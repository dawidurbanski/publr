//! TemplateContext — the bridge between CMS core and .publr templates.
//!
//! Wraps the content query API in a template-friendly surface.
//! When `deps` is set (during `publr build`), records all queries
//! for precise surgical rebuilds on publish.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cms = @import("cms");
const schema_registry = @import("schema_registry");
const taxonomy = @import("taxonomy");
const Db = @import("db").Db;
const publr_config = @import("publr_config");
const mw = @import("middleware");

/// Simple key-value param store for SSG mode (no HTTP request).
pub const SsgParams = struct {
    keys: []const []const u8 = &.{},
    values: []const []const u8 = &.{},

    pub fn get(self: SsgParams, name: []const u8) ?[]const u8 {
        for (self.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, name)) return self.values[i];
        }
        return null;
    }
};

/// Dependency collector — records what data a page accessed during render.
/// Only active during `publr build`, null during HTTP serving.
pub const DepsCollector = struct {
    allocator: Allocator,
    /// Specific entries accessed via ctx.entry() or ctx.entryById()
    entries: std.ArrayListUnmanaged(EntryDep) = .{},
    /// Content types queried via ctx.query() or ctx.count()
    content_types: std.ArrayListUnmanaged([]const u8) = .{},
    /// Taxonomies queried via ctx.terms()
    taxonomies: std.ArrayListUnmanaged([]const u8) = .{},

    pub const EntryDep = struct {
        content_type: []const u8,
        slug: []const u8,
    };

    pub fn recordEntry(self: *DepsCollector, content_type: []const u8, slug: []const u8) void {
        // Deduplicate
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.content_type, content_type) and std.mem.eql(u8, e.slug, slug)) return;
        }
        self.entries.append(self.allocator, .{ .content_type = content_type, .slug = slug }) catch {};
    }

    pub fn recordContentType(self: *DepsCollector, content_type: []const u8) void {
        for (self.content_types.items) |ct| {
            if (std.mem.eql(u8, ct, content_type)) return;
        }
        self.content_types.append(self.allocator, content_type) catch {};
    }

    pub fn recordTaxonomy(self: *DepsCollector, taxonomy_id: []const u8) void {
        for (self.taxonomies.items) |t| {
            if (std.mem.eql(u8, t, taxonomy_id)) return;
        }
        self.taxonomies.append(self.allocator, taxonomy_id) catch {};
    }

    /// Serialize deps to JSON for the manifest file.
    pub fn toJson(self: *const DepsCollector, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        const w = buf.writer(allocator);

        try w.writeAll("{\"entries\":[");
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"type\":\"");
            try w.writeAll(e.content_type);
            try w.writeAll("\",\"slug\":\"");
            try w.writeAll(e.slug);
            try w.writeAll("\"}");
        }
        try w.writeAll("],\"content_types\":[");
        for (self.content_types.items, 0..) |ct, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('"');
            try w.writeAll(ct);
            try w.writeByte('"');
        }
        try w.writeAll("],\"taxonomies\":[");
        for (self.taxonomies.items, 0..) |t, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('"');
            try w.writeAll(t);
            try w.writeByte('"');
        }
        try w.writeAll("]}");
        return try buf.toOwnedSlice(allocator);
    }
};

pub const TemplateContext = struct {
    allocator: Allocator,
    db: *Db,
    router_ctx: ?*const mw.Context = null,
    ssg_params: SsgParams = .{},
    deps: ?*DepsCollector = null, // non-null during publr build

    /// Site metadata from publr.zon (comptime)
    pub const site = SiteInfo{
        .name = if (@hasField(@TypeOf(publr_config), "name")) publr_config.name else "Publr",
        .url = if (@hasField(@TypeOf(publr_config), "url")) publr_config.url else "http://localhost:8080",
        .description = if (@hasField(@TypeOf(publr_config), "description")) publr_config.description else "",
    };

    /// Get a URL parameter from the request (HTTP) or SSG params.
    pub fn param(self: *const TemplateContext, name: []const u8) ?[]const u8 {
        if (self.router_ctx) |ctx| return ctx.param(name);
        return self.ssg_params.get(name);
    }

    /// Get a single published entry by slug or id.
    pub fn entry(self: *const TemplateContext, type_id: []const u8, slug_or_id: []const u8) !cms.query.Entry {
        const def = schema_registry.findById(type_id) orelse return error.UnknownContentType;
        if (self.deps) |d| d.recordEntry(def.handle, slug_or_id);
        return (try cms.query.getEntry(self.allocator, self.db, type_id, slug_or_id)) orelse return error.EntryNotFound;
    }

    /// Get a single entry by ID.
    pub fn entryById(self: *const TemplateContext, type_id: []const u8, id: []const u8) !cms.query.Entry {
        const def = schema_registry.findById(type_id) orelse return error.UnknownContentType;
        if (self.deps) |d| d.recordEntry(def.handle, id);
        return (try cms.query.getEntry(self.allocator, self.db, type_id, id)) orelse return error.EntryNotFound;
    }

    /// List entries with optional filters.
    pub fn query(self: *const TemplateContext, type_id: []const u8, opts: QueryOpts) ![]cms.query.Entry {
        const def = schema_registry.findById(type_id) orelse return error.UnknownContentType;
        if (self.deps) |d| d.recordContentType(def.handle);
        return cms.query.listEntries(self.allocator, self.db, type_id, .{
            .status = opts.status orelse "published",
            .limit = opts.limit,
            .offset = opts.offset,
            .order_by = opts.order_by orelse "created_at",
            .order_dir = if (opts.order_asc orelse false) .asc else .desc,
        });
    }

    /// Count entries matching filters.
    pub fn count(self: *const TemplateContext, type_id: []const u8, opts: CountOpts) !u32 {
        const def = schema_registry.findById(type_id) orelse return error.UnknownContentType;
        if (self.deps) |d| d.recordContentType(def.handle);
        return cms.query.countEntries(self.db, type_id, .{
            .status = opts.status orelse "published",
        });
    }

    /// List taxonomy terms.
    pub fn terms(self: *const TemplateContext, taxonomy_id: []const u8) ![]taxonomy.TermRecord {
        if (self.deps) |d| d.recordTaxonomy(taxonomy_id);
        return taxonomy.listTerms(self.allocator, self.db, taxonomy_id);
    }

    pub const Error = error{ EntryNotFound, UnknownContentType };
};

pub const QueryOpts = struct {
    status: ?[]const u8 = null,
    limit: ?u32 = null,
    offset: ?u32 = null,
    order_by: ?[]const u8 = null,
    order_asc: ?bool = null,
};

pub const CountOpts = struct {
    status: ?[]const u8 = null,
};

pub const SiteInfo = struct {
    name: []const u8,
    url: []const u8,
    description: []const u8,
};
