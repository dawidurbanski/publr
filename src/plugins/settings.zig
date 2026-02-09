//! Settings plugin - site configuration and admin settings
//!
//! Provides a tabbed settings interface for:
//! - General settings (site name, etc.)
//! - User management (list, create, edit, delete)
//! - Components showcase
//! - Design system reference

const std = @import("std");
const admin = @import("admin_api");
const icons = @import("icons");
const Context = @import("middleware").Context;
const tpl = @import("tpl");
const Auth = @import("auth").Auth;
const csrf = @import("csrf");
const auth_middleware = @import("auth_middleware");
const views = @import("views");
const registry = @import("registry");

/// Settings page - hidden from nav (accessed via sidebar footer)
pub const page = admin.registerPage(.{
    .id = "settings",
    .title = "Settings",
    .path = "/settings",
    .icon = icons.settings,
    .position = 100, // High position so it's last if shown
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    // General settings
    app.render(handleGeneral);

    // User management routes
    app.get("/users", handleUserList);
    app.get("/users/new", handleUserNew);
    app.get("/users/:id", handleUserEdit);
    app.postAt("/users", handleUserCreate);
    app.postAt("/users/:id", handleUserUpdate);
    app.postAt("/users/:id/delete", handleUserDelete);

    // Components and Design System
    app.get("/components", handleComponents);
    app.get("/design", handleDesign);
}

// =============================================================================
// Tab Bar
// =============================================================================

const Tab = struct {
    label: []const u8,
    path: []const u8,
    prefix: []const u8, // Path prefix for active matching
};

const tabs = [_]Tab{
    .{ .label = "General", .path = "/admin/settings", .prefix = "/admin/settings" },
    .{ .label = "Users", .path = "/admin/settings/users", .prefix = "/admin/settings/users" },
    .{ .label = "Components", .path = "/admin/settings/components", .prefix = "/admin/settings/components" },
    .{ .label = "Design", .path = "/admin/settings/design", .prefix = "/admin/settings/design" },
};

fn renderTabBar(allocator: std.mem.Allocator, current_path: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    writer.writeAll("<nav class=\"settings-tabs\">") catch return "";

    for (tabs) |tab| {
        const is_active = isTabActive(current_path, tab);
        const class = if (is_active) "settings-tab active" else "settings-tab";
        writer.print("<a href=\"{s}\" class=\"{s}\">{s}</a>", .{ tab.path, class, tab.label }) catch continue;
    }

    writer.writeAll("</nav>") catch return "";

    return buf.toOwnedSlice(allocator) catch "";
}

fn isTabActive(current_path: []const u8, tab: Tab) bool {
    // General tab: active only on exact /admin/settings
    if (std.mem.eql(u8, tab.prefix, "/admin/settings")) {
        return std.mem.eql(u8, current_path, "/admin/settings");
    }
    // Other tabs: active on prefix match
    return std.mem.startsWith(u8, current_path, tab.prefix);
}

// =============================================================================
// General Settings
// =============================================================================

fn handleGeneral(ctx: *Context) !void {
    const tab_bar = renderTabBar(ctx.allocator, "/admin/settings");
    const content =
        \\<div class="form-section">
        \\    <h2 class="form-section-title">Site Settings</h2>
        \\    <p class="form-section-desc">Configure your site's basic settings.</p>
        \\    <div class="empty-state">
        \\        <p>General settings coming soon.</p>
        \\    </div>
        \\</div>
    ;
    ctx.html(registry.renderPageWith(page, ctx, content, tab_bar));
}

// =============================================================================
// User Management
// =============================================================================

fn handleUserList(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);
    const tab_bar = renderTabBar(ctx.allocator, "/admin/settings/users");

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
        const edit_url = std.fmt.allocPrint(ctx.allocator, "/admin/settings/users/{s}", .{user.id}) catch continue;
        const delete_url = std.fmt.allocPrint(ctx.allocator, "/admin/settings/users/{s}/delete", .{user.id}) catch {
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

    const content = tpl.render(views.admin.users.list.List, .{.{
        .has_users = view_users.items.len > 0,
        .users = view_users.items,
        .csrf_token = csrf_token,
    }});

    ctx.html(registry.renderPageWith(page, ctx, content, tab_bar));
}

fn handleUserNew(ctx: *Context) !void {
    const csrf_token = csrf.ensureToken(ctx);
    const tab_bar = renderTabBar(ctx.allocator, "/admin/settings/users");
    const content = tpl.render(views.admin.users.new.New, .{.{
        .error_message = "",
        .csrf_token = csrf_token,
    }});
    ctx.html(registry.renderPageWith(page, ctx, content, tab_bar));
}

fn handleUserCreate(ctx: *Context) !void {
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
    ctx.response.setHeader("Location", "/admin/settings/users");
    ctx.response.setBody("");
}

fn handleUserEdit(ctx: *Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const csrf_token = csrf.ensureToken(ctx);
    const tab_bar = renderTabBar(ctx.allocator, "/admin/settings/users");
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

    const action_url = std.fmt.allocPrint(ctx.allocator, "/admin/settings/users/{s}", .{user_id}) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Memory error");
        return;
    };

    const content = tpl.render(views.admin.users.edit.Edit, .{.{
        .error_message = "",
        .user = .{
            .id = user.id,
            .display_name = if (user.display_name.len > 0) user.display_name else user.email,
            .email = user.email,
        },
        .csrf_token = csrf_token,
        .action_url = action_url,
    }});

    ctx.html(registry.renderPageWith(page, ctx, content, tab_bar));
}

fn handleUserUpdate(ctx: *Context) !void {
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

    // Only pass password if non-empty (empty string means "keep current password")
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

fn handleUserDelete(ctx: *Context) !void {
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
    ctx.response.setHeader("Location", "/admin/settings/users");
    ctx.response.setBody("");
}

fn renderNewError(ctx: *Context, message: []const u8) void {
    const csrf_token = csrf.ensureToken(ctx);
    const tab_bar = renderTabBar(ctx.allocator, "/admin/settings/users");
    const content = tpl.render(views.admin.users.new.New, .{.{
        .error_message = message,
        .csrf_token = csrf_token,
    }});
    ctx.html(registry.renderPageWith(page, ctx, content, tab_bar));
}

// =============================================================================
// Components Showcase
// =============================================================================

fn handleComponents(ctx: *Context) !void {
    const tab_bar = renderTabBar(ctx.allocator, "/admin/settings/components");
    const content = tpl.renderStatic(views.admin.components.Components);
    ctx.html(registry.renderPageWith(page, ctx, content, tab_bar));
}

// =============================================================================
// Design System
// =============================================================================

fn handleDesign(ctx: *Context) !void {
    const tab_bar = renderTabBar(ctx.allocator, "/admin/settings/design");
    const content = tpl.renderStatic(views.admin.design_system.DesignSystem);
    ctx.html(registry.renderPageWith(page, ctx, content, tab_bar));
}
