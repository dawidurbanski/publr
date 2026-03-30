const std = @import("std");
const Context = @import("router").Context;
const static = @import("../static.zig");

var is_dev_mode: bool = false;

pub fn setDevMode(dev_mode: bool) void {
    is_dev_mode = dev_mode;
}

const AdminCss = static.Asset("admin.css", @embedFile("static_admin_css"));
const AdminJs = static.Asset("admin.js", @embedFile("static_admin_js"));

const InteractCore = static.Asset("core.js", @embedFile("static_interact_core_js"));
const InteractToggle = static.Asset("toggle.js", @embedFile("static_interact_toggle_js"));
const InteractPortal = static.Asset("portal.js", @embedFile("static_interact_portal_js"));
const InteractFocusTrap = static.Asset("focus-trap.js", @embedFile("static_interact_focus_trap_js"));
const InteractDismiss = static.Asset("dismiss.js", @embedFile("static_interact_dismiss_js"));
const InteractComponents = static.Asset("components.js", @embedFile("static_interact_components_js"));
const InteractIndex = static.Asset("index.js", @embedFile("static_interact_index_js"));
const InteractRepeater = static.Asset("repeater.js", @embedFile("static_interact_repeater_js"));
const MediaSelectionJs = static.Asset("media-selection.js", @embedFile("static_media_selection_js"));
const InteractWebSocket = static.Asset("websocket.js", @embedFile("static_interact_websocket_js"));
const InteractPresence = static.Asset("presence.js", @embedFile("static_interact_presence_js"));

const publr_ui = @import("publr_ui");
const PublrCss = static.Asset("publr.css", publr_ui.css);
const PublrCoreJs = static.Asset("publr-core.js", publr_ui.core_js);
const PublrDialogJs = static.Asset("publr-dialog.js", publr_ui.dialog_js);
const PublrDropdownJs = static.Asset("publr-dropdown.js", publr_ui.dropdown_js);

const AssetEntry = struct {
    asset: type,
    disk_path: ?[]const u8,
};

const asset_map = .{
    .{ "admin.css", AssetEntry{ .asset = AdminCss, .disk_path = "static/admin.css" } },
    .{ "admin.js", AssetEntry{ .asset = AdminJs, .disk_path = "static/admin.js" } },
    .{ "interact/core.js", AssetEntry{ .asset = InteractCore, .disk_path = "static/interact/core.js" } },
    .{ "interact/toggle.js", AssetEntry{ .asset = InteractToggle, .disk_path = "static/interact/toggle.js" } },
    .{ "interact/portal.js", AssetEntry{ .asset = InteractPortal, .disk_path = "static/interact/portal.js" } },
    .{ "interact/focus-trap.js", AssetEntry{ .asset = InteractFocusTrap, .disk_path = "static/interact/focus-trap.js" } },
    .{ "interact/dismiss.js", AssetEntry{ .asset = InteractDismiss, .disk_path = "static/interact/dismiss.js" } },
    .{ "interact/components.js", AssetEntry{ .asset = InteractComponents, .disk_path = "static/interact/components.js" } },
    .{ "interact/index.js", AssetEntry{ .asset = InteractIndex, .disk_path = "static/interact/index.js" } },
    .{ "interact/repeater.js", AssetEntry{ .asset = InteractRepeater, .disk_path = "static/interact/repeater.js" } },
    .{ "media-selection.js", AssetEntry{ .asset = MediaSelectionJs, .disk_path = "static/media-selection.js" } },
    .{ "interact/websocket.js", AssetEntry{ .asset = InteractWebSocket, .disk_path = "static/interact/websocket.js" } },
    .{ "interact/presence.js", AssetEntry{ .asset = InteractPresence, .disk_path = "static/interact/presence.js" } },
    .{ "publr.css", AssetEntry{ .asset = PublrCss, .disk_path = null } },
    .{ "publr-core.js", AssetEntry{ .asset = PublrCoreJs, .disk_path = null } },
    .{ "publr-dialog.js", AssetEntry{ .asset = PublrDialogJs, .disk_path = null } },
    .{ "publr-dropdown.js", AssetEntry{ .asset = PublrDropdownJs, .disk_path = null } },
};

pub fn handleStatic(ctx: *Context) !void {
    const file = ctx.wildcard orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
        return;
    };

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
            if (is_dev_mode) {
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
