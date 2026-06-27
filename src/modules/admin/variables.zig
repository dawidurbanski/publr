//! Variables admin plugin — list page + manual refresh endpoint.
//!
//! Top-level admin section ("/admin/variables") showing every kv row in
//! two sections: editor-owned and plugin-registered. Computed-mode rows
//! expose a refresh button that POSTs to `:key/refresh`, which calls into
//! `kv.refresh` (task-01) to re-run the compute fn and cascade.
//!
//! Create/edit/delete forms ship in task-03; this task is list + refresh
//! only.

const std = @import("std");
const admin = @import("admin_api");
const auth_middleware = @import("auth_middleware");
const csrf = @import("csrf");
const tpl = @import("tpl");
const views = @import("views");
const kv = @import("kv");

const VALUE_PREVIEW_MAX: usize = 80;

pub const page = admin.registerPage(.{
    .id = "variables",
    .title = "Variables",
    .path = "/variables",
    .icon = .tag,
    .position = 60,
    .menu_section = "plugins",
    .setup = setup,
});

fn setup(app: *admin.PageApp) void {
    app.render(handleList);
    app.post(handleCreate);
    app.get("/new", handleNewForm);
    app.get("/:key", handleEditForm);
    app.postAt("/:key", handleUpdate);
    app.postAt("/:key/delete", handleDelete);
    app.postAt("/:key/refresh", handleRefresh);
}

// =============================================================================
// GET /admin/variables — list
// =============================================================================

fn handleList(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const db = auth_instance.db;
    const csrf_token = csrf.ensureToken(ctx);

    // Two row buckets — editor-owned (source = "editor") and plugin-registered.
    var editor_rows: std.ArrayListUnmanaged(views.admin.variables.Row) = .{};
    var plugin_rows: std.ArrayListUnmanaged(views.admin.variables.Row) = .{};

    var stmt = db.prepare(
        "SELECT key, value, source, mode, label, last_resolved FROM kv ORDER BY source, key",
    ) catch {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Database error");
        return;
    };
    defer stmt.deinit();

    while (try stmt.step()) {
        const key = stmt.columnText(0) orelse continue;
        const value = stmt.columnText(1) orelse "";
        const source = stmt.columnText(2) orelse "editor";
        const mode = stmt.columnText(3) orelse "literal-baked";
        const label = stmt.columnText(4) orelse "";
        const last_resolved = stmt.columnText(5);

        const is_editor = std.mem.eql(u8, source, "editor");
        const is_computed = std.mem.startsWith(u8, mode, "computed-");

        // Display value: computed rows show last_resolved (or sentinel),
        // literal rows show raw value plus a resolved preview in parens when
        // the value references other vars. Truncate the raw side at
        // VALUE_PREVIEW_MAX chars.
        const raw_display: []const u8 = if (is_computed)
            last_resolved orelse "(not yet computed)"
        else
            value;
        const raw_preview = try truncate(ctx.allocator, raw_display, VALUE_PREVIEW_MAX);
        const value_preview: []const u8 = blk: {
            // Only literal modes carry [kv:...] refs that recursive resolve
            // would expand. Skip the work otherwise.
            if (is_computed) break :blk raw_preview;
            if (std.mem.indexOf(u8, value, "[kv:") == null) break :blk raw_preview;
            const resolved = kv.resolveCached(db, ctx.allocator, key) catch break :blk raw_preview;
            defer ctx.allocator.free(resolved);
            // Only show the parens form when the resolved differs from raw.
            if (std.mem.eql(u8, resolved, value)) break :blk raw_preview;
            const resolved_truncated = try truncate(ctx.allocator, resolved, VALUE_PREVIEW_MAX);
            defer ctx.allocator.free(resolved_truncated);
            break :blk try std.fmt.allocPrint(ctx.allocator, "{s} ({s})", .{ raw_preview, resolved_truncated });
        };

        const edit_url = try std.fmt.allocPrint(ctx.allocator, "/admin/variables/{s}", .{key});
        const refresh_url = try std.fmt.allocPrint(ctx.allocator, "/admin/variables/{s}/refresh", .{key});

        const row = views.admin.variables.Row{
            .key = try ctx.allocator.dupe(u8, key),
            .label = try ctx.allocator.dupe(u8, label),
            .value_preview = value_preview,
            .mode = try ctx.allocator.dupe(u8, mode),
            .source = try ctx.allocator.dupe(u8, source),
            .is_editor = is_editor,
            .is_computed = is_computed,
            .edit_url = edit_url,
            .refresh_url = refresh_url,
        };

        if (is_editor) {
            try editor_rows.append(ctx.allocator, row);
        } else {
            try plugin_rows.append(ctx.allocator, row);
        }
    }

    const editor_slice = try editor_rows.toOwnedSlice(ctx.allocator);
    const plugin_slice = try plugin_rows.toOwnedSlice(ctx.allocator);

    const props = views.admin.variables.Props{
        .csrf_token = csrf_token,
        .new_url = "/admin/variables/new",
        .has_any = editor_slice.len > 0 or plugin_slice.len > 0,
        .has_editor_rows = editor_slice.len > 0,
        .editor_rows = editor_slice,
        .has_plugin_rows = plugin_slice.len > 0,
        .plugin_rows = plugin_slice,
    };

    const content = tpl.render(views.admin.variables.List, .{props});
    ctx.html(admin.renderWithLayout("variables", "Variables", ctx, content, ""));
}

