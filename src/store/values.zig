//! The `record_values` rows (and the `record_search` index): one row per field value per
//! slot. What a document becomes in rows, and back, is `model/document.zig`; this file
//! only stores, promotes, looks up and deletes them.

const std = @import("std");
const db = @import("../lib/db.zig");
const field = @import("../model/field.zig");
const document = @import("../model/document.zig");

const Def = field.Def;
const Value = std.json.Value;
const Row = document.Row;
const Stored = document.Stored;
const rows_max = document.rows_max;

pub const Error = db.Error || error{Invalid};

/// The slot of the document everyone reads; other slots (`pending`, a plugin's own) are
/// copies edited aside and never indexed.
pub const live = "live";
pub const pending = "pending";
pub const slot_len_max: u32 = 64;

pub fn write(
    connection: *db.Db,
    record_id: []const u8,
    slot: []const u8,
    type_id: []const u8,
    fields: []const Def,
    value: Value,
) Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(slot.len > 0 and slot.len <= slot_len_max);

    var buffer: [document.flat_max]document.Flat = undefined;
    const flat = try document.flatten(fields, value, &buffer);

    try clear(connection, record_id, slot);

    var insert = try connection.prepare(
        "INSERT INTO record_values (record, slot, type_id, field, ordinal, kind, value) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    );
    defer insert.finalize();

    var fts = try connection.prepare(
        "INSERT INTO record_search (text, record, slot, type_id, field) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5)",
    );
    defer fts.finalize();

    for (flat) |row| {
        insert.reset();
        try insert.bind_text(1, record_id);
        try insert.bind_text(2, slot);
        try insert.bind_text(3, type_id);
        try insert.bind_text(4, row.field);
        try insert.bind_int(5, row.ordinal);
        try insert.bind_text(6, @tagName(row.column));

        switch (row.value) {
            .text => |text| try insert.bind_text(7, text),
            .integer => |number| try insert.bind_int(7, number),
            .real => |number| try insert.bind_real(7, number),
        }

        try insert.exec();

        if (row.searchable) {
            fts.reset();
            try fts.bind_text(1, row.value.text);
            try fts.bind_text(2, record_id);
            try fts.bind_text(3, slot);
            try fts.bind_text(4, type_id);
            try fts.bind_text(5, row.field);
            try fts.exec();
        }
    }
}

pub fn clear(connection: *db.Db, record_id: []const u8, slot: ?[]const u8) db.Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    const statements = [_][:0]const u8{
        "DELETE FROM record_values WHERE record = ?1 AND (?2 IS NULL OR slot = ?2)",
        "DELETE FROM record_search WHERE record = ?1 AND (?2 IS NULL OR slot = ?2)",
    };

    inline for (statements) |sql| {
        var statement = try connection.prepare(sql);
        defer statement.finalize();

        try statement.bind_text(1, record_id);
        try statement.bind_optional_text(2, slot);
        try statement.exec();
    }
}

/// Make one slot the other: the target's rows go, the source's rows take its name.
/// Nothing happens when the source slot is empty; answers whether it did.
pub fn promote(
    connection: *db.Db,
    record_id: []const u8,
    from: []const u8,
    to: []const u8,
) db.Error!bool {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(!std.mem.eql(u8, from, to));

    if (!try has_slot(connection, record_id, from)) {
        return false;
    }

    try clear(connection, record_id, to);

    const statements = [_][:0]const u8{
        "UPDATE record_values SET slot = ?3 WHERE record = ?1 AND slot = ?2",
        "UPDATE record_search SET slot = ?3 WHERE record = ?1 AND slot = ?2",
    };

    inline for (statements) |sql| {
        var statement = try connection.prepare(sql);
        defer statement.finalize();

        try statement.bind_text(1, record_id);
        try statement.bind_text(2, from);
        try statement.bind_text(3, to);
        try statement.exec();
    }

    return true;
}

