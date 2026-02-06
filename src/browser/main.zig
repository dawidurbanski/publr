const std = @import("std");
const db = @import("db.zig");
const Db = db.Db;

// Database schema (single source of truth)
const schema_sql = @embedFile("../tools/schema.sql");

// Use a simple bump allocator for WASM
var wasm_memory: [8 * 1024 * 1024]u8 = undefined; // 8MB
var fba = std.heap.FixedBufferAllocator.init(&wasm_memory);
const allocator = fba.allocator();

// Global database instance
var global_db: ?Db = null;

// Buffer for returning strings to JavaScript
var result_buffer: [64 * 1024]u8 = undefined; // 64KB for results

// JavaScript imports for logging and time
extern "env" fn js_console_log(ptr: [*]const u8, len: usize) void;
extern "env" fn js_get_time() i64;

fn log(msg: []const u8) void {
    js_console_log(msg.ptr, msg.len);
}

// =============================================================================
// Memory Management Exports
// =============================================================================

/// Allocate memory for JavaScript to write into
export fn wasm_alloc(size: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

/// Free previously allocated memory
export fn wasm_free(ptr: [*]u8, size: usize) void {
    allocator.free(ptr[0..size]);
}

/// Get pointer to result buffer (for reading results)
export fn wasm_get_result_ptr() [*]u8 {
    return &result_buffer;
}

/// Get result buffer size
export fn wasm_get_result_size() usize {
    return result_buffer.len;
}

// =============================================================================
// JSON Helpers (manual for Zig 0.15 compatibility)
// =============================================================================

fn writeResult(json: []const u8) usize {
    @memcpy(result_buffer[0..json.len], json);
    return json.len;
}

fn writeError(msg: []const u8) usize {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{msg}) catch {
        return writeResult("{\"success\":false,\"error\":\"Unknown error\"}");
    };
    return writeResult(json);
}

fn writeSuccess() usize {
    return writeResult("{\"success\":true}");
}

// =============================================================================
// Database Initialization
// =============================================================================

/// Initialize the database (called after sql.js is ready)
export fn cms_init() i32 {
    if (global_db != null) {
        return 0; // Already initialized
    }

    global_db = Db.init(allocator, "browser.db") catch {
        const msg = "Failed to open database";
        @memcpy(result_buffer[0..msg.len], msg);
        return -1;
    };

    global_db.?.exec(schema_sql) catch {
        const msg = "Failed to execute schema";
        @memcpy(result_buffer[0..msg.len], msg);
        return -1;
    };

    log("CMS database initialized");
    return 0;
}

/// Close the database
export fn cms_close() void {
    if (global_db) |*database| {
        database.deinit();
        global_db = null;
    }
}

// =============================================================================
// User Management
// =============================================================================

/// Check if any users exist (for setup wizard)
export fn cms_has_users() i32 {
    var database = global_db orelse return -1;

    var stmt = database.prepare("SELECT 1 FROM users LIMIT 1") catch return -1;
    defer stmt.deinit();

    const has_row = stmt.step() catch return -1;
    return if (has_row) 1 else 0;
}

/// Create a new user
/// Input: JSON { "email": "...", "display_name": "...", "password": "..." }
/// Output: JSON { "success": true, "user_id": "..." } or { "success": false, "error": "..." }
export fn cms_create_user(input_ptr: [*]const u8, input_len: usize) usize {
    const input = input_ptr[0..input_len];

    // Parse JSON input
    const parsed = std.json.parseFromSlice(struct {
        email: []const u8,
        display_name: []const u8,
        password: []const u8,
    }, allocator, input, .{}) catch {
        return writeError("Invalid JSON input");
    };
    defer parsed.deinit();

    const data = parsed.value;

    // Hash password using Argon2id (reduced memory for WASM)
    var hash_buf: [128]u8 = undefined;
    const password_hash = std.crypto.pwhash.argon2.strHash(data.password, .{
        .allocator = allocator,
        .params = .{ .t = 3, .m = 4096, .p = 1 }, // 4MB instead of 19MB
    }, &hash_buf) catch {
        return writeError("Password hashing failed");
    };

    // Generate user ID
    var random_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const hex_buf = std.fmt.bytesToHex(random_bytes, .lower);

    var user_id_buf: [32]u8 = undefined;
    const user_id = std.fmt.bufPrint(&user_id_buf, "u_{s}", .{hex_buf}) catch {
        return writeError("Failed to generate user ID");
    };

    // Insert user
    var database = global_db orelse return writeError("Database not initialized");
    var stmt = database.prepare(
        "INSERT INTO users (id, email, display_name, password_hash) VALUES (?1, ?2, ?3, ?4)",
    ) catch {
        return writeError("Failed to prepare statement");
    };
    defer stmt.deinit();

    stmt.bindText(1, user_id) catch return writeError("Bind user_id failed");
    stmt.bindText(2, data.email) catch return writeError("Bind email failed");
    stmt.bindText(3, data.display_name) catch return writeError("Bind display_name failed");
    stmt.bindText(4, password_hash) catch return writeError("Bind password_hash failed");

    _ = stmt.step() catch {
        return writeError("Insert failed - check console");
    };

    // Return success with user_id
    const result = std.fmt.bufPrint(&result_buffer, "{{\"success\":true,\"user_id\":\"{s}\"}}", .{user_id}) catch {
        return writeError("Format failed");
    };
    return result.len;
}

