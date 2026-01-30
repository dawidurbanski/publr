const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const Allocator = std.mem.Allocator;

// SQLITE_STATIC (null) tells SQLite the data pointer will remain valid
// We use this since our bound data lives for the lifetime of the statement
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

/// SQLite database wrapper
pub const Db = struct {
    handle: *c.sqlite3,
    allocator: Allocator,

    pub const Error = error{
        OpenFailed,
        ExecFailed,
        PrepareFailed,
        StepFailed,
        BindFailed,
        OutOfMemory,
    };

    /// Initialize database connection, creating data directory if needed
    pub fn init(allocator: Allocator, path: []const u8) Error!Db {
        // Create parent directory if it doesn't exist
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        // Convert path to null-terminated C string
        const path_z = allocator.dupeZ(u8, path) catch return Error.OutOfMemory;
        defer allocator.free(path_z);

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path_z.ptr, &handle);

        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return Error.OpenFailed;
        }

        // Enable foreign keys
        _ = c.sqlite3_exec(handle, "PRAGMA foreign_keys = ON;", null, null, null);

        return .{
            .handle = handle.?,
            .allocator = allocator,
        };
    }

    /// Close database connection
    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute SQL without results (for DDL, INSERT, UPDATE, DELETE)
    pub fn exec(self: *Db, sql: []const u8) Error!void {
        const sql_z = self.allocator.dupeZ(u8, sql) catch return Error.OutOfMemory;
        defer self.allocator.free(sql_z);

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql_z.ptr, null, null, &err_msg);

        if (err_msg) |msg| {
            std.debug.print("SQLite error: {s}\n", .{msg});
            c.sqlite3_free(msg);
        }

        if (rc != c.SQLITE_OK) {
            return Error.ExecFailed;
        }
    }

    /// Prepare a statement for execution
    pub fn prepare(self: *Db, sql: []const u8) Error!Statement {
        const sql_z = self.allocator.dupeZ(u8, sql) catch return Error.OutOfMemory;
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql_z.ptr, @intCast(sql_z.len), &stmt, null);

        if (rc != c.SQLITE_OK or stmt == null) {
            return Error.PrepareFailed;
        }

        return .{
            .handle = stmt.?,
            .allocator = self.allocator,
        };
    }

    /// Get last insert rowid
    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Get number of rows changed by last statement
    pub fn changes(self: *Db) i32 {
        return c.sqlite3_changes(self.handle);
    }

    /// Get last error message
    pub fn errorMessage(self: *Db) []const u8 {
        const msg = c.sqlite3_errmsg(self.handle);
        return std.mem.span(msg);
    }
};