/// Every slot a record has values in.
pub fn slots_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record_id: []const u8,
) db.Error![][]const u8 {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(slot_len_max > 0);

    var select = try connection.prepare(
        "SELECT DISTINCT slot FROM record_values WHERE record = ?1 ORDER BY slot",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);

    const Slot = struct { slot: []const u8 };
    var slots: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        std.debug.assert(slots.items.len < 1000);

        const found = try select.read(Slot, arena);
        slots.append(arena, found.slot) catch return error.OutOfMemory;
    }

    return slots.items;
}

pub fn has_slot(connection: *db.Db, record_id: []const u8, slot: []const u8) db.Error!bool {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(slot.len > 0);

    var select = try connection.prepare(
        "SELECT 1 FROM record_values WHERE record = ?1 AND slot = ?2 LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);
    try select.bind_text(2, slot);

    return try select.step();
}

pub fn read(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record_id: []const u8,
    slot: []const u8,
) db.Error![]Row {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(slot.len > 0);

    var select = try connection.prepare(
        "SELECT field, ordinal, value FROM record_values WHERE record = ?1 AND slot = ?2 " ++
            "ORDER BY field, ordinal",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);
    try select.bind_text(2, slot);

    const Cell = struct { field: []const u8, ordinal: i64, value: db.Any };
    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < rows_max);

        const cell = try select.read(Cell, arena);
        const stored: Stored = switch (cell.value) {
            .integer => |number| .{ .integer = number },
            .real => |number| .{ .real = number },
            .text => |text| .{ .text = text },
            .blob, .null => unreachable,
        };

        rows.append(arena, .{
            .field = cell.field,
            .ordinal = cell.ordinal,
            .value = stored,
        }) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub const Referrer = struct { record_id: []const u8, field: []const u8 };

pub fn referrers(
    connection: *db.Db,
    arena: std.mem.Allocator,
    target_id: []const u8,
) db.Error![]Referrer {
    std.debug.assert(target_id.len > 0);
    std.debug.assert(rows_max > 0);

    var select = try connection.prepare(
        "SELECT DISTINCT record, field FROM record_values " ++
            "WHERE slot = 'live' AND kind = 'ref' AND value = ?1 ORDER BY record, field",
    );
    defer select.finalize();

    try select.bind_text(1, target_id);

    var found: std.ArrayList(Referrer) = .empty;

    while (try select.step()) {
        std.debug.assert(found.items.len < rows_max);
        found.append(arena, try select.read(Referrer, arena)) catch return error.OutOfMemory;
    }

    return found.items;
}

/// The record of a type holding a text value in a field, if any (unique lookups).
pub fn find_by_text(
    connection: *db.Db,
    arena: std.mem.Allocator,
    type_id: []const u8,
    path: []const u8,
    text: []const u8,
) db.Error!?[]const u8 {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(path.len > 0);

    var select = try connection.prepare(
        "SELECT record FROM record_values WHERE type_id = ?1 AND field = ?2 AND value = ?3 " ++
            "AND slot = 'live' AND kind <> 'long' LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, type_id);
    try select.bind_text(2, path);
    try select.bind_text(3, text);

    if (!try select.step()) {
        return null;
    }

    const Found = struct { record: []const u8 };
    return (try select.read(Found, arena)).record;
}

/// One text value of a record's slot (ordinal 0), or null when absent.
pub fn read_text(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record_id: []const u8,
    slot: []const u8,
    path: []const u8,
) db.Error!?[]const u8 {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(path.len > 0);

    var select = try connection.prepare(
        "SELECT value FROM record_values WHERE record = ?1 AND slot = ?2 AND field = ?3 " ++
            "AND ordinal = 0 AND kind <> 'int' AND kind <> 'real'",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);
    try select.bind_text(2, slot);
    try select.bind_text(3, path);

    if (!try select.step()) {
        return null;
    }

    const Found = struct { value: []const u8 };
    return (try select.read(Found, arena)).value;
}

const field_scope = "type_id = ?1 AND (field = ?2 OR substr(field, 1, length(?2) + 1) = ?2 || '.')";

pub fn delete_field(connection: *db.Db, type_id: []const u8, path: []const u8) db.Error!u32 {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(path.len > 0);

    var removed: u32 = 0;
    const statements = [_][:0]const u8{
        "DELETE FROM record_values WHERE " ++ field_scope,
        "DELETE FROM record_search WHERE " ++ field_scope,
    };

    inline for (statements) |sql| {
        var statement = try connection.prepare(sql);
        defer statement.finalize();

        try statement.bind_text(1, type_id);
        try statement.bind_text(2, path);
        try statement.exec();
        removed += connection.changes();
    }

    return removed;
}

pub fn count_field(connection: *db.Db, type_id: []const u8, path: []const u8) db.Error!u32 {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(path.len > 0);

    var select = try connection.prepare(
        "SELECT count(*) FROM record_values WHERE " ++ field_scope,
    );
    defer select.finalize();

    try select.bind_text(1, type_id);
    try select.bind_text(2, path);

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

const test_fields = [_]Def{
    .{ .name = "title", .label = "Title", .kind = .string, .searchable = true },
    .{ .name = "views", .label = "Views", .kind = .integer },
    .{ .name = "score", .label = "Score", .kind = .number },
    .{ .name = "live", .label = "Live", .kind = .boolean },
    .{ .name = "body", .label = "Body", .kind = .richtext },
    .{ .name = "cover", .label = "Cover", .kind = .image },
    .{
        .name = "tags",
        .label = "Tags",
        .kind = .reference,
        .many = true,
        .options = .{ .to = "tag" },
    },
    .{ .name = "seo", .label = "SEO", .kind = .group, .fields = &.{
        .{ .name = "description", .label = "Description", .kind = .text },
    } },
    .{ .name = "faq", .label = "FAQ", .kind = .repeater, .fields = &.{
        .{ .name = "question", .label = "Q", .kind = .string },
        .{ .name = "answer", .label = "A", .kind = .text },
        .{ .name = "link", .label = "Link", .kind = .reference, .options = .{ .to = "post" } },
    } },
};

fn seed_record(
    fixture: *db.testing.Fixture,
    arena: std.mem.Allocator,
    id: []const u8,
) ![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(fixture.connection.transaction_depth == 0);

    const content_type = @import("content_types.zig");
    const type_id = try content_type.insert(&fixture.connection, arena, .{
        .handle = "page",
        .name = "Page",
        .name_plural = "Pages",
        .fields = &test_fields,
    }, 0);
    var insert = try fixture.connection.prepare(
        "INSERT INTO records (id, type_id, status, changed, version, created_at, updated_at) " ++
            "VALUES (?1, ?2, 'draft', 0, 1, 0, 0)",
    );
    defer insert.finalize();

    try insert.bind_text(1, id);
    try insert.bind_text(2, type_id);
    try insert.exec();

    return type_id;
}

test "write then assemble round-trips every kind, groups, repeaters and many references" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const type_id = try seed_record(&fixture, arena, "e1");

    const text =
        \\{"title":"Hello","views":3,"score":4.5,"live":true,"body":"<p>x</p>","cover":"m1",
        \\ "tags":["t1","t2"],"seo":{"description":"about"},
        \\ "faq":[{"question":"q1","answer":"a1","link":"p9"},{"question":"q2"}]}
    ;
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, text, .{});

    try write(connection, "e1", live, type_id, &test_fields, parsed);

    const rows = try read(connection, arena, "e1", live);
    try std.testing.expectEqual(@as(usize, 13), rows.len);

    const back = try document.assemble(arena, &test_fields, rows);
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(back, .{}, &out.writer);

    const expected = "{\"title\":\"Hello\",\"views\":3,\"score\":4.5,\"live\":true," ++
        "\"body\":\"<p>x</p>\"," ++
        "\"cover\":\"m1\",\"tags\":[\"t1\",\"t2\"],\"seo\":{\"description\":\"about\"}," ++
        "\"faq\":[{\"question\":\"q1\",\"answer\":\"a1\",\"link\":\"p9\"},{\"question\":\"q2\"}]}";
    try std.testing.expectEqualStrings(expected, out.written());

    const pointing = try referrers(connection, arena, "t2");
    try std.testing.expectEqual(@as(usize, 1), pointing.len);
    try std.testing.expectEqualStrings("tags", pointing[0].field);
    try std.testing.expectEqualStrings(
        "faq.link",
        (try referrers(connection, arena, "p9"))[0].field,
    );

    try std.testing.expectEqualStrings(
        "e1",
        (try find_by_text(connection, arena, type_id, "title", "Hello")).?,
    );
    try std.testing.expect(try find_by_text(connection, arena, type_id, "title", "Nope") == null);

    var fts = try connection.prepare(
        "SELECT count(*) FROM record_search WHERE record_search MATCH 'hello'",
    );
    defer fts.finalize();
    try std.testing.expect(try fts.step());
    try std.testing.expectEqual(@as(i64, 1), fts.read_int());
}

test "a second write replaces everything; delete_field removes a field's rows including children" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const type_id = try seed_record(&fixture, arena, "e1");

    const first = try std.json.parseFromSliceLeaky(
        Value,
        arena,
        "{\"title\":\"A\",\"tags\":[\"t1\",\"t2\",\"t3\"]}",
        .{},
    );
    try write(connection, "e1", live, type_id, &test_fields, first);
    const second = try std.json.parseFromSliceLeaky(
        Value,
        arena,
        "{\"title\":\"B\",\"tags\":[\"t9\"],\"faq\":[{\"question\":\"q\"}]}",
        .{},
    );
    try write(connection, "e1", live, type_id, &test_fields, second);

    const rows = try read(connection, arena, "e1", live);
    try std.testing.expectEqual(@as(usize, 3), rows.len);

    try std.testing.expectEqual(@as(u32, 1), try count_field(connection, type_id, "faq"));
    try std.testing.expectEqual(@as(u32, 1), try delete_field(connection, type_id, "faq"));
    try std.testing.expectEqual(@as(usize, 2), (try read(connection, arena, "e1", live)).len);
    try std.testing.expectEqual(@as(u32, 0), try count_field(connection, type_id, "faq"));
}

