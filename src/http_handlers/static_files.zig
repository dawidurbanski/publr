const std = @import("std");
const Context = @import("router").Context;
const static = @import("../static.zig");

var is_dev_mode: bool = false;

pub fn setDevMode(dev_mode: bool) void {
    is_dev_mode = dev_mode;
}

// Runtime CSS override (dev-only) lives in its own module so the HMR
// loop can write to it without depending on the static handler's wiring.
const runtime_css = @import("runtime_css");

const LogoSvg = static.Asset("logo.svg", @embedFile("static_logo_svg"));

const KvPickerJs = static.Asset("kv-picker.js", @embedFile("static_kv_picker_js"));
const PresenceJs = static.Asset("presence.js", @embedFile("static_presence_js"));
const ShellJs = static.Asset("shell.js", @embedFile("static_shell_js"));
const RepeaterJs = static.Asset("repeater.js", @embedFile("static_repeater_js"));
const MediaLibraryJs = static.Asset("media-library.js", @embedFile("static_media_library_js"));
const MediaPickerJs = static.Asset("media-picker.js", @embedFile("static_media_picker_js"));
const MediaEditJs = static.Asset("media-edit.js", @embedFile("static_media_edit_js"));
const ImageFieldJs = static.Asset("image-field.js", @embedFile("static_image_field_js"));
const KvFilterJs = static.Asset("kv-filter.js", @embedFile("static_kv_filter_js"));
const VersionCompareJs = static.Asset("version-compare.js", @embedFile("static_version_compare_js"));
const ContentListJs = static.Asset("content-list.js", @embedFile("static_content_list_js"));
const RecompileBarJs = static.Asset("recompile-bar.js", @embedFile("static_recompile_bar_js"));
const EntryEditorJs = static.Asset("entry-editor.js", @embedFile("static_entry_editor_js"));
const WsJs = static.Asset("ws.js", @embedFile("static_ws_js"));
const PublrCore = static.Asset("publr.js", @embedFile("static_publr_js"));
const PublrAdminJs = static.Asset("publr-admin.js", @embedFile("static_publr_admin_js"));
const PublrQuery = static.Asset("publr-query.js", @embedFile("static_publr_query_js"));
const PublrPosition = static.Asset("publr-position.js", @embedFile("static_publr_position_js"));
const PublrFocus = static.Asset("publr-focus.js", @embedFile("static_publr_focus_js"));

const publr_ui = @import("publr_ui");
const PreflightCss = @embedFile("static_preflight_css");
const JitUtilitiesCss = @embedFile("static_jit_css");
const PublrCss = static.Asset("publr.css", PreflightCss ++ "\n" ++ JitUtilitiesCss);
const TokensCss = static.Asset("tokens.css", @embedFile("static_tokens_css"));

fn composePublrCss(allocator: std.mem.Allocator, runtime_delta: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}",
        .{ PreflightCss, JitUtilitiesCss, runtime_delta },
    );
}
const PublrCheckboxJs = static.Asset("publr-checkbox.js", publr_ui.checkbox_js);
const PublrDialogJs = static.Asset("publr-dialog.js", publr_ui.dialog_js);
const PublrDrawerJs = static.Asset("publr-drawer.js", publr_ui.drawer_js);
const PublrDropdownJs = static.Asset("publr-dropdown.js", publr_ui.dropdown_js);
const PublrPopoverJs = static.Asset("publr-popover.js", publr_ui.popover_js);
const PublrRadioGroupJs = static.Asset("publr-radio-group.js", publr_ui.radio_group_js);
const PublrSelectJs = static.Asset("publr-select.js", publr_ui.select_js);
const PublrSwitchJs = static.Asset("publr-switch.js", publr_ui.switch_js);
const PublrTabsJs = static.Asset("publr-tabs.js", publr_ui.tabs_js);
const PublrToastJs = static.Asset("publr-toast.js", publr_ui.toast_js);
const PublrTooltipJs = static.Asset("publr-tooltip.js", publr_ui.tooltip_js);

const AssetEntry = struct {
    asset: type,
    disk_path: ?[]const u8,
};

