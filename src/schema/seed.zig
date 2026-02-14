//! Comptime Seed SQL
//!
//! Generates INSERT statements for content types and taxonomies at comptime.
//! Used by both init_db (build tool) and the runtime (server + WASM) to
//! populate seed data without any runtime sync machinery.
//!
//! Callers execute seed_sql directly on their database handle:
//!   - init_db: `execSql(db, seed.seed_sql)`
//!   - server/WASM: `db.exec(seed.seed_sql)`

const std = @import("std");
const registry = @import("schema_registry");
const field_mod = @import("field");

/// All seed INSERT statements, generated at comptime.
/// Safe to execute multiple times (uses INSERT OR IGNORE).
pub const seed_sql: []const u8 = generateSeedSql();

fn generateSeedSql() []const u8 {
    comptime {
        var sql: []const u8 = "";

        // Content types
        for (registry.content_types) |ct| {
            sql = sql ++
                "INSERT OR IGNORE INTO content_types (id, slug, name, fields, source) VALUES ('" ++
                ct.id ++ "', '" ++ ct.id ++ "', '" ++ ct.display_name ++ "', '" ++
                fieldsJson(ct.fields) ++ "', '" ++ @tagName(ct.source) ++ "');\n";
        }

        // Taxonomies from content type fields
        for (registry.all_taxonomy_ids) |tax_id| {
            sql = sql ++
                "INSERT OR IGNORE INTO taxonomies (id, slug, name, hierarchical) VALUES ('" ++
                tax_id ++ "', '" ++ tax_id ++ "', '" ++ field_mod.humanize(tax_id) ++ "', 0);\n";
        }

        return sql;
    }
}

/// Serialize field definitions to JSON at comptime.
/// Produces: [{"name":"title","display_name":"Title","type":"string","required":true},...]
fn fieldsJson(comptime fields: []const field_mod.FieldDef) []const u8 {
    comptime {
        var json: []const u8 = "[";
        for (fields, 0..) |f, i| {
            if (i > 0) json = json ++ ",";
            json = json ++
                "{\"name\":\"" ++ f.name ++
                "\",\"display_name\":\"" ++ f.display_name ++
                "\",\"type\":\"" ++ f.field_type_id ++
                "\",\"required\":" ++ (if (f.required) "true" else "false") ++
                "}";
        }
        json = json ++ "]";
        return json;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "seed_sql is non-empty" {
    try std.testing.expect(seed_sql.len > 0);
}

test "seed_sql contains content type inserts" {
    try std.testing.expect(std.mem.indexOf(u8, seed_sql, "INSERT OR IGNORE INTO content_types") != null);
}

test "seed_sql contains fields JSON" {
    // Should have real field data, not empty '[]'
    try std.testing.expect(std.mem.indexOf(u8, seed_sql, "\"name\":\"title\"") != null);
}

test "seed_sql contains taxonomy inserts" {
    try std.testing.expect(std.mem.indexOf(u8, seed_sql, "INSERT OR IGNORE INTO taxonomies") != null);
}

test "ensureSeed populates content types" {
    const Db = @import("db").Db;
    const sync = @import("sync");
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try sync.ensureSchema(&db);
    try db.exec(seed_sql);

    var stmt = try db.prepare("SELECT COUNT(*) FROM content_types");
    defer stmt.deinit();
    _ = try stmt.step();
    const count = stmt.columnInt(0);
    try std.testing.expect(count >= 2); // post + page
}

test "ensureSeed is idempotent" {
    const Db = @import("db").Db;
    const sync = @import("sync");
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try sync.ensureSchema(&db);
    try db.exec(seed_sql);
    try db.exec(seed_sql); // second call should not fail

    var stmt = try db.prepare("SELECT COUNT(*) FROM content_types");
    defer stmt.deinit();
    _ = try stmt.step();
    const count = stmt.columnInt(0);
    try std.testing.expect(count >= 2);
}

test "ensureSeed populates taxonomies" {
    const Db = @import("db").Db;
    const sync = @import("sync");
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try sync.ensureSchema(&db);
    try db.exec(seed_sql);

    // Count user-defined taxonomies (exclude media taxonomies from schema.sql)
    var stmt = try db.prepare("SELECT COUNT(*) FROM taxonomies WHERE id NOT LIKE 'tax_%'");
    defer stmt.deinit();
    _ = try stmt.step();
    const count = stmt.columnInt(0);
    try std.testing.expect(count >= 2); // category + tag
}
