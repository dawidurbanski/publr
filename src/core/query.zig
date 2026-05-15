//! Entry Query API
//!
//! Runtime-keyed query building, filtering, and entry retrieval. All entry
//! reads return the generic `Entry` value (promoted columns + `FieldMap`).
//!
//! Example:
//! ```zig
//! const query = @import("query");
//!
//! // Get a post by slug or id
//! const post = try query.getEntry(allocator, db, "post", "hello-world");
//!
//! // List published posts
//! const posts = try query.listEntries(allocator, db, "post", .{
//!     .status = "published",
//!     .limit = 10,
//! });
//! ```

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;
const entry_mod = @import("entry");
const schema_registry = @import("schema_registry");

const Allocator = std.mem.Allocator;

/// Generic content entry value — same shape regardless of how the content
/// type was registered (compile-in, WASM, or DB-defined).
pub const Entry = entry_mod.Entry;
pub const FieldMap = entry_mod.FieldMap;
pub const FieldValue = entry_mod.FieldValue;

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

/// Options for listing entries.
pub const ListOptions = struct {
    status: ?[]const u8 = null,
    limit: ?u32 = null,
    offset: ?u32 = null,
    order_by: []const u8 = "created_at",
    order_dir: OrderDir = .desc,
    meta_filters: []const MetaFilter = &.{},
    entry_ids: ?[]const []const u8 = null,
    /// FTS5 MATCH expression. Routes through `entries_fts` to restrict
    /// the result set to entries whose searchable fields match.
    search: ?[]const u8 = null,
};

/// Get a single entry by ID or slug, runtime-keyed by content type.
/// Routes compile-in types to a specialized parse path; others fall
/// through to the generic dynamic-JSON path. Both return the same shape.
pub fn getEntry(
    allocator: Allocator,
    db: *Db,
    type_id: []const u8,
    id_or_slug: []const u8,
) !?Entry {
    inline for (schema_registry.compiled_in_types) |comptime_ct| {
        if (std.mem.eql(u8, comptime_ct.type_id, type_id)) {
            return getEntrySpecialized(allocator, db, comptime_ct, id_or_slug);
        }
    }
    return getEntryGeneric(allocator, db, type_id, id_or_slug);
}

const get_entry_sql =
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
    \\       ce.updated_at,
    \\       cv.author_id
    \\FROM content_anchors a
    \\JOIN content_entries ce ON ce.anchor_id = a.id AND ce.locale = ?1
    \\JOIN content_versions cv ON cv.id = ce.current_version_id
    \\LEFT JOIN content_versions pv ON pv.id = ce.published_version_id
    \\WHERE a.content_type = ?2
    \\  AND (a.id = ?3 OR json_extract(cv.data_json, '$.slug') = ?3)
    \\LIMIT 1
;

pub fn getEntryGeneric(
    allocator: Allocator,
    db: *Db,
    type_id: []const u8,
    id_or_slug: []const u8,
) !?Entry {
    var stmt = try db.prepare(get_entry_sql);
    defer stmt.deinit();
    try stmt.bindText(1, "en");
    try stmt.bindText(2, type_id);
    try stmt.bindText(3, id_or_slug);

    if (!try stmt.step()) return null;
    return try parseEntryRow(allocator, type_id, &stmt);
}

pub fn getEntrySpecialized(
    allocator: Allocator,
    db: *Db,
    comptime def: @import("content_type").ContentTypeDef,
    id_or_slug: []const u8,
) !?Entry {
    const Data = comptime def.zigStructForData();
    var stmt = try db.prepare(get_entry_sql);
    defer stmt.deinit();
    try stmt.bindText(1, "en");
    try stmt.bindText(2, def.type_id);
    try stmt.bindText(3, id_or_slug);

    if (!try stmt.step()) return null;
    return try parseEntryRowSpecialized(allocator, def, Data, &stmt);
}

/// List entries by content type — dispatcher.
///
/// For compile-in content types (those in `registry.compiled_in_types`)
/// routes to `listEntriesSpecialized`, which uses comptime-generated
/// JSON-parse for the data column. For WASM-loaded or DB-defined types
/// (not in the compile-in slice) falls through to `listEntriesGeneric`.
/// Both paths return identical `[]Entry`.
pub fn listEntries(
    allocator: Allocator,
    db: *Db,
    type_id: []const u8,
    opts: ListOptions,
) ![]Entry {
    inline for (schema_registry.compiled_in_types) |comptime_ct| {
        if (std.mem.eql(u8, comptime_ct.type_id, type_id)) {
            return listEntriesSpecialized(allocator, db, comptime_ct, opts);
        }
    }
    return listEntriesGeneric(allocator, db, type_id, opts);
}