const asset_map = .{
    .{ "logo.svg", AssetEntry{ .asset = LogoSvg, .disk_path = "static/logo.svg" } },
    .{ "scripts/kv-picker.js", AssetEntry{ .asset = KvPickerJs, .disk_path = "static/scripts/kv-picker.js" } },
    .{ "scripts/presence.js", AssetEntry{ .asset = PresenceJs, .disk_path = "static/scripts/presence.js" } },
    .{ "scripts/shell.js", AssetEntry{ .asset = ShellJs, .disk_path = "static/scripts/shell.js" } },
    .{ "scripts/repeater.js", AssetEntry{ .asset = RepeaterJs, .disk_path = "static/scripts/repeater.js" } },
    .{ "scripts/media-library.js", AssetEntry{ .asset = MediaLibraryJs, .disk_path = "static/scripts/media-library.js" } },
    .{ "scripts/media-picker.js", AssetEntry{ .asset = MediaPickerJs, .disk_path = "static/scripts/media-picker.js" } },
    .{ "scripts/media-edit.js", AssetEntry{ .asset = MediaEditJs, .disk_path = "static/scripts/media-edit.js" } },
    .{ "scripts/image-field.js", AssetEntry{ .asset = ImageFieldJs, .disk_path = "static/scripts/image-field.js" } },
    .{ "scripts/kv-filter.js", AssetEntry{ .asset = KvFilterJs, .disk_path = "static/scripts/kv-filter.js" } },
    .{ "scripts/version-compare.js", AssetEntry{ .asset = VersionCompareJs, .disk_path = "static/scripts/version-compare.js" } },
    .{ "scripts/content-list.js", AssetEntry{ .asset = ContentListJs, .disk_path = "static/scripts/content-list.js" } },
    .{ "scripts/recompile-bar.js", AssetEntry{ .asset = RecompileBarJs, .disk_path = "static/scripts/recompile-bar.js" } },
    .{ "scripts/entry-editor.js", AssetEntry{ .asset = EntryEditorJs, .disk_path = "static/scripts/entry-editor.js" } },
    .{ "scripts/ws.js", AssetEntry{ .asset = WsJs, .disk_path = "static/scripts/ws.js" } },
    .{ "scripts/publr.js", AssetEntry{ .asset = PublrCore, .disk_path = "lib/publr/publr.js" } },
    .{ "scripts/publr-admin.js", AssetEntry{ .asset = PublrAdminJs, .disk_path = "static/scripts/publr-admin.js" } },
    .{ "scripts/publr-query.js", AssetEntry{ .asset = PublrQuery, .disk_path = "lib/publr/publr-query.js" } },
    .{ "scripts/publr-position.js", AssetEntry{ .asset = PublrPosition, .disk_path = "lib/publr/publr-position.js" } },
    .{ "scripts/publr-focus.js", AssetEntry{ .asset = PublrFocus, .disk_path = "lib/publr/publr-focus.js" } },
    .{ "styles/tokens.css", AssetEntry{ .asset = TokensCss, .disk_path = "static/styles/tokens.css" } },
    .{ "styles/publr.css", AssetEntry{ .asset = PublrCss, .disk_path = null } },
    .{ "scripts/publr-checkbox.js", AssetEntry{ .asset = PublrCheckboxJs, .disk_path = null } },
    .{ "scripts/publr-dialog.js", AssetEntry{ .asset = PublrDialogJs, .disk_path = null } },
    .{ "scripts/publr-drawer.js", AssetEntry{ .asset = PublrDrawerJs, .disk_path = null } },
    .{ "scripts/publr-dropdown.js", AssetEntry{ .asset = PublrDropdownJs, .disk_path = null } },
    .{ "scripts/publr-popover.js", AssetEntry{ .asset = PublrPopoverJs, .disk_path = null } },
    .{ "scripts/publr-radio-group.js", AssetEntry{ .asset = PublrRadioGroupJs, .disk_path = null } },
    .{ "scripts/publr-select.js", AssetEntry{ .asset = PublrSelectJs, .disk_path = null } },
    .{ "scripts/publr-switch.js", AssetEntry{ .asset = PublrSwitchJs, .disk_path = null } },
    .{ "scripts/publr-tabs.js", AssetEntry{ .asset = PublrTabsJs, .disk_path = null } },
    .{ "scripts/publr-toast.js", AssetEntry{ .asset = PublrToastJs, .disk_path = null } },
    .{ "scripts/publr-tooltip.js", AssetEntry{ .asset = PublrTooltipJs, .disk_path = null } },
};

