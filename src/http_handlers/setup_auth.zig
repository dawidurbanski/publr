const std = @import("std");
const Context = @import("router").Context;
const tpl = @import("tpl");
const views = @import("views");
const csrf = @import("csrf");
const auth_middleware = @import("auth_middleware");
const Auth = @import("auth").Auth;
const url_mod = @import("url");

pub fn handleSetupGet(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    const has_users = auth_instance.hasUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };

    if (has_users) {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    }

    const content = tpl.render(views.admin.setup.Setup, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
        .bg_dark = false,
    }});
    ctx.html(content);
}

pub fn handleSetupPost(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    const has_users = auth_instance.hasUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };

    if (has_users) {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    }

    const email = ctx.formValue("email") orelse {
        return renderSetupError(ctx, "Email is required");
    };
    const password = ctx.formValue("password") orelse {
        return renderSetupError(ctx, "Password is required");
    };
    const confirm_password = ctx.formValue("confirm_password") orelse {
        return renderSetupError(ctx, "Please confirm your password");
    };

    const decoded_email = url_mod.formDecode(ctx.allocator, email) catch {
        return renderSetupError(ctx, "Invalid email format");
    };

    const auth_mod = @import("auth");
    if (!auth_mod.isValidEmail(decoded_email)) {
        return renderSetupError(ctx, "Invalid email format");
    }

    if (password.len < 8) {
        return renderSetupError(ctx, "Password must be at least 8 characters");
    }

    if (!std.mem.eql(u8, password, confirm_password)) {
        return renderSetupError(ctx, "Passwords do not match");
    }

    const display_name = defaultDisplayName(decoded_email);
    const user_id = auth_instance.createUser(decoded_email, display_name, password) catch |err| {
        switch (err) {
            Auth.Error.EmailExists => return renderSetupError(ctx, "An account with this email already exists"),
            else => return renderSetupError(ctx, "Failed to create account"),
        }
    };
    defer auth_instance.allocator.free(user_id);

    const token = auth_instance.createSession(user_id) catch {
        return renderSetupError(ctx, "Account created but failed to log in. Please try logging in.");
    };
    defer auth_instance.allocator.free(token);

    auth_middleware.setSessionCookie(ctx, token);

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin");
    ctx.response.setBody("");
}

pub fn handleLoginGet(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    const has_users = auth_instance.hasUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };

    if (!has_users) {
        ctx.response.setStatus("302 Found");
        ctx.response.setHeader("Location", "/admin/setup");
        ctx.response.setBody("");
        return;
    }

    const content = tpl.render(views.admin.login.Login, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
    }});
    ctx.html(content);
}

pub fn handleLoginPost(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    const email = ctx.formValue("email") orelse {
        return renderLoginError(ctx, "Email is required");
    };
    const password = ctx.formValue("password") orelse {
        return renderLoginError(ctx, "Password is required");
    };

    const decoded_email = url_mod.formDecode(ctx.allocator, email) catch {
        return renderLoginError(ctx, "Invalid email format");
    };

    const user_id = auth_instance.authenticateUser(decoded_email, password) catch {
        return renderLoginError(ctx, "Invalid email or password");
    };
    defer auth_instance.allocator.free(user_id);

    const token = auth_instance.createSession(user_id) catch {
        return renderLoginError(ctx, "Failed to create session");
    };
    defer auth_instance.allocator.free(token);

    auth_middleware.setSessionCookie(ctx, token);

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin");
    ctx.response.setBody("");
}

pub fn handleLogout(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("302 Found");
        ctx.response.setHeader("Location", "/admin/login");
        ctx.response.setBody("");
        return;
    };

    if (auth_middleware.parseCookie(ctx, auth_middleware.SESSION_COOKIE)) |token| {
        auth_instance.invalidateSession(token) catch {};
    }

    auth_middleware.clearSessionCookie(ctx);

    ctx.response.setStatus("302 Found");
    ctx.response.setHeader("Location", "/admin/login");
    ctx.response.setBody("");
}

fn renderSetupError(ctx: *Context, message: []const u8) void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.render(views.admin.setup.Setup, .{.{
        .error_message = message,
        .csrf_token = csrf_token,
        .bg_dark = false,
    }});
    ctx.html(content);
}

fn renderLoginError(ctx: *Context, message: []const u8) void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.render(views.admin.login.Login, .{.{
        .error_message = message,
        .csrf_token = csrf_token,
    }});
    ctx.html(content);
}

fn defaultDisplayName(email: []const u8) []const u8 {
    const at_pos = std.mem.indexOf(u8, email, "@") orelse return email;
    if (at_pos == 0) return email;
    return email[0..at_pos];
}
