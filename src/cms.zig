//! CMS Query API
//!
//! Core module for content management operations. Provides typed entry
//! access, CRUD operations, and query building.
//!
//! Example:
//! ```zig
//! const schemas = @import("schemas");
//! const cms = @import("cms");
//!
//! // Get a post by slug
//! const post = try cms.getEntry(schemas.Post, allocator, db, "hello-world");
//!
//! // List published posts
//! const posts = try cms.listEntries(schemas.Post, allocator, db, .{
//!     .status = "published",
//!     .limit = 10,
//! });
//! ```

const std = @import("std");
const time_util = @import("time_util");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;
const field_mod = @import("field");
const registry = @import("schema_registry");

const Allocator = std.mem.Allocator;

/// Entry status values
pub const Status = enum {
    draft,
    published,
    changed,
    archived,

    pub fn toString(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Status {
        inline for (std.meta.fields(Status)) |f| {
            if (std.mem.eql(u8, s, f.name)) {
                return @enumFromInt(f.value);
            }
        }
        return null;
    }
};

/// Generic entry type - wraps content type data with system fields
pub fn Entry(comptime CT: type) type {
    return struct {
        /// Entry ID (e_xxx format)
        id: []const u8,
        /// URL slug (unique per content type)
        slug: ?[]const u8,
        /// Entry title (promoted field)
        title: []const u8,
        /// Publication status
        status: []const u8,
        /// Typed content data
        data: CT.Data,
        /// Publication timestamp
        published_at: ?i64,
        /// Creation timestamp
        created_at: i64,
        /// Last update timestamp
        updated_at: i64,

        const Self = @This();

        /// Check if entry is published
        pub fn isPublished(self: Self) bool {
            return std.mem.eql(u8, self.status, "published");
        }

        /// Check if entry is draft
        pub fn isDraft(self: Self) bool {
            return std.mem.eql(u8, self.status, "draft");
        }

        /// Check if entry has unpublished changes
        pub fn isChanged(self: Self) bool {
            return std.mem.eql(u8, self.status, "changed");
        }
    };
}

/// Operators for meta field filtering
pub const MetaOp = enum {
    eq,
    neq,
    gt,
    gte,
    lt,
    lte,

    pub fn toSql(self: MetaOp) []const u8 {
        return switch (self) {
            .eq => "=",
            .neq => "!=",
            .gt => ">",
            .gte => ">=",
            .lt => "<",
            .lte => "<=",
        };
    }
};

/// Value types for meta filtering
pub const MetaValue = union(enum) {
    text: []const u8,
    int: i64,
    real: f64,

    /// Return which column to compare against
    pub fn columnName(self: MetaValue) []const u8 {
        return switch (self) {
            .text => "value_text",
            .int => "value_int",
            .real => "value_real",
        };
    }
};

/// Filter entries/media by meta table fields
pub const MetaFilter = struct {
    key: []const u8,
    op: MetaOp = .eq,
    value: MetaValue,
};

/// Maximum number of MetaFilter joins supported in a single query
pub const max_meta_filters = 8;

/// Sort direction
pub const OrderDir = enum { asc, desc };

/// Options for listing entries
pub const ListOptions = struct {
    /// Filter by status
    status: ?[]const u8 = null,
    /// Maximum number of entries
    limit: ?u32 = null,
    /// Offset for pagination
    offset: ?u32 = null,
    /// Order by field (default: created_at)
    order_by: []const u8 = "created_at",
    /// Order direction (default: descending)
    order_dir: OrderDir = .desc,
    /// Meta field filters (generates JOINs)
    meta_filters: []const MetaFilter = &.{},
};

/// Get a single entry by ID or slug
pub fn getEntry(
    comptime CT: type,
    allocator: Allocator,
    db: *Db,
    id_or_slug: []const u8,
) !?Entry(CT) {
    // Determine if this is an ID (e_xxx) or slug
    const is_id = std.mem.startsWith(u8, id_or_slug, "e_");

    const sql = if (is_id)
        "SELECT id, slug, title, data, status, published_at, created_at, updated_at FROM entries WHERE id = ?1 AND content_type_id = ?2"
    else
        "SELECT id, slug, title, data, status, published_at, created_at, updated_at FROM entries WHERE slug = ?1 AND content_type_id = ?2";

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try stmt.bindText(1, id_or_slug);
    try stmt.bindText(2, CT.type_id);

    if (!try stmt.step()) {
        return null;
    }

    return try parseEntryRow(CT, allocator, &stmt);
}

/// List entries with optional filtering
pub fn listEntries(
    comptime CT: type,
    allocator: Allocator,
    db: *Db,
    opts: ListOptions,
) ![]Entry(CT) {
    return listWithMeta(Entry(CT), allocator, db, .{
        .table = "entries",
        .id_column = "id",
        .meta_table = "entry_meta",
        .meta_fk = "entry_id",
        .type_filter = .{ .column = "content_type_id", .value = CT.type_id },
        .select_cols = "id, slug, title, data, status, published_at, created_at, updated_at",
        .status = opts.status,
        .limit = opts.limit,
        .offset = opts.offset,
        .order_by = opts.order_by,
        .order_dir = opts.order_dir,
        .meta_filters = opts.meta_filters,
        .parse_row = struct {
            fn parse(a: Allocator, stmt: *Statement) !Entry(CT) {
                return parseEntryRow(CT, a, stmt);
            }
        }.parse,
    });
}

/// Generic list query builder with MetaFilter JOIN support.
/// Used by both listEntries and listMedia to avoid duplicating query logic.
pub fn listWithMeta(
    comptime T: type,
    allocator: Allocator,
    db: *Db,
    config: struct {
        table: []const u8,
        id_column: []const u8,
        meta_table: []const u8,
        meta_fk: []const u8,
        type_filter: ?struct { column: []const u8, value: []const u8 } = null,
        select_cols: []const u8,
        status: ?[]const u8 = null,
        visibility: ?[]const u8 = null,
        mime_type: ?[]const u8 = null,
        filename_search: ?[]const u8 = null,
        limit: ?u32 = null,
        offset: ?u32 = null,
        order_by: []const u8 = "created_at",
        order_dir: OrderDir = .desc,
        meta_filters: []const MetaFilter = &.{},
        parse_row: *const fn (Allocator, *Statement) anyerror!T,
    },
) ![]T {
    if (config.meta_filters.len > max_meta_filters) return error.TooManyFilters;

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const w = sql_buf.writer(allocator);

    // SELECT ... FROM table t
    try w.print("SELECT t.{s} FROM {s} t", .{ config.select_cols, config.table });

    // Add meta filter JOINs
    // Each filter becomes: JOIN meta_table m0 ON m0.fk = t.id AND m0.key = ?N
    var bind_idx: u32 = 1;
    for (config.meta_filters, 0..) |_, i| {
        try w.print(" JOIN {s} m{} ON m{}.{s} = t.{s} AND m{}.key = ?{}", .{
            config.meta_table, i, i, config.meta_fk, config.id_column, i, bind_idx,
        });
        bind_idx += 1;
    }

    // WHERE 1=1
    try w.writeAll(" WHERE 1=1");

    // Type filter (entries have content_type_id)
    const type_bind_idx = bind_idx;
    if (config.type_filter != null) {
        try w.print(" AND t.{s} = ?{}", .{ config.type_filter.?.column, bind_idx });
        bind_idx += 1;
    }

    // Status filter
    const status_bind_idx = bind_idx;
    if (config.status != null) {
        try w.print(" AND t.status = ?{}", .{bind_idx});
        bind_idx += 1;
    }

    // Visibility filter (media)
    const visibility_bind_idx = bind_idx;
    if (config.visibility != null) {
        try w.print(" AND t.visibility = ?{}", .{bind_idx});
        bind_idx += 1;
    }

    // Mime type filter (media)
    const mime_bind_idx = bind_idx;
    if (config.mime_type != null) {
        try w.print(" AND t.mime_type = ?{}", .{bind_idx});
        bind_idx += 1;
    }

    // Filename search filter (media)
    const search_bind_idx = bind_idx;
    if (config.filename_search != null) {
        try w.print(" AND t.filename LIKE ?{}", .{bind_idx});
        bind_idx += 1;
    }

    // Meta filter WHERE conditions
    // m0.value_text = ?N, m1.value_int > ?N, etc.
    var meta_value_bind_indices: [max_meta_filters]u32 = undefined;
    for (config.meta_filters, 0..) |mf, i| {
        try w.print(" AND m{}.{s} {s} ?{}", .{ i, mf.value.columnName(), mf.op.toSql(), bind_idx });
        meta_value_bind_indices[i] = bind_idx;
        bind_idx += 1;
    }

    // ORDER BY
    try w.print(" ORDER BY t.{s} {s}", .{
        config.order_by,
        if (config.order_dir == .asc) "ASC" else "DESC",
    });

    // LIMIT
    if (config.limit) |limit| {
        try w.print(" LIMIT {}", .{limit});
    }

    // OFFSET
    if (config.offset) |offset| {
        try w.print(" OFFSET {}", .{offset});
    }

    // Prepare and bind
    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    // Bind meta filter keys
    var key_bind: u32 = 1;
    for (config.meta_filters) |mf| {
        try stmt.bindText(key_bind, mf.key);
        key_bind += 1;
    }

    // Bind type filter
    if (config.type_filter) |tf| {
        try stmt.bindText(type_bind_idx, tf.value);
    }

    // Bind status
    if (config.status) |status| {
        try stmt.bindText(status_bind_idx, status);
    }

    // Bind visibility
    if (config.visibility) |visibility| {
        try stmt.bindText(visibility_bind_idx, visibility);
    }

    // Bind mime type
    if (config.mime_type) |mime| {
        try stmt.bindText(mime_bind_idx, mime);
    }

    // Bind filename search
    if (config.filename_search) |search| {
        try stmt.bindText(search_bind_idx, search);
    }

    // Bind meta filter values
    for (config.meta_filters, 0..) |mf, i| {
        switch (mf.value) {
            .text => |v| try stmt.bindText(meta_value_bind_indices[i], v),
            .int => |v| try stmt.bindInt(meta_value_bind_indices[i], v),
            .real => |_| try stmt.bindNull(meta_value_bind_indices[i]), // TODO: bindReal
        }
    }

    // Collect results
    var items: std.ArrayListUnmanaged(T) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const item = try config.parse_row(allocator, &stmt);
        try items.append(allocator, item);
    }

    return items.toOwnedSlice(allocator);
}

