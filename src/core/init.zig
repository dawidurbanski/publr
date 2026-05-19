const std = @import("std");
const db_mod = @import("db");
const seed_mod = @import("seed");
const schema_registry = @import("schema_registry");
const db_open_hooks = @import("db_open_hooks");

pub const Db = db_mod.Db;

/// DDL for the content schema. The active flavor (strict default, loose
/// when a plugin's manifest.zon requests it) is wired as an anonymous
/// `schema_sql` import by build.zig — consumers never see the split.
pub const schema_sql = @embedFile("schema_sql");

/// Open/create a SQLite database and enable foreign keys.
pub fn initDatabase(allocator: std.mem.Allocator, db_path: []const u8) !Db {
    return db_mod.Db.init(allocator, db_path);
}

/// Fire every plugin-contributed `db_open_hooks` against the connection.
/// Call this once the schema is in place (cr-sqlite's CRR marking needs
/// the tables to exist). Native callers run this after `initDatabase` if
/// the on-disk DB already has the schema; WASM runs it after the in-memory
/// schema exec + seed. Hooks must be idempotent — they run on every
/// startup, and re-marking an already-CRR table no-ops in cr-sqlite.
pub fn fireDbOpenHooks(db: *Db) !void {
    try db_open_hooks.fireAll(db);
}

/// Ensure all schema tables exist.
pub fn ensureSchema(db: *Db) !void {
    try db.exec(schema_sql);
}

/// Seed core data (content types, taxonomies, defaults). Also initializes
/// the runtime schema registry with all compile-in content type
/// descriptors so that data-layer functions (`saveEntry`, `getEntry`, …)
/// can look them up.
pub fn seed(db: *Db) !void {
    try db.exec(seed_mod.seed_sql);

    schema_registry.init(db.allocator);
    for (schema_registry.compiled_in_types) |def| {
        schema_registry.register(def) catch {};
    }
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
