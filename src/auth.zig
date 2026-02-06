const std = @import("std");
const Db = @import("db").Db;
const Statement = @import("db").Statement;

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
        display_name: []const u8,
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
    pub fn createUser(self: *Auth, email: []const u8, display_name: []const u8, password: []const u8) Error![]const u8 {
        const password_hash = try self.hashPassword(password);
        defer self.allocator.free(password_hash);

        const user_id = try self.generateId("u_");
        errdefer self.allocator.free(user_id);

        var stmt = self.db.prepare(
            "INSERT INTO users (id, email, display_name, password_hash) VALUES (?1, ?2, ?3, ?4)",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, user_id) catch return Error.DbError;
        stmt.bindText(2, email) catch return Error.DbError;
        stmt.bindText(3, display_name) catch return Error.DbError;
        stmt.bindText(4, password_hash) catch return Error.DbError;

        _ = stmt.step() catch return Error.EmailExists;

        return user_id;
    }

    /// Get user by email (for login)
    pub fn getUserByEmail(self: *Auth, email: []const u8) Error!?User {
        var stmt = self.db.prepare(
            "SELECT id, email, display_name, email_verified, created_at FROM users WHERE email = ?1",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, email) catch return Error.DbError;

        const has_row = stmt.step() catch return Error.DbError;
        if (!has_row) return null;

        return User{
            .id = self.allocator.dupe(u8, stmt.columnText(0).?) catch return Error.OutOfMemory,
            .email = self.allocator.dupe(u8, stmt.columnText(1).?) catch return Error.OutOfMemory,
            .display_name = self.allocator.dupe(u8, stmt.columnText(2) orelse "") catch return Error.OutOfMemory,
            .email_verified = stmt.columnInt(3) != 0,
            .created_at = stmt.columnInt(4),
        };
    }

    /// Get user by ID
    pub fn getUserById(self: *Auth, user_id: []const u8) Error!?User {
        var stmt = self.db.prepare(
            "SELECT id, email, display_name, email_verified, created_at FROM users WHERE id = ?1",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, user_id) catch return Error.DbError;

        const has_row = stmt.step() catch return Error.DbError;
        if (!has_row) return null;

        return User{
            .id = self.allocator.dupe(u8, stmt.columnText(0).?) catch return Error.OutOfMemory,
            .email = self.allocator.dupe(u8, stmt.columnText(1).?) catch return Error.OutOfMemory,
            .display_name = self.allocator.dupe(u8, stmt.columnText(2) orelse "") catch return Error.OutOfMemory,
            .email_verified = stmt.columnInt(3) != 0,
            .created_at = stmt.columnInt(4),
        };
    }

    /// List all users
    pub fn listUsers(self: *Auth) Error![]User {
        var stmt = self.db.prepare(
            "SELECT id, email, display_name, email_verified, created_at FROM users ORDER BY created_at DESC",
        ) catch return Error.DbError;
        defer stmt.deinit();

        var users: std.ArrayListUnmanaged(User) = .{};
        errdefer {
            for (users.items) |*user| self.freeUser(user);
            users.deinit(self.allocator);
        }

        while (stmt.step() catch return Error.DbError) {
            const id = stmt.columnText(0) orelse continue;
            const email = stmt.columnText(1) orelse "";
            const display_name = stmt.columnText(2) orelse "";
            const user = User{
                .id = self.allocator.dupe(u8, id) catch return Error.OutOfMemory,
                .email = self.allocator.dupe(u8, email) catch return Error.OutOfMemory,
                .display_name = self.allocator.dupe(u8, display_name) catch return Error.OutOfMemory,
                .email_verified = stmt.columnInt(3) != 0,
                .created_at = stmt.columnInt(4),
            };
            users.append(self.allocator, user) catch return Error.OutOfMemory;
        }

        return users.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
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

    /// Update user fields (email/display name) and optionally password
    pub fn updateUser(self: *Auth, user_id: []const u8, email: []const u8, display_name: []const u8, password: ?[]const u8) Error!void {
        if (password) |pwd| {
            const password_hash = try self.hashPassword(pwd);
            defer self.allocator.free(password_hash);

            var stmt = self.db.prepare(
                "UPDATE users SET email = ?1, display_name = ?2, password_hash = ?3 WHERE id = ?4",
            ) catch return Error.DbError;
            defer stmt.deinit();

            stmt.bindText(1, email) catch return Error.DbError;
            stmt.bindText(2, display_name) catch return Error.DbError;
            stmt.bindText(3, password_hash) catch return Error.DbError;
            stmt.bindText(4, user_id) catch return Error.DbError;

            _ = stmt.step() catch return Error.EmailExists;
            return;
        }

        var stmt = self.db.prepare(
            "UPDATE users SET email = ?1, display_name = ?2 WHERE id = ?3",
        ) catch return Error.DbError;
        defer stmt.deinit();

        stmt.bindText(1, email) catch return Error.DbError;
        stmt.bindText(2, display_name) catch return Error.DbError;
        stmt.bindText(3, user_id) catch return Error.DbError;

        _ = stmt.step() catch return Error.EmailExists;
    }

    /// Delete a user (sessions cascade)
    pub fn deleteUser(self: *Auth, user_id: []const u8) Error!void {
        var stmt = self.db.prepare("DELETE FROM users WHERE id = ?1") catch return Error.DbError;
        defer stmt.deinit();
        stmt.bindText(1, user_id) catch return Error.DbError;
        _ = stmt.step() catch return Error.DbError;
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
        self.allocator.free(user.display_name);
    }

    pub fn freeUsers(self: *Auth, users: []User) void {
        for (users) |*user| self.freeUser(user);
        self.allocator.free(users);
    }
};

// Note: Auth tests require integration testing with a full database.
// These belong in a separate integration test suite, not unit tests.