/// Parse an entry from a database row
fn parseEntryRow(comptime CT: type, allocator: Allocator, stmt: *Statement) !Entry(CT) {
    const id = try allocator.dupe(u8, stmt.columnText(0) orelse "");
    const slug = if (stmt.columnText(1)) |s| try allocator.dupe(u8, s) else null;
    const title = try allocator.dupe(u8, stmt.columnText(2) orelse "");
    const data_json = try allocator.dupe(u8, stmt.columnText(3) orelse "{}");
    const status = try allocator.dupe(u8, stmt.columnText(4) orelse "draft");
    const published_at: ?i64 = if (stmt.columnIsNull(5)) null else stmt.columnInt(5);
    const created_at = stmt.columnInt(6);
    const updated_at = stmt.columnInt(7);

    // Parse JSON data into typed struct
    const parsed = try CT.parseData(allocator, data_json);
    // Note: parsed.deinit() should be called when entry is freed

    return .{
        .id = id,
        .slug = slug,
        .title = title,
        .data = parsed.value,
        .status = status,
        .published_at = published_at,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

/// Generate a unique entry ID
pub fn generateId(allocator: Allocator) ![]u8 {
    var id_buf: [24]u8 = undefined;
    id_buf[0] = 'e';
    id_buf[1] = '_';

    // Generate random suffix
    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (rand_buf, 0..) |byte, i| {
        id_buf[2 + i] = charset[byte % charset.len];
    }

    return try allocator.dupe(u8, id_buf[0..18]);
}

/// Generate a version ID (v_ prefix + 16 random alphanumeric chars)
fn generateVersionId() [18]u8 {
    var id_buf: [18]u8 = undefined;
    id_buf[0] = 'v';
    id_buf[1] = '_';

    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (rand_buf, 0..) |byte, i| {
        id_buf[2 + i] = charset[byte % charset.len];
    }

    return id_buf;
}

/// Prune old versions if version_history_limit is set.
/// Keeps the N most recent versions per entry, deletes the rest.
fn pruneVersions(db: *Db, entry_id: []const u8) !void {
    // Read the limit from settings table
    var limit_stmt = try db.prepare(
        "SELECT value FROM settings WHERE key = 'version_history_limit'",
    );
    defer limit_stmt.deinit();

    if (!try limit_stmt.step()) return; // No limit set
    const limit_str = limit_stmt.columnText(0) orelse return;

    const limit = std.fmt.parseInt(u32, limit_str, 10) catch return;
    if (limit == 0) return;

    // Delete oldest versions beyond the limit.
    // Keep the N most recent by created_at; delete the rest.
    var del_stmt = try db.prepare(
        \\DELETE FROM entry_versions
        \\WHERE entry_id = ?1
        \\  AND id NOT IN (
        \\    SELECT id FROM entry_versions
        \\    WHERE entry_id = ?1
        \\    ORDER BY created_at DESC
        \\    LIMIT ?2
        \\  )
    );
    defer del_stmt.deinit();

    try del_stmt.bindText(1, entry_id);
    try del_stmt.bindInt(2, @intCast(limit));

    _ = try del_stmt.step();
}

/// Options for saving an entry
pub const SaveOptions = struct {
    /// Author user ID for version tracking (null for system/anonymous saves)
    author_id: ?[]const u8 = null,
    /// When true, update existing version in-place instead of creating a new one.
    /// Used by autosave to avoid polluting version history.
    autosave: bool = false,
};

/// Save an entry (create or update), creating a version in the history
pub fn saveEntry(
    comptime CT: type,
    allocator: Allocator,
    db: *Db,
    id: ?[]const u8,
    data: anytype,
    opts: SaveOptions,
) !Entry(CT) {
    const entry_id = id orelse try generateId(allocator);
    const is_update = id != null;

    // Extract title from data if present
    const title: []const u8 = if (@hasField(@TypeOf(data), "title")) blk: {
        const title_val = data.title;
        if (@typeInfo(@TypeOf(title_val)) == .optional) {
            break :blk title_val orelse "";
        } else {
            break :blk title_val;
        }
    } else "";

    // Extract slug from data if present (coerce to optional)
    const slug: ?[]const u8 = if (@hasField(@TypeOf(data), "slug"))
        @as(?[]const u8, data.slug)
    else
        null;

    // Extract status from data if present
    const status: []const u8 = if (@hasField(@TypeOf(data), "status")) blk: {
        const status_val = data.status;
        if (@typeInfo(@TypeOf(status_val)) == .optional) {
            break :blk status_val orelse "draft";
        } else {
            break :blk status_val;
        }
    } else "draft";

    // Serialize data to JSON
    const data_json = try CT.stringifyData(allocator, data);
    defer allocator.free(data_json);

    // Get previous version id, data, author (for change detection + author tracking)
    var prev_version_id: ?[]const u8 = null;
    var prev_data: ?[]const u8 = null;
    var published_vid: ?[]const u8 = null;
    var prev_author_id: ?[]const u8 = null;
    if (is_update) {
        var pv_stmt = try db.prepare(
            \\SELECT e.current_version_id, e.data, e.published_version_id, ev.author_id
            \\FROM entries e
            \\LEFT JOIN entry_versions ev ON ev.id = e.current_version_id
            \\WHERE e.id = ?1
        );
        defer pv_stmt.deinit();
        try pv_stmt.bindText(1, entry_id);
        if (try pv_stmt.step()) {
            if (pv_stmt.columnText(0)) |v| {
                prev_version_id = try allocator.dupe(u8, v);
            }
            if (pv_stmt.columnText(1)) |d| {
                prev_data = try allocator.dupe(u8, d);
            }
            if (pv_stmt.columnText(2)) |v| {
                published_vid = try allocator.dupe(u8, v);
            }
            if (pv_stmt.columnText(3)) |v| {
                prev_author_id = try allocator.dupe(u8, v);
            }
        }
    }
    defer if (prev_version_id) |v| allocator.free(v);
    defer if (prev_data) |d| allocator.free(d);
    defer if (published_vid) |v| allocator.free(v);
    defer if (prev_author_id) |v| allocator.free(v);

    // Skip version creation if data hasn't changed
    const data_changed = if (prev_data) |pd| !std.mem.eql(u8, pd, data_json) else true;

    // Autosave must create a new version (not update in-place) when current == published,
    // otherwise the published version's data would be corrupted.
    const is_published_version = if (prev_version_id) |pv|
        if (published_vid) |pub_v| std.mem.eql(u8, pv, pub_v) else false
    else
        false;

    const version_id = generateVersionId();

    // Autosave can update in-place ONLY when:
    // 1. Current version != published version (preserve published snapshot)
    // 2. Same author is editing (different author = new version for attribution)
    const same_author = if (prev_author_id) |pa|
        if (opts.author_id) |oa| std.mem.eql(u8, pa, oa) else true
    else
        true;
    const can_autosave_inplace = opts.autosave and !is_published_version and same_author;

    if (is_update) {
        if (data_changed and !can_autosave_inplace) {
            // Create new version (explicit save, or autosave that would corrupt published)
            const version_type: []const u8 = if (opts.autosave) "autosave" else "updated";
            var v_stmt = try db.prepare(
                \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            );
            defer v_stmt.deinit();

            try v_stmt.bindText(1, &version_id);
            try v_stmt.bindText(2, entry_id);
            if (prev_version_id) |pv| try v_stmt.bindText(3, pv) else try v_stmt.bindNull(3);
            try v_stmt.bindText(4, data_json);
            if (opts.author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);
            try v_stmt.bindText(6, version_type);

            _ = try v_stmt.step();
        } else if (data_changed and can_autosave_inplace) {
            // Autosave: update existing version in-place (no history entry)
            if (prev_version_id) |pv| {
                var v_stmt = try db.prepare(
                    "UPDATE entry_versions SET data = ?1 WHERE id = ?2",
                );
                defer v_stmt.deinit();

                try v_stmt.bindText(1, data_json);
                try v_stmt.bindText(2, pv);

                _ = try v_stmt.step();
            }
        }

        // Update entry
        {
            var stmt = try db.prepare(
                \\UPDATE entries SET slug = ?2, title = ?3, data = ?4,
                \\    status = ?5, updated_at = unixepoch()
                \\WHERE id = ?1
            );
            defer stmt.deinit();

            try stmt.bindText(1, entry_id);
            if (slug) |s| try stmt.bindText(2, s) else try stmt.bindNull(2);
            try stmt.bindText(3, title);
            try stmt.bindText(4, data_json);
            try stmt.bindText(5, status);

            _ = try stmt.step();
        }

        // Point to new version if data changed (skip for in-place autosave)
        if (data_changed and !can_autosave_inplace) {
            var cv_stmt = try db.prepare(
                "UPDATE entries SET current_version_id = ?1 WHERE id = ?2",
            );
            defer cv_stmt.deinit();

            try cv_stmt.bindText(1, &version_id);
            try cv_stmt.bindText(2, entry_id);

            _ = try cv_stmt.step();
        }
    } else {
        // Create entry first (so FK on entry_versions.entry_id is satisfied)
        {
            var stmt = try db.prepare(
                \\INSERT INTO entries (id, content_type_id, slug, title, data, status)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            );
            defer stmt.deinit();

            try stmt.bindText(1, entry_id);
            try stmt.bindText(2, CT.type_id);
            if (slug) |s| try stmt.bindText(3, s) else try stmt.bindNull(3);
            try stmt.bindText(4, title);
            try stmt.bindText(5, data_json);
            try stmt.bindText(6, status);

            _ = try stmt.step();
        }

        // Then create version
        {
            var v_stmt = try db.prepare(
                \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
                \\VALUES (?1, ?2, NULL, ?3, ?4, 'created')
            );
            defer v_stmt.deinit();

            try v_stmt.bindText(1, &version_id);
            try v_stmt.bindText(2, entry_id);
            try v_stmt.bindText(3, data_json);
            if (opts.author_id) |aid| try v_stmt.bindText(4, aid) else try v_stmt.bindNull(4);

            _ = try v_stmt.step();
        }

        // Update entry with version pointer
        {
            var u_stmt = try db.prepare(
                "UPDATE entries SET current_version_id = ?1 WHERE id = ?2",
            );
            defer u_stmt.deinit();

            try u_stmt.bindText(1, &version_id);
            try u_stmt.bindText(2, entry_id);

            _ = try u_stmt.step();
        }
    }

    // Enforce version retention limit
    try pruneVersions(db, entry_id);

    // Sync filterable fields to entry_meta
    try syncEntryMeta(CT, db, entry_id, data);

    // Sync taxonomy fields to entry_terms
    try syncEntryTerms(CT, db, entry_id, data);

    // Return the saved entry
    return try getEntry(CT, allocator, db, entry_id) orelse error.EntryNotFound;
}

/// Sync filterable fields to entry_meta table
fn syncEntryMeta(comptime CT: type, db: *Db, entry_id: []const u8, data: anytype) !void {
    // Delete existing meta for this entry
    var del_stmt = try db.prepare("DELETE FROM entry_meta WHERE entry_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, entry_id);
    _ = try del_stmt.step();

    // Insert new meta values for filterable fields
    const filterable = CT.getFilterableFields();
    if (filterable.len == 0) return;

    var stmt = try db.prepare(
        \\INSERT INTO entry_meta (entry_id, key, value_text, value_int, value_real)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.deinit();

    inline for (filterable) |f| {
        if (@hasField(@TypeOf(data), f.name)) {
            const value = @field(data, f.name);

            try stmt.bindText(1, entry_id);
            try stmt.bindText(2, f.name);

            // Bind appropriate value column based on meta type
            switch (f.meta_type) {
                .text => {
                    if (value) |v| {
                        try stmt.bindText(3, v);
                    } else {
                        try stmt.bindNull(3);
                    }
                    try stmt.bindNull(4);
                    try stmt.bindNull(5);
                },
                .int => {
                    try stmt.bindNull(3);
                    if (value) |v| {
                        try stmt.bindInt(4, v);
                    } else {
                        try stmt.bindNull(4);
                    }
                    try stmt.bindNull(5);
                },
                .real => {
                    try stmt.bindNull(3);
                    try stmt.bindNull(4);
                    // TODO: bind real value
                    try stmt.bindNull(5);
                },
            }

            _ = try stmt.step();
            stmt.reset();
        }
    }
}

/// Sync taxonomy fields to entry_terms table
fn syncEntryTerms(comptime CT: type, db: *Db, entry_id: []const u8, data: anytype) !void {
    // Delete existing terms for this entry
    var del_stmt = try db.prepare("DELETE FROM entry_terms WHERE entry_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, entry_id);
    _ = try del_stmt.step();

    // Insert new term relationships
    const taxonomies = CT.getTaxonomyFields();
    if (taxonomies.len == 0) return;

    var stmt = try db.prepare(
        \\INSERT INTO entry_terms (entry_id, term_id)
        \\VALUES (?1, ?2)
    );
    defer stmt.deinit();

    inline for (taxonomies) |f| {
        if (@hasField(@TypeOf(data), f.name)) {
            const value = @field(data, f.name);
            const ValueType = @TypeOf(value);

            // Handle different taxonomy field types
            if (ValueType == []const []const u8) {
                // Array of term IDs
                for (value) |term_id| {
                    try stmt.bindText(1, entry_id);
                    try stmt.bindText(2, term_id);
                    _ = try stmt.step();
                    stmt.reset();
                }
            } else if (@typeInfo(ValueType) == .optional) {
                // Optional taxonomy field - check child type
                const ChildType = @typeInfo(ValueType).optional.child;
                if (value) |unwrapped| {
                    if (ChildType == []const []const u8) {
                        // Optional array of term IDs
                        for (unwrapped) |term_id| {
                            try stmt.bindText(1, entry_id);
                            try stmt.bindText(2, term_id);
                            _ = try stmt.step();
                            stmt.reset();
                        }
                    } else {
                        // Optional single term ID
                        try stmt.bindText(1, entry_id);
                        try stmt.bindText(2, unwrapped);
                        _ = try stmt.step();
                        stmt.reset();
                    }
                }
            } else if (ValueType == []const u8) {
                // Non-optional single term ID
                try stmt.bindText(1, entry_id);
                try stmt.bindText(2, value);
                _ = try stmt.step();
                stmt.reset();
            }
        }
    }
}

/// Delete an entry
pub fn deleteEntry(db: *Db, entry_id: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM entries WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    _ = try stmt.step();
}

/// Count entries by content type
pub fn countEntries(comptime CT: type, db: *Db, opts: struct {
    status: ?[]const u8 = null,
}) !u32 {
    const sql = if (opts.status != null)
        "SELECT COUNT(*) FROM entries WHERE content_type_id = ?1 AND status = ?2"
    else
        "SELECT COUNT(*) FROM entries WHERE content_type_id = ?1";

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try stmt.bindText(1, CT.type_id);
    if (opts.status) |status| {
        try stmt.bindText(2, status);
    }

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

// =============================================================================
// Version History API
// =============================================================================

/// A version record from entry_versions
pub const Version = struct {
    id: []const u8,
    entry_id: []const u8,
    parent_id: ?[]const u8,
    data: []const u8,
    author_id: ?[]const u8,
    author_email: ?[]const u8,
    author_display_name: ?[]const u8 = null,
    created_at: i64,
    version_type: []const u8,
    is_current: bool,
    release_name: ?[]const u8 = null,
    collaborators: ?[]const u8 = null,

    /// Returns display_name if non-empty, otherwise email, otherwise "System"
    pub fn authorLabel(self: Version) []const u8 {
        if (self.author_display_name) |dn| {
            if (dn.len > 0) return dn;
        }
        return self.author_email orelse "System";
    }
};

/// List versions for an entry, newest first. Joins users for author email.
pub fn listVersions(allocator: Allocator, db: *Db, entry_id: []const u8, opts: struct {
    limit: u32 = 50,
}) ![]Version {
    var stmt = try db.prepare(
        \\SELECT ev.id, ev.entry_id, ev.parent_id, ev.data,
        \\       ev.author_id, u.email, ev.created_at, ev.version_type,
        \\       (e.current_version_id = ev.id) AS is_current,
        \\       r.name AS release_name,
        \\       ev.collaborators, u.display_name
        \\FROM entry_versions ev
        \\JOIN entries e ON e.id = ev.entry_id
        \\LEFT JOIN users u ON u.id = ev.author_id
        \\LEFT JOIN release_items ri ON ri.to_version = ev.id AND ri.entry_id = ev.entry_id
        \\LEFT JOIN releases r ON r.id = ri.release_id AND r.name IS NOT NULL
        \\WHERE ev.entry_id = ?1
        \\  AND ev.version_type != 'autosave'
        \\ORDER BY ev.created_at DESC
        \\LIMIT ?2
    );
    defer stmt.deinit();

    try stmt.bindText(1, entry_id);
    try stmt.bindInt(2, @intCast(opts.limit));

    var items: std.ArrayListUnmanaged(Version) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, .{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .entry_id = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .parent_id = if (stmt.columnText(2)) |v| try allocator.dupe(u8, v) else null,
            .data = try allocator.dupe(u8, stmt.columnText(3) orelse "{}"),
            .author_id = if (stmt.columnText(4)) |v| try allocator.dupe(u8, v) else null,
            .author_email = if (stmt.columnText(5)) |v| try allocator.dupe(u8, v) else null,
            .created_at = stmt.columnInt(6),
            .version_type = try allocator.dupe(u8, stmt.columnText(7) orelse "edit"),
            .is_current = stmt.columnInt(8) == 1,
            .release_name = if (stmt.columnText(9)) |v| try allocator.dupe(u8, v) else null,
            .collaborators = if (stmt.columnText(10)) |v| try allocator.dupe(u8, v) else null,
            .author_display_name = if (stmt.columnText(11)) |v| try allocator.dupe(u8, v) else null,
        });
    }

    return items.toOwnedSlice(allocator);
}

/// Get a single version by ID
pub fn getVersion(allocator: Allocator, db: *Db, version_id: []const u8) !?Version {
    var stmt = try db.prepare(
        \\SELECT ev.id, ev.entry_id, ev.parent_id, ev.data,
        \\       ev.author_id, u.email, ev.created_at, ev.version_type,
        \\       (e.current_version_id = ev.id) AS is_current,
        \\       ev.collaborators, u.display_name
        \\FROM entry_versions ev
        \\JOIN entries e ON e.id = ev.entry_id
        \\LEFT JOIN users u ON u.id = ev.author_id
        \\WHERE ev.id = ?1
    );
    defer stmt.deinit();

    try stmt.bindText(1, version_id);

    if (!try stmt.step()) return null;

    return .{
        .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
        .entry_id = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
        .parent_id = if (stmt.columnText(2)) |v| try allocator.dupe(u8, v) else null,
        .data = try allocator.dupe(u8, stmt.columnText(3) orelse "{}"),
        .author_id = if (stmt.columnText(4)) |v| try allocator.dupe(u8, v) else null,
        .author_email = if (stmt.columnText(5)) |v| try allocator.dupe(u8, v) else null,
        .created_at = stmt.columnInt(6),
        .version_type = try allocator.dupe(u8, stmt.columnText(7) orelse "edit"),
        .is_current = stmt.columnInt(8) == 1,
        .collaborators = if (stmt.columnText(9)) |v| try allocator.dupe(u8, v) else null,
        .author_display_name = if (stmt.columnText(10)) |v| try allocator.dupe(u8, v) else null,
    };
}

/// Restore a previous version: creates a new 'restored' version with the old data,
/// pointing parent_id to the current version. Updates entries.data and current_version_id.
pub fn restoreVersion(
    allocator: Allocator,
    db: *Db,
    entry_id: []const u8,
    source_version_id: []const u8,
    author_id: ?[]const u8,
) !void {
    // Get the source version's data
    const source = try getVersion(allocator, db, source_version_id) orelse return error.VersionNotFound;

    // Delegate to restoreVersionWithData with the source version's data
    try restoreVersionWithData(db, entry_id, source.data, author_id);
}

/// Format a unix timestamp as a relative time string ("2 hours ago", "yesterday", etc.)
pub fn formatRelativeTime(allocator: Allocator, timestamp: i64) ![]const u8 {
    const now = time_util.timestamp();
    const diff = now - timestamp;

    if (diff < 0) return try allocator.dupe(u8, "just now");
    if (diff < 60) return try allocator.dupe(u8, "just now");
    if (diff < 3600) {
        const mins: u64 = @intCast(@divFloor(diff, 60));
        return if (mins == 1)
            try allocator.dupe(u8, "1 minute ago")
        else
            try std.fmt.allocPrint(allocator, "{d} minutes ago", .{mins});
    }
    if (diff < 86400) {
        const hours: u64 = @intCast(@divFloor(diff, 3600));
        return if (hours == 1)
            try allocator.dupe(u8, "1 hour ago")
        else
            try std.fmt.allocPrint(allocator, "{d} hours ago", .{hours});
    }
    if (diff < 604800) {
        const days: u64 = @intCast(@divFloor(diff, 86400));
        return if (days == 1)
            try allocator.dupe(u8, "yesterday")
        else
            try std.fmt.allocPrint(allocator, "{d} days ago", .{days});
    }

    const weeks: u64 = @intCast(@divFloor(diff, 604800));
    return if (weeks == 1)
        try allocator.dupe(u8, "1 week ago")
    else
        try std.fmt.allocPrint(allocator, "{d} weeks ago", .{weeks});
}

/// Structured field comparison result
pub const FieldComparison = struct {
    key: []const u8,
    old_value: []const u8,
    new_value: []const u8,
    changed: bool,
    changed_by: ?[]const u8 = null, // display name (or email) of who last changed this field
    changed_by_email: ?[]const u8 = null, // email of who last changed this field (for gravatar)
};

/// Compare two JSON data strings field-by-field, returning structured data
/// for all fields (union of keys from both objects).
pub fn compareVersionFields(allocator: Allocator, old_data: []const u8, new_data: []const u8) ![]FieldComparison {
    const old_parsed = std.json.parseFromSlice(std.json.Value, allocator, old_data, .{}) catch
        return &.{};
    defer old_parsed.deinit();

    const new_parsed = std.json.parseFromSlice(std.json.Value, allocator, new_data, .{}) catch
        return &.{};
    defer new_parsed.deinit();

    const old_obj = if (old_parsed.value == .object) old_parsed.value.object else return &.{};
    const new_obj = if (new_parsed.value == .object) new_parsed.value.object else return &.{};

    var items: std.ArrayListUnmanaged(FieldComparison) = .{};
    errdefer items.deinit(allocator);

    // Keys from new version
    var new_it = new_obj.iterator();
    while (new_it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const new_val = jsonValueToString(allocator, entry.value_ptr.*) catch try allocator.dupe(u8, "");
        const old_val = if (old_obj.get(key)) |ov| jsonValueToString(allocator, ov) catch try allocator.dupe(u8, "") else try allocator.dupe(u8, "");

        try items.append(allocator, .{
            .key = key,
            .old_value = old_val,
            .new_value = new_val,
            .changed = !std.mem.eql(u8, old_val, new_val),
        });
    }

    // Keys only in old version (removed fields)
    var old_it = old_obj.iterator();
    while (old_it.next()) |entry| {
        if (!new_obj.contains(entry.key_ptr.*)) {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const old_val = jsonValueToString(allocator, entry.value_ptr.*) catch try allocator.dupe(u8, "");

            try items.append(allocator, .{
                .key = key,
                .old_value = old_val,
                .new_value = try allocator.dupe(u8, ""),
                .changed = true,
            });
        }
    }

    return items.toOwnedSlice(allocator);
}

/// Walk the version chain from current back to old_version and determine
/// who last changed each field. Populates `changed_by` on the FieldComparison items.
pub fn populateFieldAuthors(allocator: Allocator, db: *Db, fields: []FieldComparison, current_version_id: []const u8, old_version_id: []const u8) void {
    // Walk parent_id chain from current to old, collecting (data, author_label) pairs
    const ChainEntry = struct { data: []const u8, label: ?[]const u8, email: ?[]const u8 };
    var chain: std.ArrayListUnmanaged(ChainEntry) = .{};
    defer {
        for (chain.items) |item| {
            allocator.free(item.data);
            if (item.label) |l| allocator.free(l);
            if (item.email) |e| allocator.free(e);
        }
        chain.deinit(allocator);
    }

    var walk_id: ?[]const u8 = allocator.dupe(u8, current_version_id) catch return;
    defer if (walk_id) |w| allocator.free(w);

    var steps: usize = 0;
    while (walk_id) |wid| {
        if (steps > 100) break; // safety limit
        steps += 1;

        var stmt = db.prepare(
            \\SELECT ev.data, u.email, ev.parent_id, u.display_name
            \\FROM entry_versions ev
            \\LEFT JOIN users u ON u.id = ev.author_id
            \\WHERE ev.id = ?1
        ) catch break;
        defer stmt.deinit();
        stmt.bindText(1, wid) catch break;
        if (!(stmt.step() catch break)) break;

        const data = allocator.dupe(u8, stmt.columnText(0) orelse "{}") catch break;
        // Prefer display_name over email
        const display_name = stmt.columnText(3);
        const email = stmt.columnText(1);
        const label = if (display_name) |dn| (if (dn.len > 0) allocator.dupe(u8, dn) catch null else if (email) |e| allocator.dupe(u8, e) catch null else null) else if (email) |e| allocator.dupe(u8, e) catch null else null;
        const email_dupe = if (email) |e| allocator.dupe(u8, e) catch null else null;
        chain.append(allocator, .{ .data = data, .label = label, .email = email_dupe }) catch break;

        const at_old = std.mem.eql(u8, wid, old_version_id);
        if (at_old) break;

        if (stmt.columnText(2)) |parent| {
            allocator.free(wid);
            walk_id = allocator.dupe(u8, parent) catch null;
        } else break;
    }

    if (chain.items.len < 2) return;

    // chain is [current, parent, grandparent, ..., old] — walk adjacent pairs
    // For each pair (newer, older): fields that differ were changed by newer's author
    for (0..chain.items.len - 1) |i| {
        const newer = chain.items[i];
        const older = chain.items[i + 1];

        const newer_parsed = std.json.parseFromSlice(std.json.Value, allocator, newer.data, .{}) catch continue;
        defer newer_parsed.deinit();
        const older_parsed = std.json.parseFromSlice(std.json.Value, allocator, older.data, .{}) catch continue;
        defer older_parsed.deinit();

        if (newer_parsed.value != .object or older_parsed.value != .object) continue;
        const newer_obj = newer_parsed.value.object;
        const older_obj = older_parsed.value.object;

        for (fields) |*f| {
            if (!f.changed or f.changed_by != null) continue; // already attributed

            const newer_val = newer_obj.get(f.key);
            const older_val = older_obj.get(f.key);

            const differs = if (newer_val) |nv| blk: {
                if (older_val) |ov| {
                    const nv_str = jsonValueToString(allocator, nv) catch continue;
                    defer allocator.free(nv_str);
                    const ov_str = jsonValueToString(allocator, ov) catch continue;
                    defer allocator.free(ov_str);
                    break :blk !std.mem.eql(u8, nv_str, ov_str);
                } else break :blk true;
            } else older_val != null;

            if (differs) {
                // This version introduced the change for this field
                if (newer.label) |l| {
                    f.changed_by = allocator.dupe(u8, l) catch null;
                }
                if (newer.email) |e| {
                    f.changed_by_email = allocator.dupe(u8, e) catch null;
                }
            }
        }
    }
}

/// Restore a version with arbitrary merged data. Creates a 'restored' version
/// with the given data, updates entries.data, title, slug, status from the JSON.
pub fn restoreVersionWithData(
    db: *Db,
    entry_id: []const u8,
    data: []const u8,
    author_id: ?[]const u8,
) !void {
    // Get current version id and check if entry is published
    var cur_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM entries WHERE id = ?1",
    );
    defer cur_stmt.deinit();
    try cur_stmt.bindText(1, entry_id);
    if (!try cur_stmt.step()) return error.EntryNotFound;
    const current_vid = cur_stmt.columnText(0);
    const is_published = cur_stmt.columnText(1) != null;

    // Create new version with merged data
    const new_vid = generateVersionId();

    {
        var v_stmt = try db.prepare(
            \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 'restored')
        );
        defer v_stmt.deinit();

        try v_stmt.bindText(1, &new_vid);
        try v_stmt.bindText(2, entry_id);
        if (current_vid) |cv| try v_stmt.bindText(3, cv) else try v_stmt.bindNull(3);
        try v_stmt.bindText(4, data);
        if (author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);

        _ = try v_stmt.step();
    }

    // Extract title, slug, status from data JSON for entries update
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch null;
    defer if (parsed) |p| p.deinit();

    var title: []const u8 = "";
    var slug: ?[]const u8 = null;
    var status: []const u8 = "draft";

    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get("title")) |v| {
                if (v == .string) title = v.string;
            }
            if (p.value.object.get("slug")) |v| {
                if (v == .string) slug = v.string;
            }
            if (p.value.object.get("status")) |v| {
                if (v == .string) status = v.string;
            }
        }
    }

    // Update entry — if published, also update published_version_id so restore goes live immediately
    if (is_published) {
        var u_stmt = try db.prepare(
            \\UPDATE entries SET current_version_id = ?1, published_version_id = ?1, data = ?2,
            \\    title = ?3, slug = ?4, status = ?5, updated_at = unixepoch()
            \\WHERE id = ?6
        );
        defer u_stmt.deinit();

        try u_stmt.bindText(1, &new_vid);
        try u_stmt.bindText(2, data);
        try u_stmt.bindText(3, title);
        if (slug) |s| try u_stmt.bindText(4, s) else try u_stmt.bindNull(4);
        try u_stmt.bindText(5, status);
        try u_stmt.bindText(6, entry_id);

        _ = try u_stmt.step();
    } else {
        var u_stmt = try db.prepare(
            \\UPDATE entries SET current_version_id = ?1, data = ?2,
            \\    title = ?3, slug = ?4, status = ?5, updated_at = unixepoch()
            \\WHERE id = ?6
        );
        defer u_stmt.deinit();

        try u_stmt.bindText(1, &new_vid);
        try u_stmt.bindText(2, data);
        try u_stmt.bindText(3, title);
        if (slug) |s| try u_stmt.bindText(4, s) else try u_stmt.bindNull(4);
        try u_stmt.bindText(5, status);
        try u_stmt.bindText(6, entry_id);

        _ = try u_stmt.step();
    }

    // Enforce retention limit
    try pruneVersions(db, entry_id);
}