// =============================================================================
// POST /admin/variables/:key/refresh — re-run computed-baked resolver
// =============================================================================

fn handleRefresh(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse {
        ctx.response.setStatus("500 Internal Server Error");
        ctx.response.setBody("Auth not initialized");
        return;
    };
    const db = auth_instance.db;

    // :key — path param name registered in `setup`.
    const key = ctx.params.get("key") orelse {
        ctx.response.setStatus("400 Bad Request");
        ctx.response.setBody("Missing :key");
        return;
    };

    kv.refresh(db, ctx.allocator, key) catch |err| switch (err) {
        error.NotFound => {
            ctx.response.setStatus("404 Not Found");
            ctx.response.setBody("Variable not found");
            return;
        },
        error.WrongMode => {
            ctx.response.setStatus("400 Bad Request");
            ctx.response.setBody("Only computed-baked variables can be refreshed");
            return;
        },
        error.NoComputeFn => {
            ctx.response.setStatus("400 Bad Request");
            ctx.response.setBody("No registered compute fn for this variable (plugin may have been removed)");
            return;
        },
        error.DbError, error.OutOfMemory => {
            ctx.response.setStatus("500 Internal Server Error");
            ctx.response.setBody("Refresh failed");
            return;
        },
    };

    // Redirect back to the list.
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", "/admin/variables");
}

// =============================================================================
// Helpers
// =============================================================================

/// Returns a duped, length-capped slice of `s`. If `s` exceeds `max`, the
/// suffix is replaced with `…`.
fn truncate(allocator: std.mem.Allocator, s: []const u8, max: usize) ![]u8 {
    if (s.len <= max) return try allocator.dupe(u8, s);
    const ellipsis = "…";
    var out = try allocator.alloc(u8, max + ellipsis.len);
    @memcpy(out[0..max], s[0..max]);
    @memcpy(out[max..], ellipsis);
    return out;
}

/// Thin wrapper over `kv.pickerVarsJson` — kept so callers in this file
/// don't have to repeat the max-value arg. The shared helper lives in the
/// kv module so content-side render code can reuse it too.
fn buildVarsJson(allocator: std.mem.Allocator, db: *@import("db").Db, exclude_key: []const u8) ![]u8 {
    return try kv.pickerVarsJson(allocator, db, exclude_key, 40);
}

// =============================================================================
// GET /admin/variables/new — create form
// =============================================================================

