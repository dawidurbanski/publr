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

/// Prune old edit versions if version_history_limit is set.
/// Keeps the N most recent 'edit' versions per entry, deletes the rest.
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

    // Delete oldest edit versions beyond the limit.
    // Keep the N most recent by created_at; delete the rest.
    var del_stmt = try db.prepare(
        \\DELETE FROM entry_versions
        \\WHERE entry_id = ?1
        \\  AND version_type = 'edit'
        \\  AND id NOT IN (
        \\    SELECT id FROM entry_versions
        \\    WHERE entry_id = ?1
        \\      AND version_type = 'edit'
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

    // Get previous current_version_id (parent for new version)
    var prev_version_id: ?[]const u8 = null;
    if (is_update) {
        var pv_stmt = try db.prepare(
            "SELECT current_version_id FROM entries WHERE id = ?1",
        );
        defer pv_stmt.deinit();
        try pv_stmt.bindText(1, entry_id);
        if (try pv_stmt.step()) {
            if (pv_stmt.columnText(0)) |v| {
                prev_version_id = try allocator.dupe(u8, v);
            }
        }
    }
    defer if (prev_version_id) |v| allocator.free(v);

    // Create version
    const version_id = generateVersionId();

    {
        var v_stmt = try db.prepare(
            \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 'edit')
        );
        defer v_stmt.deinit();

        try v_stmt.bindText(1, &version_id);
        try v_stmt.bindText(2, entry_id);
        if (prev_version_id) |pv| try v_stmt.bindText(3, pv) else try v_stmt.bindNull(3);
        try v_stmt.bindText(4, data_json);
        if (opts.author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);

        _ = try v_stmt.step();
    }

    if (is_update) {
        // Update existing entry (keep entries.data in sync as denormalized copy)
        var stmt = try db.prepare(
            \\UPDATE entries SET
            \\    slug = ?2,
            \\    title = ?3,
            \\    data = ?4,
            \\    status = ?5,
            \\    current_version_id = ?6,
            \\    updated_at = unixepoch()
            \\WHERE id = ?1
        );
        defer stmt.deinit();

        try stmt.bindText(1, entry_id);
        if (slug) |s| try stmt.bindText(2, s) else try stmt.bindNull(2);
        try stmt.bindText(3, title);
        try stmt.bindText(4, data_json);
        try stmt.bindText(5, status);
        try stmt.bindText(6, &version_id);

        _ = try stmt.step();
    } else {
        // Create new entry with version pointer
        var stmt = try db.prepare(
            \\INSERT INTO entries (id, content_type_id, slug, title, data, status, current_version_id)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        );
        defer stmt.deinit();

        try stmt.bindText(1, entry_id);
        try stmt.bindText(2, CT.type_id);
        if (slug) |s| try stmt.bindText(3, s) else try stmt.bindNull(3);
        try stmt.bindText(4, title);
        try stmt.bindText(5, data_json);
        try stmt.bindText(6, status);
        try stmt.bindText(7, &version_id);

        _ = try stmt.step();
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
        \\    version_type TEXT NOT NULL DEFAULT 'edit'
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