test "slots: a pending copy is invisible to lookups until promoted to live" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const type_id = try seed_record(&fixture, arena, "e1");

    const first = try std.json.parseFromSliceLeaky(Value, arena, "{\"title\":\"Live\"}", .{});
    try write(connection, "e1", live, type_id, &test_fields, first);
    const second = try std.json.parseFromSliceLeaky(Value, arena, "{\"title\":\"Edited\"}", .{});
    try write(connection, "e1", pending, type_id, &test_fields, second);

    try std.testing.expect(try has_slot(connection, "e1", pending));
    const live_title = (try read_text(connection, arena, "e1", live, "title")).?;
    const pending_title = (try read_text(connection, arena, "e1", pending, "title")).?;
    try std.testing.expectEqualStrings("Live", live_title);
    try std.testing.expectEqualStrings("Edited", pending_title);
    try std.testing.expect(try find_by_text(connection, arena, type_id, "title", "Edited") == null);

    try std.testing.expect(try promote(connection, "e1", pending, live));
    try std.testing.expect(!try promote(connection, "e1", pending, live));

    try std.testing.expect(!try has_slot(connection, "e1", pending));
    try std.testing.expectEqual(@as(usize, 1), (try slots_of(connection, arena, "e1")).len);
    const promoted_title = (try read_text(connection, arena, "e1", live, "title")).?;
    try std.testing.expectEqualStrings("Edited", promoted_title);
    try std.testing.expect(try find_by_text(connection, arena, type_id, "title", "Edited") != null);

    try clear(connection, "e1", null);
    try std.testing.expectEqual(@as(usize, 0), (try read(connection, arena, "e1", live)).len);
}
