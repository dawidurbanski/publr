//! Entry Query API
//!
//! Generic query building, filtering, and entry retrieval. Provides typed
//! entry access, list operations with meta-field filtering, and count queries.
//!
//! Example:
//! ```zig
//! const schemas = @import("schemas");
//! const query = @import("query");
//!
//! // Get a post by slug
//! const post = try query.getEntry(schemas.Post, allocator, db, "hello-world");
//!
//! // List published posts
//! const posts = try query.listEntries(schemas.Post, allocator, db, .{
//!     .status = "published",
//!     .limit = 10,
//! });
//! ```

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;

const Allocator = std.mem.Allocator;

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
    /// Filter to specific entry IDs (e.g., from author filter)
    entry_ids: ?[]const []const u8 = null,
};

/// Get a single entry by ID or slug
pub fn getEntry(
    comptime CT: type,
    allocator: Allocator,
    db: *Db,
    id_or_slug: []const u8,
) !?Entry(CT) {
    const locale = defaultLocaleFor(CT);
    var stmt = try db.prepare(
        \\SELECT a.id,
        \\       json_extract(cv.data_json, '$.slug') AS slug,
        \\       COALESCE(json_extract(cv.data_json, '$.title'), '') AS title,
        \\       cv.data_json AS data,
        \\       CASE
        \\         WHEN ce.archived = 1 THEN 'archived'
        \\         WHEN ce.published_version_id IS NULL THEN 'draft'
        \\         WHEN ce.published_version_id = ce.current_version_id THEN 'published'
        \\         ELSE 'changed'
        \\       END AS status,
        \\       CAST(json_extract(pv.data_json, '$.published_at') AS INTEGER) AS published_at,
        \\       ce.created_at,
        \\       ce.updated_at
        \\FROM content_anchors a
        \\JOIN content_entries ce ON ce.anchor_id = a.id AND ce.locale = ?1
        \\JOIN content_versions cv ON cv.id = ce.current_version_id
        \\LEFT JOIN content_versions pv ON pv.id = ce.published_version_id
        \\WHERE a.content_type = ?2
        \\  AND (a.id = ?3 OR json_extract(cv.data_json, '$.slug') = ?3)
        \\LIMIT 1
    );
    defer stmt.deinit();

    try stmt.bindText(1, locale);
    try stmt.bindText(2, CT.type_id);
    try stmt.bindText(3, id_or_slug);

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
    if (opts.meta_filters.len > max_meta_filters) return error.TooManyFilters;

    const locale = defaultLocaleFor(CT);
    var sql: std.ArrayList(u8) = .{};
    defer sql.deinit(allocator);
    const w = sql.writer(allocator);

    try w.writeAll(
        \\SELECT a.id,
        \\       json_extract(cv.data_json, '$.slug') AS slug,
        \\       COALESCE(json_extract(cv.data_json, '$.title'), '') AS title,
        \\       cv.data_json AS data,
        \\       CASE
        \\         WHEN ce.archived = 1 THEN 'archived'
        \\         WHEN ce.published_version_id IS NULL THEN 'draft'
        \\         WHEN ce.published_version_id = ce.current_version_id THEN 'published'
        \\         ELSE 'changed'
        \\       END AS status,
        \\       CAST(json_extract(pv.data_json, '$.published_at') AS INTEGER) AS published_at,
        \\       ce.created_at,
        \\       ce.updated_at
        \\FROM content_anchors a
        \\JOIN content_entries ce ON ce.anchor_id = a.id AND ce.locale = ?1
        \\JOIN content_versions cv ON cv.id = ce.current_version_id
        \\LEFT JOIN content_versions pv ON pv.id = ce.published_version_id
    );

    var bind_idx: u32 = 3; // 1 locale, 2 content_type
    for (opts.meta_filters, 0..) |_, i| {
        try w.print(
            " JOIN content_meta m{} ON m{}.entry_id = ce.id AND m{}.version_id = ce.current_version_id AND m{}.field_name = ?{}",
            .{ i, i, i, i, bind_idx },
        );
        bind_idx += 1;
    }

    try w.writeAll(" WHERE a.content_type = ?2");

    if (opts.status) |status| {
        try appendUnifiedStatusFilter(w, status);
    }

    const entry_ids_bind_start = bind_idx;
    if (opts.entry_ids) |ids| {
        if (ids.len > 0) {
            try w.writeAll(" AND a.id IN (");
            for (ids, 0..) |_, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("?{d}", .{bind_idx});
                bind_idx += 1;
            }
            try w.writeByte(')');
        } else {
            try w.writeAll(" AND 1=0");
        }
    }

    var meta_value_bind_indices: [max_meta_filters]u32 = undefined;
    for (opts.meta_filters, 0..) |mf, i| {
        switch (mf.value) {
            .text => try w.print(" AND m{}.{s} {s} ?{}", .{ i, "value", mf.op.toSql(), bind_idx }),
            .int, .real => try w.print(" AND CAST(m{}.value AS REAL) {s} ?{}", .{ i, mf.op.toSql(), bind_idx }),
        }
        meta_value_bind_indices[i] = bind_idx;
        bind_idx += 1;
    }

    const order_expr = if (std.mem.eql(u8, opts.order_by, "updated_at"))
        "ce.updated_at"
    else if (std.mem.eql(u8, opts.order_by, "title"))
        "title"
    else if (std.mem.eql(u8, opts.order_by, "status"))
        "status"
    else
        "ce.created_at";

    try w.print(" ORDER BY {s} {s}", .{
        order_expr,
        if (opts.order_dir == .asc) "ASC" else "DESC",
    });

    if (opts.limit) |limit| {
        try w.print(" LIMIT {d}", .{limit});
    }
    if (opts.offset) |offset| {
        try w.print(" OFFSET {d}", .{offset});
    }

    const sql_slice = try sql.toOwnedSlice(allocator);
    defer allocator.free(sql_slice);

    var stmt = try db.prepare(sql_slice);
    defer stmt.deinit();
    try stmt.bindText(1, locale);
    try stmt.bindText(2, CT.type_id);

    var key_bind: u32 = 3;
    for (opts.meta_filters) |mf| {
        try stmt.bindText(key_bind, mf.key);
        key_bind += 1;
    }

    if (opts.entry_ids) |ids| {
        for (ids, 0..) |eid, i| {
            try stmt.bindText(entry_ids_bind_start + @as(u32, @intCast(i)), eid);
        }
    }

    for (opts.meta_filters, 0..) |mf, i| {
        switch (mf.value) {
            .text => |v| try stmt.bindText(meta_value_bind_indices[i], v),
            .int => |v| try stmt.bindInt(meta_value_bind_indices[i], v),
            .real => |_| try stmt.bindNull(meta_value_bind_indices[i]), // TODO: bindReal in db wrapper
        }
    }

    var items: std.ArrayListUnmanaged(Entry(CT)) = .{};
    errdefer items.deinit(allocator);
    while (try stmt.step()) {
        try items.append(allocator, try parseEntryRow(CT, allocator, &stmt));
    }
    return items.toOwnedSlice(allocator);
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
        entry_ids: ?[]const []const u8 = null,
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

    // Entry ID filter (e.g., from author filtering)
    const entry_ids_bind_start = bind_idx;
    if (config.entry_ids) |ids| {
        if (ids.len > 0) {
            try w.writeAll(" AND t.id IN (");
            for (ids, 0..) |_, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("?{d}", .{bind_idx});
                bind_idx += 1;
            }
            try w.writeByte(')');
        } else {
            // Empty ID list = no results
            try w.writeAll(" AND 1=0");
        }
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

    // Bind entry IDs
    if (config.entry_ids) |ids| {
        for (ids, 0..) |eid, i| {
            try stmt.bindText(entry_ids_bind_start + @as(u32, @intCast(i)), eid);
        }
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

/// Count entries by content type
pub fn countEntries(comptime CT: type, db: *Db, opts: struct {
    status: ?[]const u8 = null,
}) !u32 {
    const locale = defaultLocaleFor(CT);
    var sql: std.ArrayList(u8) = .{};
    defer sql.deinit(db.allocator);
    const w = sql.writer(db.allocator);

    try w.writeAll(
        \\SELECT COUNT(*)
        \\FROM content_anchors a
        \\JOIN content_entries ce ON ce.anchor_id = a.id AND ce.locale = ?1
        \\WHERE a.content_type = ?2
    );
    if (opts.status) |status| {
        try appendUnifiedStatusFilter(w, status);
    }

    const sql_slice = try sql.toOwnedSlice(db.allocator);
    defer db.allocator.free(sql_slice);

    var stmt = try db.prepare(sql_slice);
    defer stmt.deinit();

    try stmt.bindText(1, locale);
    try stmt.bindText(2, CT.type_id);

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

fn appendUnifiedStatusFilter(w: anytype, status: []const u8) !void {
    if (std.mem.eql(u8, status, "archived")) {
        try w.writeAll(" AND ce.archived = 1");
    } else if (std.mem.eql(u8, status, "draft")) {
        try w.writeAll(" AND ce.archived = 0 AND ce.published_version_id IS NULL");
    } else if (std.mem.eql(u8, status, "published")) {
        try w.writeAll(" AND ce.archived = 0 AND ce.published_version_id IS NOT NULL AND ce.published_version_id = ce.current_version_id");
    } else if (std.mem.eql(u8, status, "changed")) {
        try w.writeAll(" AND ce.archived = 0 AND ce.published_version_id IS NOT NULL AND ce.published_version_id != ce.current_version_id");
    }
}

fn defaultLocaleFor(comptime CT: type) []const u8 {
    if (@hasDecl(CT, "available_locales") and CT.available_locales.len > 0) {
        return CT.available_locales[0];
    }
    return "en";
}

test "core query: public API coverage" {
    _ = Entry;
    _ = getEntry;
    _ = listEntries;
    _ = listWithMeta;
    _ = countEntries;
}
