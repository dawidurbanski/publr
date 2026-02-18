//! Auth & CSRF Plugin API
//!
//! Wraps auth_middleware and csrf modules for plugins.
//! Provides request-scoped helpers (bound API), middleware functions,
//! constants, types, and auth instance access for user management.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! fn handle(ctx: *publr.Context) !void {
//!     const auth = publr.auth(ctx);
//!     const user_id = auth.getUserId() orelse return;
//!     const csrf_token = auth.ensureToken();
//!
//!     // User management via auth instance
//!     const auth_instance = publr.Auth.instance() orelse return;
//!     var user = (auth_instance.getUserById(user_id) catch return) orelse return;
//!     defer auth_instance.freeUser(&user);
//! }
//! ```

const auth_middleware = @import("auth_middleware");
const csrf = @import("csrf");
const auth = @import("auth");
const Context = @import("middleware").Context;

// =========================================================================
// Bound API (request-scoped)
// =========================================================================

/// Create a bound auth API for the current request context.
pub fn init(ctx: *Context) AuthApi {
    return .{ .ctx = ctx };
}

pub const AuthApi = struct {
    ctx: *Context,

    /// Get authenticated user ID from context (set by authMiddleware).
    pub fn getUserId(self: @This()) ?[]const u8 {
        return auth_middleware.getUserId(self.ctx);
    }

    /// Get authenticated user email from context.
    pub fn getUserEmail(self: @This()) ?[]const u8 {
        return auth_middleware.getUserEmail(self.ctx);
    }

    /// Parse a cookie value from the request Cookie header.
    pub fn parseCookie(self: @This(), name: []const u8) ?[]const u8 {
        return auth_middleware.parseCookie(self.ctx, name);
    }

    /// Set session cookie on the response.
    pub fn setSessionCookie(self: @This(), token: []const u8) void {
        auth_middleware.setSessionCookie(self.ctx, token);
    }

    /// Clear session cookie on the response.
    pub fn clearSessionCookie(self: @This()) void {
        auth_middleware.clearSessionCookie(self.ctx);
    }

    /// Ensure a CSRF token exists (reads from cookie or generates new one).
    pub fn ensureToken(self: @This()) []const u8 {
        return csrf.ensureToken(self.ctx);
    }
};

// =========================================================================
// Middleware (not request-scoped — used in middleware chain setup)
// =========================================================================

pub const authMiddleware = auth_middleware.authMiddleware;
pub const csrfMiddleware = csrf.csrfMiddleware;

// =========================================================================
// Constants
// =========================================================================

pub const SESSION_COOKIE = auth_middleware.SESSION_COOKIE;
pub const CSRF_COOKIE = csrf.CSRF_COOKIE;
pub const CSRF_FIELD = csrf.CSRF_FIELD;

// =========================================================================
// Types (for user management)
// =========================================================================

pub const User = auth.Auth.User;
pub const Error = auth.Auth.Error;

// =========================================================================
// Auth Instance Access (for user management — NOT request-scoped)
// =========================================================================

/// Get the auth instance for user management operations.
/// Returns null if auth has not been initialized (e.g., during startup).
pub fn instance() ?*auth.Auth {
    return auth_middleware.auth;
}
