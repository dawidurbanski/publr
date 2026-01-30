const std = @import("std");
const Db = @import("db.zig").Db;
const Statement = @import("db.zig").Statement;

const Allocator = std.mem.Allocator;
const argon2 = std.crypto.pwhash.argon2;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Session duration: 30 days in seconds
const SESSION_DURATION_SECS: i64 = 30 * 24 * 60 * 60;

/// Sliding expiration threshold: extend if >50% of lifetime passed
const SLIDING_THRESHOLD_SECS: i64 = SESSION_DURATION_SECS / 2;

pub const Auth = struct {
    db: *Db,
    allocator: Allocator,

    pub const Error = error{
        HashFailed,
        VerifyFailed,
        InvalidCredentials,
        SessionNotFound,
        SessionExpired,
        UserNotFound,
        EmailExists,
        DbError,
        OutOfMemory,
    };

    pub const User = struct {
        id: []const u8,
        email: []const u8,
        email_verified: bool,
        created_at: i64,
    };

    pub const Session = struct {
        id: []const u8,
        user_id: []const u8,
        expires_at: i64,
        created_at: i64,
    };

    pub fn init(allocator: Allocator, db: *Db) Auth {
        return .{
            .db = db,
            .allocator = allocator,
        };
    }

    // =========================================================================
    // Password Hashing
    // =========================================================================

    /// Hash password using Argon2id with OWASP recommended params
    pub fn hashPassword(self: *Auth, password: []const u8) Error![]const u8 {
        var hash_buf: [128]u8 = undefined;

        const hash = argon2.strHash(password, .{
            .allocator = self.allocator,
            .params = .{ .t = 2, .m = 19456, .p = 1 },
        }, &hash_buf) catch return Error.HashFailed;

        return self.allocator.dupe(u8, hash) catch return Error.OutOfMemory;
    }

    /// Verify password against stored hash
    pub fn verifyPassword(self: *Auth, password: []const u8, hash: []const u8) Error!void {
        argon2.strVerify(hash, password, .{
            .allocator = self.allocator,
        }) catch return Error.InvalidCredentials;
    }

    // =========================================================================
    // User Management
    // =========================================================================

    /// Create a new user with hashed password
    pub fn createUser(self: *Auth, email: []const u8, password: []const u8) Error![]const u8 {
        const password_hash = try self.hashPassword(password);
        defer self.allocator.free(password_hash);

        const user_id = try self.generateId("u_");
        errdefer self.allocator.free(user_id);

        var stmt = self.db.prepare(
            "INSERT INTO users (id, email, password_hash) VALUES (?1, ?2, ?3)",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, user_id) catch return Error.DbError;
        stmt.bindText(2, email) catch return Error.DbError;
        stmt.bindText(3, password_hash) catch return Error.DbError;

        _ = stmt.step() catch return Error.EmailExists;

        return user_id;
    }

    /// Get user by email (for login)
    pub fn getUserByEmail(self: *Auth, email: []const u8) Error!?User {
        var stmt = self.db.prepare(
            "SELECT id, email, email_verified, created_at FROM users WHERE email = ?1",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, email) catch return Error.DbError;

        const has_row = stmt.step() catch return Error.DbError;
        if (!has_row) return null;

        return User{
            .id = self.allocator.dupe(u8, stmt.columnText(0).?) catch return Error.OutOfMemory,
            .email = self.allocator.dupe(u8, stmt.columnText(1).?) catch return Error.OutOfMemory,
            .email_verified = stmt.columnInt(2) != 0,
            .created_at = stmt.columnInt(3),
        };
    }

    /// Get user by ID
    pub fn getUserById(self: *Auth, user_id: []const u8) Error!?User {
        var stmt = self.db.prepare(
            "SELECT id, email, email_verified, created_at FROM users WHERE id = ?1",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, user_id) catch return Error.DbError;

        const has_row = stmt.step() catch return Error.DbError;
        if (!has_row) return null;

        return User{
            .id = self.allocator.dupe(u8, stmt.columnText(0).?) catch return Error.OutOfMemory,
            .email = self.allocator.dupe(u8, stmt.columnText(1).?) catch return Error.OutOfMemory,
            .email_verified = stmt.columnInt(2) != 0,
            .created_at = stmt.columnInt(3),
        };
    }

    /// Check if any users exist (for setup wizard)
    pub fn hasUsers(self: *Auth) Error!bool {
        var stmt = self.db.prepare("SELECT 1 FROM users LIMIT 1") catch return Error.DbError;
        defer stmt.deinit();

        const has_row = stmt.step() catch return Error.DbError;
        return has_row;
    }

    /// Verify password for user (returns user_id if valid)
    pub fn authenticateUser(self: *Auth, email: []const u8, password: []const u8) Error![]const u8 {
        var stmt = self.db.prepare(
            "SELECT id, password_hash FROM users WHERE email = ?1",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, email) catch return Error.DbError;

        const has_row = stmt.step() catch return Error.DbError;
        if (!has_row) return Error.InvalidCredentials;

        const user_id = stmt.columnText(0).?;
        const stored_hash = stmt.columnText(1).?;

        try self.verifyPassword(password, stored_hash);

        return self.allocator.dupe(u8, user_id) catch return Error.OutOfMemory;
    }

    // =========================================================================
    // Session Management
    // =========================================================================

    /// Create a new session for user, returns token (id.secret format)
    pub fn createSession(self: *Auth, user_id: []const u8) Error![]const u8 {
        const session_id = try self.generateId("s_");
        defer self.allocator.free(session_id);

        // Generate 32 random bytes for secret
        var secret_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&secret_bytes);

        // Encode secret as hex for token
        const secret_hex = std.fmt.bytesToHex(secret_bytes, .lower);

        // Hash secret for storage
        var secret_hash: [32]u8 = undefined;
        Sha256.hash(&secret_bytes, &secret_hash, .{});

        const now = std.time.timestamp();
        const expires_at = now + SESSION_DURATION_SECS;

        var stmt = self.db.prepare(
            "INSERT INTO sessions (id, secret_hash, user_id, expires_at) VALUES (?1, ?2, ?3, ?4)",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, session_id) catch return Error.DbError;
        stmt.bindBlob(2, &secret_hash) catch return Error.DbError;
        stmt.bindText(3, user_id) catch return Error.DbError;
        stmt.bindInt(4, expires_at) catch return Error.DbError;

        _ = stmt.step() catch return Error.DbError;

        // Return token in id.secret format
        const token = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ session_id, secret_hex }) catch {
            return Error.OutOfMemory;
        };

        return token;
    }

    /// Validate session token, returns user if valid
    /// Also handles sliding expiration
    pub fn validateSession(self: *Auth, token: []const u8) Error!User {
        // Parse token: id.secret
        const dot_pos = std.mem.indexOf(u8, token, ".") orelse return Error.SessionNotFound;
        const session_id = token[0..dot_pos];
        const secret_hex = token[dot_pos + 1 ..];

        if (secret_hex.len != 64) return Error.SessionNotFound;

        // Decode hex secret
        var secret_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&secret_bytes, secret_hex) catch return Error.SessionNotFound;

        // Hash the provided secret
        var provided_hash: [32]u8 = undefined;
        Sha256.hash(&secret_bytes, &provided_hash, .{});

        // Look up session
        var stmt = self.db.prepare(
            "SELECT secret_hash, user_id, expires_at, created_at FROM sessions WHERE id = ?1",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, session_id) catch return Error.DbError;

        const has_row = stmt.step() catch return Error.DbError;
        if (!has_row) return Error.SessionNotFound;

        const stored_hash = stmt.columnBlob(0) orelse return Error.SessionNotFound;
        const user_id = stmt.columnText(1) orelse return Error.SessionNotFound;
        const expires_at = stmt.columnInt(2);
        const created_at = stmt.columnInt(3);

        // Constant-time comparison of hashes
        if (!std.crypto.timing_safe.eql([32]u8, stored_hash[0..32].*, provided_hash)) {
            return Error.SessionNotFound;
        }

        // Check expiry
        const now = std.time.timestamp();
        if (now > expires_at) {
            return Error.SessionExpired;
        }

        // Sliding expiration: extend if >50% of lifetime passed
        const elapsed = now - created_at;
        if (elapsed > SLIDING_THRESHOLD_SECS) {
            try self.extendSession(session_id, now + SESSION_DURATION_SECS);
        }

        // Get user
        const user = try self.getUserById(user_id) orelse return Error.UserNotFound;
        return user;
    }

    /// Extend session expiration
    fn extendSession(self: *Auth, session_id: []const u8, new_expires_at: i64) Error!void {
        var stmt = self.db.prepare(
            "UPDATE sessions SET expires_at = ?1 WHERE id = ?2",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindInt(1, new_expires_at) catch return Error.DbError;
        stmt.bindText(2, session_id) catch return Error.DbError;

        _ = stmt.step() catch return Error.DbError;
    }

    /// Invalidate session (logout)
    pub fn invalidateSession(self: *Auth, token: []const u8) Error!void {
        const dot_pos = std.mem.indexOf(u8, token, ".") orelse return Error.SessionNotFound;
        const session_id = token[0..dot_pos];

        var stmt = self.db.prepare("DELETE FROM sessions WHERE id = ?1") catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, session_id) catch return Error.DbError;
        _ = stmt.step() catch return Error.DbError;
    }

    /// Invalidate all sessions for user (e.g., on password change)
    pub fn invalidateAllSessions(self: *Auth, user_id: []const u8) Error!void {
        var stmt = self.db.prepare("DELETE FROM sessions WHERE user_id = ?1") catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, user_id) catch return Error.DbError;
        _ = stmt.step() catch return Error.DbError;
    }

    /// Clean up expired sessions
    pub fn cleanupExpiredSessions(self: *Auth) Error!u32 {
        const now = std.time.timestamp();

        var stmt = self.db.prepare("DELETE FROM sessions WHERE expires_at < ?1") catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindInt(1, now) catch return Error.DbError;
        _ = stmt.step() catch return Error.DbError;

        return @intCast(self.db.changes());
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Generate prefixed random ID (e.g., "u_abc123...")
    fn generateId(self: *Auth, prefix: []const u8) Error![]const u8 {
        var random_bytes: [12]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        const hex_buf = std.fmt.bytesToHex(random_bytes, .lower);

        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, hex_buf }) catch return Error.OutOfMemory;
    }

    /// Free user struct fields
    pub fn freeUser(self: *Auth, user: *User) void {
        self.allocator.free(user.id);
        self.allocator.free(user.email);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const initWithSchema = @import("db.zig").initWithSchema;

test "Auth: hash and verify password" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    const hash = try auth.hashPassword("mysecretpassword");
    defer testing.allocator.free(hash);

    // Correct password should verify
    try auth.verifyPassword("mysecretpassword", hash);

    // Wrong password should fail
    const result = auth.verifyPassword("wrongpassword", hash);
    try testing.expectError(Auth.Error.InvalidCredentials, result);
}