/// Generic implementation — used for runtime-only content types
/// (WASM-loaded, DB-defined). Parses each row's data column via the
/// dynamic `FieldMap.fromJson` path. Exposed publicly so tests and
/// benchmarks can exercise both paths directly.
pub fn listEntriesGeneric(
    allocator: Allocator,
    db: *Db,
    type_id: []const u8,
    opts: ListOptions,
) ![]Entry {
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    var binds: ListBindIndices = undefined;
    try buildListSql(allocator, &sql_buf, opts, &binds);

    var stmt = try db.prepare(sql_buf.items);
    defer stmt.deinit();
    try bindListStatement(&stmt, type_id, opts, binds);

    var items: std.ArrayListUnmanaged(Entry) = .{};
    errdefer items.deinit(allocator);
    while (try stmt.step()) {
        try items.append(allocator, try parseEntryRow(allocator, type_id, &stmt));
    }
    return items.toOwnedSlice(allocator);
}

/// Compile-in fast path: typed JSON parse via the descriptor-generated
/// `Data` struct, then converted to `FieldMap` for uniform `Entry.data`.
/// Exposed publicly so tests and benchmarks can exercise both paths.
pub fn listEntriesSpecialized(
    allocator: Allocator,
    db: *Db,
    comptime def: @import("content_type").ContentTypeDef,
    opts: ListOptions,
) ![]Entry {
    const Data = comptime def.zigStructForData();

    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    var binds: ListBindIndices = undefined;
    try buildListSql(allocator, &sql_buf, opts, &binds);

    var stmt = try db.prepare(sql_buf.items);
    defer stmt.deinit();
    try bindListStatement(&stmt, def.type_id, opts, binds);

    var items: std.ArrayListUnmanaged(Entry) = .{};
    errdefer items.deinit(allocator);
    while (try stmt.step()) {
        try items.append(allocator, try parseEntryRowSpecialized(allocator, def, Data, &stmt));
    }
    return items.toOwnedSlice(allocator);
}

/// Bind-index bookkeeping for `listEntries`. Filled by `buildListSql`,
/// consumed by `bindListStatement`.
const ListBindIndices = struct {
    entry_ids_start: u32,
    meta_value_indices: [max_meta_filters]u32,
    search_index: u32,
    has_search: bool,
};

/// Shared SQL build for both list paths. Writes the SELECT/JOIN/WHERE/
/// ORDER/LIMIT clauses into `buf` and records bind positions into `binds`.
fn buildListSql(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    opts: ListOptions,
    binds: *ListBindIndices,
) !void {
    if (opts.meta_filters.len > max_meta_filters) return error.TooManyFilters;

    const w = buf.writer(allocator);

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
        \\       ce.updated_at,
        \\       cv.author_id
        \\FROM content_anchors a
        \\JOIN content_entries ce ON ce.anchor_id = a.id AND ce.locale = ?1
        \\JOIN content_versions cv ON cv.id = ce.current_version_id
        \\LEFT JOIN content_versions pv ON pv.id = ce.published_version_id
    );

    var bind_idx: u32 = 3;
    for (opts.meta_filters, 0..) |_, i| {
        try w.print(
            " JOIN content_meta m{} ON m{}.entry_id = ce.id AND m{}.version_id = ce.current_version_id AND m{}.field_name = ?{}",
            .{ i, i, i, i, bind_idx },
        );
        bind_idx += 1;
    }

    try w.writeAll(" WHERE a.content_type = ?2");

    if (opts.status) |status| try appendUnifiedStatusFilter(w, status);

    binds.entry_ids_start = bind_idx;
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

    for (opts.meta_filters, 0..) |mf, i| {
        switch (mf.value) {
            .text => try w.print(" AND m{}.{s} {s} ?{}", .{ i, "value", mf.op.toSql(), bind_idx }),
            .int, .real => try w.print(" AND CAST(m{}.value AS REAL) {s} ?{}", .{ i, mf.op.toSql(), bind_idx }),
        }
        binds.meta_value_indices[i] = bind_idx;
        bind_idx += 1;
    }

    binds.search_index = bind_idx;
    binds.has_search = opts.search != null;
    if (opts.search) |_| {
        try w.print(" AND a.id IN (SELECT entry_id FROM entries_fts WHERE entries_fts MATCH ?{})", .{bind_idx});
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

    if (opts.limit) |limit| try w.print(" LIMIT {d}", .{limit});
    if (opts.offset) |offset| try w.print(" OFFSET {d}", .{offset});
}

