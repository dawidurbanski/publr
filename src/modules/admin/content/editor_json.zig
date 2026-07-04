//! Editor-side HTML/JSON builders: version history list, flow audit, field
//! editors map, fields-in-releases array, collaborator avatar stack.

const std = @import("std");
const db_mod = @import("db");
const cms = @import("cms");
const gravatar = @import("gravatar");
const pu = @import("plugin_utils");
const views = @import("views");

const Allocator = std.mem.Allocator;
const Db = db_mod.Db;
const writeJsonEscaped = pu.writeJsonEscaped;

const HistoryRow = struct {
    is_current: bool = false,
    avatars_html: []const u8 = "",
    version_type: []const u8 = "",
    release_name: ?[]const u8 = null,
    time_str: []const u8 = "",
    compare_url: []const u8 = "",
    flow_url: []const u8 = "",
};

pub fn buildVersionHistoryHtml(allocator: Allocator, db: *Db, entry_id: []const u8, base_url: []const u8) ![]const u8 {
    const versions = try cms.listVersions(allocator, db, entry_id, .{ .limit = 20 });

    if (versions.len == 0) return try allocator.dupe(u8, "");

    // Build a row per version; the HTML is rendered by the VersionHistory ZSX component.
    // Per-row temporaries (relative time, URLs, avatar fragment) must outlive the loop, so
    // they're allocated with the caller's allocator (an arena in practice) and not freed here.
    var rows: std.ArrayListUnmanaged(HistoryRow) = .{};
    defer rows.deinit(allocator);

    for (versions) |v| {
        const time_opt = cms.formatRelativeTime(allocator, v.created_at) catch null;
        const time_str = time_opt orelse "Unknown";

        const compare_url = std.fmt.allocPrint(allocator, "{s}/{s}/versions/{s}/compare", .{ base_url, entry_id, v.id }) catch "";
        const flow_url = std.fmt.allocPrint(allocator, "{s}/{s}/versions/{s}/flow", .{ base_url, entry_id, v.id }) catch "";

        var ab: std.ArrayList(u8) = .{};
        writeCollaboratorAvatars(ab.writer(allocator).any(), allocator, v.collaborators, v.author_email, v.authorLabel()) catch {};
        const avatars_html = ab.toOwnedSlice(allocator) catch "";

        rows.append(allocator, .{
            .is_current = v.is_current,
            .avatars_html = avatars_html,
            .version_type = v.version_type,
            .release_name = v.release_name,
            .time_str = time_str,
            .compare_url = compare_url,
            .flow_url = flow_url,
        }) catch {};
    }

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try views.components.version_history.VersionHistory(buf.writer(allocator).any(), .{ .rows = rows.items });
    return buf.toOwnedSlice(allocator);
}

