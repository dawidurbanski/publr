//! Shared routing and handler logic for both server and WASM entry points
//! Single dispatch function handles all routes - add routes once, works everywhere

const std = @import("std");
const tpl = @import("tpl.zig");
const db_mod = @import("db.zig");
const Auth = @import("auth.zig").Auth;

// Templates
const zsx_admin_layout = @import("zsx_admin_layout");
const zsx_admin_dashboard = @import("zsx_admin_dashboard");
const zsx_admin_posts_list = @import("zsx_admin_posts_list");
const zsx_admin_posts_edit = @import("zsx_admin_posts_edit");
const zsx_admin_users_list = @import("zsx_admin_users_list");
const zsx_admin_users_new = @import("zsx_admin_users_new");
const zsx_admin_users_edit = @import("zsx_admin_users_edit");
const zsx_admin_users_profile = @import("zsx_admin_users_profile");
const zsx_admin_setup = @import("zsx_admin_setup");
const zsx_admin_login = @import("zsx_admin_login");
const zsx_admin_components = @import("zsx_admin_components");
const zsx_admin_design_system = @import("zsx_admin_design_system");

// =============================================================================
// Types
// =============================================================================

pub const Method = enum { GET, POST };

/// Result of route dispatch - caller converts to their response format
pub const RouteResult = union(enum) {
    html: []const u8,
    redirect: []const u8,
    redirect_with_token: struct { path: []const u8, token: []const u8 },
    static_css: []const u8,
    static_js: []const u8,
    not_found: void,
    server_error: []const u8,
    needs_setup: void,
    needs_auth: void,
};

/// Request context passed to dispatch
pub const RequestContext = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
    db: *db_mod.Db,
    auth: *Auth,
    session_valid: bool,
    csrf_token: []const u8,
    allocator: std.mem.Allocator,

    // Embedded static assets (passed from caller)
    admin_css: []const u8,
    admin_js: []const u8,
};

/// Navigation state for admin layout
pub const NavState = struct {
    dashboard: bool = false,
    posts: bool = false,
    users: bool = false,
    users_all: bool = false,
    users_new: bool = false,
    users_profile: bool = false,
    settings: bool = false,
    components: bool = false,
    design_system: bool = false,

    pub const dashboard_active = NavState{ .dashboard = true };
    pub const posts_active = NavState{ .posts = true };
    pub const users_list_active = NavState{ .users = true, .users_all = true };
    pub const users_new_active = NavState{ .users = true, .users_new = true };
    pub const users_profile_active = NavState{ .users = true, .users_profile = true };
    pub const settings_active = NavState{ .settings = true };
    pub const components_active = NavState{ .components = true };
    pub const design_system_active = NavState{ .design_system = true };
};

/// Post data for list view
pub const PostListItem = struct {
    id: []const u8,
    title: []const u8,
    author: []const u8,
    status: []const u8,
    date: []const u8,
};

/// Post data for edit view
pub const PostEditData = struct {
    title: []const u8,
    slug: []const u8,
    content: []const u8,
    date: []const u8,
    is_draft: bool,
    is_published: bool,
};

/// User data for list view
pub const UserListItem = struct {
    id: []const u8,
    display_name: []const u8,
    email: []const u8,
    edit_url: []const u8,
    delete_url: []const u8,
};

// =============================================================================
// Main Dispatch - ALL ROUTES DEFINED HERE
// =============================================================================

