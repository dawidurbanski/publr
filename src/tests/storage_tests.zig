//! Test aggregator for the entry_storage module.
//!
//! Tests live here (rather than inline in `src/core/entry_storage.zig`)
//! because:
//!   1. Zig 0.15's test runner only discovers tests reachable from the
//!      test root via the import graph, so we need a dedicated root.
//!   2. The schema SQL is embedded from `src/tools/`. From `src/tests/`
//!      that path resolves within the package; from `src/core/` it doesn't.

const std = @import("std");

const Db = @import("db").Db;
const entry_storage = @import("entry_storage");
const field_mod = @import("field");
const content_type_mod = @import("content_type");
const taxonomy = @import("taxonomy");
const query = @import("query");
const entry_mod = @import("entry");

const ContentTypeDef = content_type_mod.ContentTypeDef;
const FieldMap = entry_mod.FieldMap;

// Schema lives at src/core/schema/content_schema.sql. Reading at runtime
// via std.fs avoids the package-boundary restriction Zig places on
// `@embedFile` paths for test-mode roots in `src/tests/`.
fn loadSchema(allocator: std.mem.Allocator) ![]u8 {
    var file = try std.fs.cwd().openFile("src/core/schema/content_schema.sql", .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1 * 1024 * 1024);
}

fn initTestDb() !Db {
    var db = try Db.init(std.testing.allocator, ":memory:");
    errdefer db.deinit();
    const sql = try loadSchema(std.testing.allocator);
    defer std.testing.allocator.free(sql);
    try db.exec(sql);
    return db;
}

fn insertSampleEntry(db: *Db, entry_id: []const u8, content_type_id: []const u8) !void {
    var ct = try db.prepare(
        \\INSERT OR IGNORE INTO content_types (id, slug, name, fields, source)
        \\VALUES (?1, ?1, 'Sample', '[]', 'plugin')
    );
    defer ct.deinit();
    try ct.bindText(1, content_type_id);
    _ = try ct.step();

    var anchor = try db.prepare("INSERT INTO content_anchors (id, content_type) VALUES (?1, ?2)");
    defer anchor.deinit();
    try anchor.bindText(1, entry_id);
    try anchor.bindText(2, content_type_id);
    _ = try anchor.step();

    var entry = try db.prepare(
        \\INSERT INTO content_entries (id, anchor_id, locale, content_type_id, data)
        \\VALUES (?1, ?1, 'en', ?2, '{}')
    );
    defer entry.deinit();
    try entry.bindText(1, entry_id);
    try entry.bindText(2, content_type_id);
    _ = try entry.step();
}

fn sampleDef() ContentTypeDef {
    const field = field_mod;
    return content_type_mod.contentType(.{
        .type_id = "book",
        .display_name = "Book",
        .handle = "books",
        .fields = &.{
            field.String("title", .{ .searchable = true }),
            field.String("isbn", .{ .filterable = true }),
            field.Integer("year", .{ .filterable = true }),
            field.Number("price", .{ .filterable = true }),
            field.DateTime("released_at", .{ .filterable = true }),
            field.Text("description", .{ .searchable = true }),
        },
    });
}

test "writeEntryMeta projects filterable fields to typed columns" {
    var db = try initTestDb();
    defer db.deinit();

    try insertSampleEntry(&db, "e_book1", "book");
    const def = sampleDef();

    var data: FieldMap = .{};
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "isbn", .{ .text = "978-0-123456-78-9" });
    try data.put(std.testing.allocator, "year", .{ .int = 2026 });
    try data.put(std.testing.allocator, "price", .{ .real = 29.95 });
    try data.put(std.testing.allocator, "released_at", .{ .datetime = 1_710_000_000 });

    try entry_storage.writeEntryMeta(&db, "e_book1", &def, data);

    var stmt = try db.prepare("SELECT field_name, text_value, int_value, real_value, datetime_value FROM entry_meta WHERE entry_id = ?1 ORDER BY field_name");
    defer stmt.deinit();
    try stmt.bindText(1, "e_book1");

    // isbn → text
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("isbn", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("978-0-123456-78-9", stmt.columnText(1).?);
    try std.testing.expect(stmt.columnIsNull(2));

    // price → real
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("price", stmt.columnText(0).?);
    try std.testing.expect(stmt.columnIsNull(1));
    try std.testing.expectApproxEqAbs(@as(f64, 29.95), stmt.columnReal(3), 0.001);

    // released_at → datetime
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("released_at", stmt.columnText(0).?);
    try std.testing.expectEqual(@as(i64, 1_710_000_000), stmt.columnInt(4));

    // year → int
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("year", stmt.columnText(0).?);
    try std.testing.expectEqual(@as(i64, 2026), stmt.columnInt(2));
}

