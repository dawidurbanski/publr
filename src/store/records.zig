const std = @import("std");
const ids = @import("../lib/id.zig");
const db = @import("../lib/db.zig");
const field = @import("../model/field.zig");

pub const id_len = ids.len;
pub const list_max: u32 = 200;
pub const statuses_filter_max: u32 = 64;
pub const document_bytes_max: u32 = 8 << 20;
pub const search_len_max: u32 = 256;

pub const Error = db.Error || error{ NotFound, Conflict };

/// One row of `records`, with what every reader wants next to it: the type's handle,
/// and the record's live title and slug (from the type's `title_field` and its slug
/// field, found in the type definition by SQLite's JSON functions). Field order is the
/// column order of `select_record`: the struct is what `Statement.read` fills.
pub const Record = struct {
    id: []const u8,
    type_id: []const u8,
    type: []const u8,
    status: []const u8,
    changed: bool,
    version: i64,
    title: []const u8,
    slug: ?[]const u8,
    created_by: ?[]const u8,
    updated_by: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

pub const Insert = struct {
    type_id: []const u8,
    created_by: ?[]const u8,
    status: []const u8,
};

pub const Order = enum { updated_desc, created_desc, title_asc };

pub const Filter = struct {
    field: []const u8,
    text: ?[]const u8 = null,
    int: ?i64 = null,
    real: ?f64 = null,
    ref: ?[]const u8 = null,
};

pub const Query = struct {
    type_id: []const u8,
    statuses: ?[]const []const u8 = null,
    changed: ?bool = null,
    search: ?[]const u8 = null,
    filter: ?Filter = null,
    order: Order = .updated_desc,
    limit: u32 = 50,
    offset: u32 = 0,
};

pub const new_id = ids.random;

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    row: Insert,
    now_ms: i64,
) Error![]const u8 {
    std.debug.assert(row.type_id.len > 0);
    std.debug.assert(row.status.len > 0);

    var id_buffer: [id_len]u8 = undefined;
    const id = arena.dupe(u8, new_id(io, &id_buffer)) catch return error.OutOfMemory;

    var statement = try connection.prepare(
        "INSERT INTO records (id, type_id, created_by, updated_by, status, changed, version, " ++
            "created_at, updated_at) VALUES (?1, ?2, ?3, ?3, ?4, 0, 1, ?5, ?5)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, row.type_id);
    try statement.bind_optional_text(3, row.created_by);
    try statement.bind_text(4, row.status);
    try statement.bind_int(5, now_ms);
    try statement.exec();

    return id;
}

/// The columns of a Record, in `read_record` order, from `records r` joined with its type
/// `t` and its live title `title` and slug `slug` values.
const select_record = "SELECT r.id, r.type_id, t.handle, r.status, r.changed, r.version, " ++
    "title.value, slug.value, r.created_by, r.updated_by, r.created_at, r.updated_at " ++
    "FROM records r JOIN content_types t ON t.id = r.type_id " ++
    "LEFT JOIN record_values title ON title.record = r.id AND title.slot = 'live' " ++
    "AND title.ordinal = 0 AND title.field = json_extract(t.definition, '$.title_field') " ++
    "LEFT JOIN record_values slug ON slug.record = r.id AND slug.slot = 'live' " ++
    "AND slug.ordinal = 0 AND slug.field = (SELECT f.value ->> 'name' " ++
    "FROM json_each(t.definition, '$.fields') f WHERE f.value ->> 'kind' = 'slug' LIMIT 1)";

pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?Record {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    var select = try connection.prepare(select_record ++ " WHERE r.id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Record, arena);
}

/// Bump the version after a document write and record whether edits are parked.
pub fn save(
    connection: *db.Db,
    id: []const u8,
    updated_by: ?[]const u8,
    expected_version: ?i64,
    now_ms: i64,
    changed: bool,
) Error!i64 {
    std.debug.assert(id.len > 0);
    std.debug.assert(now_ms >= 0);

    const current = try current_version(connection, id);

    if (expected_version) |expected| {
        if (expected != current) {
            return error.Conflict;
        }
    }

    var statement = try connection.prepare(
        "UPDATE records SET version = version + 1, updated_at = ?2, updated_by = ?3, " ++
            "changed = ?4 WHERE id = ?1",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_int(2, now_ms);
    try statement.bind_optional_text(3, updated_by);
    try statement.bind_int(4, @intFromBool(changed));
    try statement.exec();

    std.debug.assert(connection.changes() == 1);

    return current + 1;
}

pub fn set_status(
    connection: *db.Db,
    id: []const u8,
    status: []const u8,
    expected_version: ?i64,
    now_ms: i64,
    updated_by: ?[]const u8,
    changed: bool,
) Error!i64 {
    std.debug.assert(id.len > 0);
    std.debug.assert(status.len > 0);

    const current = try current_version(connection, id);

    if (expected_version) |expected| {
        if (expected != current) {
            return error.Conflict;
        }
    }

    var statement = try connection.prepare(
        "UPDATE records SET status = ?2, version = version + 1, updated_at = ?3, " ++
            "updated_by = ?4, changed = ?5 WHERE id = ?1",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, status);
    try statement.bind_int(3, now_ms);
    try statement.bind_optional_text(4, updated_by);
    try statement.bind_int(5, @intFromBool(changed));
    try statement.exec();

    return current + 1;
}

fn current_version(connection: *db.Db, id: []const u8) Error!i64 {
    std.debug.assert(id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT version FROM records WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return error.NotFound;
    }

    return select.read_int();
}

pub fn delete(connection: *db.Db, id: []const u8) Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    const statements = [_][:0]const u8{
        "DELETE FROM record_search WHERE record = ?1",
        "DELETE FROM records WHERE id = ?1",
    };
    var removed = false;

    inline for (statements) |sql| {
        var statement = try connection.prepare(sql);
        defer statement.finalize();

        try statement.bind_text(1, id);
        try statement.exec();
        removed = connection.changes() > 0;
    }

    return removed;
}

/// Give a record another id (tests and examples want known ids): every table that names it.
pub fn rename(connection: *db.Db, from: []const u8, to: []const u8) Error!void {
    std.debug.assert(from.len == id_len);
    std.debug.assert(to.len == id_len);

    try connection.exec("PRAGMA foreign_keys = OFF");
    defer connection.exec("PRAGMA foreign_keys = ON") catch unreachable;

    const statements = [_][:0]const u8{
        "UPDATE records SET id = ?1 WHERE id = ?2",
        "UPDATE snapshots SET record = ?1 WHERE record = ?2",
        "UPDATE record_values SET record = ?1 WHERE record = ?2",
        "UPDATE record_search SET record = ?1 WHERE record = ?2",
    };

    inline for (statements) |sql| {
        var statement = try connection.prepare(sql);
        defer statement.finalize();

        try statement.bind_text(1, to);
        try statement.bind_text(2, from);
        try statement.exec();
    }
}

pub fn count_by_type(connection: *db.Db, type_id: []const u8) Error!u32 {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*) FROM records WHERE type_id = ?1");
    defer select.finalize();

    try select.bind_text(1, type_id);

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// The one query composed at runtime: which clauses it has, and how many `?N` the
/// status filter takes, depend on the query. `build_list_sql` writes only literals and
/// placeholder numbers; every value still goes through `bind_query`.
pub fn list(connection: *db.Db, arena: std.mem.Allocator, query: Query) Error![]Record {
    std.debug.assert(query.type_id.len > 0);
    std.debug.assert(query.limit <= list_max);

    const text = try build_list_sql(arena, query);
    var select = try connection.prepare_dynamic(text);
    defer select.finalize();

    try bind_query(&select, query);

    var records: std.ArrayList(Record) = .empty;

    while (try select.step()) {
        std.debug.assert(records.items.len < list_max);
        records.append(arena, try select.read(Record, arena)) catch return error.OutOfMemory;
    }

    return records.items;
}

const list_select = select_record ++ " WHERE r.type_id = ?1";
const list_filter = " AND EXISTS (SELECT 1 FROM record_values v WHERE v.record = r.id " ++
    "AND v.type_id = ?1 AND v.field = ?{d} AND v.value = ?{d} AND v.slot = 'live' " ++
    "AND v.kind <> 'long')";
const list_search = " AND r.id IN (SELECT record FROM record_search " ++
    "WHERE record_search MATCH ?{d} AND slot = 'live')";

fn build_list_sql(arena: std.mem.Allocator, query: Query) Error![]const u8 {
    std.debug.assert(query.type_id.len > 0);
    std.debug.assert(query.limit <= list_max);

    var sql: std.Io.Writer.Allocating = .init(arena);
    const writer = &sql.writer;
    var bind_index: u32 = 2;

    writer.writeAll(list_select) catch return error.OutOfMemory;

    if (query.statuses) |statuses| {
        std.debug.assert(statuses.len <= statuses_filter_max);
        writer.writeAll(" AND r.status IN (") catch return error.OutOfMemory;

        for (statuses, 0..) |_, index| {
            const separator = if (index == 0) "" else ", ";
            writer.print("{s}?{d}", .{ separator, bind_index }) catch return error.OutOfMemory;
            bind_index += 1;
        }

        writer.writeAll(")") catch return error.OutOfMemory;
    }

    if (query.changed) |changed| {
        const clause: []const u8 = if (changed) " AND r.changed = 1" else " AND r.changed = 0";
        writer.writeAll(clause) catch return error.OutOfMemory;
    }

    if (query.filter != null) {
        const args = .{ bind_index, bind_index + 1 };
        writer.print(list_filter, args) catch return error.OutOfMemory;
        bind_index += 2;
    }

    if (query.search != null) {
        writer.print(list_search, .{bind_index}) catch return error.OutOfMemory;
        bind_index += 1;
    }

    const order: []const u8 = switch (query.order) {
        .updated_desc => " ORDER BY r.updated_at DESC, r.id",
        .created_desc => " ORDER BY r.created_at DESC, r.id",
        .title_asc => " ORDER BY title.value, r.id",
    };
    const limit = @min(query.limit, list_max);
    writer.print("{s} LIMIT {d} OFFSET {d}", .{ order, limit, query.offset }) catch {
        return error.OutOfMemory;
    };

    return sql.toOwnedSlice() catch return error.OutOfMemory;
}

fn bind_query(select: *db.Statement, query: Query) Error!void {
    std.debug.assert(query.type_id.len > 0);
    std.debug.assert(query.limit <= list_max);

    var bind_index: u31 = 2;

    try select.bind_text(1, query.type_id);

    if (query.statuses) |statuses| {
        for (statuses) |status| {
            try select.bind_text(bind_index, status);
            bind_index += 1;
        }
    }

    if (query.filter) |filter| {
        try select.bind_text(bind_index, filter.field);

        if (filter.text) |text| {
            try select.bind_text(bind_index + 1, text);
        } else if (filter.real) |real| {
            try select.bind_real(bind_index + 1, real);
        } else if (filter.ref) |ref| {
            try select.bind_text(bind_index + 1, ref);
        } else {
            try select.bind_int(bind_index + 1, filter.int orelse 0);
        }

        bind_index += 2;
    }

    if (query.search) |search| {
        try select.bind_text(bind_index, search);
        bind_index += 1;
    }
}

const content_type = @import("content_types.zig");
const model_content_type = @import("../model/content_type.zig");

fn seed_type(fixture: *db.testing.Fixture, arena: std.mem.Allocator) ![]const u8 {
    std.debug.assert(fixture.connection.transaction_depth == 0);
    std.debug.assert(model_content_type.test_post.fields.len > 0);

    return content_type.insert(&fixture.connection, arena, model_content_type.test_post, 0);
}

fn seed_record(
    fixture: *db.testing.Fixture,
    arena: std.mem.Allocator,
    type_id: []const u8,
    title: []const u8,
    status: []const u8,
    views: i64,
) ![]const u8 {
    const data = try std.fmt.allocPrint(
        arena,
        "{{\"title\":\"{s}\",\"body\":\"about {s}\",\"views\":{d}}}",
        .{ title, title, views },
    );
    const id = try insert(&fixture.connection, std.testing.io, arena, .{
        .type_id = type_id,
        .created_by = "u_1",
        .status = status,
    }, 1_000);
    const document = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
    const values = @import("values.zig");
    const fields = model_content_type.test_post.fields;

    try values.write(&fixture.connection, id, values.live, type_id, fields, document);

    return id;
}

test "insert, get, save with version check, transition, delete" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const type_id = try seed_type(&fixture, arena);
    const id = try seed_record(&fixture, arena, type_id, "Hello", "draft", 3);

    const row = (try get(connection, arena, id)).?;
    try std.testing.expectEqual(@as(i64, 1), row.version);
    try std.testing.expectEqualStrings("draft", row.status);

    const saved = try save(connection, id, "u_2", 1, 2_000, true);
    try std.testing.expectEqual(@as(i64, 2), saved);
    try std.testing.expectEqualStrings("u_2", (try get(connection, arena, id)).?.updated_by.?);
    try std.testing.expect((try get(connection, arena, id)).?.changed);
    const stale = save(connection, id, "u_2", 1, 3_000, false);
    try std.testing.expectError(error.Conflict, stale);
    const missing = save(connection, "missing", "u_2", null, 3_000, false);
    try std.testing.expectError(error.NotFound, missing);

    const published = try set_status(connection, id, "published", null, 4_000, "u_1", false);
    try std.testing.expectEqual(@as(i64, 3), published);
    try std.testing.expectEqualStrings("published", (try get(connection, arena, id)).?.status);
    try std.testing.expect(!(try get(connection, arena, id)).?.changed);
    try std.testing.expect(try delete(connection, id));
    try std.testing.expect((try get(connection, arena, id)) == null);
    try std.testing.expectEqual(
        @as(usize, 0),
        (try @import("values.zig").read(connection, arena, id, "live")).len,
    );
}

test "list: by status, filter on a field value, full-text search, order and paging" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const type_id = try seed_type(&fixture, arena);

    _ = try seed_record(&fixture, arena, type_id, "Alpha", "published", 10);
    _ = try seed_record(&fixture, arena, type_id, "Beta", "draft", 20);
    _ = try seed_record(&fixture, arena, type_id, "Gamma", "published", 20);

    const all = try list(connection, arena, .{ .type_id = type_id, .order = .title_asc });
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("Alpha", all[0].title);

    const live = try list(
        connection,
        arena,
        .{ .type_id = type_id, .statuses = &.{"published"}, .order = .title_asc },
    );
    try std.testing.expectEqual(@as(usize, 2), live.len);

    const twenty = try list(
        connection,
        arena,
        .{ .type_id = type_id, .filter = .{ .field = "views", .int = 20 }, .order = .title_asc },
    );
    try std.testing.expectEqual(@as(usize, 2), twenty.len);
    try std.testing.expectEqualStrings("Beta", twenty[0].title);

    const found = try list(connection, arena, .{ .type_id = type_id, .search = "gamma" });
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Gamma", found[0].title);

    const page = try list(
        connection,
        arena,
        .{ .type_id = type_id, .order = .title_asc, .limit = 2, .offset = 2 },
    );
    try std.testing.expectEqual(@as(usize, 1), page.len);
    try std.testing.expectEqualStrings("Gamma", page[0].title);
}
