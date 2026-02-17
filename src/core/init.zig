const std = @import("std");
const db_mod = @import("db");
const schema_sync = @import("schema_sync");
const seed_mod = @import("seed");

pub const Db = db_mod.Db;

/// Open/create a SQLite database and enable foreign keys.
pub fn initDatabase(allocator: std.mem.Allocator, db_path: []const u8) !Db {
    return db_mod.Db.init(allocator, db_path);
}

/// Ensure all schema tables exist.
pub fn ensureSchema(db: *Db) !void {
    try schema_sync.ensureSchema(db);
}

/// Seed core data (content types, taxonomies, defaults).
pub fn seed(db: *Db) !void {
    try db.exec(seed_mod.seed_sql);
}

test "initDatabase opens memory db" {
    var db = try initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();
}

test "ensureSchema creates tables" {
    var db = try initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();
    try ensureSchema(&db);

    var stmt = try db.prepare(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'content_entries' LIMIT 1",
    );
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
}

test "seed populates initial data" {
    var db = try initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();
    try ensureSchema(&db);
    try seed(&db);

    var stmt = try db.prepare("SELECT COUNT(*) FROM content_types");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expect(stmt.columnInt(0) > 0);
}

test "init is idempotent" {
    var db = try initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);
    try seed(&db);
    try ensureSchema(&db);
    try seed(&db);
}

test "init: public API coverage" {
    _ = initDatabase;
    _ = ensureSchema;
    _ = seed;
}