fn handleNewForm(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse return serverError(ctx, "Auth not initialized");
    const csrf_token = csrf.ensureToken(ctx);
    const vars_json = buildVarsJson(ctx.allocator, auth_instance.db, "") catch "[]";
    const props = views.admin.variables_form.Props{
        .csrf_token = csrf_token,
        .action_url = "/admin/variables",
        .cancel_url = "/admin/variables",
        .delete_url = "",
        .is_new = true,
        .can_delete = false,
        .key_locked = false,
        .mode_locked = false,
        .referencer_count = 0,
        .key = "",
        .label = "",
        .description = "",
        .value = "",
        .mode = "literal-baked",
        .has_error = false,
        .error_message = "",
        .cycle_path = "",
        .vars_json = vars_json,
    };
    const content = tpl.render(views.admin.variables_form.Form, .{props});
    ctx.html(admin.renderWithLayout("variables", "New variable", ctx, content, ""));
}

// =============================================================================
// POST /admin/variables — create action
// =============================================================================

fn handleCreate(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse return serverError(ctx, "Auth not initialized");
    const db = auth_instance.db;
    const csrf_token = csrf.ensureToken(ctx);

    const key = ctx.formValue("key") orelse "";
    const label = ctx.formValue("label") orelse "";
    const description = ctx.formValue("description") orelse "";
    const value = ctx.formValue("value") orelse "";
    const live_mode_set = ctx.formValue("live_mode") != null;
    const mode_str: []const u8 = if (live_mode_set) "literal-live" else "literal-baked";

    // Validation
    if (validateKey(key)) |msg| {
        return renderFormError(ctx, csrf_token, true, "", key, label, description, value, mode_str, msg, "");
    }
    if (try keyExists(db, key)) {
        return renderFormError(ctx, csrf_token, true, "", key, label, description, value, mode_str, "A variable with this key already exists.", "");
    }
    if (try kv.validateNoCycle(ctx.allocator, db, key, value)) |path| {
        defer kv.freeCyclePath(ctx.allocator, path);
        const path_str = try formatCyclePath(ctx.allocator, path);
        return renderFormError(ctx, csrf_token, true, "", key, label, description, value, mode_str, "This value would create a reference cycle:", path_str);
    }

    // Insert
    var stmt = db.prepare(
        "INSERT INTO kv (key, value, source, mode, label, description, updated_at) VALUES (?, ?, 'editor', ?, ?, ?, unixepoch())",
    ) catch return serverError(ctx, "Database error");
    defer stmt.deinit();
    stmt.bindText(1, key) catch return serverError(ctx, "Database error");
    stmt.bindText(2, value) catch return serverError(ctx, "Database error");
    stmt.bindText(3, mode_str) catch return serverError(ctx, "Database error");
    if (label.len > 0) stmt.bindText(4, label) catch return serverError(ctx, "Database error") else stmt.bindNull(4) catch {};
    if (description.len > 0) stmt.bindText(5, description) catch return serverError(ctx, "Database error") else stmt.bindNull(5) catch {};
    _ = stmt.step() catch return serverError(ctx, "Database error");

    redirect(ctx, "/admin/variables");
}

// =============================================================================
// GET /admin/variables/:key — edit form
// =============================================================================

