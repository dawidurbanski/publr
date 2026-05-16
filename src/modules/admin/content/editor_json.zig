//! Editor-side HTML/JSON builders: version history list, flow audit, field
//! editors map, fields-in-releases array, collaborator avatar stack.

const std = @import("std");
const db_mod = @import("db");
const cms = @import("cms");
const gravatar = @import("gravatar");
const pu = @import("plugin_utils");

const Allocator = std.mem.Allocator;
const Db = db_mod.Db;
const writeJsonEscaped = pu.writeJsonEscaped;

pub fn buildVersionHistoryHtml(allocator: Allocator, db: *Db, entry_id: []const u8, base_url: []const u8) ![]const u8 {
    const versions = try cms.listVersions(allocator, db, entry_id, .{ .limit = 20 });

    if (versions.len == 0) return try allocator.dupe(u8, "");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(
        \\<div class="edit-sidebar-section">
        \\  <h3 class="edit-sidebar-title">Version History</h3>
        \\  <div class="version-list">
    );

    for (versions) |v| {
        const time_opt = cms.formatRelativeTime(allocator, v.created_at) catch null;
        defer if (time_opt) |ts| allocator.free(ts);
        const time_str = time_opt orelse "Unknown";

        const compare_url_opt = std.fmt.allocPrint(allocator, "{s}/{s}/versions/{s}/compare", .{ base_url, entry_id, v.id }) catch null;
        defer if (compare_url_opt) |url| allocator.free(url);
        const compare_url = compare_url_opt orelse "";

        const flow_url_opt = std.fmt.allocPrint(allocator, "{s}/{s}/versions/{s}/flow", .{ base_url, entry_id, v.id }) catch null;
        defer if (flow_url_opt) |url| allocator.free(url);
        const flow_url = flow_url_opt orelse "";

        try w.writeAll("<div class=\"version-item version-history-item");
        if (v.is_current) try w.writeAll(" version-current");
        try w.writeAll("\">");

        try writeCollaboratorAvatars(w, allocator, v.collaborators, v.author_email, v.authorLabel());

        try w.writeAll("<span class=\"version-info\">");
        try w.writeAll("<span class=\"version-type\">");
        try w.writeAll(v.version_type);
        try w.writeAll("</span>");
        if (v.release_name) |rn| {
            try w.writeAll("<span class=\"version-release\">");
            try cms.writeEscaped(w, rn);
            try w.writeAll("</span>");
        }
        try w.writeAll("<span class=\"version-time\">");
        try w.writeAll(time_str);
        try w.writeAll("</span>");
        try w.writeAll("</span>");

        try w.writeAll("<span class=\"version-item-actions\">");
        if (!v.is_current) {
            try w.writeAll("<a href=\"");
            try w.writeAll(compare_url);
            try w.writeAll("\" class=\"version-action\">Compare</a>");
        }
        try w.writeAll("<a href=\"");
        try w.writeAll(flow_url);
        try w.writeAll("\" class=\"version-action\">Flow</a>");
        if (v.is_current) {
            try w.writeAll("<span class=\"version-badge\">current</span>");
        }
        try w.writeAll("</span></div>");
    }

    try w.writeAll("</div></div>");
    return buf.toOwnedSlice(allocator);
}

