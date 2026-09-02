//! The `content_types` table. The definition itself (fields, validation, JSON) is
//! `model/content_type.zig`.

const std = @import("std");
const db = @import("../lib/db.zig");
const content_type = @import("../model/content_type.zig");

pub const Def = content_type.Def;
pub const id_len = content_type.id_len;
pub const list_max: u32 = 500;
const encode = content_type.encode;
const decode = content_type.decode;
const id_of = content_type.id_of;
const test_post = content_type.test_post;

pub const Row = struct {
    id: []const u8,
    def: Def,
    created_at: i64,
    updated_at: i64,
};

pub const Error = db.Error || error{Invalid};

pub fn insert(
    connection: *db.Db,
    arena: std.mem.Allocator,
    def: Def,
    now_ms: i64,
) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(now_ms >= 0);

    var id_buffer: [id_len]u8 = undefined;
    const id = arena.dupe(u8, id_of(def.handle, &id_buffer)) catch return error.OutOfMemory;
    const definition = try encode(arena, def);

    var statement = try connection.prepare(
        "INSERT INTO content_types (id, handle, name, name_plural, icon, public, editor, " ++
            "editor_config, definition, created_at, updated_at, system) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?11)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try bind_def(&statement, def, definition);
    try statement.bind_int(10, now_ms);
    try statement.exec();

    return id;
}

pub fn update(
    connection: *db.Db,
    arena: std.mem.Allocator,
    id: []const u8,
    def: Def,
    now_ms: i64,
) Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(now_ms >= 0);

    const definition = try encode(arena, def);

    var statement = try connection.prepare(
        "UPDATE content_types SET handle = ?2, name = ?3, name_plural = ?4, icon = ?5, " ++
            "public = ?6, editor = ?7, editor_config = ?8, definition = ?9, updated_at = ?10, " ++
            "system = ?11 WHERE id = ?1",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try bind_def(&statement, def, definition);
    try statement.bind_int(10, now_ms);
    try statement.exec();

    return connection.changes() > 0;
}

fn bind_def(statement: *db.Statement, def: Def, definition: []const u8) db.Error!void {
    std.debug.assert(definition.len > 0);
    std.debug.assert(def.handle.len > 0);

    try statement.bind_text(2, def.handle);
    try statement.bind_text(3, def.name);
    try statement.bind_text(4, def.name_plural);
    try statement.bind_text(5, def.icon);
    try statement.bind_int(6, if (def.public) 1 else 0);
    try statement.bind_text(7, def.editor);
    try statement.bind_text(8, def.editor_config);
    try statement.bind_text(9, definition);
    try statement.bind_int(11, if (def.system) 1 else 0);
}

const select_columns = "id, definition, created_at, updated_at FROM content_types";

pub fn get_by_id(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?Row {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    var select = try connection.prepare("SELECT " ++ select_columns ++ " WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    return try read_row(&select, arena);
}

pub fn get_by_handle(connection: *db.Db, arena: std.mem.Allocator, handle: []const u8) Error!?Row {
    std.debug.assert(handle.len > 0);
    std.debug.assert(handle.len <= 128);

    var select = try connection.prepare("SELECT " ++ select_columns ++ " WHERE handle = ?1");
    defer select.finalize();

    try select.bind_text(1, handle);

    return try read_row(&select, arena);
}

pub fn list(connection: *db.Db, arena: std.mem.Allocator) Error![]Row {
    std.debug.assert(list_max > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT " ++ select_columns ++ " ORDER BY name, id LIMIT " ++
            std.fmt.comptimePrint("{d}", .{list_max}),
    );
    defer select.finalize();

    var rows: std.ArrayList(Row) = .empty;

    while (try read_row(&select, arena)) |row| {
        std.debug.assert(rows.items.len < list_max);
        try rows.append(arena, row);
    }

    return rows.items;
}

/// Deleting a type cascades to its records and values; the search index (a virtual
/// table, no cascade) is cleared here.
pub fn delete(connection: *db.Db, id: []const u8) db.Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    const statements = [_][:0]const u8{
        "DELETE FROM record_search WHERE type_id = ?1",
        "DELETE FROM snapshots WHERE record IN (SELECT id FROM records WHERE type_id = ?1)",
        "DELETE FROM content_types WHERE id = ?1",
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

/// `select_columns`, in order.
const Columns = struct {
    id: []const u8,
    definition: []const u8,
    created_at: i64,
    updated_at: i64,
};

fn read_row(select: *db.Statement, arena: std.mem.Allocator) Error!?Row {
    std.debug.assert(id_len > 0);

    if (!try select.step()) {
        return null;
    }

    const columns = try select.read(Columns, arena);

    std.debug.assert(columns.definition.len > 0);

    return .{
        .id = columns.id,
        .def = try decode(arena, columns.definition),
        .created_at = columns.created_at,
        .updated_at = columns.updated_at,
    };
}

test "insert, encode/decode round trip, get, list, update, delete" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const id = try insert(connection, arena, test_post, 1_000);
    const row = (try get_by_handle(connection, arena, "post")).?;
    try std.testing.expectEqualStrings(id, row.id);
    try std.testing.expectEqual(@as(usize, 5), row.def.fields.len);
    try std.testing.expectEqual(content_type.field.Kind.reference, row.def.fields[4].kind);
    try std.testing.expectEqualStrings("tag", row.def.fields[4].options.to);
    try std.testing.expect(row.def.public);

    var renamed = test_post;
    renamed.name = "Article";
    try std.testing.expect(try update(connection, arena, id, renamed, 2_000));
    try std.testing.expectEqualStrings(
        "Article",
        (try get_by_id(connection, arena, id)).?.def.name,
    );
    try std.testing.expectEqual(@as(usize, 1), (try list(connection, arena)).len);
    try std.testing.expect(try delete(connection, id));
    try std.testing.expect((try get_by_id(connection, arena, id)) == null);
}