test "writeEntryMeta upserts on conflict" {
    var db = try initTestDb();
    defer db.deinit();

    try insertSampleEntry(&db, "e_book1", "book");
    const def = sampleDef();

    var data: FieldMap = .{};
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "year", .{ .int = 2024 });
    try entry_storage.writeEntryMeta(&db, "e_book1", &def, data);

    try data.put(std.testing.allocator, "year", .{ .int = 2026 });
    try entry_storage.writeEntryMeta(&db, "e_book1", &def, data);

    var stmt = try db.prepare("SELECT int_value FROM entry_meta WHERE entry_id = ?1 AND field_name = 'year'");
    defer stmt.deinit();
    try stmt.bindText(1, "e_book1");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 2026), stmt.columnInt(0));
}

test "writeEntryFts populates FTS5 table and MATCH returns hits" {
    var db = try initTestDb();
    defer db.deinit();

    try insertSampleEntry(&db, "e_book1", "book");
    const def = sampleDef();

    var data: FieldMap = .{};
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "title", .{ .text = "Zigging through the storage layer" });
    try data.put(std.testing.allocator, "description", .{ .text = "A treatise on indexes" });

    try entry_storage.writeEntryFts(&db, "e_book1", &def, data);

    var stmt = try db.prepare("SELECT entry_id, field_name FROM entries_fts WHERE entries_fts MATCH 'storage' ORDER BY field_name");
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("e_book1", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("title", stmt.columnText(1).?);
}

test "writeEntryFts clears stale rows on rewrite" {
    var db = try initTestDb();
    defer db.deinit();

    try insertSampleEntry(&db, "e_book1", "book");
    const def = sampleDef();

    var data: FieldMap = .{};
    defer data.deinit(std.testing.allocator);

    try data.put(std.testing.allocator, "title", .{ .text = "First title" });
    try entry_storage.writeEntryFts(&db, "e_book1", &def, data);

    try data.put(std.testing.allocator, "title", .{ .text = "Second title" });
    try entry_storage.writeEntryFts(&db, "e_book1", &def, data);

    var stmt = try db.prepare("SELECT COUNT(*) FROM entries_fts WHERE entries_fts MATCH 'first'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));

    var stmt2 = try db.prepare("SELECT COUNT(*) FROM entries_fts WHERE entries_fts MATCH 'second'");
    defer stmt2.deinit();
    try std.testing.expect(try stmt2.step());
    try std.testing.expectEqual(@as(i64, 1), stmt2.columnInt(0));
}

test "deleteEntryFts removes all rows for the entry" {
    var db = try initTestDb();
    defer db.deinit();

    try insertSampleEntry(&db, "e_book1", "book");
    const def = sampleDef();

    var data: FieldMap = .{};
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "title", .{ .text = "Some title" });
    try entry_storage.writeEntryFts(&db, "e_book1", &def, data);

    try entry_storage.deleteEntryFts(&db, "e_book1");

    var stmt = try db.prepare("SELECT COUNT(*) FROM entries_fts WHERE entry_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, "e_book1");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "deleting an entry cascades entry_meta but not entries_fts" {
    var db = try initTestDb();
    defer db.deinit();

    try db.exec("PRAGMA foreign_keys = ON");
    try insertSampleEntry(&db, "e_book1", "book");
    const def = sampleDef();

    var data: FieldMap = .{};
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "year", .{ .int = 2026 });
    try data.put(std.testing.allocator, "title", .{ .text = "Some title" });

    try entry_storage.writeEntry(&db, "e_book1", &def, data);

    try db.exec("DELETE FROM content_entries WHERE id = 'e_book1'");

    var stmt = try db.prepare("SELECT COUNT(*) FROM entry_meta WHERE entry_id = 'e_book1'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));

    var stmt2 = try db.prepare("SELECT COUNT(*) FROM entries_fts WHERE entry_id = 'e_book1'");
    defer stmt2.deinit();
    try std.testing.expect(try stmt2.step());
    try std.testing.expectEqual(@as(i64, 1), stmt2.columnInt(0));

    try entry_storage.deleteEntryFts(&db, "e_book1");

    var stmt3 = try db.prepare("SELECT COUNT(*) FROM entries_fts WHERE entry_id = 'e_book1'");
    defer stmt3.deinit();
    try std.testing.expect(try stmt3.step());
    try std.testing.expectEqual(@as(i64, 0), stmt3.columnInt(0));
}

test "fieldValueFromText coerces by meta_type" {
    const field = field_mod;
    const text_field = field.String("name", .{});
    const int_field = field.Integer("count", .{});
    const real_field = field.Number("price", .{});

    const t = entry_storage.fieldValueFromText(text_field, "hello");
    try std.testing.expectEqualStrings("hello", t.text);

    const i = entry_storage.fieldValueFromText(int_field, "42");
    try std.testing.expectEqual(@as(i64, 42), i.int);

    const r = entry_storage.fieldValueFromText(real_field, "3.14");
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), r.real, 0.001);

    const i_bad = entry_storage.fieldValueFromText(int_field, "not-a-number");
    try std.testing.expect(i_bad == .null_);

    const empty = entry_storage.fieldValueFromText(int_field, null);
    try std.testing.expect(empty == .null_);
}