/// Shared statement binding. Binds locale (?1), type_id (?2), then any
/// meta-filter keys, entry-id list, meta values, and FTS search term.
fn bindListStatement(
    stmt: *Statement,
    type_id: []const u8,
    opts: ListOptions,
    binds: ListBindIndices,
) !void {
    try stmt.bindText(1, "en");
    try stmt.bindText(2, type_id);

    var key_bind: u32 = 3;
    for (opts.meta_filters) |mf| {
        try stmt.bindText(key_bind, mf.key);
        key_bind += 1;
    }

    if (opts.entry_ids) |ids| {
        for (ids, 0..) |eid, i| {
            try stmt.bindText(binds.entry_ids_start + @as(u32, @intCast(i)), eid);
        }
    }

    for (opts.meta_filters, 0..) |mf, i| {
        switch (mf.value) {
            .text => |v| try stmt.bindText(binds.meta_value_indices[i], v),
            .int => |v| try stmt.bindInt(binds.meta_value_indices[i], v),
            .real => |v| try stmt.bindReal(binds.meta_value_indices[i], v),
        }
    }

    if (binds.has_search) {
        if (opts.search) |term| try stmt.bindText(binds.search_index, term);
    }
}

/// Generic list query builder with MetaFilter JOIN support.
/// Used by `listMedia` and other table-keyed lists to avoid duplicating
/// query logic. (Distinct from `listEntries` above which is content-entry
/// specific.)
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

    try w.print("SELECT t.{s} FROM {s} t", .{ config.select_cols, config.table });

    var bind_idx: u32 = 1;
    for (config.meta_filters, 0..) |_, i| {
        try w.print(" JOIN {s} m{} ON m{}.{s} = t.{s} AND m{}.key = ?{}", .{
            config.meta_table, i, i, config.meta_fk, config.id_column, i, bind_idx,
        });
        bind_idx += 1;
    }

    try w.writeAll(" WHERE 1=1");

    const type_bind_idx = bind_idx;
    if (config.type_filter != null) {
        try w.print(" AND t.{s} = ?{}", .{ config.type_filter.?.column, bind_idx });
        bind_idx += 1;
    }

    const status_bind_idx = bind_idx;
    if (config.status != null) {
        try w.print(" AND t.status = ?{}", .{bind_idx});
        bind_idx += 1;
    }

    const visibility_bind_idx = bind_idx;
    if (config.visibility != null) {
        try w.print(" AND t.visibility = ?{}", .{bind_idx});
        bind_idx += 1;
    }

    const mime_bind_idx = bind_idx;
    if (config.mime_type != null) {
        try w.print(" AND t.mime_type = ?{}", .{bind_idx});
        bind_idx += 1;
    }

    const search_bind_idx = bind_idx;
    if (config.filename_search != null) {
        try w.print(" AND t.filename LIKE ?{}", .{bind_idx});
        bind_idx += 1;
    }

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
            try w.writeAll(" AND 1=0");
        }
    }

    var meta_value_bind_indices: [max_meta_filters]u32 = undefined;
    for (config.meta_filters, 0..) |mf, i| {
        try w.print(" AND m{}.{s} {s} ?{}", .{ i, mf.value.columnName(), mf.op.toSql(), bind_idx });
        meta_value_bind_indices[i] = bind_idx;
        bind_idx += 1;
    }

    try w.print(" ORDER BY t.{s} {s}", .{
        config.order_by,
        if (config.order_dir == .asc) "ASC" else "DESC",
    });

    if (config.limit) |limit| {
        try w.print(" LIMIT {}", .{limit});
    }

    if (config.offset) |offset| {
        try w.print(" OFFSET {}", .{offset});
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var key_bind: u32 = 1;
    for (config.meta_filters) |mf| {
        try stmt.bindText(key_bind, mf.key);
        key_bind += 1;
    }

    if (config.type_filter) |tf| {
        try stmt.bindText(type_bind_idx, tf.value);
    }
    if (config.status) |status| {
        try stmt.bindText(status_bind_idx, status);
    }
    if (config.visibility) |visibility| {
        try stmt.bindText(visibility_bind_idx, visibility);
    }
    if (config.mime_type) |mime| {
        try stmt.bindText(mime_bind_idx, mime);
    }
    if (config.filename_search) |search| {
        try stmt.bindText(search_bind_idx, search);
    }
    if (config.entry_ids) |ids| {
        for (ids, 0..) |eid, i| {
            try stmt.bindText(entry_ids_bind_start + @as(u32, @intCast(i)), eid);
        }
    }
    for (config.meta_filters, 0..) |mf, i| {
        switch (mf.value) {
            .text => |v| try stmt.bindText(meta_value_bind_indices[i], v),
            .int => |v| try stmt.bindInt(meta_value_bind_indices[i], v),
            .real => |_| try stmt.bindNull(meta_value_bind_indices[i]),
        }
    }

    var items: std.ArrayListUnmanaged(T) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const item = try config.parse_row(allocator, &stmt);
        try items.append(allocator, item);
    }

    return items.toOwnedSlice(allocator);
}

