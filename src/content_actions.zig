//! Default content action handlers wired into the `/admin/action` dispatcher.
//!
//! Each handler reads `type` (URL handle) and `entry_id` from the form body,
//! resolves the matching content type via the runtime registry, fires the
//! corresponding `http_hooks.*` hook on the descriptor if present, then runs
//! the default per-CT behavior (the `pub fn …For(def, ctx)` impls in
//! `content.zig`).
//!
//! Hook contract: runs BEFORE default behavior. If the hook sets a 4xx status
//! on the response, the default does NOT run. Otherwise default runs and may
//! redirect / render normally.
//!
//! Action names registered: `content.create`, `content.update`, `content.delete`,
//! `content.publish`, `content.unpublish`, `content.autosave`, `content.discard`,
//! `content.restore`, `content.preview`.

const std = @import("std");
const mw = @import("middleware");
const actions = @import("actions");
const schema_registry = @import("schema_registry");
const content_type_mod = @import("content_type");
const content = @import("plugin_content");
const css_jit = @import("css_jit");
const tpl = @import("tpl");
const views = @import("views");

const Context = mw.Context;
const ContentTypeDef = content_type_mod.ContentTypeDef;

const HookKind = enum {
    on_create,
    on_update,
    on_delete,
    on_publish,
    on_unpublish,
    on_autosave,
    on_discard,
    on_restore,
};

/// Register the 8 default content action handlers. Idempotent — re-calling
/// re-registers (last-write-wins with a warning, per `actions.register`).
pub fn registerDefaults() void {
    actions.register("content.create", handleCreate);
    actions.register("content.update", handleUpdate);
    actions.register("content.delete", handleDelete);
    actions.register("content.publish", handlePublish);
    actions.register("content.unpublish", handleUnpublish);
    actions.register("content.autosave", handleAutosave);
    actions.register("content.discard", handleDiscard);
    actions.register("content.restore", handleRestore);
    actions.register("content.preview", handlePreview);
}

/// `content.preview` — render posted entry content as a standalone page
/// through the site's REAL CSS pipeline: the theme stylesheet
/// (`/theme/theme.css`: preflight + build-time utilities + theme tokens)
/// plus a runtime JIT compile of the posted content's own class universe
/// (unsaved edits may use classes the build scan never saw). Used by the
/// block editor's topbar Preview (new tab, form POST) — no entry write.
fn handlePreview(ctx: *Context) !void {
    const html = ctx.formValue("content") orelse "";
    const utilities = css_jit.compileFromHtml(ctx.allocator, html) catch |err| blk: {
        std.log.warn("content.preview: css compile failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    ctx.html(tpl.render(views.admin.content.preview.ContentPreview, .{.{
        .utilities_css = utilities,
        .content = html,
    }}));
}

/// Resolve the content type referenced by the form's `type` field.
fn resolveDef(ctx: *Context) ?*const ContentTypeDef {
    const type_id = ctx.formValue("type") orelse return null;
    return schema_registry.findById(type_id);
}

/// Render the same styled 404 as `error.notFoundHandler`. Inlined to avoid
/// cross-module relative imports.
fn notFound(ctx: *Context) anyerror!void {
    ctx.response.setStatus("404 Not Found");
    const content_html = tpl.render(views.@"error".error_404.Error404, .{.{
        .status_code = "404",
        .title = "Page Not Found",
        .message = "The page you're looking for doesn't exist or has been moved.",
    }});
    if (ctx.isPartial()) {
        ctx.html(content_html);
    } else {
        ctx.html(tpl.render(views.base.Base, .{.{
            .title = "Error - Publr",
            .content = content_html,
            .css = &[_][]const u8{},
            .js = &[_][]const u8{},
        }}));
    }
}

/// True when the response status starts with '4' (e.g. 400, 403).
fn statusIs4xx(status: []const u8) bool {
    return status.len >= 3 and status[0] == '4';
}

/// Promote form fields to URL params so the per-CT impls (which read
/// `ctx.param("id")` and "vid") work unchanged.
fn promoteFormToParams(ctx: *Context, entry_id_field: []const u8, version_id_field: ?[]const u8) !void {
    if (ctx.formValue(entry_id_field)) |id| {
        try ctx.params.put(ctx.allocator, "id", id);
    }
    if (version_id_field) |vfield| {
        if (ctx.formValue(vfield)) |vid| {
            try ctx.params.put(ctx.allocator, "vid", vid);
        }
    }
}

fn handleCreate(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    try runHookAndDefault(.on_create, def, ctx, content.createFor);
}

fn handleUpdate(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    try promoteFormToParams(ctx, "entry_id", null);
    try runHookAndDefault(.on_update, def, ctx, content.updateFor);
}

fn handleDelete(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    try promoteFormToParams(ctx, "entry_id", null);
    try runHookAndDefault(.on_delete, def, ctx, content.deleteFor);
}

fn handlePublish(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    try promoteFormToParams(ctx, "entry_id", null);
    try runHookAndDefault(.on_publish, def, ctx, content.publishFor);
}

fn handleUnpublish(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    try promoteFormToParams(ctx, "entry_id", null);
    try runHookAndDefault(.on_unpublish, def, ctx, content.unpublishFor);
}

fn handleAutosave(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    // Autosave covers both "create" (no entry_id) and "update" (with entry_id).
    const has_entry_id = ctx.formValue("entry_id") != null;
    try promoteFormToParams(ctx, "entry_id", null);

    // Hook fires regardless of create vs. update.
    if (def.http_hooks.on_autosave) |hook| {
        const eid = ctx.formValue("entry_id") orelse "";
        try hook(ctx, def.type_id, eid);
        if (statusIs4xx(ctx.response.status)) return;
    }
    if (has_entry_id) {
        return content.autosaveUpdateFor(def, ctx);
    } else {
        return content.autosaveCreateFor(def, ctx);
    }
}

fn handleDiscard(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    try promoteFormToParams(ctx, "entry_id", null);
    try runHookAndDefault(.on_discard, def, ctx, content.discardFor);
}

fn handleRestore(ctx: *Context) !void {
    const def = resolveDef(ctx) orelse return notFound(ctx);
    try promoteFormToParams(ctx, "entry_id", "version_id");
    try runHookAndDefault(.on_restore, def, ctx, content.restoreFor);
}

/// Look up `http_hooks.<kind>` on the descriptor and call it (with the
/// runtime type_id + entry_id) before running `default`. The hook can
/// short-circuit the default by setting a 4xx status.
fn runHookAndDefault(
    kind: HookKind,
    def: *const ContentTypeDef,
    ctx: *Context,
    default: *const fn (def: *const ContentTypeDef, ctx: *Context) anyerror!void,
) !void {
    const hook = switch (kind) {
        .on_create => def.http_hooks.on_create,
        .on_update => def.http_hooks.on_update,
        .on_delete => def.http_hooks.on_delete,
        .on_publish => def.http_hooks.on_publish,
        .on_unpublish => def.http_hooks.on_unpublish,
        .on_autosave => def.http_hooks.on_autosave,
        .on_discard => def.http_hooks.on_discard,
        .on_restore => def.http_hooks.on_restore,
    };
    if (hook) |h| {
        const entry_id = ctx.formValue("entry_id") orelse "";
        try h(ctx, def.type_id, entry_id);
        if (statusIs4xx(ctx.response.status)) return;
    }
    return default(def, ctx);
}