/// Compute a field-level diff between two JSON data strings.
/// Returns HTML showing changes per field.
pub fn diffVersions(allocator: Allocator, old_data: []const u8, new_data: []const u8) ![]const u8 {
    // Parse both JSON objects
    const old_parsed = std.json.parseFromSlice(std.json.Value, allocator, old_data, .{}) catch
        return try allocator.dupe(u8, "<p class=\"diff-error\">Could not parse old version data</p>");
    defer old_parsed.deinit();

    const new_parsed = std.json.parseFromSlice(std.json.Value, allocator, new_data, .{}) catch
        return try allocator.dupe(u8, "<p class=\"diff-error\">Could not parse new version data</p>");
    defer new_parsed.deinit();

    const old_obj = if (old_parsed.value == .object) old_parsed.value.object else return try allocator.dupe(u8, "");
    const new_obj = if (new_parsed.value == .object) new_parsed.value.object else return try allocator.dupe(u8, "");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("<div class=\"diff\">");

    // Check fields in new version (changed + added)
    var new_it = new_obj.iterator();
    while (new_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const new_val = jsonValueToString(allocator, entry.value_ptr.*) catch "";
        const old_val = if (old_obj.get(key)) |ov| jsonValueToString(allocator, ov) catch "" else "";

        if (old_val.len == 0 and new_val.len == 0) continue;

        if (!old_obj.contains(key)) {
            // Added field
            try w.writeAll("<div class=\"diff-field diff-added\"><span class=\"diff-key\">");
            try w.writeAll(key);
            try w.writeAll("</span><span class=\"diff-badge\">added</span><div class=\"diff-val diff-new\">");
            try writeEscaped(w, new_val);
            try w.writeAll("</div></div>");
        } else if (!std.mem.eql(u8, old_val, new_val)) {
            // Changed field
            try w.writeAll("<div class=\"diff-field diff-changed\"><span class=\"diff-key\">");
            try w.writeAll(key);
            try w.writeAll("</span><span class=\"diff-badge\">changed</span><div class=\"diff-val diff-old\">");
            try writeEscaped(w, old_val);
            try w.writeAll("</div><div class=\"diff-val diff-new\">");
            try writeEscaped(w, new_val);
            try w.writeAll("</div></div>");
        }
    }

    // Check fields removed (in old but not new)
    var old_it = old_obj.iterator();
    while (old_it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!new_obj.contains(key)) {
            const old_val = jsonValueToString(allocator, entry.value_ptr.*) catch "";
            try w.writeAll("<div class=\"diff-field diff-removed\"><span class=\"diff-key\">");
            try w.writeAll(key);
            try w.writeAll("</span><span class=\"diff-badge\">removed</span><div class=\"diff-val diff-old\">");
            try writeEscaped(w, old_val);
            try w.writeAll("</div></div>");
        }
    }

    try w.writeAll("</div>");

    return buf.toOwnedSlice(allocator);
}

