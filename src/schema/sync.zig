//! Schema DDL Module
//!
//! Contains the DDL for all content schema tables and a function to
//! ensure they exist. Content type/taxonomy seeding is handled by
//! the seed module (comptime-generated INSERT statements).

const std = @import("std");
const Db = @import("db").Db;

/// SQL for creating content schema tables
pub const content_schema_sql = @embedFile("content_schema.sql");

/// Ensure content schema tables exist
pub fn ensureSchema(db: *Db) Db.Error!void {
    try db.exec(content_schema_sql);
}

// =============================================================================
// Tests
// =============================================================================

test "ensureSchema creates tables" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='content_types'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
}

test "ensureSchema creates content_versions table" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='content_versions'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
}

test "ensureSchema creates unified lifecycle tables" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='content_anchors'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());

    var stmt2 = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='entry_flow_state'");
    defer stmt2.deinit();
    try std.testing.expect(try stmt2.step());

    var stmt3 = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='release_entries'");
    defer stmt3.deinit();
    try std.testing.expect(try stmt3.step());
}

test "ensureSchema creates settings table" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
}

test "content_entries table has current_version_id column" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    try db.exec(
        \\INSERT INTO content_types (id, slug, name, fields, source)
        \\VALUES ('test_ct', 'test_ct', 'Test', '[]', 'plugin')
    );
    try db.exec(
        \\INSERT INTO content_anchors (id, content_type)
        \\VALUES ('e_test1', 'test_ct')
    );
    try db.exec(
        \\INSERT INTO content_entries (id, anchor_id, locale, content_type_id, data, current_version_id)
        \\VALUES ('e_test1', 'e_test1', 'en', 'test_ct', '{}', NULL)
    );

    var stmt = try db.prepare("SELECT current_version_id FROM content_entries WHERE id = 'e_test1'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expect(stmt.columnIsNull(0));
}
