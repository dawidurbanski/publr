//! Build-time database initialization
//!
//! Creates the database and schema if it doesn't exist.
//! Run as a build step, not at runtime.
//! Content types and taxonomies are generated from the schema registry at comptime.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const registry = @import("schema_registry");
const field = @import("field");

const schema_sql = @embedFile("schema.sql");

/// Content types INSERT SQL - generated at comptime from registry
const content_types_sql = generateContentTypesSql();

/// Taxonomies INSERT SQL - generated at comptime from registry
const taxonomies_sql = generateTaxonomiesSql();

fn generateContentTypesSql() []const u8 {
    comptime {
        var sql: []const u8 = "";
        for (registry.content_types) |ct| {
            sql = sql ++ "INSERT OR IGNORE INTO content_types (id, slug, name, fields, source) VALUES ('" ++
                ct.id ++ "', '" ++ ct.id ++ "', '" ++ ct.display_name ++ "', '[]', '" ++ @tagName(ct.source) ++ "');\n";
        }
        return sql;
    }
}

fn generateTaxonomiesSql() []const u8 {
    comptime {
        var sql: []const u8 = "";
        for (registry.all_taxonomy_ids) |tax_id| {
            sql = sql ++ "INSERT OR IGNORE INTO taxonomies (id, slug, name, hierarchical) VALUES ('" ++
                tax_id ++ "', '" ++ tax_id ++ "', '" ++ field.humanize(tax_id) ++ "', 0);\n";
        }
        return sql;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: init_db <database_path>\n", .{});
        return error.InvalidArgs;
    }

    const db_path = args[1];

    // Check if database already exists
    std.fs.cwd().access(db_path, .{}) catch {
        // Database doesn't exist, create directory and initialize
        if (std.fs.path.dirname(db_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }
        try initDatabase(db_path);
        std.debug.print("Database initialized: {s}\n", .{db_path});
        return;
    };

    // Database exists, ensure schema is up to date
    try ensureSchema(db_path);
}

fn initDatabase(path: []const u8) !void {
    var db: ?*c.sqlite3 = null;

    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);

    const rc = c.sqlite3_open(path_z.ptr, &db);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.DatabaseOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    // Execute base schema
    try execSql(db, schema_sql);

    // Insert content types (generated at comptime)
    try execSql(db, content_types_sql);

    // Insert taxonomies (generated at comptime)
    try execSql(db, taxonomies_sql);
}

fn execSql(db: ?*c.sqlite3, sql: []const u8) !void {
    var err_msg: [*c]u8 = null;
    const exec_rc = c.sqlite3_exec(db, sql.ptr, null, null, &err_msg);
    if (exec_rc != c.SQLITE_OK) {
        std.debug.print("SQL error: {s}\n", .{err_msg});
        c.sqlite3_free(err_msg);
        return error.SqlFailed;
    }
}

fn ensureSchema(path: []const u8) !void {
    try initDatabase(path);
}