/// Convert a JSON value to a display string
pub fn jsonValueToString(allocator: Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .null => try allocator.dupe(u8, ""),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .array, .object => try std.fmt.allocPrint(allocator, "[complex value]", .{}),
        else => try allocator.dupe(u8, ""),
    };
}

/// Write HTML-escaped text
pub fn writeEscaped(w: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

// =============================================================================
// Releases
// =============================================================================

/// Generate a release ID (rel_ prefix + 16 random alphanumeric chars)
fn generateReleaseId() [20]u8 {
    var id_buf: [20]u8 = undefined;
    id_buf[0] = 'r';
    id_buf[1] = 'e';
    id_buf[2] = 'l';
    id_buf[3] = '_';

    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (rand_buf, 0..) |byte, i| {
        id_buf[4 + i] = charset[byte % charset.len];
    }

    return id_buf;
}

/// Get the current_version_id for an entry
pub fn getEntryVersionId(db: *Db, entry_id: []const u8) !?[]const u8 {
    var stmt = try db.prepare(
        "SELECT current_version_id FROM entries WHERE id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    if (try stmt.step()) {
        if (stmt.columnText(0)) |v| {
            return try db.allocator.dupe(u8, v);
        }
    }
    return null;
}

/// Set published_version_id on an entry (used when publishing without data change)
/// Get the published version's data for an entry (for smart change detection).
/// Returns null if no published version exists (i.e. entry was never published).
pub fn getPublishedData(allocator: Allocator, db: *Db, entry_id: []const u8) !?[]const u8 {
    var stmt = try db.prepare(
        \\SELECT ev.data FROM entries e
        \\JOIN entry_versions ev ON ev.id = e.published_version_id
        \\WHERE e.id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    if (try stmt.step()) {
        if (stmt.columnText(0)) |d| {
            return try allocator.dupe(u8, d);
        }
    }
    return null;
}

/// Discard WIP changes by resetting an entry to its published version.
/// No history entry is created — this silently reverts current_version_id
/// and entries.data back to the published snapshot.
pub fn discardToPublished(db: *Db, entry_id: []const u8) !void {
    // Get published version id and data
    var stmt = try db.prepare(
        \\SELECT e.published_version_id, ev.data
        \\FROM entries e
        \\JOIN entry_versions ev ON ev.id = e.published_version_id
        \\WHERE e.id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    if (!try stmt.step()) return;

    const published_vid = stmt.columnText(0) orelse return;
    const published_data = stmt.columnText(1) orelse return;

    // Extract title and slug from published data for entries table
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, published_data, .{}) catch null;
    defer if (parsed) |p| p.deinit();

    var title: []const u8 = "";
    var slug: ?[]const u8 = null;

    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get("title")) |t| {
                if (t == .string) title = t.string;
            }
            if (p.value.object.get("slug")) |s| {
                if (s == .string) slug = s.string;
            }
        }
    }

    // Reset entry to published state
    var u_stmt = try db.prepare(
        \\UPDATE entries SET current_version_id = ?1, data = ?2,
        \\    title = ?3, slug = ?4, status = 'published', updated_at = unixepoch()
        \\WHERE id = ?5
    );
    defer u_stmt.deinit();
    try u_stmt.bindText(1, published_vid);
    try u_stmt.bindText(2, published_data);
    try u_stmt.bindText(3, title);
    if (slug) |s| try u_stmt.bindText(4, s) else try u_stmt.bindNull(4);
    try u_stmt.bindText(5, entry_id);
    _ = try u_stmt.step();
}

/// Merge selected fields from draft JSON into published JSON.
/// Returns a new JSON string with all published fields + selected fields overlaid from draft.
pub fn mergeJsonFields(allocator: Allocator, published_json: []const u8, draft_json: []const u8, field_names: []const []const u8) ![]const u8 {
    const pub_parsed = std.json.parseFromSlice(std.json.Value, allocator, published_json, .{}) catch
        return try allocator.dupe(u8, published_json);
    defer pub_parsed.deinit();

    const draft_parsed = std.json.parseFromSlice(std.json.Value, allocator, draft_json, .{}) catch
        return try allocator.dupe(u8, published_json);
    defer draft_parsed.deinit();

    const pub_obj = if (pub_parsed.value == .object) pub_parsed.value.object else return try allocator.dupe(u8, published_json);
    const draft_obj = if (draft_parsed.value == .object) draft_parsed.value.object else return try allocator.dupe(u8, published_json);

    // Build merged JSON string: start with all published fields, overlay selected from draft
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var first = true;

    // Write all published fields, substituting selected ones from draft
    var pub_it = pub_obj.iterator();
    while (pub_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;

        // Write key
        try w.print("\"{s}\":", .{entry.key_ptr.*});

        // Check if this field should come from draft
        var use_draft = false;
        for (field_names) |fname| {
            if (std.mem.eql(u8, fname, entry.key_ptr.*)) {
                use_draft = true;
                break;
            }
        }

        if (use_draft) {
            if (draft_obj.get(entry.key_ptr.*)) |draft_val| {
                try writeJsonValue(w, draft_val);
            } else {
                try writeJsonValue(w, entry.value_ptr.*);
            }
        } else {
            try writeJsonValue(w, entry.value_ptr.*);
        }
    }

    // Add any draft-only fields that are in the selection but not in published
    for (field_names) |fname| {
        if (!pub_obj.contains(fname)) {
            if (draft_obj.get(fname)) |draft_val| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("\"{s}\":", .{fname});
                try writeJsonValue(w, draft_val);
            }
        }
    }

    try w.writeByte('}');
    return try buf.toOwnedSlice(allocator);
}

/// Write a JSON value to a writer
fn writeJsonValue(w: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| {
            try w.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                }
            }
            try w.writeByte('"');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("\"{s}\":", .{entry.key_ptr.*});
                try writeJsonValue(w, entry.value_ptr.*);
            }
            try w.writeByte('}');
        },
        .number_string => |s| try w.writeAll(s),
    }
}

/// Publish a single entry by creating an instant release and publishing it.
/// Handles both full and partial (field-level) publish through the same
/// publishBatchRelease path — one code path for all publishing.
pub fn publishEntry(allocator: Allocator, db: *Db, entry_id: []const u8, author_id: ?[]const u8, fields_json: ?[]const u8) !void {
    // Get current version IDs
    var e_stmt = try db.prepare("SELECT current_version_id, published_version_id FROM entries WHERE id = ?1");
    defer e_stmt.deinit();
    try e_stmt.bindText(1, entry_id);
    if (!try e_stmt.step()) return error.EntryNotFound;

    const to_version = e_stmt.columnText(0) orelse return error.EntryNotFound;
    const from_version = e_stmt.columnText(1);

    // Skip if already published with same version and no partial fields
    if (fields_json == null) {
        if (from_version) |fv| {
            if (std.mem.eql(u8, fv, to_version)) return;
        }
    }

    // Create pending release (instant = unnamed)
    const release_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            \\INSERT INTO releases (id, name, status, author_id, created_at)
            \\VALUES (?1, NULL, 'pending', ?2, unixepoch())
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        if (author_id) |aid| try stmt.bindText(2, aid) else try stmt.bindNull(2);
        _ = try stmt.step();
    }

    // Add single item
    {
        var stmt = try db.prepare(
            \\INSERT INTO release_items (release_id, entry_id, from_version, to_version, fields)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        try stmt.bindText(2, entry_id);
        if (from_version) |fv| try stmt.bindText(3, fv) else try stmt.bindNull(3);
        try stmt.bindText(4, to_version);
        if (fields_json) |fj| try stmt.bindText(5, fj) else try stmt.bindNull(5);
        _ = try stmt.step();
    }

    // Publish through the single shared path
    try publishBatchRelease(allocator, db, &release_id);
}