pub fn buildVersionFlowAuditHtml(allocator: Allocator, db: *Db, entry_id: []const u8, version_id: []const u8) ![]const u8 {
    var stmt = try db.prepare(
        \\SELECT h.action,
        \\       COALESCE(u.display_name, ''),
        \\       COALESCE(u.email, ''),
        \\       h.created_at,
        \\       COALESCE(datetime(h.created_at, 'unixepoch'), ''),
        \\       h.from_step,
        \\       h.to_step,
        \\       h.details
        \\FROM entry_flow_history h
        \\LEFT JOIN users u ON u.id = h.user_id
        \\WHERE h.anchor_id = ?1
        \\  AND h.version_id = ?2
        \\ORDER BY h.created_at ASC, h.id ASC
        \\LIMIT 20
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    try stmt.bindText(2, version_id);

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var has_rows = false;
    while (try stmt.step()) {
        if (!has_rows) {
            has_rows = true;
            try w.writeAll("<div class=\"version-flow-audit\">");
        }

        const action = stmt.columnText(0) orelse "event";
        const display_name = stmt.columnText(1) orelse "";
        const email = stmt.columnText(2) orelse "";
        const actor = if (display_name.len > 0) display_name else if (email.len > 0) email else "System";
        const created_at = stmt.columnInt(3);
        const timestamp_utc = stmt.columnText(4) orelse "";
        const details = stmt.columnText(7);
        const relative_opt = cms.formatRelativeTime(allocator, created_at) catch null;
        defer if (relative_opt) |r| allocator.free(r);
        const relative = relative_opt orelse timestamp_utc;

        try w.writeAll("<div class=\"version-flow-event\">");
        try w.writeAll("<span class=\"version-flow-action\">");

        if (std.mem.eql(u8, action, "flow_entered")) {
            var flow_label: []const u8 = "Flow Entered";
            var owns_flow_label = false;
            if (details) |d| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                if (parsed) |p| {
                    if (p.value == .object) {
                        if (p.value.object.get("flow_id")) |f| {
                            if (f == .string and f.string.len > 0) {
                                flow_label = try std.fmt.allocPrint(allocator, "Flow Entered ({s})", .{f.string});
                                owns_flow_label = true;
                            }
                        }
                    }
                }
            }
            defer if (owns_flow_label) allocator.free(flow_label);
            try cms.writeEscaped(w, flow_label);
        } else if (std.mem.eql(u8, action, "step_started")) {
            try w.writeAll("Step Started");
        } else if (std.mem.eql(u8, action, "step_completed")) {
            try w.writeAll("Step Completed");
        } else if (std.mem.eql(u8, action, "terminal_action")) {
            var terminal_label: []const u8 = "Terminal Action";
            var owns_terminal_label = false;
            if (details) |d| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                if (parsed) |p| {
                    if (p.value == .object) {
                        if (p.value.object.get("terminal_action")) |t| {
                            if (t == .string and t.string.len > 0) {
                                terminal_label = try std.fmt.allocPrint(allocator, "Terminal: {s}", .{t.string});
                                owns_terminal_label = true;
                            }
                        }
                    }
                }
            }
            defer if (owns_terminal_label) allocator.free(terminal_label);
            try cms.writeEscaped(w, terminal_label);
        } else if (std.mem.eql(u8, action, "flow_completed")) {
            try w.writeAll("Flow Completed");
        } else {
            try cms.writeEscaped(w, action);
        }
        try w.writeAll("</span>");

        if (!stmt.columnIsNull(5)) {
            const from_step = stmt.columnInt(5);
            if (!stmt.columnIsNull(6)) {
                const to_step = stmt.columnInt(6);
                try w.print("<span class=\"version-flow-step\">Step {d} -> {d}</span>", .{ from_step, to_step });
            } else {
                try w.print("<span class=\"version-flow-step\">Step {d}</span>", .{from_step});
            }
        }

        try w.writeAll("<span class=\"version-flow-time\" title=\"");
        try cms.writeEscaped(w, timestamp_utc);
        try w.writeAll(" UTC\">");
        try cms.writeEscaped(w, relative);
        try w.writeAll(" · ");
        try cms.writeEscaped(w, actor);
        try w.writeAll("</span>");
        try w.writeAll("</div>");
    }

    if (!has_rows) return try allocator.dupe(u8, "");
    try w.writeAll("</div>");
    return buf.toOwnedSlice(allocator);
}

/// Render collaborator avatar stack from a JSON array of {email, name} objects.
pub fn writeCollaboratorAvatars(
    w: anytype,
    allocator: Allocator,
    collab_json: ?[]const u8,
    author_email: ?[]const u8,
    author_label: []const u8,
) !void {
    if (collab_json) |json| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch null;
        defer if (parsed) |p| p.deinit();

        if (parsed) |p| {
            if (p.value == .array and p.value.array.items.len > 0) {
                try w.writeAll("<span class=\"version-avatars\">");
                const items = p.value.array.items;
                const max_show: usize = 3;
                const show_count = @min(items.len, max_show);
                for (items[0..show_count]) |item| {
                    if (item == .object) {
                        if (item.object.get("email")) |email_val| {
                            if (email_val == .string) {
                                const avatar = gravatar.url(email_val.string, 24);
                                const name_val = if (item.object.get("name")) |n| (if (n == .string and n.string.len > 0) n.string else email_val.string) else email_val.string;
                                try w.writeAll("<img src=\"");
                                try w.writeAll(avatar.slice());
                                try w.writeAll("\" alt=\"\" title=\"");
                                try cms.writeEscaped(w, name_val);
                                try w.writeAll("\" class=\"version-avatar version-avatar-stacked\" />");
                            }
                        }
                    }
                }
                if (items.len > max_show) {
                    try w.print("<span class=\"version-avatar version-avatar-overflow\">+{d}</span>", .{items.len - max_show});
                }
                try w.writeAll("</span>");
                return;
            }
        }
        try w.writeAll("<span class=\"version-avatar version-avatar-system\">S</span>");
        return;
    }

    if (author_email) |email| {
        const avatar = gravatar.url(email, 24);
        try w.writeAll("<img src=\"");
        try w.writeAll(avatar.slice());
        try w.writeAll("\" alt=\"\" title=\"");
        try cms.writeEscaped(w, author_label);
        try w.writeAll("\" class=\"version-avatar\" />");
    } else {
        try w.writeAll("<span class=\"version-avatar version-avatar-system\">S</span>");
    }
}