pub fn dispatch(ctx: RequestContext) RouteResult {
    const path = ctx.path;
    const method = ctx.method;

    // Static assets (no auth required)
    if (eql(path, "/static/admin.css")) return .{ .static_css = ctx.admin_css };
    if (eql(path, "/static/admin.js")) return .{ .static_js = ctx.admin_js };

    // Public routes (no auth required)
    if (eql(path, "/admin/setup")) {
        if (ctx.auth.hasUsers() catch false) return .{ .redirect = "/admin/login" };
        return if (method == .POST) handleSetupPost(ctx) else .{ .html = renderSetup("", ctx.csrf_token) };
    }
    if (eql(path, "/admin/login")) {
        return if (method == .POST) handleLoginPost(ctx) else .{ .html = renderLogin("", ctx.csrf_token) };
    }
    if (eql(path, "/admin/logout") and method == .POST) {
        return handleLogout(ctx);
    }

    // Check if setup needed
    if (!(ctx.auth.hasUsers() catch false)) return .needs_setup;

    // Protected routes - require valid session
    if (!ctx.session_valid) return .needs_auth;

    // Dashboard
    if (eql(path, "/admin") or eql(path, "/admin/")) {
        return .{ .html = renderDashboard(ctx.db, ctx.csrf_token) };
    }

    // Posts
    if (eql(path, "/admin/posts")) {
        return .{ .html = renderPostsList(ctx.db, ctx.csrf_token) };
    }
    if (eql(path, "/admin/posts/new")) {
        return .{ .html = renderPostNew(ctx.csrf_token) };
    }
    if (startsWith(path, "/admin/posts/")) {
        const post_id = path["/admin/posts/".len..];
        return .{ .html = renderPostEdit(ctx.db, post_id, ctx.csrf_token) };
    }

    // Users
    if (eql(path, "/admin/users")) {
        return .{ .html = renderUsersList(ctx.auth, ctx.allocator, ctx.csrf_token) orelse return .{ .server_error = "Database error" } };
    }
    if (eql(path, "/admin/users/new")) {
        return if (method == .POST) handleUsersCreate(ctx) else .{ .html = renderUsersNew(ctx.csrf_token) };
    }
    if (eql(path, "/admin/users/profile")) {
        return if (method == .POST) handleUsersProfileUpdate(ctx) else .{ .html = renderUsersProfile(ctx) };
    }
    if (startsWith(path, "/admin/users/") and endsWith(path, "/delete") and method == .POST) {
        return handleUsersDelete(ctx);
    }
    if (startsWith(path, "/admin/users/")) {
        const user_id = path["/admin/users/".len..];
        return if (method == .POST) handleUsersUpdate(ctx, user_id) else .{ .html = renderUsersEdit(ctx, user_id) };
    }

    // Other admin pages
    if (eql(path, "/admin/components")) {
        return .{ .html = renderComponents(ctx.csrf_token) };
    }
    if (eql(path, "/admin/design-system")) {
        return .{ .html = renderDesignSystem(ctx.csrf_token) };
    }
    if (eql(path, "/admin/settings")) {
        return .{ .html = renderSettings(ctx.csrf_token) };
    }

    return .not_found;
}

// =============================================================================
// Auth Handlers (return RouteResult for redirects/tokens)
// =============================================================================

fn handleSetupPost(ctx: RequestContext) RouteResult {
    const params = parseForm(ctx.body, ctx.allocator);
    defer params.deinit();

    const email = params.get("email") orelse "";
    const password = params.get("password") orelse "";
    const display_name = if (std.mem.indexOf(u8, email, "@")) |i| email[0..i] else email;

    const user_id = ctx.auth.createUser(email, display_name, password) catch |err| {
        const msg = switch (err) {
            Auth.Error.EmailExists => "Email already exists",
            else => "Failed to create user",
        };
        return .{ .html = renderSetup(msg, ctx.csrf_token) };
    };
    defer ctx.allocator.free(user_id);

    const token = ctx.auth.createSession(user_id) catch {
        return .{ .html = renderSetup("Session error", ctx.csrf_token) };
    };

    return .{ .redirect_with_token = .{ .path = "/admin", .token = token } };
}

fn handleLoginPost(ctx: RequestContext) RouteResult {
    const params = parseForm(ctx.body, ctx.allocator);
    defer params.deinit();

    const email = params.get("email") orelse "";
    const password = params.get("password") orelse "";

    const user_id = ctx.auth.authenticateUser(email, password) catch {
        return .{ .html = renderLogin("Invalid credentials", ctx.csrf_token) };
    };
    defer ctx.allocator.free(user_id);

    const token = ctx.auth.createSession(user_id) catch {
        return .{ .html = renderLogin("Session error", ctx.csrf_token) };
    };

    return .{ .redirect_with_token = .{ .path = "/admin", .token = token } };
}

fn handleLogout(ctx: RequestContext) RouteResult {
    _ = ctx;
    // Note: Session invalidation happens in the caller (they have the token)
    return .{ .redirect = "/admin/login" };
}

// =============================================================================
// User Handlers
// =============================================================================

fn handleUsersCreate(ctx: RequestContext) RouteResult {
    const params = parseForm(ctx.body, ctx.allocator);
    defer params.deinit();

    const email = params.get("email") orelse "";
    const display_name = params.get("display_name") orelse "";
    const password = params.get("password") orelse "";

    _ = ctx.auth.createUser(email, display_name, password) catch |err| {
        const msg = switch (err) {
            Auth.Error.EmailExists => "Email already exists",
            else => "Failed to create user",
        };
        const content = tpl.renderFnToSlice(zsx_admin_users_new.New, .{ msg, ctx.csrf_token });
        return .{ .html = wrapAdmin(content, "Add User", "", NavState.users_new_active, ctx.csrf_token) };
    };

    return .{ .redirect = "/admin/users" };
}