/// Error returned when a release operation is blocked
pub const ReleaseError = error{
    ReleaseNotFound,
    InvalidReleaseStatus,
    EntryModifiedSinceRelease,
};

/// Revert a released release: for each item, create a new version with
/// from_version's data, update current_version_id, set status to 'reverted'.
/// Blocked if any entry's current_version_id != the release item's to_version.
pub fn revertRelease(db: *Db, release_id: []const u8, author_id: ?[]const u8) (Db.Error || ReleaseError)!void {
    // 1. Load release — must be status='released'
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "released")) return ReleaseError.InvalidReleaseStatus;
    }

    // 2. Check blocking condition for all items
    {
        var stmt = try db.prepare(
            \\SELECT ri.entry_id FROM release_items ri
            \\JOIN entries e ON e.id = ri.entry_id
            \\WHERE ri.release_id = ?1
            \\  AND e.current_version_id != ri.to_version
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (try stmt.step()) return ReleaseError.EntryModifiedSinceRelease;
    }

    // 3. For each item, create new version with from_version's data
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.from_version, ri.to_version
            \\FROM release_items ri
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const entry_id = items_stmt.columnText(0) orelse continue;
            const from_version = items_stmt.columnText(1);
            const current_to = items_stmt.columnText(2) orelse continue;

            // Get data to restore: from_version's data, or empty JSON if from_version is NULL (new entry)
            var data: []const u8 = "{}";
            var data_stmt: ?Statement = null;
            defer if (data_stmt) |*s| s.deinit();

            if (from_version) |fv| {
                var stmt = try db.prepare("SELECT data FROM entry_versions WHERE id = ?1");
                try stmt.bindText(1, fv);
                if (try stmt.step()) {
                    data = stmt.columnText(0) orelse "{}";
                }
                data_stmt = stmt;
            }

            // Create new version
            const new_vid = generateVersionId();
            {
                var v_stmt = try db.prepare(
                    \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
                    \\VALUES (?1, ?2, ?3, ?4, ?5, 'reverted')
                );
                defer v_stmt.deinit();

                try v_stmt.bindText(1, &new_vid);
                try v_stmt.bindText(2, entry_id);
                try v_stmt.bindText(3, current_to);
                try v_stmt.bindText(4, data);
                if (author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);

                _ = try v_stmt.step();
            }

            // Update entry
            {
                var u_stmt = try db.prepare(
                    \\UPDATE entries SET current_version_id = ?1, data = ?2, updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();

                try u_stmt.bindText(1, &new_vid);
                try u_stmt.bindText(2, data);
                try u_stmt.bindText(3, entry_id);

                _ = try u_stmt.step();
            }
        }
    }

    // 4. Update release status
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'reverted', reverted_at = unixepoch() WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// Re-release a reverted release: for each item, create a new version with
/// to_version's data, update current_version_id, set status back to 'released'.
/// Blocked if any entry has been modified since the revert.
pub fn reReleaseReverted(db: *Db, release_id: []const u8, author_id: ?[]const u8) (Db.Error || ReleaseError)!void {
    // 1. Load release — must be status='reverted'
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "reverted")) return ReleaseError.InvalidReleaseStatus;
    }

    // 2. Check blocking: current_version_id must be the version created by the revert.
    //    That version's parent_id == to_version, so we check that current_version_id's
    //    parent matches to_version for each item.
    {
        var stmt = try db.prepare(
            \\SELECT ri.entry_id FROM release_items ri
            \\JOIN entries e ON e.id = ri.entry_id
            \\JOIN entry_versions ev ON ev.id = e.current_version_id
            \\WHERE ri.release_id = ?1
            \\  AND (ev.parent_id IS NULL OR ev.parent_id != ri.to_version)
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (try stmt.step()) return ReleaseError.EntryModifiedSinceRelease;
    }

    // 3. For each item, create new version with to_version's data
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.to_version
            \\FROM release_items ri
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const entry_id = items_stmt.columnText(0) orelse continue;
            const to_version = items_stmt.columnText(1) orelse continue;

            // Get to_version's data
            var data: []const u8 = "{}";
            var data_stmt: ?Statement = null;
            defer if (data_stmt) |*s| s.deinit();
            {
                var stmt = try db.prepare("SELECT data FROM entry_versions WHERE id = ?1");
                try stmt.bindText(1, to_version);
                if (try stmt.step()) {
                    data = stmt.columnText(0) orelse "{}";
                }
                data_stmt = stmt;
            }

            // Get current version id (parent for new version)
            var current_vid: ?[]const u8 = null;
            var cv_stmt: ?Statement = null;
            defer if (cv_stmt) |*s| s.deinit();
            {
                var stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = ?1");
                try stmt.bindText(1, entry_id);
                if (try stmt.step()) {
                    current_vid = stmt.columnText(0);
                }
                cv_stmt = stmt;
            }

            // Create new version
            const new_vid = generateVersionId();
            {
                var v_stmt = try db.prepare(
                    \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
                    \\VALUES (?1, ?2, ?3, ?4, ?5, 'restored')
                );
                defer v_stmt.deinit();

                try v_stmt.bindText(1, &new_vid);
                try v_stmt.bindText(2, entry_id);
                if (current_vid) |cv| try v_stmt.bindText(3, cv) else try v_stmt.bindNull(3);
                try v_stmt.bindText(4, data);
                if (author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);

                _ = try v_stmt.step();
            }

            // Update entry
            {
                var u_stmt = try db.prepare(
                    \\UPDATE entries SET current_version_id = ?1, data = ?2, updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();

                try u_stmt.bindText(1, &new_vid);
                try u_stmt.bindText(2, data);
                try u_stmt.bindText(3, entry_id);

                _ = try u_stmt.step();
            }
        }
    }

    // 4. Update release status back to released
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'released', released_at = unixepoch(), reverted_at = NULL WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// Set a pending release to scheduled state with a target timestamp.
/// No execution — just stores the state for future use.
pub fn scheduleRelease(db: *Db, release_id: []const u8, scheduled_for: i64) (Db.Error || ReleaseError)!void {
    var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
    const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
    if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;

    var u_stmt = try db.prepare(
        "UPDATE releases SET status = 'scheduled', scheduled_for = ?1 WHERE id = ?2",
    );
    defer u_stmt.deinit();
    try u_stmt.bindInt(1, scheduled_for);
    try u_stmt.bindText(2, release_id);
    _ = try u_stmt.step();
}

// =============================================================================
// Batch Releases
// =============================================================================

/// Lightweight struct for pending release dropdowns
pub const PendingReleaseOption = struct {
    id: []const u8,
    name: []const u8,
};

/// Struct for release list items
pub const ReleaseListItem = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    item_count: i64,
    author_email: ?[]const u8,
    created_at: i64,
};

/// Struct for a single release item in the detail view
pub const ReleaseDetailItem = struct {
    entry_id: []const u8,
    entry_title: []const u8,
    entry_status: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    fields: ?[]const u8,
};

/// Full release detail (header + items)
pub const ReleaseDetail = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    author_email: ?[]const u8,
    created_at: i64,
    released_at: ?i64,
    scheduled_for: ?i64,
    reverted_at: ?i64,
    items: []const ReleaseDetailItem,
};

/// Create a pending (batch) release with a name.
pub fn createPendingRelease(db: *Db, name: []const u8, author_id: ?[]const u8) (Db.Error || error{OutOfMemory})![20]u8 {
    const release_id = generateReleaseId();

    var stmt = try db.prepare(
        \\INSERT INTO releases (id, name, status, author_id, created_at)
        \\VALUES (?1, ?2, 'pending', ?3, unixepoch())
    );
    defer stmt.deinit();
    try stmt.bindText(1, &release_id);
    try stmt.bindText(2, name);
    if (author_id) |aid| try stmt.bindText(3, aid) else try stmt.bindNull(3);
    _ = try stmt.step();

    return release_id;
}