/// Build JSON mapping field keys to their last editor info.
pub fn buildFieldEditorsJson(allocator: Allocator, db: *Db, entry_id: []const u8, current_user_id: []const u8) ![]const u8 {
    var ver_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1",
    );
    defer ver_stmt.deinit();
    try ver_stmt.bindText(1, entry_id);
    if (!try ver_stmt.step()) return try allocator.dupe(u8, "{}");

    const current_vid = ver_stmt.columnText(0) orelse return try allocator.dupe(u8, "{}");
    const published_vid = ver_stmt.columnText(1) orelse return try allocator.dupe(u8, "{}");
    if (std.mem.eql(u8, current_vid, published_vid)) return try allocator.dupe(u8, "{}");

    const cur_vid = try allocator.dupe(u8, current_vid);
    defer allocator.free(cur_vid);
    const pub_vid = try allocator.dupe(u8, published_vid);
    defer allocator.free(pub_vid);

    const published_data = try cms.getPublishedData(allocator, db, entry_id) orelse return try allocator.dupe(u8, "{}");
    defer allocator.free(published_data);

    var data_stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
    defer data_stmt.deinit();
    try data_stmt.bindText(1, cur_vid);
    if (!try data_stmt.step()) return try allocator.dupe(u8, "{}");
    const current_data = try allocator.dupe(u8, data_stmt.columnText(0) orelse "{}");
    defer allocator.free(current_data);

    const fields = try cms.compareVersionFields(allocator, published_data, current_data);
    defer allocator.free(fields);
    cms.populateFieldAuthors(allocator, db, fields, cur_vid, pub_vid);

    var user_stmt = try db.prepare("SELECT email FROM users WHERE id = ?1");
    defer user_stmt.deinit();
    try user_stmt.bindText(1, current_user_id);
    const current_email = if (try user_stmt.step())
        user_stmt.columnText(0) orelse ""
    else
        "";

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('{');
    var first = true;
    for (fields) |f| {
        if (!f.changed) continue;
        const editor_email = f.changed_by_email orelse continue;
        if (current_email.len > 0 and std.mem.eql(u8, editor_email, current_email)) continue;

        if (!first) try w.writeByte(',');
        first = false;

        try w.writeByte('"');
        try writeJsonEscaped(w, f.key);
        try w.writeAll("\":{\"name\":\"");
        try writeJsonEscaped(w, f.changed_by orelse editor_email);
        try w.writeAll("\",\"avatar\":\"");
        const avatar = gravatar.url(editor_email, 20);
        try w.writeAll(avatar.slice());
        try w.writeAll("\"}");
    }
    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

/// Build JSON for fields-in-releases data attribute.
pub fn buildFieldsInReleasesJson(allocator: Allocator, items: []const cms.EntryReleaseFieldInfo) ![]const u8 {
    if (items.len == 0) return try allocator.dupe(u8, "[]");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try w.writeAll(item.release_id);
        try w.writeAll("\",\"name\":");
        try w.writeByte('"');
        for (item.release_name) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            }
        }
        try w.writeByte('"');
        try w.writeAll(",\"fields\":");
        if (item.fields) |f| {
            try w.writeAll(f);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"scheduled_for\":");
        if (item.scheduled_for) |sf| {
            try w.print("{d}", .{sf});
        } else {
            try w.writeAll("null");
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(allocator);
}