fn handleUsersUpdate(ctx: RequestContext, user_id: []const u8) RouteResult {
    const params = parseForm(ctx.body, ctx.allocator);
    defer params.deinit();

    const display_name = params.get("display_name") orelse "";
    const email = params.get("email") orelse "";
    const password = params.get("password");

    ctx.auth.updateUser(user_id, display_name, email, password) catch {
        return .{ .html = renderUsersEditWithError(ctx, user_id, "Failed to update user") };
    };

    return .{ .redirect = "/admin/users" };
}

fn handleUsersDelete(ctx: RequestContext) RouteResult {
    // Extract user ID from path: /admin/users/{id}/delete
    const path = ctx.path;
    const prefix = "/admin/users/";
    const suffix = "/delete";
    if (path.len <= prefix.len + suffix.len) return .{ .redirect = "/admin/users" };

    const user_id = path[prefix.len .. path.len - suffix.len];
    ctx.auth.deleteUser(user_id) catch {};

    return .{ .redirect = "/admin/users" };
}

fn handleUsersProfileUpdate(ctx: RequestContext) RouteResult {
    // TODO: Get current user from session and update their profile
    _ = ctx;
    return .{ .redirect = "/admin/users/profile" };
}

// =============================================================================
// Render Functions
// =============================================================================

pub fn renderSetup(error_msg: []const u8, csrf_token: []const u8) []const u8 {
    return tpl.renderFnToSlice(zsx_admin_setup.Setup, .{ error_msg, csrf_token });
}

pub fn renderLogin(error_msg: []const u8, csrf_token: []const u8) []const u8 {
    return tpl.renderFnToSlice(zsx_admin_login.Login, .{ error_msg, csrf_token });
}

pub fn renderDashboard(db: *db_mod.Db, csrf_token: []const u8) []const u8 {
    const users_count = countQuery(db, "SELECT COUNT(*) FROM users");
    const posts_count = countQuery(db, "SELECT COUNT(*) FROM posts");

    const empty_posts: []const PostListItem = &.{};
    const content = tpl.renderFnToSlice(zsx_admin_dashboard.Dashboard, .{
        posts_count, "0", "0", users_count, false, empty_posts,
    });

    return wrapAdmin(content, "Dashboard", "", NavState.dashboard_active, csrf_token);
}

pub fn renderPostsList(db: *db_mod.Db, csrf_token: []const u8) []const u8 {
    _ = db; // TODO: Query real posts from database

    const posts = [_]PostListItem{
        .{ .id = "1", .title = "Welcome to Publr", .author = "Admin", .status = "published", .date = "2024-01-15" },
        .{ .id = "2", .title = "Getting Started Guide", .author = "Admin", .status = "draft", .date = "2024-01-14" },
        .{ .id = "3", .title = "Advanced Features", .author = "Admin", .status = "draft", .date = "2024-01-13" },
    };

    const content = tpl.renderFnToSlice(zsx_admin_posts_list.List, .{ true, &posts });
    const actions = "<a href=\"/admin/posts/new\" class=\"btn btn-primary\">New Post</a>";
    return wrapAdmin(content, "Posts", actions, NavState.posts_active, csrf_token);
}

pub fn renderPostNew(csrf_token: []const u8) []const u8 {
    const content = tpl.renderFnToSlice(zsx_admin_posts_edit.Edit, .{
        PostEditData{
            .title = "",
            .slug = "",
            .content = "",
            .date = "2024-01-15",
            .is_draft = true,
            .is_published = false,
        },
        csrf_token,
    });
    return wrapAdmin(content, "New Post", "", NavState.posts_active, csrf_token);
}

pub fn renderPostEdit(db: *db_mod.Db, post_id: []const u8, csrf_token: []const u8) []const u8 {
    _ = db;
    _ = post_id; // TODO: Query post from database

    const content = tpl.renderFnToSlice(zsx_admin_posts_edit.Edit, .{
        PostEditData{
            .title = "Welcome to Publr",
            .slug = "welcome-to-publr",
            .content = "This is the content of the post...",
            .date = "2024-01-15",
            .is_draft = false,
            .is_published = true,
        },
        csrf_token,
    });
    return wrapAdmin(content, "Edit Post", "", NavState.posts_active, csrf_token);
}

pub fn renderUsersList(auth: *Auth, allocator: std.mem.Allocator, csrf_token: []const u8) ?[]const u8 {
    const users = auth.listUsers() catch return null;
    defer auth.freeUsers(users);

    var view_users: [64]UserListItem = undefined;
    var url_storage: [64 * 2][64]u8 = undefined;
    var count: usize = 0;

    for (users) |user| {
        if (count >= 64) break;
        const edit_url = std.fmt.bufPrint(&url_storage[count * 2], "/admin/users/{s}", .{user.id}) catch continue;
        const delete_url = std.fmt.bufPrint(&url_storage[count * 2 + 1], "/admin/users/{s}/delete", .{user.id}) catch continue;

        view_users[count] = .{
            .id = user.id,
            .display_name = user.display_name,
            .email = user.email,
            .edit_url = edit_url,
            .delete_url = delete_url,
        };
        count += 1;
    }

    _ = allocator;
    const content = tpl.renderFnToSlice(zsx_admin_users_list.List, .{ count > 0, view_users[0..count], csrf_token });
    const actions = "<a href=\"/admin/users/new\" class=\"btn btn-primary\">Add New</a>";
    return wrapAdmin(content, "Users", actions, NavState.users_list_active, csrf_token);
}

