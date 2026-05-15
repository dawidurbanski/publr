//! Settings plugin - site configuration and admin settings
//!
//! Each tab is a separately-registered admin page. Sub-pages have parent="settings"
//! so they're excluded from the sidebar nav, but they appear in the SettingsTabs
//! component rendered by each view.

const std = @import("std");
const admin = @import("admin_api");
const tpl = @import("tpl");
const Auth = @import("auth").Auth;
const csrf = @import("csrf");
const auth_middleware = @import("auth_middleware");
const views = @import("views");
const publr_config = @import("publr_config");

// =============================================================================
// Page registrations
// =============================================================================

fn noopSetup(_: *admin.PageApp) void {}

// Settings is a metadata-only parent. The actual /admin/settings route is owned
// by page_general (a child with path "/" — resolves to the parent's path).
const page_settings = admin.registerPage(.{
    .id = "settings",
    .title = "Settings",
    .path = "/settings",
    .icon = .settings,
    .position = 100,
    .setup = noopSetup,
});

const page_general = admin.registerPage(.{
    .id = "settings.general",
    .title = "General",
    .path = "/",
    .parent = "settings",
    .view = views.admin.settings.general.General,
});

const page_users = admin.registerPage(.{
    .id = "settings.users",
    .title = "Users",
    .path = "/users",
    .parent = "settings",
    .setup = setupUsers,
});

const page_users_new = admin.registerPage(.{
    .id = "settings.users.new",
    .title = "Add User",
    .path = "/new",
    .parent = "settings.users",
    .view = views.admin.users.new.New,
    .loader = loadUsersNew,
});

const page_users_edit = admin.registerPage(.{
    .id = "settings.users.edit",
    .title = "Edit User",
    .path = "/:id",
    .parent = "settings.users",
    .view = views.admin.users.edit.Edit,
    .loader = loadUsersEdit,
});

const page_system = admin.registerPage(.{
    .id = "settings.system",
    .title = "System",
    .path = "/system",
    .parent = "settings",
    .view = views.admin.system.System,
    .loader = loadSystem,
});

pub const pages = [_]admin.Page{
    page_settings,
    page_general,
    page_users,
    page_users_new,
    page_users_edit,
    page_system,
};

// =============================================================================
// Tabs — derived from direct children of "settings" at comptime.
// Add a new tab by registering a page with parent="settings"; it appears here.
// =============================================================================

const Tab = struct {
    label: []const u8,
    href: []const u8,
    key: []const u8,
};

pub const tabs = blk: {
    var count: usize = 0;
    for (pages) |p| if (p.parent) |par| {
        if (std.mem.eql(u8, par, "settings")) count += 1;
    };
    var t: [count]Tab = undefined;
    var i: usize = 0;
    for (pages) |p| if (p.parent) |par| {
        if (std.mem.eql(u8, par, "settings")) {
            t[i] = .{
                .label = p.title,
                .href = admin.resolvePagePath(p, &pages),
                .key = p.id,
            };
            i += 1;
        }
    };
    const final = t;
    break :blk &final;
};

// =============================================================================
// settings.users — manual setup for GET list + POST handlers
// =============================================================================

fn setupUsers(app: *admin.PageApp) void {
    app.render(handleUserList);
    app.action("settings.user_create", handleUserCreate);
    app.action("settings.user_update", handleUserUpdate);
    app.action("settings.user_delete", handleUserDelete);
}

fn handleUserList(ctx: *admin.Context) !void {
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

    var view_users: std.ArrayListUnmanaged(views.admin.users.list.User) = .{};
    for (users) |user| {
        const edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/settings/users/{s}", .{user.id}) catch continue;
        const delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/settings/users/{s}/delete", .{user.id}) catch continue;
        view_users.append(ctx.allocator, .{
            .id = user.id,
            .display_name = user.display_name,
            .email = user.email,
            .edit_url = edit_url,
            .delete_url = delete_url,
        }) catch continue;
    }

    const content = tpl.render(views.admin.users.list.List, .{views.admin.users.list.Props{
        .has_users = view_users.items.len > 0,
        .users = view_users.items,
        .csrf_token = csrf_token,
    }});

    ctx.html(admin.renderWithLayout(page_users.id, page_users.title, ctx, content, ""));
}

fn handleUserCreate(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };

    const display_name = ctx.formValue("display_name") orelse return renderNewError(ctx, "Display name is required");
    const email = ctx.formValue("email") orelse return renderNewError(ctx, "Email is required");
    const password = ctx.formValue("password") orelse return renderNewError(ctx, "Password is required");

    const user_id = auth_instance.createUser(email, display_name, password) catch |err| {
        const msg = switch (err) {
            Auth.Error.EmailExists => "An account with this email already exists",
            else => "Failed to create user",
        };
        return renderNewError(ctx, msg);
    };
    auth_instance.allocator.free(user_id);

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/settings/users");
    ctx.response.setBody("");
}

fn renderNewError(ctx: *admin.Context, message: []const u8) void {
    const csrf_token = csrf.ensureToken(ctx);
    const content = tpl.render(views.admin.users.new.New, .{views.admin.users.new.Props{
        .error_message = message,
        .csrf_token = csrf_token,
    }});
    ctx.html(admin.renderWithLayout(page_users_new.id, page_users_new.title, ctx, content, ""));
}

fn handleUserUpdate(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const user_id = ctx.formValue("user_id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    const display_name = ctx.formValue("display_name") orelse "";
    const email = ctx.formValue("email") orelse "";

    const password_raw = ctx.formValue("password");
    const password: ?[]const u8 = if (password_raw) |p| (if (p.len > 0) p else null) else null;

    auth_instance.updateUser(user_id, email, display_name, password) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Failed to update user");
        return;
    };

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/settings/users");
    ctx.response.setBody("");
}

fn handleUserDelete(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const user_id = ctx.formValue("user_id") orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setBody("Not Found");
        return;
    };

    auth_instance.deleteUser(user_id) catch {};

    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/settings/users");
    ctx.response.setBody("");
}

// =============================================================================
// Loaders (declarative pages)
// =============================================================================

fn loadUsersNew(ctx: *admin.Context) !views.admin.users.new.Props {
    return .{
        .error_message = "",
        .csrf_token = csrf.ensureToken(ctx),
    };
}

fn loadUsersEdit(ctx: *admin.Context) !views.admin.users.edit.Props {
    const auth_instance = auth_middleware.auth orelse return error.AuthNotInitialized;
    const user_id = ctx.param("id") orelse return error.UserIdMissing;

    var user = (try auth_instance.getUserById(user_id)) orelse return error.UserNotFound;
    defer auth_instance.freeUser(&user);

    return .{
        .error_message = "",
        .user = .{
            .id = try ctx.allocator.dupe(u8, user.id),
            .display_name = try ctx.allocator.dupe(u8, if (user.display_name.len > 0) user.display_name else user.email),
            .email = try ctx.allocator.dupe(u8, user.email),
        },
        .csrf_token = csrf.ensureToken(ctx),
        .action_url = try std.fmt.allocPrint(ctx.allocator, "/admin/settings/users/{s}", .{user_id}),
    };
}

fn loadSystem(ctx: *admin.Context) !views.admin.system.Props {
    return .{
        .csrf_token = csrf.ensureToken(ctx),
        .config_text = if (@hasField(@TypeOf(publr_config), "configText")) publr_config.configText else "",
    };
}