test "Auth: create and authenticate user" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    const user_id = try auth.createUser("test@example.com", "password123");
    defer testing.allocator.free(user_id);

    // Should start with "u_"
    try testing.expect(std.mem.startsWith(u8, user_id, "u_"));

    // Authenticate with correct password
    const auth_id = try auth.authenticateUser("test@example.com", "password123");
    defer testing.allocator.free(auth_id);
    try testing.expectEqualStrings(user_id, auth_id);

    // Wrong password should fail
    const bad_result = auth.authenticateUser("test@example.com", "wrongpassword");
    try testing.expectError(Auth.Error.InvalidCredentials, bad_result);

    // Non-existent user should fail
    const no_user = auth.authenticateUser("nobody@example.com", "password123");
    try testing.expectError(Auth.Error.InvalidCredentials, no_user);
}

test "Auth: hasUsers returns correct state" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    // Initially no users
    try testing.expect(!try auth.hasUsers());

    // After creating user
    const user_id = try auth.createUser("admin@example.com", "password");
    defer testing.allocator.free(user_id);

    try testing.expect(try auth.hasUsers());
}

test "Auth: session creation and validation" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    // Create user
    const user_id = try auth.createUser("user@example.com", "pass123");
    defer testing.allocator.free(user_id);

    // Create session
    const token = try auth.createSession(user_id);
    defer testing.allocator.free(token);

    // Token should be in id.secret format
    try testing.expect(std.mem.indexOf(u8, token, ".") != null);
    try testing.expect(std.mem.startsWith(u8, token, "s_"));

    // Validate session
    var user = try auth.validateSession(token);
    defer auth.freeUser(&user);

    try testing.expectEqualStrings(user_id, user.id);
    try testing.expectEqualStrings("user@example.com", user.email);
}

