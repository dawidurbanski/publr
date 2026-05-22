//! Editor plugin registry.
//!
//! Content types declare which editor renders their entry edit page via the
//! `editor` field on `ContentTypeDef` (default `"form"`). At route time
//! (task-03), the edit-page dispatcher will resolve the id through `get(id)`
//! and invoke the matching `Editor.bootstrap` to render the main pane.
//!
//! Task-02 establishes the registry primitive and registers the built-in
//! `"form"` editor. The form bootstrap here is a stub — task-03 wires it to
//! the existing per-field form-rendering helpers in
//! `src/modules/admin/content/render.zig`.

const std = @import("std");
const mw = @import("middleware");
const content_type = @import("content_type");
const plugin_registry = @import("plugin_registry");

const Context = mw.Context;
const ContentTypeDef = content_type.ContentTypeDef;

/// Static asset shipped with an editor (JS, CSS, etc.). Embedded into the
/// binary at compile time; served by task-03's route under
/// `/admin/editors/<id>/<name>`.
pub const Asset = struct {
    /// File name as served, e.g. "editor.js".
    name: []const u8,
    /// Embedded asset bytes.
    content: []const u8,
    /// HTTP content type, e.g. "application/javascript".
    content_type: []const u8,
};

/// Arguments passed to an editor's bootstrap function. Bundled so the
/// signature is stable as new context fields are added later.
pub const BootstrapArgs = struct {
    /// The content type whose entry is being edited.
    def: *const ContentTypeDef,
    /// Request context — provides allocator, route params, helpers.
    ctx: *Context,
    /// The id of the entry being edited.
    entry_id: []const u8,
};

/// Renders the main-pane HTML for an editor instance to the provided writer.
/// Admin chrome (topbar + nav) wraps this output and is rendered by the
/// route handler, not by the editor. Editors that want sidebar content can
/// emit a sidebar section as part of their main-pane output for v0.
pub const BootstrapFn = *const fn (args: BootstrapArgs, w: std.io.AnyWriter) anyerror!void;

/// Optional frontend render override. When set, the theme's `{entry.<field>}`
/// rendering for a content field owned by this editor is routed through here
/// instead of emitting the stored value as-is. Used by the Gutenberg editor
/// to strip `<!-- wp:* -->` comments before output (task-05).
pub const RenderFn = *const fn (value: []const u8, w: std.io.AnyWriter) anyerror!void;

/// Editor declaration. Built-in editors are constant; plugin-registered
/// editors (deferred) would be appended at plugin load.
pub const Editor = struct {
    /// Unique id matched against `ContentTypeDef.editor`.
    id: []const u8,
    /// Renders the editor's main-pane HTML.
    bootstrap: BootstrapFn,
    /// Static assets served under `/admin/editors/<id>/<name>` (task-03).
    assets: []const Asset = &.{},
    /// Optional frontend value renderer.
    render: ?RenderFn = null,
};

/// Built-in `"form"` editor — wraps today's per-field form-edit experience.
/// Task-02 registers it with a stub bootstrap; task-03 replaces the stub
/// body with a call into the existing `render.renderFieldsHtml` pipeline
/// from `src/modules/admin/content/`.
pub const form_editor: Editor = .{
    .id = "form",
    .bootstrap = formBootstrap,
};

fn formBootstrap(args: BootstrapArgs, w: std.io.AnyWriter) anyerror!void {
    // task-03: replace with a call into the per-field form renderer.
    // Keeping a stub here keeps the registry contract honest without
    // pulling content/render imports into this top-level module yet.
    _ = args;
    try w.writeAll("<!-- form editor: wired by task-03 -->");
}

/// All registered editors: the core `form_editor` plus any plugin-registered
/// editors discovered via the plugin manifest. Plugins export either
/// `pub const editor: Editor` (single) or `pub const editors: []const Editor`
/// (multiple). Same aggregation pattern as `src/registry.zig`'s pages.
pub const builtin_editors: []const Editor = blk: {
    var result: []const Editor = &.{form_editor};
    for (plugin_registry.plugins) |p| {
        if (@hasDecl(p.mod, "editor")) {
            result = result ++ &[_]Editor{p.mod.editor};
        }
        if (@hasDecl(p.mod, "editors")) {
            result = result ++ p.mod.editors;
        }
    }
    break :blk result;
};

/// Look up an editor by id. Returns null when the id is unknown.
pub fn get(id: []const u8) ?*const Editor {
    for (builtin_editors) |*ed| {
        if (std.mem.eql(u8, ed.id, id)) return ed;
    }
    return null;
}

// Tests for this module live in `src/tests/editors_tests.zig` — the
// dedicated test target can't use editors.zig as its own root because the
// plugin aggregation creates a cyclic file reference (editors → plugins →
// editors). The wrapper file avoids the "file exists in modules 'root' and
// 'editors'" conflict by being a different file from src/editors.zig.
