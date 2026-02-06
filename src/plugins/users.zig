//! Users plugin - user management pages

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const Auth = @import("auth").Auth;
const csrf = @import("csrf");
const auth_middleware = @import("auth_middleware");
const zsx_admin_users_list = @import("zsx_admin_users_list");
const zsx_admin_users_new = @import("zsx_admin_users_new");
const zsx_admin_users_edit = @import("zsx_admin_users_edit");
const zsx_admin_users_profile = @import("zsx_admin_users_profile");
const registry = @import("registry");

/// Users parent page (nav item with submenu, also handles list/edit routes)
pub const page = admin.registerPage(.{
    .id = "users",
    .title = "Users",
    .path = "/users",
    .icon = icons.users,
    .position = 30,
    .setup = setup,
});

/// All users list (for nav display only - points to same path as parent)
pub const page_all = admin.registerPage(.{
    .id = "users.all",
    .title = "All Users",
    .path = "/",
    .parent = "users",
    .position = 5,
    .setup = setupNoop,
});

/// Add new user (shows in Users submenu)
pub const page_new = admin.registerPage(.{
    .id = "users.new",
    .title = "Add New",
    .path = "/new",
    .parent = "users",
    .position = 10,
    .setup = setupNew,
});

/// User profile (shows in Users submenu)
pub const page_profile = admin.registerPage(.{
    .id = "users.profile",
    .title = "Profile",
    .path = "/profile",
    .parent = "users",
    .position = 20,
    .setup = setupProfile,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleList);
    app.get("/:id", handleEdit);
    app.postAt("/:id", handleUpdate);
    app.postAt("/:id/delete", handleDelete);
}

fn setupNoop(_: *admin.PageApp) void {}

fn setupNew(app: *admin.PageApp) void {
    app.render(handleNew);
    app.post(handleCreate);
}

fn setupProfile(app: *admin.PageApp) void {
    app.render(handleProfile);
    app.post(handleProfileUpdate);
}

// =============================================================================
// Handlers
// =============================================================================

fn handleList(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);

    const users = auth_instance.listUsers() catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };
    defer auth_instance.freeUsers(users);

    const ViewUser = struct {
        id: []const u8,
        display_name: []const u8,
        email: []const u8,
        edit_url: []const u8,
        delete_url: []const u8,
    };

    var view_users: std.ArrayListUnmanaged(ViewUser) = .{};
    defer {
        for (view_users.items) |vu| {
            ctx.allocator.free(vu.edit_url);
            ctx.allocator.free(vu.delete_url);
        }
        view_users.deinit(ctx.allocator);
    }

    for (users) |user| {
        const edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/users/{s}", .{user.id}) catch continue;
        const delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/users/{s}/delete", .{user.id}) catch {
            ctx.allocator.free(edit_url);
            continue;
        };

        view_users.append(ctx.allocator, .{
            .id = user.id,
            .display_name = user.display_name,
            .email = user.email,
            .edit_url = edit_url,
            .delete_url = delete_url,
        }) catch {
            ctx.allocator.free(edit_url);
            ctx.allocator.free(delete_url);
            continue;
        };
    }

    const content = tpl.render(zsx_admin_users_list.List, .{.{
        .has_users = view_users.items.len > 0,
        .users = view_users.items,
        .csrf_token = csrf_token,
    }});

    const actions = "<a href=\"/admin/users/new\" class=\"btn btn-primary\">Add New</a>";
    ctx.html(registry.renderPage(page_all, ctx, content, actions));
}

fn handleNew(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.render(zsx_admin_users_new.New, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
    }});
    ctx.html(registry.renderPage(page_new, ctx, content, ""));
}

fn handleCreate(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    const display_name = ctx.formValue("display_name") orelse {
        return renderNewError(ctx, "Display name is required");
    };
    const email = ctx.formValue("email") orelse {
        return renderNewError(ctx, "Email is required");
    };
    const password = ctx.formValue("password") orelse {
        return renderNewError(ctx, "Password is required");
    };

    const user_id = auth_instance.createUser(email, display_name, password) catch |err| {
        const msg = switch (err) {
            Auth.Error.EmailExists => "An account with this email already exists",
            else => "Failed to create user",
        };
        return renderNewError(ctx, msg);
    };
    auth_instance.allocator.free(user_id);

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users");
    ctx.response.setBody("");
}

fn handleEdit(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);
    const user_id = ctx.param("id") orelse {
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

    const content = tpl.render(zsx_admin_users_edit.Edit, .{.{
        .error_message = "",
        .user = .{
            .id = user.id,
            .display_name = if (user.display_name.len > 0) user.display_name else user.email,
            .email = user.email,
        },
        .csrf_token = csrf_token,
    }});

    ctx.html(registry.renderPage(page_all, ctx, content, ""));
}

fn handleUpdate(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const user_id = ctx.param("id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    const display_name = ctx.formValue("display_name") orelse "";
    const email = ctx.formValue("email") orelse "";
    const password = ctx.formValue("password");

    auth_instance.updateUser(user_id, email, display_name, password) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Failed to update user");
        return;
    };

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users");
    ctx.response.setBody("");
}

fn handleDelete(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const user_id = ctx.param("id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    auth_instance.deleteUser(user_id) catch {};

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users");
    ctx.response.setBody("");
}

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

    ctx.html(registry.renderPage(page_profile, ctx, content, ""));
}

fn handleProfileUpdate(ctx: *Context) !void {
    // TODO: Implement profile update
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/users/profile");
    ctx.response.setBody("");
}

// =============================================================================
// Helpers
// =============================================================================

fn renderNewError(ctx: *Context, message: []const u8) void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.render(zsx_admin_users_new.New, .{.{
        .error_message = message,
        .csrf_token = csrf_token,
    }});
    ctx.html(registry.renderPage(page_new, ctx, content, ""));
}