test "Auth: session invalidation" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    const user_id = try auth.createUser("user@example.com", "pass123");
    defer testing.allocator.free(user_id);

    const token = try auth.createSession(user_id);
    defer testing.allocator.free(token);

    // Invalidate session
    try auth.invalidateSession(token);

    // Validation should now fail
    const result = auth.validateSession(token);
    try testing.expectError(Auth.Error.SessionNotFound, result);
}

test "Auth: invalid token formats rejected" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    // No dot
    try testing.expectError(Auth.Error.SessionNotFound, auth.validateSession("nodothere"));

    // Wrong secret length
    try testing.expectError(Auth.Error.SessionNotFound, auth.validateSession("s_abc.tooshort"));

    // Non-existent session
    const fake_secret = "0" ** 64;
    try testing.expectError(Auth.Error.SessionNotFound, auth.validateSession("s_fake." ++ fake_secret));
}

test "Auth: invalidate all sessions for user" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    const user_id = try auth.createUser("user@example.com", "pass123");
    defer testing.allocator.free(user_id);

    // Create multiple sessions
    const token1 = try auth.createSession(user_id);
    defer testing.allocator.free(token1);
    const token2 = try auth.createSession(user_id);
    defer testing.allocator.free(token2);

    // Both should be valid
    var user1 = try auth.validateSession(token1);
    auth.freeUser(&user1);
    var user2 = try auth.validateSession(token2);
    auth.freeUser(&user2);

    // Invalidate all
    try auth.invalidateAllSessions(user_id);

    // Both should now be invalid
    try testing.expectError(Auth.Error.SessionNotFound, auth.validateSession(token1));
    try testing.expectError(Auth.Error.SessionNotFound, auth.validateSession(token2));
}

test "Auth: get user by email and id" {
    var db = try initWithSchema(testing.allocator, ":memory:");
    defer db.deinit();

    var auth = Auth.init(testing.allocator, &db);

    const user_id = try auth.createUser("find@example.com", "pass");
    defer testing.allocator.free(user_id);

    // By email
    var by_email = (try auth.getUserByEmail("find@example.com")).?;
    defer auth.freeUser(&by_email);
    try testing.expectEqualStrings(user_id, by_email.id);

    // By ID
    var by_id = (try auth.getUserById(user_id)).?;
    defer auth.freeUser(&by_id);
    try testing.expectEqualStrings("find@example.com", by_id.email);

    // Non-existent
    try testing.expect(try auth.getUserByEmail("nobody@example.com") == null);
    try testing.expect(try auth.getUserById("u_nonexistent") == null);
}