const FlowEvent = struct {
    action_label: []const u8 = "",
    step_text: ?[]const u8 = null,
    time_title: []const u8 = "",
    relative: []const u8 = "",
    actor: []const u8 = "",
};

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

    // Collect one event per row; the HTML is rendered by the VersionFlowAudit ZSX component.
    // Column-derived strings are invalidated by the next stmt.step(), so everything stored in
    // the event is duped into (or allocated with) the caller's allocator.
    var events: std.ArrayListUnmanaged(FlowEvent) = .{};
    defer events.deinit(allocator);

    while (try stmt.step()) {
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

        // Action label: constants stay literal; the JSON-derived labels are allocated into a
        // temp freed after it is duped into the event.
        var label_buf: ?[]const u8 = null;
        defer if (label_buf) |lb| allocator.free(lb);
        var label: []const u8 = action;
        if (std.mem.eql(u8, action, "flow_entered")) {
            label = "Flow Entered";
            if (details) |d| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                if (parsed) |p| {
                    if (p.value == .object) {
                        if (p.value.object.get("flow_id")) |f| {
                            if (f == .string and f.string.len > 0) {
                                label_buf = std.fmt.allocPrint(allocator, "Flow Entered ({s})", .{f.string}) catch null;
                                if (label_buf) |lb| label = lb;
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, action, "step_started")) {
            label = "Step Started";
        } else if (std.mem.eql(u8, action, "step_completed")) {
            label = "Step Completed";
        } else if (std.mem.eql(u8, action, "terminal_action")) {
            label = "Terminal Action";
            if (details) |d| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                if (parsed) |p| {
                    if (p.value == .object) {
                        if (p.value.object.get("terminal_action")) |t| {
                            if (t == .string and t.string.len > 0) {
                                label_buf = std.fmt.allocPrint(allocator, "Terminal: {s}", .{t.string}) catch null;
                                if (label_buf) |lb| label = lb;
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, action, "flow_completed")) {
            label = "Flow Completed";
        }

        var step_text: ?[]const u8 = null;
        if (!stmt.columnIsNull(5)) {
            const from_step = stmt.columnInt(5);
            if (!stmt.columnIsNull(6)) {
                const to_step = stmt.columnInt(6);
                step_text = std.fmt.allocPrint(allocator, "Step {d} -> {d}", .{ from_step, to_step }) catch null;
            } else {
                step_text = std.fmt.allocPrint(allocator, "Step {d}", .{from_step}) catch null;
            }
        }

        const time_title = std.fmt.allocPrint(allocator, "{s} UTC", .{timestamp_utc}) catch timestamp_utc;

        events.append(allocator, .{
            .action_label = allocator.dupe(u8, label) catch label,
            .step_text = step_text,
            .time_title = time_title,
            .relative = allocator.dupe(u8, relative) catch relative,
            .actor = allocator.dupe(u8, actor) catch actor,
        }) catch {};
    }

    if (events.items.len == 0) return try allocator.dupe(u8, "");

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try views.components.version_flow_audit.VersionFlowAudit(buf.writer(allocator).any(), .{ .events = events.items });
    return buf.toOwnedSlice(allocator);
}

/// Render collaborator avatar stack from a JSON array of {email, name} objects.
/// Parses the collaborator JSON, resolves gravatar URLs + titles, then renders the matching
/// VersionAvatars ZSX variant (Stack / Single / System) into `w`.
pub fn writeCollaboratorAvatars(
    w: anytype,
    allocator: Allocator,
    collab_json: ?[]const u8,
    author_email: ?[]const u8,
    author_label: []const u8,
) !void {
    const AvatarProp = struct { url: []const u8, title: []const u8 };

    if (collab_json) |json| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch null;
        defer if (parsed) |p| p.deinit();

        if (parsed) |p| {
            if (p.value == .array and p.value.array.items.len > 0) {
                const items = p.value.array.items;
                const max_show: usize = 3;
                const show_count = @min(items.len, max_show);

                // Keep the gravatar structs alive so their .slice() pointers stay valid while
                // the component renders.
                var urls: std.ArrayListUnmanaged(gravatar.GravatarUrl) = .{};
                defer urls.deinit(allocator);
                var titles: std.ArrayListUnmanaged([]const u8) = .{};
                defer titles.deinit(allocator);
                for (items[0..show_count]) |item| {
                    if (item == .object) {
                        if (item.object.get("email")) |email_val| {
                            if (email_val == .string) {
                                urls.append(allocator, gravatar.url(email_val.string, 24)) catch {};
                                const name_val = if (item.object.get("name")) |n| (if (n == .string and n.string.len > 0) n.string else email_val.string) else email_val.string;
                                titles.append(allocator, name_val) catch {};
                            }
                        }
                    }
                }

                var props: std.ArrayListUnmanaged(AvatarProp) = .{};
                defer props.deinit(allocator);
                for (urls.items, titles.items) |*g, title| {
                    props.append(allocator, .{ .url = g.slice(), .title = title }) catch {};
                }

                const overflow: usize = if (items.len > max_show) items.len - max_show else 0;
                try views.components.version_avatars.Stack(w, .{ .avatars = props.items, .overflow = overflow });
                return;
            }
        }
        try views.components.version_avatars.System(w, .{});
        return;
    }

    if (author_email) |email| {
        const avatar = gravatar.url(email, 24);
        try views.components.version_avatars.Single(w, .{ .url = avatar.slice(), .title = author_label });
    } else {
        try views.components.version_avatars.System(w, .{});
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