test "writeEntry round-trips meta and fts in one transaction" {
    var db = try initTestDb();
    defer db.deinit();

    try insertSampleEntry(&db, "e_book1", "book");
    const def = sampleDef();

    var data: FieldMap = .{};
    defer data.deinit(std.testing.allocator);
    try data.put(std.testing.allocator, "year", .{ .int = 2026 });
    try data.put(std.testing.allocator, "title", .{ .text = "Indexes and you" });

    try entry_storage.writeEntry(&db, "e_book1", &def, data);

    var meta = try db.prepare("SELECT int_value FROM entry_meta WHERE entry_id = ?1 AND field_name = 'year'");
    defer meta.deinit();
    try meta.bindText(1, "e_book1");
    try std.testing.expect(try meta.step());
    try std.testing.expectEqual(@as(i64, 2026), meta.columnInt(0));

    var fts = try db.prepare("SELECT field_name FROM entries_fts WHERE entries_fts MATCH 'indexes'");
    defer fts.deinit();
    try std.testing.expect(try fts.step());
    try std.testing.expectEqualStrings("title", fts.columnText(0).?);
}

fn freeTerm(allocator: std.mem.Allocator, term: taxonomy.TermRecord) void {
    allocator.free(term.id);
    allocator.free(term.taxonomy_id);
    allocator.free(term.slug);
    allocator.free(term.name);
    allocator.free(term.description);
    if (term.parent_id) |p| allocator.free(p);
    if (term.author_id) |a| allocator.free(a);
    if (term.last_updated_by) |u| allocator.free(u);
}

test "createTerm stamps author_id, last_updated_by, and timestamps" {
    var db = try initTestDb();
    defer db.deinit();
    try db.exec(
        \\INSERT INTO users (id, email, password_hash) VALUES ('u_test', 't@e.com', 'h')
    );

    const term = try taxonomy.createTerm(std.testing.allocator, &db, taxonomy.tax_media_folders, "Photos", null, "u_test");
    defer freeTerm(std.testing.allocator, term);

    try std.testing.expectEqualStrings("u_test", term.author_id.?);
    try std.testing.expectEqualStrings("u_test", term.last_updated_by.?);
    try std.testing.expect(term.created_at > 0);
    try std.testing.expectEqual(term.created_at, term.updated_at);
}