/// Prepared statement wrapper
pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    allocator: Allocator,

    /// Bind text parameter (1-indexed)
    pub fn bindText(self: *Statement, index: u32, value: []const u8) Db.Error!void {
        const rc = c.sqlite3_bind_text(
            self.handle,
            @intCast(index),
            value.ptr,
            @intCast(value.len),
            SQLITE_STATIC,
        );
        if (rc != c.SQLITE_OK) return Db.Error.BindFailed;
    }

    /// Bind integer parameter (1-indexed)
    pub fn bindInt(self: *Statement, index: u32, value: i64) Db.Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, @intCast(index), value);
        if (rc != c.SQLITE_OK) return Db.Error.BindFailed;
    }

    /// Bind blob parameter (1-indexed)
    pub fn bindBlob(self: *Statement, index: u32, value: []const u8) Db.Error!void {
        const rc = c.sqlite3_bind_blob(
            self.handle,
            @intCast(index),
            value.ptr,
            @intCast(value.len),
            SQLITE_STATIC,
        );
        if (rc != c.SQLITE_OK) return Db.Error.BindFailed;
    }

    /// Bind null parameter (1-indexed)
    pub fn bindNull(self: *Statement, index: u32) Db.Error!void {
        const rc = c.sqlite3_bind_null(self.handle, @intCast(index));
        if (rc != c.SQLITE_OK) return Db.Error.BindFailed;
    }

    /// Execute statement and iterate rows
    pub fn step(self: *Statement) Db.Error!bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return Db.Error.StepFailed;
    }

    /// Get text column value (0-indexed)
    pub fn columnText(self: *Statement, index: u32) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, @intCast(index));
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.handle, @intCast(index));
        return ptr[0..@intCast(len)];
    }

    /// Get integer column value (0-indexed)
    pub fn columnInt(self: *Statement, index: u32) i64 {
        return c.sqlite3_column_int64(self.handle, @intCast(index));
    }

    /// Get blob column value (0-indexed)
    pub fn columnBlob(self: *Statement, index: u32) ?[]const u8 {
        const ptr: [*c]const u8 = @ptrCast(c.sqlite3_column_blob(self.handle, @intCast(index)));
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.handle, @intCast(index));
        return ptr[0..@intCast(len)];
    }

    /// Check if column is null (0-indexed)
    pub fn columnIsNull(self: *Statement, index: u32) bool {
        return c.sqlite3_column_type(self.handle, @intCast(index)) == c.SQLITE_NULL;
    }

    /// Reset statement for reuse with new parameters
    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    /// Finalize and free statement
    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }
};

/// Schema for auth tables
const schema_sql =
    \\CREATE TABLE IF NOT EXISTS users (
    \\    id TEXT PRIMARY KEY,
    \\    email TEXT UNIQUE NOT NULL,
    \\    email_verified INTEGER DEFAULT 0,
    \\    password_hash TEXT NOT NULL,
    \\    created_at INTEGER DEFAULT (unixepoch())
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS sessions (
    \\    id TEXT PRIMARY KEY,
    \\    secret_hash BLOB NOT NULL,
    \\    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\    expires_at INTEGER NOT NULL,
    \\    created_at INTEGER DEFAULT (unixepoch())
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
    \\CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
;

/// Initialize database with schema
pub fn initWithSchema(allocator: Allocator, path: []const u8) Db.Error!Db {
    var db = try Db.init(allocator, path);
    errdefer db.deinit();
    try db.exec(schema_sql);
    return db;
}

// Tests
test "Db: open in-memory database" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();
}

test "Db: exec creates table" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
    try db.exec("INSERT INTO test (name) VALUES ('hello')");

    var stmt = try db.prepare("SELECT name FROM test WHERE id = 1");
    defer stmt.deinit();

    const has_row = try stmt.step();
    try std.testing.expect(has_row);

    const name = stmt.columnText(0);
    try std.testing.expectEqualStrings("hello", name.?);
}

test "Db: prepared statement with bindings" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT, age INTEGER)");

    var insert = try db.prepare("INSERT INTO users (id, email, age) VALUES (?1, ?2, ?3)");
    defer insert.deinit();

    try insert.bindText(1, "u_123");
    try insert.bindText(2, "test@example.com");
    try insert.bindInt(3, 25);
    _ = try insert.step();

    var select = try db.prepare("SELECT email, age FROM users WHERE id = ?1");
    defer select.deinit();

    try select.bindText(1, "u_123");
    const has_row = try select.step();
    try std.testing.expect(has_row);

    try std.testing.expectEqualStrings("test@example.com", select.columnText(0).?);
    try std.testing.expectEqual(@as(i64, 25), select.columnInt(1));
}

test "Db: blob binding and retrieval" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try db.exec("CREATE TABLE blobs (id INTEGER PRIMARY KEY, data BLOB)");

    const blob_data = [_]u8{ 0x01, 0x02, 0x03, 0xFF, 0x00, 0xAB };

    var insert = try db.prepare("INSERT INTO blobs (data) VALUES (?1)");
    defer insert.deinit();
    try insert.bindBlob(1, &blob_data);
    _ = try insert.step();

    var select = try db.prepare("SELECT data FROM blobs WHERE id = 1");
    defer select.deinit();
    _ = try select.step();

    const retrieved = select.columnBlob(0).?;
    try std.testing.expectEqualSlices(u8, &blob_data, retrieved);
}