pub fn renderUsersNew(csrf_token: []const u8) []const u8 {
    const content = tpl.renderFnToSlice(zsx_admin_users_new.New, .{ "", csrf_token });
    return wrapAdmin(content, "Add User", "", NavState.users_new_active, csrf_token);
}

fn renderUsersEdit(ctx: RequestContext, user_id: []const u8) []const u8 {
    return renderUsersEditWithError(ctx, user_id, "");
}

fn renderUsersEditWithError(ctx: RequestContext, user_id: []const u8, error_msg: []const u8) []const u8 {
    const user = ctx.auth.getUserById(user_id) catch {
        return wrapAdmin("<p>User not found</p>", "Edit User", "", NavState.users_list_active, ctx.csrf_token);
    } orelse {
        return wrapAdmin("<p>User not found</p>", "Edit User", "", NavState.users_list_active, ctx.csrf_token);
    };
    defer ctx.auth.freeUser(&@constCast(&user).*);

    const content = tpl.renderFnToSlice(zsx_admin_users_edit.Edit, .{
        error_msg,
        user,
        ctx.csrf_token,
    });
    return wrapAdmin(content, "Edit User", "", NavState.users_list_active, ctx.csrf_token);
}

const ProfileUser = struct {
    id: []const u8,
    display_name: []const u8,
    email: []const u8,
};

fn renderUsersProfile(ctx: RequestContext) []const u8 {
    // TODO: Get current user from session
    const user = ProfileUser{
        .id = "",
        .display_name = "Current User",
        .email = "user@example.com",
    };
    const content = tpl.renderFnToSlice(zsx_admin_users_profile.Profile, .{
        "", // error_message
        user,
        ctx.csrf_token,
    });
    return wrapAdmin(content, "Profile", "", NavState.users_profile_active, ctx.csrf_token);
}

pub fn renderComponents(csrf_token: []const u8) []const u8 {
    const content = tpl.renderFnToSlice(zsx_admin_components.Components, .{});
    return wrapAdmin(content, "Components", "", NavState.components_active, csrf_token);
}

pub fn renderDesignSystem(csrf_token: []const u8) []const u8 {
    const content = tpl.renderFnToSlice(zsx_admin_design_system.DesignSystem, .{});
    return wrapAdmin(content, "Design System", "", NavState.design_system_active, csrf_token);
}

pub fn renderSettings(csrf_token: []const u8) []const u8 {
    const content =
        \\<div class="empty-state">
        \\    <p>Settings feature coming soon.</p>
        \\</div>
    ;
    return wrapAdmin(content, "Settings", "", NavState.settings_active, csrf_token);
}

// =============================================================================
// Layout Wrapper
// =============================================================================

pub fn wrapAdmin(content: []const u8, title: []const u8, actions: []const u8, nav: NavState, csrf_token: []const u8) []const u8 {
    return tpl.renderFnToSlice(zsx_admin_layout.Layout, .{
        title,
        content,
        actions,
        nav.dashboard,
        nav.posts,
        nav.users,
        nav.users_all,
        nav.users_new,
        nav.users_profile,
        nav.settings,
        nav.components,
        nav.design_system,
        csrf_token,
    });
}

// =============================================================================
// Helpers
// =============================================================================

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, haystack, prefix);
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, haystack, suffix);
}

var count_buf: [16]u8 = undefined;

fn countQuery(db: *db_mod.Db, query: []const u8) []const u8 {
    var stmt = db.prepare(query) catch return "0";
    defer stmt.deinit();
    if (stmt.step() catch return "0") {
        const n = stmt.columnInt(0);
        return std.fmt.bufPrint(&count_buf, "{d}", .{n}) catch "0";
    }
    return "0";
}

const FormParams = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn get(self: *const FormParams, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn deinit(self: *const FormParams) void {
        var map = @constCast(&self.map);
        map.deinit();
    }
};

fn parseForm(body: []const u8, allocator: std.mem.Allocator) FormParams {
    var map = std.StringHashMap([]const u8).init(allocator);
    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq| {
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            map.put(key, value) catch {};
        }
    }
    return .{ .map = map, .allocator = allocator };
}