test "createTerm with null author writes nulls but still stamps timestamps" {
    var db = try initTestDb();
    defer db.deinit();

    const term = try taxonomy.createTerm(std.testing.allocator, &db, taxonomy.tax_media_tags, "system-tag", null, null);
    defer freeTerm(std.testing.allocator, term);

    try std.testing.expect(term.author_id == null);
    try std.testing.expect(term.last_updated_by == null);
    try std.testing.expect(term.created_at > 0);
}

test "renameTerm bumps updated_at and stamps last_updated_by" {
    var db = try initTestDb();
    defer db.deinit();
    try db.exec(
        \\INSERT INTO users (id, email, password_hash) VALUES ('u_author', 'a@e.com', 'h');
        \\INSERT INTO users (id, email, password_hash) VALUES ('u_editor', 'e@e.com', 'h');
    );

    const term = try taxonomy.createTerm(std.testing.allocator, &db, taxonomy.tax_media_tags, "Old", null, "u_author");
    defer freeTerm(std.testing.allocator, term);

    // Force a measurable time gap so the timestamp diff is observable.
    try db.exec("UPDATE terms SET created_at = created_at - 10, updated_at = updated_at - 10");

    try taxonomy.renameTerm(&db, term.id, "New", "u_editor");

    var stmt = try db.prepare("SELECT author_id, last_updated_by, created_at, updated_at FROM terms WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term.id);
    try std.testing.expect(try stmt.step());

    try std.testing.expectEqualStrings("u_author", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("u_editor", stmt.columnText(1).?);
    try std.testing.expect(stmt.columnInt(3) > stmt.columnInt(2));
}

// =============================================================================
// Runtime data-layer tests (query.zig new runtime API)
// =============================================================================

/// Insert an anchor + entry + version that the runtime listEntries/getEntry
/// path can find. Order matters: content_versions has an FK to
/// content_entries, so insert the entry first with a placeholder
/// current_version_id (NULL), then create the version, then UPDATE the
/// entry to point at it.
fn insertEntryWithVersion(
    db: *Db,
    entry_id: []const u8,
    content_type_id: []const u8,
    data_json: []const u8,
) !void {
    var ct = try db.prepare(
        \\INSERT OR IGNORE INTO content_types (id, slug, name, fields, source)
        \\VALUES (?1, ?1, 'Sample', '[]', 'plugin')
    );
    defer ct.deinit();
    try ct.bindText(1, content_type_id);
    _ = try ct.step();

    var anchor = try db.prepare("INSERT INTO content_anchors (id, content_type) VALUES (?1, ?2)");
    defer anchor.deinit();
    try anchor.bindText(1, entry_id);
    try anchor.bindText(2, content_type_id);
    _ = try anchor.step();

    var e = try db.prepare(
        \\INSERT INTO content_entries (id, anchor_id, locale, content_type_id, data)
        \\VALUES (?1, ?1, 'en', ?2, ?3)
    );
    defer e.deinit();
    try e.bindText(1, entry_id);
    try e.bindText(2, content_type_id);
    try e.bindText(3, data_json);
    _ = try e.step();

    const version_id = try std.fmt.allocPrint(std.testing.allocator, "v_{s}", .{entry_id});
    defer std.testing.allocator.free(version_id);

    var v = try db.prepare(
        \\INSERT INTO content_versions (id, entry_id, data_json) VALUES (?1, ?2, ?3)
    );
    defer v.deinit();
    try v.bindText(1, version_id);
    try v.bindText(2, entry_id);
    try v.bindText(3, data_json);
    _ = try v.step();

    var u = try db.prepare("UPDATE content_entries SET current_version_id = ?1 WHERE id = ?2");
    defer u.deinit();
    try u.bindText(1, version_id);
    try u.bindText(2, entry_id);
    _ = try u.step();
}

test "getEntry returns null for unknown id" {
    var db = try initTestDb();
    defer db.deinit();

    const found = try query.getEntry(std.testing.allocator, &db, "book", "no-such");
    try std.testing.expect(found == null);
}

test "getEntry parses FieldMap from entries.data JSON" {
    var db = try initTestDb();
    defer db.deinit();

    try insertEntryWithVersion(
        &db,
        "e_book1",
        "book",
        \\{"title": "Zig at Scale", "slug": "zig-at-scale", "year": 2026, "rating": 4.7}
        ,
    );

    var entry = (try query.getEntry(std.testing.allocator, &db, "book", "e_book1")) orelse
        return error.TestUnexpectedNull;
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("e_book1", entry.id);
    try std.testing.expectEqualStrings("Zig at Scale", entry.title);
    try std.testing.expectEqualStrings("zig-at-scale", entry.slug.?);
    try std.testing.expectEqualStrings("book", entry.content_type);
    try std.testing.expectEqual(@as(i64, 2026), entry.data.getInt("year").?);
    try std.testing.expectApproxEqAbs(@as(f64, 4.7), entry.data.getReal("rating").?, 0.001);
}

test "listEntries returns all entries for a type" {
    var db = try initTestDb();
    defer db.deinit();

    try insertEntryWithVersion(&db, "e_b1", "book",
        \\{"title": "Book One", "slug": "book-one"}
    );
    try insertEntryWithVersion(&db, "e_b2", "book",
        \\{"title": "Book Two", "slug": "book-two"}
    );

    const entries = try query.listEntries(std.testing.allocator, &db, "book", .{});
    defer {
        for (entries) |*e| {
            var ee = e.*;
            ee.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "listEntries .search routes through entries_fts" {
    var db = try initTestDb();
    defer db.deinit();

    try insertEntryWithVersion(&db, "e_a", "book",
        \\{"title": "Storage layers", "slug": "a"}
    );
    try insertEntryWithVersion(&db, "e_b", "book",
        \\{"title": "Network protocols", "slug": "b"}
    );

    // Index only e_a's title.
    var fts = try db.prepare(
        \\INSERT INTO entries_fts (entry_id, content_type_id, field_name, value)
        \\VALUES (?1, 'book', 'title', ?2)
    );
    defer fts.deinit();
    try fts.bindText(1, "e_a");
    try fts.bindText(2, "Storage layers");
    _ = try fts.step();

    const entries = try query.listEntries(std.testing.allocator, &db, "book", .{ .search = "storage" });
    defer {
        for (entries) |*e| {
            var ee = e.*;
            ee.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("e_a", entries[0].id);
}

test "countEntries counts only the requested type" {
    var db = try initTestDb();
    defer db.deinit();

    try insertEntryWithVersion(&db, "e_b1", "book", "{}");
    try insertEntryWithVersion(&db, "e_b2", "book", "{}");
    try insertEntryWithVersion(&db, "e_p1", "page", "{}");

    try std.testing.expectEqual(@as(u32, 2), try query.countEntries(&db, "book", .{}));
    try std.testing.expectEqual(@as(u32, 1), try query.countEntries(&db, "page", .{}));
    try std.testing.expectEqual(@as(u32, 0), try query.countEntries(&db, "movie", .{}));
}

test "moveTermParent stamps last_updated_by" {
    var db = try initTestDb();
    defer db.deinit();
    try db.exec(
        \\INSERT INTO users (id, email, password_hash) VALUES ('u_e', 'e@e.com', 'h')
    );

    const parent = try taxonomy.createTerm(std.testing.allocator, &db, taxonomy.tax_media_folders, "Parent", null, null);
    defer freeTerm(std.testing.allocator, parent);
    const child = try taxonomy.createTerm(std.testing.allocator, &db, taxonomy.tax_media_folders, "Child", null, null);
    defer freeTerm(std.testing.allocator, child);

    try taxonomy.moveTermParent(&db, child.id, parent.id, "u_e");

    var stmt = try db.prepare("SELECT parent_id, last_updated_by FROM terms WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, child.id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings(parent.id, stmt.columnText(0).?);
    try std.testing.expectEqualStrings("u_e", stmt.columnText(1).?);
}