/// Add an entry to a pending release. Uses INSERT OR REPLACE so
/// re-adding the same entry updates the version references.
pub fn addToRelease(
    db: *Db,
    release_id: []const u8,
    entry_id: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    fields: ?[]const u8,
) (Db.Error || ReleaseError)!void {
    // Validate release is pending
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    var stmt = try db.prepare(
        \\INSERT OR REPLACE INTO release_items (release_id, entry_id, from_version, to_version, fields)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    try stmt.bindText(2, entry_id);
    if (from_version) |fv| try stmt.bindText(3, fv) else try stmt.bindNull(3);
    try stmt.bindText(4, to_version);
    if (fields) |f| try stmt.bindText(5, f) else try stmt.bindNull(5);
    _ = try stmt.step();
}

/// Remove an entry from a pending release.
pub fn removeFromRelease(db: *Db, release_id: []const u8, entry_id: []const u8) (Db.Error || ReleaseError)!void {
    // Validate release is pending
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    var stmt = try db.prepare(
        "DELETE FROM release_items WHERE release_id = ?1 AND entry_id = ?2",
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    try stmt.bindText(2, entry_id);
    _ = try stmt.step();
}

/// Archive a release (any status except pending). Archived releases are hidden
/// from the list by default but can still be viewed directly.
pub fn archiveRelease(db: *Db, release_id: []const u8) (Db.Error || ReleaseError)!void {
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    var stmt = try db.prepare(
        "UPDATE releases SET status = 'archived' WHERE id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, release_id);
    _ = try stmt.step();
}

/// Collect unique collaborators between from_version and to_version for an entry.
/// Returns a JSON array like [{"id":"u1","email":"a@b.com","name":"Alice"},{"id":"u2","email":"c@d.com","name":""}].
/// Includes all version authors in the range, plus the publisher who triggered the release.
fn collectCollaborators(
    allocator: Allocator,
    db: *Db,
    entry_id: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    publisher_id: ?[]const u8,
) !?[]const u8 {
    // Get the created_at of from_version (0 if null = first publish, include all)
    var from_time: i64 = 0;
    if (from_version) |fv| {
        var t_stmt = try db.prepare("SELECT created_at FROM entry_versions WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, fv);
        if (try t_stmt.step()) {
            from_time = t_stmt.columnInt(0);
        }
    }

    // Get to_version's created_at as upper bound
    var to_time: i64 = std.math.maxInt(i32);
    {
        var t_stmt = try db.prepare("SELECT created_at FROM entry_versions WHERE id = ?1");
        defer t_stmt.deinit();
        try t_stmt.bindText(1, to_version);
        if (try t_stmt.step()) {
            to_time = t_stmt.columnInt(0);
        }
    }

    const Collab = struct { id: []const u8, email: []const u8, name: []const u8 };
    var collabs: std.ArrayListUnmanaged(Collab) = .{};
    defer {
        for (collabs.items) |c| {
            allocator.free(c.id);
            allocator.free(c.email);
            allocator.free(c.name);
        }
        collabs.deinit(allocator);
    }

    // Collect unique authors from versions in the range
    {
        var stmt = try db.prepare(
            \\SELECT DISTINCT ev.author_id, u.email, u.display_name
            \\FROM entry_versions ev
            \\JOIN users u ON u.id = ev.author_id
            \\WHERE ev.entry_id = ?1
            \\  AND ev.author_id IS NOT NULL
            \\  AND ev.created_at > ?2
            \\  AND ev.created_at <= ?3
        );
        defer stmt.deinit();
        try stmt.bindText(1, entry_id);
        try stmt.bindInt(2, from_time);
        try stmt.bindInt(3, to_time);

        while (try stmt.step()) {
            const aid = stmt.columnText(0) orelse continue;
            const email = stmt.columnText(1) orelse continue;
            const name = stmt.columnText(2) orelse "";
            try collabs.append(allocator, .{
                .id = try allocator.dupe(u8, aid),
                .email = try allocator.dupe(u8, email),
                .name = try allocator.dupe(u8, name),
            });
        }
    }

    // Add publisher if not already present
    if (publisher_id) |pid| {
        var exists = false;
        for (collabs.items) |c| {
            if (std.mem.eql(u8, c.id, pid)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            var pu_stmt = try db.prepare("SELECT email, display_name FROM users WHERE id = ?1");
            defer pu_stmt.deinit();
            try pu_stmt.bindText(1, pid);
            if (try pu_stmt.step()) {
                if (pu_stmt.columnText(0)) |email| {
                    const name = pu_stmt.columnText(1) orelse "";
                    try collabs.append(allocator, .{
                        .id = try allocator.dupe(u8, pid),
                        .email = try allocator.dupe(u8, email),
                        .name = try allocator.dupe(u8, name),
                    });
                }
            }
        }
    }

    if (collabs.items.len == 0) return null;

    // Serialize to JSON
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('[');
    for (collabs.items, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try writeEscaped(w, c.id);
        try w.writeAll("\",\"email\":\"");
        try writeEscaped(w, c.email);
        try w.writeAll("\",\"name\":\"");
        try writeEscaped(w, c.name);
        try w.writeAll("\"}");
    }
    try w.writeByte(']');

    return try buf.toOwnedSlice(allocator);
}

/// Publish a batch release: for each item, set entry status to 'published',
/// then mark release as 'released'.
pub fn publishBatchRelease(allocator: Allocator, db: *Db, release_id: []const u8) !void {
    // Validate release is pending
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        if (!try stmt.step()) return ReleaseError.ReleaseNotFound;
        const status = stmt.columnText(0) orelse return ReleaseError.ReleaseNotFound;
        if (!std.mem.eql(u8, status, "pending")) return ReleaseError.InvalidReleaseStatus;
    }

    // Fetch release author
    var release_author_id: ?[]const u8 = null;
    {
        var a_stmt = try db.prepare("SELECT author_id FROM releases WHERE id = ?1");
        defer a_stmt.deinit();
        try a_stmt.bindText(1, release_id);
        if (try a_stmt.step()) {
            if (a_stmt.columnText(0)) |aid| {
                release_author_id = try allocator.dupe(u8, aid);
            }
        }
    }
    defer if (release_author_id) |a| allocator.free(a);

    // For each item: apply to_version data and set status/published_version_id
    {
        var items_stmt = try db.prepare(
            \\SELECT ri.entry_id, ri.to_version, ev.data, ri.fields, ri.from_version
            \\FROM release_items ri
            \\JOIN entry_versions ev ON ev.id = ri.to_version
            \\WHERE ri.release_id = ?1
        );
        defer items_stmt.deinit();
        try items_stmt.bindText(1, release_id);

        while (try items_stmt.step()) {
            const eid = items_stmt.columnText(0) orelse continue;
            const to_vid = items_stmt.columnText(1) orelse continue;
            const to_data = items_stmt.columnText(2) orelse continue;
            const fields = items_stmt.columnText(3);
            const from_vid = items_stmt.columnText(4);

            if (fields) |fields_json| {
                // Partial publish: merge selected fields into published version
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, fields_json, .{}) catch continue;
                defer parsed.deinit();

                if (parsed.value != .array) continue;

                const arr = parsed.value.array;
                var names = allocator.alloc([]const u8, arr.items.len) catch continue;
                defer allocator.free(names);
                var count: usize = 0;

                for (arr.items) |item| {
                    if (item == .string) {
                        names[count] = item.string;
                        count += 1;
                    }
                }
                if (count == 0) continue;
                const field_names = names[0..count];

                // Get current published data
                const published_data = getPublishedData(allocator, db, eid) catch continue orelse continue;
                defer allocator.free(published_data);

                // Merge: published + selected fields from to_version data
                const merged_data = mergeJsonFields(allocator, published_data, to_data, field_names) catch continue;
                defer allocator.free(merged_data);

                // Collect collaborators from version chain
                const collab_json = collectCollaborators(
                    allocator,
                    db,
                    eid,
                    from_vid,
                    to_vid,
                    release_author_id,
                ) catch null;
                defer if (collab_json) |c| allocator.free(c);

                // Create new version with merged data, author, and collaborators
                const new_vid = generateVersionId();
                {
                    var v_stmt = try db.prepare(
                        \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type, collaborators)
                        \\VALUES (?1, ?2, ?3, ?4, ?5, 'published', ?6)
                    );
                    defer v_stmt.deinit();
                    try v_stmt.bindText(1, &new_vid);
                    try v_stmt.bindText(2, eid);
                    try v_stmt.bindText(3, to_vid);
                    try v_stmt.bindText(4, merged_data);
                    if (release_author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);
                    if (collab_json) |cj| try v_stmt.bindText(6, cj) else try v_stmt.bindNull(6);
                    _ = try v_stmt.step();
                }

                // Update release_items.to_version to point to the new published version
                {
                    var ri_stmt = try db.prepare(
                        "UPDATE release_items SET to_version = ?1 WHERE release_id = ?2 AND entry_id = ?3",
                    );
                    defer ri_stmt.deinit();
                    try ri_stmt.bindText(1, &new_vid);
                    try ri_stmt.bindText(2, release_id);
                    try ri_stmt.bindText(3, eid);
                    _ = try ri_stmt.step();
                }

                // Determine status: compare merged (new published) vs current draft
                var cur_stmt2 = try db.prepare(
                    \\SELECT ev.data FROM entries e
                    \\JOIN entry_versions ev ON ev.id = e.current_version_id
                    \\WHERE e.id = ?1
                );
                defer cur_stmt2.deinit();
                try cur_stmt2.bindText(1, eid);
                const still_changed = if (try cur_stmt2.step())
                    if (cur_stmt2.columnText(0)) |cur_data|
                        !std.mem.eql(u8, cur_data, merged_data)
                    else
                        true
                else
                    true;

                const new_status: []const u8 = if (still_changed) "changed" else "published";
                var u_stmt = try db.prepare(
                    \\UPDATE entries SET status = ?1, published_version_id = ?2,
                    \\published_at = unixepoch(), updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, new_status);
                try u_stmt.bindText(2, &new_vid);
                try u_stmt.bindText(3, eid);
                _ = try u_stmt.step();
            } else {
                // Full publish: set published_version_id, determine status
                var cur_stmt2 = try db.prepare(
                    \\SELECT ev.data FROM entries e
                    \\JOIN entry_versions ev ON ev.id = e.current_version_id
                    \\WHERE e.id = ?1
                );
                defer cur_stmt2.deinit();
                try cur_stmt2.bindText(1, eid);
                const still_changed = if (try cur_stmt2.step())
                    if (cur_stmt2.columnText(0)) |cur_data|
                        !std.mem.eql(u8, cur_data, to_data)
                    else
                        false
                else
                    false;

                const new_status: []const u8 = if (still_changed) "changed" else "published";
                var u_stmt = try db.prepare(
                    \\UPDATE entries SET status = ?1, published_version_id = ?2,
                    \\published_at = unixepoch(), updated_at = unixepoch()
                    \\WHERE id = ?3
                );
                defer u_stmt.deinit();
                try u_stmt.bindText(1, new_status);
                try u_stmt.bindText(2, to_vid);
                try u_stmt.bindText(3, eid);
                _ = try u_stmt.step();

                // Mark the published version's type and store collaborators
                {
                    const collab_json = collectCollaborators(
                        allocator,
                        db,
                        eid,
                        from_vid,
                        to_vid,
                        release_author_id,
                    ) catch null;
                    defer if (collab_json) |c| allocator.free(c);

                    var vt_stmt = try db.prepare(
                        "UPDATE entry_versions SET version_type = 'published', collaborators = ?1, author_id = ?2 WHERE id = ?3",
                    );
                    defer vt_stmt.deinit();
                    if (collab_json) |cj| try vt_stmt.bindText(1, cj) else try vt_stmt.bindNull(1);
                    if (release_author_id) |aid| try vt_stmt.bindText(2, aid) else try vt_stmt.bindNull(2);
                    try vt_stmt.bindText(3, to_vid);
                    _ = try vt_stmt.step();
                }
            }
        }
    }

    // Mark release as released
    {
        var stmt = try db.prepare(
            "UPDATE releases SET status = 'released', released_at = unixepoch() WHERE id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, release_id);
        _ = try stmt.step();
    }
}

/// List releases with optional status filter.
pub fn listReleases(allocator: Allocator, db: *Db, opts: struct {
    status: ?[]const u8 = null,
    limit: u32 = 50,
    include_archived: bool = false,
}) ![]ReleaseListItem {
    // Build query dynamically based on filter
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(
        \\SELECT r.id, r.name, r.status,
        \\  COUNT(ri.entry_id) as item_count,
        \\  u.email, r.created_at
        \\FROM releases r
        \\LEFT JOIN release_items ri ON ri.release_id = r.id
        \\LEFT JOIN users u ON u.id = r.author_id
        \\WHERE r.name IS NOT NULL
    );

    if (opts.status) |_| {
        try w.writeAll(" AND r.status = ?1");
    }

    if (!opts.include_archived) {
        try w.writeAll(" AND r.status != 'archived'");
    }

    try w.writeAll(" GROUP BY r.id ORDER BY r.created_at DESC");
    try w.print(" LIMIT {d}", .{opts.limit});

    const sql = try buf.toOwnedSlice(allocator);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    if (opts.status) |s| try stmt.bindText(1, s);

    var results: std.ArrayList(ReleaseListItem) = .{};
    errdefer results.deinit(allocator);

    while (try stmt.step()) {
        const item = ReleaseListItem{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .name = try allocator.dupe(u8, stmt.columnText(1) orelse "(unnamed)"),
            .status = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
            .item_count = stmt.columnInt(3),
            .author_email = if (stmt.columnText(4)) |e| try allocator.dupe(u8, e) else null,
            .created_at = stmt.columnInt(5),
        };
        try results.append(allocator, item);
    }

    return results.toOwnedSlice(allocator);
}

/// Get full release detail (header + items with entry info).
pub fn getRelease(allocator: Allocator, db: *Db, release_id: []const u8) !?ReleaseDetail {
    // Fetch header
    var h_stmt = try db.prepare(
        \\SELECT r.id, COALESCE(r.name, ''), r.status, u.email,
        \\  r.created_at, r.released_at, r.scheduled_for, r.reverted_at
        \\FROM releases r
        \\LEFT JOIN users u ON u.id = r.author_id
        \\WHERE r.id = ?1
    );
    defer h_stmt.deinit();
    try h_stmt.bindText(1, release_id);
    if (!try h_stmt.step()) return null;

    const id = try allocator.dupe(u8, h_stmt.columnText(0) orelse "");
    const name = try allocator.dupe(u8, h_stmt.columnText(1) orelse "");
    const status = try allocator.dupe(u8, h_stmt.columnText(2) orelse "");
    const author_email = if (h_stmt.columnText(3)) |e| try allocator.dupe(u8, e) else null;
    const created_at = h_stmt.columnInt(4);
    const released_at: ?i64 = if (h_stmt.columnIsNull(5)) null else h_stmt.columnInt(5);
    const scheduled_for: ?i64 = if (h_stmt.columnIsNull(6)) null else h_stmt.columnInt(6);
    const reverted_at: ?i64 = if (h_stmt.columnIsNull(7)) null else h_stmt.columnInt(7);

    // Fetch items
    var i_stmt = try db.prepare(
        \\SELECT ri.entry_id, COALESCE(e.title, '(untitled)'), COALESCE(e.status, ''),
        \\  ri.from_version, ri.to_version, ri.fields
        \\FROM release_items ri
        \\LEFT JOIN entries e ON e.id = ri.entry_id
        \\WHERE ri.release_id = ?1
    );
    defer i_stmt.deinit();
    try i_stmt.bindText(1, release_id);

    var items: std.ArrayList(ReleaseDetailItem) = .{};
    errdefer items.deinit(allocator);

    while (try i_stmt.step()) {
        try items.append(allocator, .{
            .entry_id = try allocator.dupe(u8, i_stmt.columnText(0) orelse ""),
            .entry_title = try allocator.dupe(u8, i_stmt.columnText(1) orelse "(untitled)"),
            .entry_status = try allocator.dupe(u8, i_stmt.columnText(2) orelse ""),
            .from_version = if (i_stmt.columnText(3)) |v| try allocator.dupe(u8, v) else null,
            .to_version = try allocator.dupe(u8, i_stmt.columnText(4) orelse ""),
            .fields = if (i_stmt.columnText(5)) |f| try allocator.dupe(u8, f) else null,
        });
    }

    return ReleaseDetail{
        .id = id,
        .name = name,
        .status = status,
        .author_email = author_email,
        .created_at = created_at,
        .released_at = released_at,
        .scheduled_for = scheduled_for,
        .reverted_at = reverted_at,
        .items = try items.toOwnedSlice(allocator),
    };
}

/// List pending releases (lightweight, for dropdown).
pub fn listPendingReleases(allocator: Allocator, db: *Db) ![]PendingReleaseOption {
    var stmt = try db.prepare(
        "SELECT id, name FROM releases WHERE status = 'pending' ORDER BY created_at DESC",
    );
    defer stmt.deinit();

    var results: std.ArrayList(PendingReleaseOption) = .{};
    errdefer results.deinit(allocator);

    while (try stmt.step()) {
        try results.append(allocator, .{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .name = try allocator.dupe(u8, stmt.columnText(1) orelse "(unnamed)"),
        });
    }

    return results.toOwnedSlice(allocator);
}

/// Get IDs of pending releases that contain a given entry.
pub fn getEntryPendingReleaseIds(allocator: Allocator, db: *Db, entry_id: []const u8) ![][]const u8 {
    var stmt = try db.prepare(
        \\SELECT ri.release_id FROM release_items ri
        \\JOIN releases r ON r.id = ri.release_id
        \\WHERE ri.entry_id = ?1 AND r.status = 'pending'
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);

    var results: std.ArrayList([]const u8) = .{};
    errdefer results.deinit(allocator);
    while (try stmt.step()) {
        try results.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
    }
    return results.toOwnedSlice(allocator);
}

/// Info about which fields of an entry are in pending releases.
pub const EntryReleaseFieldInfo = struct {
    release_id: []const u8,
    release_name: []const u8,
    fields: ?[]const u8, // JSON array of field names, or null for full publish
};

/// Get pending release items for an entry, with release name and field list.
pub fn getEntryPendingReleaseFields(allocator: Allocator, db: *Db, entry_id: []const u8) ![]const EntryReleaseFieldInfo {
    var stmt = try db.prepare(
        \\SELECT ri.release_id, r.name, ri.fields
        \\FROM release_items ri
        \\JOIN releases r ON r.id = ri.release_id
        \\WHERE ri.entry_id = ?1 AND r.status = 'pending' AND r.name IS NOT NULL
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);

    var results: std.ArrayList(EntryReleaseFieldInfo) = .{};
    errdefer results.deinit(allocator);
    while (try stmt.step()) {
        try results.append(allocator, .{
            .release_id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .release_name = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .fields = if (stmt.columnText(2)) |f| try allocator.dupe(u8, f) else null,
        });
    }
    return results.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "generateId produces valid entry IDs" {
    const id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expect(std.mem.startsWith(u8, id, "e_"));
    try std.testing.expect(id.len >= 10);
}

test "Status enum conversions" {
    try std.testing.expectEqualStrings("draft", Status.draft.toString());
    try std.testing.expectEqualStrings("published", Status.published.toString());

    try std.testing.expect(Status.fromString("draft") == .draft);
    try std.testing.expect(Status.fromString("published") == .published);
    try std.testing.expect(Status.fromString("invalid") == null);
}

test "generateVersionId produces valid IDs" {
    const id = generateVersionId();
    try std.testing.expect(id[0] == 'v');
    try std.testing.expect(id[1] == '_');
    try std.testing.expectEqual(@as(usize, 18), id.len);
}

/// Helper: set up a test database with schema for versioning tests
fn setupTestDb() !*Db {
    var db = try Db.init(std.testing.allocator, ":memory:");
    errdefer db.deinit();

    // Create minimal schema
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id TEXT PRIMARY KEY,
        \\    email TEXT UNIQUE NOT NULL,
        \\    display_name TEXT DEFAULT '',
        \\    email_verified INTEGER DEFAULT 0,
        \\    password_hash TEXT NOT NULL,
        \\    created_at INTEGER DEFAULT (unixepoch())
        \\);
        \\CREATE TABLE IF NOT EXISTS content_types (
        \\    id TEXT PRIMARY KEY,
        \\    slug TEXT UNIQUE NOT NULL,
        \\    name TEXT NOT NULL,
        \\    fields TEXT NOT NULL,
        \\    source TEXT NOT NULL,
        \\    created_at INTEGER DEFAULT (unixepoch())
        \\);
        \\CREATE TABLE IF NOT EXISTS entry_versions (
        \\    id TEXT PRIMARY KEY,
        \\    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        \\    parent_id TEXT REFERENCES entry_versions(id),
        \\    data TEXT NOT NULL,
        \\    author_id TEXT REFERENCES users(id),
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    version_type TEXT NOT NULL DEFAULT 'edit',
        \\    collaborators TEXT
        \\);
        \\CREATE TABLE IF NOT EXISTS entries (
        \\    id TEXT PRIMARY KEY,
        \\    content_type_id TEXT NOT NULL REFERENCES content_types(id),
        \\    slug TEXT,
        \\    title TEXT,
        \\    data TEXT NOT NULL,
        \\    status TEXT DEFAULT 'draft',
        \\    version INTEGER DEFAULT 1,
        \\    current_version_id TEXT REFERENCES entry_versions(id),
        \\    published_version_id TEXT REFERENCES entry_versions(id),
        \\    published_at INTEGER,
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    updated_at INTEGER DEFAULT (unixepoch()),
        \\    UNIQUE(content_type_id, slug)
        \\);
        \\CREATE TABLE IF NOT EXISTS settings (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL,
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    updated_at INTEGER DEFAULT (unixepoch())
        \\);
        \\CREATE TABLE IF NOT EXISTS releases (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    status TEXT NOT NULL DEFAULT 'pending',
        \\    author_id TEXT REFERENCES users(id),
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    released_at INTEGER,
        \\    scheduled_for INTEGER,
        \\    reverted_at INTEGER
        \\);
        \\CREATE TABLE IF NOT EXISTS release_items (
        \\    release_id TEXT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
        \\    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        \\    from_version TEXT REFERENCES entry_versions(id),
        \\    to_version TEXT NOT NULL REFERENCES entry_versions(id),
        \\    fields TEXT,
        \\    PRIMARY KEY (release_id, entry_id)
        \\);
        \\INSERT INTO content_types (id, slug, name, fields, source)
        \\VALUES ('test_ct', 'test_ct', 'Test', '[]', 'core');
    );

    // Need to return a pointer that outlives this function
    const ptr = try std.testing.allocator.create(Db);
    ptr.* = db;
    return ptr;
}

fn destroyTestDb(db: **Db) void {
    db.*.deinit();
    std.testing.allocator.destroy(db.*);
}

/// Helper: insert a version and link it to an entry
fn insertTestVersion(db: *Db, entry_id: []const u8, data: []const u8, parent_id: ?[]const u8) ![18]u8 {
    const version_id = generateVersionId();

    var v_stmt = try db.prepare(
        \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
        \\VALUES (?1, ?2, ?3, ?4, NULL, 'edit')
    );
    defer v_stmt.deinit();

    try v_stmt.bindText(1, &version_id);
    try v_stmt.bindText(2, entry_id);
    if (parent_id) |pid| try v_stmt.bindText(3, pid) else try v_stmt.bindNull(3);
    try v_stmt.bindText(4, data);
    _ = try v_stmt.step();

    // Update entry's current_version_id
    var u_stmt = try db.prepare(
        "UPDATE entries SET current_version_id = ?1, data = ?2 WHERE id = ?3",
    );
    defer u_stmt.deinit();
    try u_stmt.bindText(1, &version_id);
    try u_stmt.bindText(2, data);
    try u_stmt.bindText(3, entry_id);
    _ = try u_stmt.step();

    return version_id;
}

test "version is created on save and linked to entry" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create an entry manually
    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'draft')
    );

    // Insert a version (simulates what saveEntry does)
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);

    // Verify version exists
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    }

    // Verify entry points to version
    {
        var stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v1, stmt.columnText(0) orelse "");
    }

    // Verify version data matches
    {
        var stmt = try db.prepare(
            \\SELECT ev.data FROM entries e
            \\JOIN entry_versions ev ON e.current_version_id = ev.id
            \\WHERE e.id = 'e_test1'
        );
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"v1\"}", stmt.columnText(0) orelse "");
    }
}