test "Db: null handling" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try db.exec("CREATE TABLE nullable (id INTEGER PRIMARY KEY, value TEXT)");

    var insert = try db.prepare("INSERT INTO nullable (value) VALUES (?1)");
    defer insert.deinit();
    try insert.bindNull(1);
    _ = try insert.step();

    var select = try db.prepare("SELECT value FROM nullable WHERE id = 1");
    defer select.deinit();
    _ = try select.step();

    try std.testing.expect(select.columnIsNull(0));
    try std.testing.expect(select.columnText(0) == null);
}

test "Db: statement reset and reuse" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)");

    var insert = try db.prepare("INSERT INTO items (name) VALUES (?1)");
    defer insert.deinit();

    try insert.bindText(1, "first");
    _ = try insert.step();

    insert.reset();

    try insert.bindText(1, "second");
    _ = try insert.step();

    var count_stmt = try db.prepare("SELECT COUNT(*) FROM items");
    defer count_stmt.deinit();
    _ = try count_stmt.step();

    try std.testing.expectEqual(@as(i64, 2), count_stmt.columnInt(0));
}

test "Db: schema initialization" {
    var db = try initWithSchema(std.testing.allocator, ":memory:");
    defer db.deinit();

    // Verify users table exists
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='users'");
    defer stmt.deinit();
    const has_users = try stmt.step();
    try std.testing.expect(has_users);

    // Verify sessions table exists
    var stmt2 = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'");
    defer stmt2.deinit();
    const has_sessions = try stmt2.step();
    try std.testing.expect(has_sessions);
}

test "Db: foreign key cascade delete" {
    var db = try initWithSchema(std.testing.allocator, ":memory:");
    defer db.deinit();

    // Insert user
    var insert_user = try db.prepare("INSERT INTO users (id, email, password_hash) VALUES (?1, ?2, ?3)");
    defer insert_user.deinit();
    try insert_user.bindText(1, "u_test");
    try insert_user.bindText(2, "test@example.com");
    try insert_user.bindText(3, "hash123");
    _ = try insert_user.step();

    // Insert session
    var insert_session = try db.prepare(
        "INSERT INTO sessions (id, secret_hash, user_id, expires_at) VALUES (?1, ?2, ?3, ?4)",
    );
    defer insert_session.deinit();
    try insert_session.bindText(1, "s_test");
    try insert_session.bindBlob(2, "secret");
    try insert_session.bindText(3, "u_test");
    try insert_session.bindInt(4, 9999999999);
    _ = try insert_session.step();

    // Delete user - should cascade to sessions
    try db.exec("DELETE FROM users WHERE id = 'u_test'");

    // Verify session was deleted
    var count = try db.prepare("SELECT COUNT(*) FROM sessions WHERE user_id = 'u_test'");
    defer count.deinit();
    _ = try count.step();
    try std.testing.expectEqual(@as(i64, 0), count.columnInt(0));
}

test "Db: auto-creates parent directory" {
    const test_dir = "/tmp/publr_test_db";
    const test_path = test_dir ++ "/nested/publr.db";

    // Clean up any previous test run
    std.fs.deleteTreeAbsolute(test_dir) catch {};

    // Init should create the directory
    var db = try Db.init(std.testing.allocator, test_path);
    defer db.deinit();

    // Verify directory was created
    const dir = std.fs.openDirAbsolute(test_dir ++ "/nested", .{}) catch |err| {
        std.debug.print("Failed to open dir: {}\n", .{err});
        return err;
    };
    var d = dir;
    d.close();

    // Clean up
    std.fs.deleteTreeAbsolute(test_dir) catch {};
}