/// Count entries, runtime-keyed by content type.
pub fn countEntries(
    db: *Db,
    type_id: []const u8,
    opts: struct { status: ?[]const u8 = null },
) !u32 {
    var sql: std.ArrayList(u8) = .{};
    defer sql.deinit(db.allocator);
    const w = sql.writer(db.allocator);

    try w.writeAll(
        \\SELECT COUNT(*)
        \\FROM content_anchors a
        \\JOIN content_entries ce ON ce.anchor_id = a.id AND ce.locale = ?1
        \\WHERE a.content_type = ?2
    );
    if (opts.status) |status| try appendUnifiedStatusFilter(w, status);

    const sql_slice = try sql.toOwnedSlice(db.allocator);
    defer db.allocator.free(sql_slice);

    var stmt = try db.prepare(sql_slice);
    defer stmt.deinit();
    try stmt.bindText(1, "en");
    try stmt.bindText(2, type_id);

    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

fn parseEntryRow(
    allocator: Allocator,
    type_id: []const u8,
    stmt: *Statement,
) !Entry {
    const id = try allocator.dupe(u8, stmt.columnText(0) orelse "");
    const slug = if (stmt.columnText(1)) |s| try allocator.dupe(u8, s) else null;
    const title = try allocator.dupe(u8, stmt.columnText(2) orelse "");
    const data_json = stmt.columnText(3) orelse "{}";
    const status = try allocator.dupe(u8, stmt.columnText(4) orelse "draft");
    const published_at: ?i64 = if (stmt.columnIsNull(5)) null else stmt.columnInt(5);
    const created_at = stmt.columnInt(6);
    const updated_at = stmt.columnInt(7);
    const author_id = if (stmt.columnText(8)) |a| try allocator.dupe(u8, a) else null;

    const field_map = try FieldMap.fromJson(allocator, data_json);

    return .{
        .id = id,
        .content_type = try allocator.dupe(u8, type_id),
        .slug = slug,
        .title = title,
        .status = status,
        .created_at = created_at,
        .updated_at = updated_at,
        .published_at = published_at,
        .author_id = author_id,
        .data = field_map,
    };
}

/// Specialized row parser — uses a comptime-known `Data` struct to drive
/// typed JSON parsing, then materializes a `FieldMap` for uniform
/// `Entry.data` shape.
fn parseEntryRowSpecialized(
    allocator: Allocator,
    comptime def: @import("content_type").ContentTypeDef,
    comptime Data: type,
    stmt: *Statement,
) !Entry {
    const id = try allocator.dupe(u8, stmt.columnText(0) orelse "");
    const slug = if (stmt.columnText(1)) |s| try allocator.dupe(u8, s) else null;
    const title = try allocator.dupe(u8, stmt.columnText(2) orelse "");
    const data_json = stmt.columnText(3) orelse "{}";
    const status = try allocator.dupe(u8, stmt.columnText(4) orelse "draft");
    const published_at: ?i64 = if (stmt.columnIsNull(5)) null else stmt.columnInt(5);
    const created_at = stmt.columnInt(6);
    const updated_at = stmt.columnInt(7);
    const author_id = if (stmt.columnText(8)) |a| try allocator.dupe(u8, a) else null;

    // Typed parse via the comptime-generated Data struct. On parse error
    // (e.g. legacy rows with unexpected shape) fall back to the dynamic
    // FieldMap.fromJson so the caller still gets a valid Entry.
    const field_map = blk: {
        const parsed = std.json.parseFromSlice(Data, allocator, data_json, .{ .ignore_unknown_fields = true }) catch {
            break :blk try FieldMap.fromJson(allocator, data_json);
        };
        defer parsed.deinit();
        break :blk try FieldMap.fromTypedStruct(allocator, def, parsed.value);
    };

    return .{
        .id = id,
        .content_type = try allocator.dupe(u8, def.type_id),
        .slug = slug,
        .title = title,
        .status = status,
        .created_at = created_at,
        .updated_at = updated_at,
        .published_at = published_at,
        .author_id = author_id,
        .data = field_map,
    };
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

test "core query: public API coverage" {
    _ = Entry;
    _ = FieldMap;
    _ = FieldValue;
    _ = getEntry;
    _ = listEntries;
    _ = listWithMeta;
    _ = countEntries;
}