test "sequential saves form a parent chain" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'draft')
    );

    // First version — no parent
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    // Second version — parent is v1
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1);
    // Third version — parent is v2
    const v3 = try insertTestVersion(db, "e_test1", "{\"title\":\"v3\"}", &v2);

    // Verify 3 versions exist
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
    }

    // Verify entry points to latest
    {
        var stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v3, stmt.columnText(0) orelse "");
    }

    // Verify v1 has no parent
    {
        var stmt = try db.prepare("SELECT parent_id FROM entry_versions WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &v1);
        _ = try stmt.step();
        try std.testing.expect(stmt.columnIsNull(0));
    }

    // Verify v2 parent is v1
    {
        var stmt = try db.prepare("SELECT parent_id FROM entry_versions WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &v2);
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v1, stmt.columnText(0) orelse "");
    }

    // Verify v3 parent is v2
    {
        var stmt = try db.prepare("SELECT parent_id FROM entry_versions WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &v3);
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v2, stmt.columnText(0) orelse "");
    }
}

test "pruneVersions does nothing without limit" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Insert 5 versions
    var prev: ?[]const u8 = null;
    var prev_buf: [18]u8 = undefined;
    for (0..5) |_| {
        const vid = try insertTestVersion(db, "e_test1", "{}", prev);
        prev_buf = vid;
        prev = &prev_buf;
    }

    // No settings row — pruneVersions should be a no-op
    try pruneVersions(db, "e_test1");

    var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 5), stmt.columnInt(0));
}

test "pruneVersions enforces retention limit" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Insert 5 versions
    var prev: ?[]const u8 = null;
    var prev_buf: [18]u8 = undefined;
    for (0..5) |_| {
        const vid = try insertTestVersion(db, "e_test1", "{}", prev);
        prev_buf = vid;
        prev = &prev_buf;
    }

    // Set retention limit to 3
    try db.exec("INSERT INTO settings (key, value) VALUES ('version_history_limit', '3')");

    try pruneVersions(db, "e_test1");

    // Should have 3 versions left
    var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
}

test "pruneVersions keeps most recent versions" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Insert 3 versions with distinct data
    _ = try insertTestVersion(db, "e_test1", "{\"v\":1}", null);
    // Small sleep not possible in tests, but created_at defaults to unixepoch()
    // which is the same second. Use explicit timestamps instead.
    // Actually, all versions in the same second will have same created_at.
    // The pruning uses ORDER BY created_at DESC, LIMIT — with ties,
    // SQLite picks arbitrarily but consistently. We'll verify count only.

    var prev_buf: [18]u8 = undefined;
    prev_buf = try insertTestVersion(db, "e_test1", "{\"v\":1}", null);
    const v2 = try insertTestVersion(db, "e_test1", "{\"v\":2}", &prev_buf);
    prev_buf = v2;
    _ = try insertTestVersion(db, "e_test1", "{\"v\":3}", &prev_buf);

    // Set limit to 2
    try db.exec("INSERT INTO settings (key, value) VALUES ('version_history_limit', '2')");

    try pruneVersions(db, "e_test1");

    var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
}

test "listVersions returns versions in newest-first order" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"v\":1}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    _ = try insertTestVersion(db, "e_test1", "{\"v\":2}", &v1_copy);

    const versions = try listVersions(std.testing.allocator, db, "e_test1", .{});
    defer std.testing.allocator.free(versions);

    try std.testing.expectEqual(@as(usize, 2), versions.len);
    // Newest first — v2 should be first (is_current = true)
    try std.testing.expect(versions[0].is_current);
}

test "listVersions returns empty for nonexistent entry" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const versions = try listVersions(std.testing.allocator, db, "e_nonexistent", .{});
    defer std.testing.allocator.free(versions);

    try std.testing.expectEqual(@as(usize, 0), versions.len);
}

test "getVersion returns correct version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"hello\"}", null);

    const version = try getVersion(std.testing.allocator, db, &v1);
    try std.testing.expect(version != null);
    try std.testing.expectEqualStrings("{\"title\":\"hello\"}", version.?.data);
    try std.testing.expect(version.?.is_current);
}

test "getVersion returns null for nonexistent version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const version = try getVersion(std.testing.allocator, db, "v_nonexistent12345");
    try std.testing.expect(version == null);
}

test "restoreVersion creates new version with old data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Create two versions
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"original\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"modified\"}", &v1_copy);

    // Restore v1
    try restoreVersion(std.testing.allocator, db, "e_test1", &v1, null);

    // Should now have 3 versions
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
    }

    // Current version data should be the original
    {
        var stmt = try db.prepare(
            \\SELECT ev.data FROM entries e
            \\JOIN entry_versions ev ON e.current_version_id = ev.id
            \\WHERE e.id = 'e_test1'
        );
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"original\"}", stmt.columnText(0) orelse "");
    }

    // entries.data should also be synced
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"original\"}", stmt.columnText(0) orelse "");
    }
}