/// Authenticate user (login)
/// Input: JSON { "email": "...", "password": "..." }
/// Output: JSON { "success": true, "user_id": "...", "session_token": "..." }
export fn cms_login(input_ptr: [*]const u8, input_len: usize) usize {
    const input = input_ptr[0..input_len];

    const parsed = std.json.parseFromSlice(struct {
        email: []const u8,
        password: []const u8,
    }, allocator, input, .{}) catch {
        return writeError("Invalid JSON input");
    };
    defer parsed.deinit();

    const data = parsed.value;

    var database = global_db orelse return writeError("Database not initialized");

    // Get user by email
    var stmt = database.prepare(
        "SELECT id, password_hash FROM users WHERE email = ?1",
    ) catch return writeError("Query failed");
    defer stmt.deinit();

    stmt.bindText(1, data.email) catch return writeError("Bind failed");

    const has_row = stmt.step() catch return writeError("Query failed");
    if (!has_row) {
        return writeError("Invalid credentials");
    }

    const user_id = stmt.columnText(0) orelse return writeError("Invalid user data");
    const stored_hash = stmt.columnText(1) orelse return writeError("Invalid user data");

    // Verify password
    std.crypto.pwhash.argon2.strVerify(stored_hash, data.password, .{
        .allocator = allocator,
    }) catch {
        return writeError("Invalid credentials");
    };

    // Create session
    const session_token = createSession(user_id) catch {
        return writeError("Failed to create session");
    };

    const result = std.fmt.bufPrint(&result_buffer, "{{\"success\":true,\"user_id\":\"{s}\",\"session_token\":\"{s}\"}}", .{ user_id, session_token }) catch {
        return writeError("Format failed");
    };
    return result.len;
}

/// Validate session and get current user
/// Input: session token string
/// Output: JSON { "success": true, "user": { ... } } or { "success": false }
export fn cms_validate_session(token_ptr: [*]const u8, token_len: usize) usize {
    const token = token_ptr[0..token_len];

    // Parse token: id.secret
    const dot_pos = std.mem.indexOf(u8, token, ".") orelse return writeError("Invalid token format");
    const session_id = token[0..dot_pos];
    const secret_hex = token[dot_pos + 1 ..];

    if (secret_hex.len != 64) return writeError("Invalid token format");

    // Decode hex secret
    var secret_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&secret_bytes, secret_hex) catch return writeError("Invalid token");

    // Hash the provided secret
    var provided_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&secret_bytes, &provided_hash, .{});

    var database = global_db orelse return writeError("Database not initialized");

    // Look up session
    var stmt = database.prepare(
        "SELECT secret_hash, user_id, expires_at FROM sessions WHERE id = ?1",
    ) catch return writeError("Query failed");
    defer stmt.deinit();

    stmt.bindText(1, session_id) catch return writeError("Bind failed");

    const has_row = stmt.step() catch return writeError("Query failed");
    if (!has_row) return writeError("Session not found");

    const stored_hash = stmt.columnBlob(0) orelse return writeError("Invalid session");
    const user_id = stmt.columnText(1) orelse return writeError("Invalid session");
    const expires_at = stmt.columnInt(2);

    // Constant-time comparison
    if (!std.crypto.timing_safe.eql([32]u8, stored_hash[0..32].*, provided_hash)) {
        return writeError("Invalid session");
    }

    // Check expiry (use JavaScript time)
    const now = @divFloor(js_get_time(), 1000); // Convert ms to seconds
    if (now > expires_at) {
        return writeError("Session expired");
    }

    // Get user details
    var user_stmt = database.prepare(
        "SELECT id, email, display_name FROM users WHERE id = ?1",
    ) catch return writeError("Query failed");
    defer user_stmt.deinit();

    user_stmt.bindText(1, user_id) catch return writeError("Bind failed");
    const has_user = user_stmt.step() catch return writeError("Query failed");
    if (!has_user) return writeError("User not found");

    const email = user_stmt.columnText(1) orelse "";
    const display_name = user_stmt.columnText(2) orelse "";

    const result = std.fmt.bufPrint(&result_buffer, "{{\"success\":true,\"user\":{{\"id\":\"{s}\",\"email\":\"{s}\",\"display_name\":\"{s}\"}}}}", .{ user_id, email, display_name }) catch {
        return writeError("Format failed");
    };
    return result.len;
}