fn handleEditForm(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse return serverError(ctx, "Auth not initialized");
    const db = auth_instance.db;
    const csrf_token = csrf.ensureToken(ctx);

    const key = ctx.params.get("key") orelse return notFound(ctx, "Missing :key");

    const row = (try loadKvRow(ctx.allocator, db, key)) orelse return notFound(ctx, "Variable not found");
    defer row.deinit(ctx.allocator);

    const ref_count = try countReferencers(db, key);
    const is_editor = std.mem.eql(u8, row.source, "editor");
    const is_computed = std.mem.startsWith(u8, row.mode, "computed-");

    const delete_url = try std.fmt.allocPrint(ctx.allocator, "/admin/variables/{s}/delete", .{key});

    const vars_json = buildVarsJson(ctx.allocator, db, key) catch "[]";
    const props = views.admin.variables_form.Props{
        .csrf_token = csrf_token,
        .action_url = try std.fmt.allocPrint(ctx.allocator, "/admin/variables/{s}", .{key}),
        .cancel_url = "/admin/variables",
        .delete_url = delete_url,
        .is_new = false,
        .can_delete = is_editor,
        .key_locked = true,
        .mode_locked = !is_editor or is_computed,
        .referencer_count = ref_count,
        .key = row.key,
        .label = row.label,
        .description = row.description,
        .value = row.value,
        .mode = row.mode,
        .has_error = false,
        .error_message = "",
        .cycle_path = "",
        .vars_json = vars_json,
    };
    const content = tpl.render(views.admin.variables_form.Form, .{props});
    ctx.html(admin.renderWithLayout("variables", "Edit variable", ctx, content, ""));
}

// =============================================================================
// POST /admin/variables/:key — update action
// =============================================================================

fn handleUpdate(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse return serverError(ctx, "Auth not initialized");
    const db = auth_instance.db;
    const csrf_token = csrf.ensureToken(ctx);

    const key = ctx.params.get("key") orelse return notFound(ctx, "Missing :key");
    const row = (try loadKvRow(ctx.allocator, db, key)) orelse return notFound(ctx, "Variable not found");
    defer row.deinit(ctx.allocator);

    const new_value = ctx.formValue("value") orelse "";
    const new_label = ctx.formValue("label") orelse "";
    const new_description = ctx.formValue("description") orelse "";

    // Cycle check on new value
    if (try kv.validateNoCycle(ctx.allocator, db, key, new_value)) |path| {
        defer kv.freeCyclePath(ctx.allocator, path);
        const path_str = try formatCyclePath(ctx.allocator, path);
        return renderFormError(ctx, csrf_token, false, key, key, new_label, new_description, new_value, row.mode, "This value would create a reference cycle:", path_str);
    }

    const is_editor = std.mem.eql(u8, row.source, "editor");
    const is_computed = std.mem.startsWith(u8, row.mode, "computed-");

    // Plugin literal rows: only value is editable. Editor rows: value + label + description.
    if (is_editor) {
        var stmt = db.prepare("UPDATE kv SET value = ?, label = ?, description = ?, updated_at = unixepoch() WHERE key = ?") catch return serverError(ctx, "Database error");
        defer stmt.deinit();
        stmt.bindText(1, new_value) catch return serverError(ctx, "Database error");
        if (new_label.len > 0) stmt.bindText(2, new_label) catch return serverError(ctx, "Database error") else stmt.bindNull(2) catch {};
        if (new_description.len > 0) stmt.bindText(3, new_description) catch return serverError(ctx, "Database error") else stmt.bindNull(3) catch {};
        stmt.bindText(4, key) catch return serverError(ctx, "Database error");
        _ = stmt.step() catch return serverError(ctx, "Database error");
    } else if (!is_computed) {
        // Plugin literal — only value
        var stmt = db.prepare("UPDATE kv SET value = ?, updated_at = unixepoch() WHERE key = ?") catch return serverError(ctx, "Database error");
        defer stmt.deinit();
        stmt.bindText(1, new_value) catch return serverError(ctx, "Database error");
        stmt.bindText(2, key) catch return serverError(ctx, "Database error");
        _ = stmt.step() catch return serverError(ctx, "Database error");
    }

    // Cascade if value materially changed AND mode is literal-baked.
    if (std.mem.eql(u8, row.mode, "literal-baked") and !std.mem.eql(u8, row.value, new_value)) {
        kv.session.cascadeOnVarEdit(db, ctx.allocator, key) catch |err| {
            std.log.warn("kv: cascadeOnVarEdit failed for '{s}': {s}", .{ key, @errorName(err) });
        };
    }

    redirect(ctx, "/admin/variables");
}