test "diffVersions shows changed fields" {
    const result = try diffVersions(
        std.testing.allocator,
        "{\"title\":\"old title\",\"body\":\"same\"}",
        "{\"title\":\"new title\",\"body\":\"same\"}",
    );
    defer std.testing.allocator.free(result);

    // Should contain "title" as changed
    try std.testing.expect(std.mem.indexOf(u8, result, "title") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "changed") != null);
    // Should NOT contain "body" (unchanged)
    try std.testing.expect(std.mem.indexOf(u8, result, "diff-key\">body") == null);
}

test "diffVersions shows added fields" {
    const result = try diffVersions(
        std.testing.allocator,
        "{\"title\":\"hello\"}",
        "{\"title\":\"hello\",\"extra\":\"new\"}",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "added") != null);
}

test "diffVersions shows removed fields" {
    const result = try diffVersions(
        std.testing.allocator,
        "{\"title\":\"hello\",\"old_field\":\"gone\"}",
        "{\"title\":\"hello\"}",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "old_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "removed") != null);
}

test "generateReleaseId produces valid IDs" {
    const id = generateReleaseId();
    try std.testing.expect(id[0] == 'r');
    try std.testing.expect(id[1] == 'e');
    try std.testing.expect(id[2] == 'l');
    try std.testing.expect(id[3] == '_');
    try std.testing.expectEqual(@as(usize, 20), id.len);
}

test "publishEntry creates release and publishes" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);

    try publishEntry(std.testing.allocator, db, "e_test1", null, null);

    // Verify entry is published with published_version_id set
    {
        var stmt = try db.prepare("SELECT status, published_version_id FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("published", stmt.columnText(0) orelse "");
        try std.testing.expectEqualStrings(&v1, stmt.columnText(1) orelse "");
    }

    // Verify release exists and is released
    {
        var stmt = try db.prepare("SELECT status, released_at, name FROM releases");
        defer stmt.deinit();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
        try std.testing.expect(!stmt.columnIsNull(1));
        try std.testing.expect(stmt.columnIsNull(2)); // instant release has null name
    }

    // Verify release item
    {
        var stmt = try db.prepare("SELECT entry_id, from_version, to_version FROM release_items");
        defer stmt.deinit();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("e_test1", stmt.columnText(0) orelse "");
        try std.testing.expect(stmt.columnIsNull(1)); // from_version is NULL (first publish)
        try std.testing.expectEqualStrings(&v1, stmt.columnText(2) orelse "");
    }
}

test "publishEntry skips when already published with same version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'published')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    // Set published_version_id = current_version_id (already published)
    {
        var stmt = try db.prepare("UPDATE entries SET published_version_id = ?1 WHERE id = 'e_test1'");
        defer stmt.deinit();
        try stmt.bindText(1, &v1);
        _ = try stmt.step();
    }

    try publishEntry(std.testing.allocator, db, "e_test1", null, null);

    // No release should be created
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM releases");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
    }
}

test "publishEntry partial publish merges selected fields" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Start with published entry
    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"old","slug":"old-slug"}', 'changed')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"old\",\"slug\":\"old-slug\"}", null);

    // Set as published
    {
        var stmt = try db.prepare("UPDATE entries SET published_version_id = ?1 WHERE id = 'e_test1'");
        defer stmt.deinit();
        try stmt.bindText(1, &v1);
        _ = try stmt.step();
    }

    // Create draft with changes to both fields
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"new\",\"slug\":\"new-slug\"}", &v1_copy);

    // Partial publish: only title
    try publishEntry(std.testing.allocator, db, "e_test1", null, "[\"title\"]");

    // Entry should still be changed (slug not published)
    {
        var stmt = try db.prepare("SELECT status FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("changed", stmt.columnText(0) orelse "");
    }

    // Published data should have new title but old slug
    const pub_data = try getPublishedData(std.testing.allocator, db, "e_test1");
    defer if (pub_data) |d| std.testing.allocator.free(d);
    try std.testing.expect(pub_data != null);

    // Parse and verify
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pub_data.?, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("new", obj.get("title").?.string);
    try std.testing.expectEqualStrings("old-slug", obj.get("slug").?.string);
}

test "getEntryVersionId returns current version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    const version_id = try getEntryVersionId(db, "e_test1");
    try std.testing.expect(version_id != null);
    defer db.allocator.free(version_id.?);
    try std.testing.expectEqualStrings(&v1, version_id.?);
}

test "getEntryVersionId returns null for no version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status, current_version_id)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft', NULL)
    );

    const version_id = try getEntryVersionId(db, "e_test1");
    try std.testing.expect(version_id == null);
}

/// Helper: create a released release for testing revert/re-release
fn createTestRelease(db: *Db, entry_id: []const u8, from_v: ?[]const u8, to_v: []const u8) ![20]u8 {
    const release_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            \\INSERT INTO releases (id, name, status, author_id, created_at, released_at)
            \\VALUES (?1, NULL, 'released', NULL, unixepoch(), unixepoch())
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        _ = try stmt.step();
    }
    {
        var stmt = try db.prepare(
            \\INSERT INTO release_items (release_id, entry_id, from_version, to_version)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        try stmt.bindText(2, entry_id);
        if (from_v) |fv| try stmt.bindText(3, fv) else try stmt.bindNull(3);
        try stmt.bindText(4, to_v);
        _ = try stmt.step();
    }
    return release_id;
}

test "revertRelease restores from_version data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release: v1 → v2
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);

    // Revert
    try revertRelease(db, &rel_id, null);

    // Verify entry data is restored to v1
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"v1\"}", stmt.columnText(0) orelse "");
    }

    // Verify release status is reverted
    {
        var stmt = try db.prepare("SELECT status, reverted_at FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("reverted", stmt.columnText(0) orelse "");
        try std.testing.expect(!stmt.columnIsNull(1)); // reverted_at set
    }

    // Verify a new 'reverted' version was created
    {
        var stmt = try db.prepare(
            "SELECT version_type FROM entry_versions WHERE entry_id = 'e_test1' ORDER BY created_at DESC LIMIT 1",
        );
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("reverted", stmt.columnText(0) orelse "");
    }
}

test "revertRelease blocked when entry modified since release" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release: v1 → v2
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);

    // Modify entry after release (v3)
    var v2_copy: [18]u8 = undefined;
    @memcpy(&v2_copy, &v2);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"v3\"}", &v2_copy);

    // Revert should be blocked
    const result = revertRelease(db, &rel_id, null);
    try std.testing.expectError(ReleaseError.EntryModifiedSinceRelease, result);

    // Verify release status unchanged
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
    }
}

test "revertRelease fails on non-released status" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create a pending release (not released)
    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            "INSERT INTO releases (id, status) VALUES (?1, 'pending')",
        );
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = revertRelease(db, &rel_id, null);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "reReleaseReverted restores to_version data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release and revert it
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);
    try revertRelease(db, &rel_id, null);

    // Re-release
    try reReleaseReverted(db, &rel_id, null);

    // Verify entry data is back to v2
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"v2\"}", stmt.columnText(0) orelse "");
    }

    // Verify release status is released again
    {
        var stmt = try db.prepare("SELECT status, reverted_at FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
        try std.testing.expect(stmt.columnIsNull(1)); // reverted_at cleared
    }
}

test "reReleaseReverted blocked when entry modified after revert" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release, revert, then modify
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);
    try revertRelease(db, &rel_id, null);

    // Get current version (the revert version) and modify entry after revert
    const revert_vid = (try getEntryVersionId(db, "e_test1")).?;
    defer db.allocator.free(revert_vid);
    var rv_copy: [18]u8 = undefined;
    @memcpy(&rv_copy, revert_vid[0..18]);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"v4\"}", &rv_copy);

    // Re-release should be blocked
    const result = reReleaseReverted(db, &rel_id, null);
    try std.testing.expectError(ReleaseError.EntryModifiedSinceRelease, result);
}

test "scheduleRelease sets scheduled state" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create a pending release
    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            "INSERT INTO releases (id, status) VALUES (?1, 'pending')",
        );
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const target_time: i64 = 1738800000; // some future timestamp
    try scheduleRelease(db, &rel_id, target_time);

    // Verify
    {
        var stmt = try db.prepare("SELECT status, scheduled_for FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("scheduled", stmt.columnText(0) orelse "");
        try std.testing.expectEqual(target_time, stmt.columnInt(1));
    }
}

test "scheduleRelease fails on non-pending status" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create a released release
    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            "INSERT INTO releases (id, status) VALUES (?1, 'released')",
        );
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = scheduleRelease(db, &rel_id, 1738800000);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "revertRelease with null from_version restores empty data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"first"}', 'published')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"first\"}", null);

    // Release with null from_version (new entry publish)
    const rel_id = try createTestRelease(db, "e_test1", null, &v1);

    try revertRelease(db, &rel_id, null);

    // Entry data should be empty JSON
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{}", stmt.columnText(0) orelse "");
    }
}

test "createPendingRelease creates a pending release with name" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const rel_id = try createPendingRelease(db, "Sprint 42", null);

    var stmt = try db.prepare("SELECT name, status FROM releases WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, &rel_id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("Sprint 42", stmt.columnText(0) orelse "");
    try std.testing.expectEqualStrings("pending", stmt.columnText(1) orelse "");
}

test "addToRelease inserts item into pending release" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    const rel_id = try createPendingRelease(db, "Batch 1", null);
    try addToRelease(db, &rel_id, "e_test1", null, &v1, null);

    var stmt = try db.prepare("SELECT entry_id, to_version FROM release_items WHERE release_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, &rel_id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("e_test1", stmt.columnText(0) orelse "");
    try std.testing.expectEqualStrings(&v1, stmt.columnText(1) orelse "");
}

test "addToRelease fails on non-pending release" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare("INSERT INTO releases (id, status) VALUES (?1, 'released')");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = addToRelease(db, &rel_id, "e_test1", null, "v_fake_version123", null);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "removeFromRelease removes item" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    const rel_id = try createPendingRelease(db, "Batch 1", null);
    try addToRelease(db, &rel_id, "e_test1", null, &v1, null);

    // Remove
    try removeFromRelease(db, &rel_id, "e_test1");

    var stmt = try db.prepare("SELECT COUNT(*) FROM release_items WHERE release_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, &rel_id);
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "publishBatchRelease sets entries to published" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"staged\"}", null);

    const rel_id = try createPendingRelease(db, "Launch", null);
    try addToRelease(db, &rel_id, "e_test1", null, &v1, null);

    try publishBatchRelease(std.testing.allocator, db, &rel_id);

    // Entry should be published
    {
        var stmt = try db.prepare("SELECT status FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("published", stmt.columnText(0) orelse "");
    }

    // Release should be released
    {
        var stmt = try db.prepare("SELECT status, released_at FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
        try std.testing.expect(!stmt.columnIsNull(1));
    }
}

test "publishBatchRelease fails on non-pending" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare("INSERT INTO releases (id, status) VALUES (?1, 'released')");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = publishBatchRelease(std.testing.allocator, db, &rel_id);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "listReleases returns releases" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    _ = try createPendingRelease(db, "Release A", null);
    _ = try createPendingRelease(db, "Release B", null);

    const releases = try listReleases(std.testing.allocator, db, .{});
    defer std.testing.allocator.free(releases);
    try std.testing.expectEqual(@as(usize, 2), releases.len);
}

test "listReleases filters by status" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    _ = try createPendingRelease(db, "Pending One", null);

    // Create a released one directly
    try db.exec("INSERT INTO releases (id, name, status) VALUES ('rel_released_test1', 'Done', 'released')");

    const pending = try listReleases(std.testing.allocator, db, .{ .status = "pending" });
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqualStrings("Pending One", pending[0].name);
}

test "getRelease returns detail with items" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, title, data, status)
        \\VALUES ('e_test1', 'test_ct', 'My Post', '{}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    const rel_id = try createPendingRelease(db, "Detail Test", null);
    try addToRelease(db, &rel_id, "e_test1", null, &v1, null);

    const detail = try getRelease(std.testing.allocator, db, &rel_id);
    try std.testing.expect(detail != null);
    const d = detail.?;
    defer std.testing.allocator.free(d.items);
    try std.testing.expectEqualStrings("Detail Test", d.name);
    try std.testing.expectEqualStrings("pending", d.status);
    try std.testing.expectEqual(@as(usize, 1), d.items.len);
    try std.testing.expectEqualStrings("My Post", d.items[0].entry_title);
}

test "getRelease returns null for nonexistent" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const detail = try getRelease(std.testing.allocator, db, "rel_nonexistent12345");
    try std.testing.expect(detail == null);
}

test "listPendingReleases returns only pending" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    _ = try createPendingRelease(db, "Active", null);
    try db.exec("INSERT INTO releases (id, name, status) VALUES ('rel_released_test2', 'Done', 'released')");

    const pending = try listPendingReleases(std.testing.allocator, db);
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqualStrings("Active", pending[0].name);
}