pub fn handleStatic(ctx: *Context) !void {
    const file = ctx.wildcard orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
        return;
    };

    // In dev mode, the HMR loop may have compiled additional utilities from
    // the last hot-swapped component (see runtime_css.set). That payload is
    // only a delta: replacing JitUtilitiesCss with it drops every utility
    // used outside the swapped subtree and breaks unrelated admin pages.
    // Keep the complete build-time sheet and append the runtime delta.
    if (is_dev_mode and std.mem.eql(u8, file, "styles/publr.css")) {
        if (try runtime_css.dupCurrent(std.heap.page_allocator)) |content| {
            defer std.heap.page_allocator.free(content);
            const body = try composePublrCss(std.heap.page_allocator, content);
            ctx.response.setContentType(static.getMimeType(file));
            ctx.response.setBody(body);
            return;
        }
    }

    inline for (asset_map) |entry| {
        if (std.mem.eql(u8, file, entry[0])) {
            if (is_dev_mode) {
                if (entry[1].disk_path) |disk_path| {
                    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, disk_path, 1024 * 1024) catch {
                        ctx.response.setStatus("404 Not Found");
                        ctx.response.setContentType("text/plain");
                        ctx.response.setBody("File not found");
                        return;
                    };
                    ctx.response.setContentType(static.getMimeType(file));
                    ctx.response.setBody(content);
                    return;
                }
            }
            entry[1].asset.serve(ctx, ctx.getRequestHeader("If-None-Match"));
            return;
        }
    }

    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
}

test "dev publr.css keeps build-time utilities when adding an HMR delta" {
    const delta = "@layer utilities { .hmr-only { display: block; } }";
    const body = try composePublrCss(std.testing.allocator, delta);
    defer std.testing.allocator.free(body);

    const base_end = PreflightCss.len + 1 + JitUtilitiesCss.len;
    try std.testing.expectEqualSlices(u8, PreflightCss, body[0..PreflightCss.len]);
    try std.testing.expectEqual('\n', body[PreflightCss.len]);
    try std.testing.expectEqualSlices(
        u8,
        JitUtilitiesCss,
        body[PreflightCss.len + 1 .. base_end],
    );
    try std.testing.expectEqual('\n', body[base_end]);
    try std.testing.expectEqualSlices(u8, delta, body[base_end + 1 ..]);
}

const theme_static = @import("theme_static");

/// Serve theme static assets at /theme/*
pub fn handleThemeStatic(ctx: *Context) !void {
    const file = ctx.wildcard orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
        return;
    };

    inline for (theme_static.files) |entry| {
        if (std.mem.eql(u8, file, entry.path)) {
            // Dev mode reads from disk so changes appear without rebuild —
            // except for synthetic entries (build-generated, no disk file),
            // which carry an empty disk_path and fall through to the embedded
            // bytes.
            if (is_dev_mode and entry.disk_path.len > 0) {
                const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, entry.disk_path, 4 * 1024 * 1024) catch {
                    ctx.response.setStatus("404 Not Found");
                    ctx.response.setContentType("text/plain");
                    ctx.response.setBody("File not found");
                    return;
                };
                ctx.response.setContentType(entry.content_type);
                ctx.response.setBody(content);
                return;
            }

            // Production: serve embedded with caching
            const etag = comptime static.compileTimeETag(entry.data);
            if (ctx.getRequestHeader("If-None-Match")) |client_etag| {
                if (std.mem.indexOf(u8, client_etag, &etag) != null) {
                    ctx.response.setStatus("304 Not Modified");
                    ctx.response.setHeader("ETag", &etag);
                    return;
                }
            }
            ctx.response.setContentType(entry.content_type);
            ctx.response.setBody(entry.data);
            ctx.response.setHeader("ETag", &etag);
            ctx.response.setHeader("Cache-Control", "public, max-age=31536000, immutable");
            return;
        }
    }

    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
}
