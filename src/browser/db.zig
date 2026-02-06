const std = @import("std");
const Allocator = std.mem.Allocator;

// JavaScript imports for sql.js operations
extern "env" fn js_db_open() i32;
extern "env" fn js_db_close() void;
extern "env" fn js_db_exec(sql_ptr: [*]const u8, sql_len: usize) i32;
extern "env" fn js_db_prepare(sql_ptr: [*]const u8, sql_len: usize) i32;
extern "env" fn js_stmt_bind_text(stmt_id: i32, index: i32, ptr: [*]const u8, len: usize) i32;
extern "env" fn js_stmt_bind_int(stmt_id: i32, index: i32, value: i64) i32;
extern "env" fn js_stmt_bind_blob(stmt_id: i32, index: i32, ptr: [*]const u8, len: usize) i32;
extern "env" fn js_stmt_bind_null(stmt_id: i32, index: i32) i32;
extern "env" fn js_stmt_step(stmt_id: i32) i32; // 1 = row, 0 = done, -1 = error
extern "env" fn js_stmt_column_text(stmt_id: i32, index: i32, out_ptr: *[*]const u8, out_len: *usize) i32;
extern "env" fn js_stmt_column_int(stmt_id: i32, index: i32) i64;
extern "env" fn js_stmt_column_blob(stmt_id: i32, index: i32, out_ptr: *[*]const u8, out_len: *usize) i32;
extern "env" fn js_stmt_column_is_null(stmt_id: i32, index: i32) i32;
extern "env" fn js_stmt_reset(stmt_id: i32) void;
extern "env" fn js_stmt_finalize(stmt_id: i32) void;
extern "env" fn js_db_last_insert_rowid() i64;
extern "env" fn js_db_changes() i32;

/// SQLite database wrapper for WASM (uses JavaScript sql.js)
pub const Db = struct {
    allocator: Allocator,

    pub const Error = error{
        OpenFailed,
        ExecFailed,
        PrepareFailed,
        StepFailed,
        BindFailed,
        OutOfMemory,
    };

    /// Initialize database connection
    pub fn init(allocator: Allocator, path: []const u8) Error!Db {
        _ = path; // Path is handled by JavaScript/IndexedDB
        const rc = js_db_open();
        if (rc != 0) {
            return Error.OpenFailed;
        }
        return .{ .allocator = allocator };
    }

    /// Close database connection
    pub fn deinit(self: *Db) void {
        _ = self;
        js_db_close();
    }

    /// Execute SQL without results (for DDL, INSERT, UPDATE, DELETE)
    pub fn exec(self: *Db, sql: []const u8) Error!void {
        _ = self;
        const rc = js_db_exec(sql.ptr, sql.len);
        if (rc != 0) {
            return Error.ExecFailed;
        }
    }

    /// Prepare a statement for execution
    pub fn prepare(self: *Db, sql: []const u8) Error!Statement {
        const stmt_id = js_db_prepare(sql.ptr, sql.len);
        if (stmt_id < 0) {
            return Error.PrepareFailed;
        }
        return .{
            .id = stmt_id,
            .allocator = self.allocator,
        };
    }

    /// Get last insert rowid
    pub fn lastInsertRowId(self: *Db) i64 {
        _ = self;
        return js_db_last_insert_rowid();
    }

    /// Get number of rows changed by last statement
    pub fn changes(self: *Db) i32 {
        _ = self;
        return js_db_changes();
    }

    /// Get last error message (not implemented for WASM)
    pub fn errorMessage(self: *Db) []const u8 {
        _ = self;
        return "Error (check browser console)";
    }
};

/// Prepared statement wrapper for WASM
pub const Statement = struct {
    id: i32,
    allocator: Allocator,

    /// Bind text parameter (1-indexed)
    pub fn bindText(self: *Statement, index: u32, value: []const u8) Db.Error!void {
        const rc = js_stmt_bind_text(self.id, @intCast(index), value.ptr, value.len);
        if (rc != 0) return Db.Error.BindFailed;
    }

    /// Bind integer parameter (1-indexed)
    pub fn bindInt(self: *Statement, index: u32, value: i64) Db.Error!void {
        const rc = js_stmt_bind_int(self.id, @intCast(index), value);
        if (rc != 0) return Db.Error.BindFailed;
    }

    /// Bind blob parameter (1-indexed)
    pub fn bindBlob(self: *Statement, index: u32, value: []const u8) Db.Error!void {
        const rc = js_stmt_bind_blob(self.id, @intCast(index), value.ptr, value.len);
        if (rc != 0) return Db.Error.BindFailed;
    }

    /// Bind null parameter (1-indexed)
    pub fn bindNull(self: *Statement, index: u32) Db.Error!void {
        const rc = js_stmt_bind_null(self.id, @intCast(index));
        if (rc != 0) return Db.Error.BindFailed;
    }

    /// Execute statement and iterate rows
    pub fn step(self: *Statement) Db.Error!bool {
        const rc = js_stmt_step(self.id);
        if (rc == 1) return true; // SQLITE_ROW
        if (rc == 0) return false; // SQLITE_DONE
        return Db.Error.StepFailed;
    }

    /// Get text column value (0-indexed)
    pub fn columnText(self: *Statement, index: u32) ?[]const u8 {
        var ptr: [*]const u8 = undefined;
        var len: usize = 0;
        const rc = js_stmt_column_text(self.id, @intCast(index), &ptr, &len);
        if (rc != 0 or len == 0) return null;
        return ptr[0..len];
    }

    /// Get integer column value (0-indexed)
    pub fn columnInt(self: *Statement, index: u32) i64 {
        return js_stmt_column_int(self.id, @intCast(index));
    }

    /// Get blob column value (0-indexed)
    pub fn columnBlob(self: *Statement, index: u32) ?[]const u8 {
        var ptr: [*]const u8 = undefined;
        var len: usize = 0;
        const rc = js_stmt_column_blob(self.id, @intCast(index), &ptr, &len);
        if (rc != 0 or len == 0) return null;
        return ptr[0..len];
    }

    /// Check if column is null (0-indexed)
    pub fn columnIsNull(self: *Statement, index: u32) bool {
        return js_stmt_column_is_null(self.id, @intCast(index)) != 0;
    }

    /// Reset statement for reuse with new parameters
    pub fn reset(self: *Statement) void {
        js_stmt_reset(self.id);
    }

    /// Finalize and free statement
    pub fn deinit(self: *Statement) void {
        js_stmt_finalize(self.id);
    }
};

// Note: Schema initialization happens at build time via init_db.
// For browser builds, the caller should apply schema.sql after Db.init().