// =============================================================================
// POST /admin/variables/:key/delete — delete with three-option dialog
//
// Two-stage flow:
//   1. POST without `action` → render confirm template (if referencers > 0)
//   2. POST with `action=bake|leave|remove` → perform the chosen action
//
// Zero-referencer case skips the dialog (single-step delete).
//
// v1 implementation: only `leave` action is fully wired. `bake` and `remove`
// rely on rewriter helpers that were intentionally removed from cms; their
// dialog options are disabled at the template level and the handler rejects
// them defensively.
// =============================================================================

fn handleDelete(ctx: *admin.Context) !void {
    const auth_instance = auth_middleware.auth orelse return serverError(ctx, "Auth not initialized");
    const db = auth_instance.db;
    const csrf_token = csrf.ensureToken(ctx);

    const key = ctx.params.get("key") orelse return notFound(ctx, "Missing :key");
    const row = (try loadKvRow(ctx.allocator, db, key)) orelse return notFound(ctx, "Variable not found");
    defer row.deinit(ctx.allocator);

    // Defense in depth — plugin rows can't be deleted via UI.
    if (!std.mem.eql(u8, row.source, "editor")) {
        ctx.response.setStatus("403 Forbidden");
        ctx.response.setBody("Plugin-registered variables can only be removed by the plugin author.");
        return;
    }

    const ref_count = try countReferencers(db, key);

    // Zero referencers — skip the dialog, just delete.
    if (ref_count == 0) {
        return performDelete(ctx, db, key);
    }

    // With referencers, decide based on `action` form param.
    const action = ctx.formValue("action") orelse {
        // No action → render confirm template.
        const delete_url = try std.fmt.allocPrint(ctx.allocator, "/admin/variables/{s}/delete", .{key});
        const props = views.admin.variables_delete.Props{
            .csrf_token = csrf_token,
            .action_url = delete_url,
            .cancel_url = "/admin/variables",
            .key = key,
            .referencer_count = ref_count,
            .can_bake = false,
            .can_remove = false,
        };
        const content = tpl.render(views.admin.variables_delete.Delete, .{props});
        ctx.html(admin.renderWithLayout("variables", "Delete variable", ctx, content, ""));
        return;
    };

    if (std.mem.eql(u8, action, "leave")) {
        return performDelete(ctx, db, key);
    }
    if (std.mem.eql(u8, action, "bake") or std.mem.eql(u8, action, "remove")) {
        ctx.response.setStatus("501 Not Implemented");
        ctx.response.setBody("The 'bake' and 'remove' delete actions are not yet wired up. Choose 'Leave broken' for now, or fix referencing content manually before retrying.");
        return;
    }
    ctx.response.setStatus("400 Bad Request");
    ctx.response.setBody("Unknown delete action");
}

fn performDelete(ctx: *admin.Context, db: *@import("db").Db, key: []const u8) !void {
    var stmt = db.prepare("DELETE FROM kv WHERE key = ?") catch return serverError(ctx, "Database error");
    defer stmt.deinit();
    stmt.bindText(1, key) catch return serverError(ctx, "Database error");
    _ = stmt.step() catch return serverError(ctx, "Database error");
    // kv_refs orphans for this key remain in place; next save of any
    // referencing field will rebuild kv_refs and the orphans disappear
    // naturally. For an explicit cleanup later, a periodic GC job could
    // sweep them.
    redirect(ctx, "/admin/variables");
}

// =============================================================================
// Helpers (validation, DB reads, error rendering, redirects)
// =============================================================================

const KvRow = struct {
    key: []const u8,
    value: []const u8,
    source: []const u8,
    mode: []const u8,
    label: []const u8,
    description: []const u8,

    fn deinit(self: KvRow, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        allocator.free(self.source);
        allocator.free(self.mode);
        allocator.free(self.label);
        allocator.free(self.description);
    }
};

