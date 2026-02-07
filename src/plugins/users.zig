//! Users plugin - user profile page only
//!
//! User management (list, create, edit, delete) has moved to Settings.
//! This plugin only handles the current user's profile at /admin/users/profile.

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const Auth = @import("auth").Auth;
const csrf = @import("csrf");
const auth_middleware = @import("auth_middleware");
const zsx_admin_users_profile = @import("zsx_admin_users_profile");
const registry = @import("registry");

/// Users page - only used as parent for profile, hidden from nav
pub const page = admin.registerPage(.{
    .id = "users",
    .title = "Users",
    .path = "/users",
    .icon = icons.users,
    .position = 30,
    .setup = setup,
});

/// User profile page
pub const page_profile = admin.registerPage(.{
    .id = "users.profile",
    .title = "Profile",
    .path = "/profile",
    .parent = "users",
    .position = 10,
    .setup = setupProfile,
});

fn setup(_: *admin.PageApp) void {
    // No routes on the parent - user management is in Settings now
}

fn setupProfile(app: *admin.PageApp) void {
    app.render(handleProfile);
    app.post(handleProfileUpdate);
}

// =============================================================================
// Profile Handlers
// =============================================================================

fn handleProfile(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);
    const user_id = auth_middleware.getUserId(ctx) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    var user = (auth_instance.getUserById(user_id) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    }) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };
    defer auth_instance.freeUser(&user);

    const content = tpl.render(zsx_admin_users_profile.Profile, .{.{
        .error_message = "",
        .user = .{
            .id = user.id,
            .display_name = if (user.display_name.len > 0) user.display_name else user.email,
            .email = user.email,
        },
        .csrf_token = csrf_token,
    }});

    ctx.html(registry.renderPage(page_profile, ctx, content));
}

fn handleProfileUpdate(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const user_id = auth_middleware.getUserId(ctx) orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    const display_name = ctx.formValue("display_name") orelse "";
    const email = ctx.formValue("email") orelse "";
    // Only pass password if non-empty (empty string means "keep current password")
    const password_raw = ctx.formValue("password");
    const password: ?[]const u8 = if (password_raw) |p| (if (p.len > 0) p else null) else null;

    auth_instance.updateUser(user_id, email, display_name, password) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Failed to update profile");
        return;
    };

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users/profile");
    ctx.response.setBody("");
}