/// List all users - returns JSON array
export fn cms_list_users() usize {
    var database = global_db orelse return writeError("Database not initialized");

    var stmt = database.prepare(
        "SELECT id, email, display_name FROM users ORDER BY created_at DESC",
    ) catch return writeError("Query failed");
    defer stmt.deinit();

    // Build JSON manually
    var pos: usize = 0;
    result_buffer[pos] = '{';
    pos += 1;
    const prefix = "\"success\":true,\"users\":[";
    @memcpy(result_buffer[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var first = true;
    while (stmt.step() catch return writeError("Query failed")) {
        if (!first) {
            result_buffer[pos] = ',';
            pos += 1;
        }
        first = false;

        const id = stmt.columnText(0) orelse "";
        const email = stmt.columnText(1) orelse "";
        const display_name = stmt.columnText(2) orelse "";

        const user_json = std.fmt.bufPrint(result_buffer[pos..], "{{\"id\":\"{s}\",\"email\":\"{s}\",\"display_name\":\"{s}\"}}", .{ id, email, display_name }) catch {
            return writeError("Buffer overflow");
        };
        pos += user_json.len;
    }

    const suffix = "]}";
    @memcpy(result_buffer[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return pos;
}

/// Logout (invalidate session)
export fn cms_logout(token_ptr: [*]const u8, token_len: usize) usize {
    const token = token_ptr[0..token_len];

    const dot_pos = std.mem.indexOf(u8, token, ".") orelse return writeError("Invalid token");
    const session_id = token[0..dot_pos];

    var database = global_db orelse return writeError("Database not initialized");

    var stmt = database.prepare("DELETE FROM sessions WHERE id = ?1") catch return writeError("Query failed");
    defer stmt.deinit();

    stmt.bindText(1, session_id) catch return writeError("Bind failed");
    _ = stmt.step() catch return writeError("Query failed");

    return writeSuccess();
}

// =============================================================================
// Helper Functions
// =============================================================================

var session_token_buf: [128]u8 = undefined;

fn createSession(user_id: []const u8) ![]const u8 {
    // Generate session ID
    var session_id_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&session_id_bytes);
    const session_hex = std.fmt.bytesToHex(session_id_bytes, .lower);

    var session_id_buf: [32]u8 = undefined;
    const session_id = try std.fmt.bufPrint(&session_id_buf, "s_{s}", .{session_hex});

    // Generate secret
    var secret_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&secret_bytes);
    const secret_hex = std.fmt.bytesToHex(secret_bytes, .lower);

    // Hash secret for storage
    var secret_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&secret_bytes, &secret_hash, .{});

    // Calculate expiry (30 days)
    const now = @divFloor(js_get_time(), 1000);
    const expires_at = now + 30 * 24 * 60 * 60;

    var database = global_db orelse return error.DatabaseNotInitialized;

    var stmt = database.prepare(
        "INSERT INTO sessions (id, secret_hash, user_id, expires_at) VALUES (?1, ?2, ?3, ?4)",
    ) catch return error.DatabaseError;
    defer stmt.deinit();

    stmt.bindText(1, session_id) catch return error.DatabaseError;
    stmt.bindBlob(2, &secret_hash) catch return error.DatabaseError;
    stmt.bindText(3, user_id) catch return error.DatabaseError;
    stmt.bindInt(4, expires_at) catch return error.DatabaseError;

    _ = stmt.step() catch return error.DatabaseError;

    // Return token
    const token = try std.fmt.bufPrint(&session_token_buf, "{s}.{s}", .{ session_id, secret_hex });
    return token;
}