fn loadKvRow(allocator: std.mem.Allocator, db: *@import("db").Db, key: []const u8) !?KvRow {
    var stmt = try db.prepare("SELECT key, value, source, mode, label, description FROM kv WHERE key = ?");
    defer stmt.deinit();
    try stmt.bindText(1, key);
    if (!try stmt.step()) return null;
    return KvRow{
        .key = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
        .value = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
        .source = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
        .mode = try allocator.dupe(u8, stmt.columnText(3) orelse ""),
        .label = try allocator.dupe(u8, stmt.columnText(4) orelse ""),
        .description = try allocator.dupe(u8, stmt.columnText(5) orelse ""),
    };
}

fn keyExists(db: *@import("db").Db, key: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM kv WHERE key = ?");
    defer stmt.deinit();
    try stmt.bindText(1, key);
    return try stmt.step();
}

fn countReferencers(db: *@import("db").Db, key: []const u8) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM kv_refs WHERE var_key = ?");
    defer stmt.deinit();
    try stmt.bindText(1, key);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

/// Returns null if valid; otherwise a human-readable error message.
fn validateKey(key: []const u8) ?[]const u8 {
    if (key.len == 0) return "Key is required.";
    if (key.len > 64) return "Key cannot exceed 64 characters.";
    if (!isIdentFirst(key[0])) return "Key must start with a letter or underscore.";
    for (key[1..]) |c| {
        if (!isIdentRest(c)) return "Key can only contain letters, digits, and underscores.";
    }
    return null;
}

inline fn isIdentFirst(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

inline fn isIdentRest(c: u8) bool {
    return isIdentFirst(c) or (c >= '0' and c <= '9');
}

fn formatCyclePath(allocator: std.mem.Allocator, path: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    for (path, 0..) |key, i| {
        if (i > 0) try out.appendSlice(allocator, " → ");
        try out.appendSlice(allocator, key);
    }
    return try out.toOwnedSlice(allocator);
}

fn renderFormError(
    ctx: *admin.Context,
    csrf_token: []const u8,
    is_new: bool,
    edit_key: []const u8,
    key: []const u8,
    label: []const u8,
    description: []const u8,
    value: []const u8,
    mode_str: []const u8,
    error_message: []const u8,
    cycle_path: []const u8,
) !void {
    const action_url: []const u8 = if (is_new) "/admin/variables" else try std.fmt.allocPrint(ctx.allocator, "/admin/variables/{s}", .{edit_key});
    const delete_url: []const u8 = if (is_new) "" else try std.fmt.allocPrint(ctx.allocator, "/admin/variables/{s}/delete", .{edit_key});
    const db = if (auth_middleware.auth) |a| a.db else null;
    const vars_json: []const u8 = if (db) |d| (buildVarsJson(ctx.allocator, d, edit_key) catch "[]") else "[]";
    const props = views.admin.variables_form.Props{
        .csrf_token = csrf_token,
        .action_url = action_url,
        .cancel_url = "/admin/variables",
        .delete_url = delete_url,
        .is_new = is_new,
        .can_delete = !is_new,
        .key_locked = !is_new,
        .mode_locked = !is_new,
        .referencer_count = 0,
        .key = key,
        .label = label,
        .description = description,
        .value = value,
        .mode = mode_str,
        .has_error = true,
        .error_message = error_message,
        .cycle_path = cycle_path,
        .vars_json = vars_json,
    };
    const content = tpl.render(views.admin.variables_form.Form, .{props});
    ctx.html(admin.renderWithLayout("variables", "Variable", ctx, content, ""));
}

fn serverError(ctx: *admin.Context, msg: []const u8) void {
    ctx.response.setStatus("500 Internal Server Error");
    ctx.response.setBody(msg);
}

fn notFound(ctx: *admin.Context, msg: []const u8) void {
    ctx.response.setStatus("404 Not Found");
    ctx.response.setBody(msg);
}

fn redirect(ctx: *admin.Context, location: []const u8) void {
    ctx.response.setStatus("303 See Other");
    ctx.response.setHeader("Location", location);
}
