//! Schema-driven form parsing + hard-lock / field-ownership validation.

const std = @import("std");
const db_mod = @import("db");
const cms = @import("cms");
const field_mod = @import("field");
const content_type_mod = @import("content_type");
const pu = @import("plugin_utils");
const _p = @import("_platform.zig");
const Context = @import("middleware").Context;

const Allocator = std.mem.Allocator;
const Db = db_mod.Db;
const ContentTypeDef = content_type_mod.ContentTypeDef;
const FieldDef = field_mod.FieldDef;
const writeJsonEscaped = pu.writeJsonEscaped;
const presence = _p.presence;

pub const RejectedField = struct {
    field: []const u8,
    owner_name: []const u8,
};

/// Build a JSON string from form values, iterating the descriptor's fields.
pub fn parseFormDataJson(
    allocator: Allocator,
    def: *const ContentTypeDef,
    ctx: *Context,
    existing: ?cms.query.FieldMap,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var first = true;
    for (def.fields) |fd| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('"');
        try writeJsonEscaped(w, fd.name);
        try w.writeAll("\":");

        if (std.mem.eql(u8, fd.field_type_id, "repeater")) {
            try writeRepeaterJson(w, allocator, fd.sub_fields, fd.name, ctx);
        } else if (fd.sub_fields.len > 0) {
            try writeGroupJson(w, allocator, fd.sub_fields, fd.name, ctx);
        } else if (fd.multi) {
            if (existing) |em| {
                try writeFieldMapValueJson(w, em.get(fd.name));
            } else {
                try w.writeAll("[]");
            }
        } else {
            const raw = ctx.formValue(fd.name) orelse "";
            try writeFieldJson(w, fd.field_type_id, raw);
        }
    }
    try w.writeByte('}');

    return buf.toOwnedSlice(allocator);
}

pub fn writeGroupJson(
    w: anytype,
    allocator: Allocator,
    sub_fields: []const FieldDef,
    prefix: []const u8,
    ctx: *Context,
) anyerror!void {
    try w.writeByte('{');
    var first = true;
    for (sub_fields) |sf| {
        if (!first) try w.writeByte(',');
        first = false;
        const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, sf.name });
        defer allocator.free(key);

        try w.writeByte('"');
        try writeJsonEscaped(w, sf.name);
        try w.writeAll("\":");

        if (std.mem.eql(u8, sf.field_type_id, "repeater")) {
            try writeRepeaterJson(w, allocator, sf.sub_fields, key, ctx);
        } else if (sf.sub_fields.len > 0) {
            try writeGroupJson(w, allocator, sf.sub_fields, key, ctx);
        } else if (sf.multi) {
            try w.writeAll("[]");
        } else {
            const raw = ctx.formValue(key) orelse "";
            try writeFieldJson(w, sf.field_type_id, raw);
        }
    }
    try w.writeByte('}');
}

pub fn writeRepeaterJson(
    w: anytype,
    allocator: Allocator,
    sub_fields: []const FieldDef,
    prefix: []const u8,
    ctx: *Context,
) anyerror!void {
    const count_key = try std.fmt.allocPrint(allocator, "{s}._count", .{prefix});
    defer allocator.free(count_key);
    const count_str = ctx.formValue(count_key) orelse "0";
    const count = std.fmt.parseInt(usize, count_str, 10) catch 0;

    try w.writeByte('[');
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        const item_prefix = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ prefix, i });
        defer allocator.free(item_prefix);
        try writeGroupJson(w, allocator, sub_fields, item_prefix, ctx);
    }
    try w.writeByte(']');
}

pub fn writeFieldJson(w: anytype, field_type_id: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, field_type_id, "boolean")) {
        const is_truthy = std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "on");
        try w.writeAll(if (is_truthy) "true" else "false");
        return;
    }
    if (std.mem.eql(u8, field_type_id, "integer")) {
        if (raw.len == 0) {
            try w.writeAll("null");
        } else if (std.fmt.parseInt(i64, raw, 10)) |_| {
            try w.writeAll(raw);
        } else |_| {
            try w.writeAll("null");
        }
        return;
    }
    if (std.mem.eql(u8, field_type_id, "number") or std.mem.eql(u8, field_type_id, "real")) {
        if (raw.len == 0) {
            try w.writeAll("null");
        } else if (std.fmt.parseFloat(f64, raw)) |_| {
            try w.writeAll(raw);
        } else |_| {
            try w.writeAll("null");
        }
        return;
    }
    try w.writeByte('"');
    try writeJsonEscaped(w, raw);
    try w.writeByte('"');
}

pub fn writeFieldMapValueJson(w: anytype, val: ?cms.query.FieldValue) !void {
    const v = val orelse {
        try w.writeAll("null");
        return;
    };
    switch (v) {
        .text => |s| {
            try w.writeByte('"');
            try writeJsonEscaped(w, s);
            try w.writeByte('"');
        },
        .int => |n| try w.print("{d}", .{n}),
        .real => |n| try w.print("{d}", .{n}),
        .bool_ => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |t| try w.print("{d}", .{t}),
        .json => |j| try w.print("{f}", .{std.json.fmt(j, .{})}),
        .null_ => try w.writeAll("null"),
    }
}

pub fn parseFormDataWithValidation(
    allocator: Allocator,
    def: *const ContentTypeDef,
    ctx: *Context,
    existing: *const cms.query.FieldMap,
    author_id: ?[]const u8,
    entry_id: []const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    rejected: *std.ArrayListUnmanaged(RejectedField),
    newly_acquired: *std.ArrayListUnmanaged([]const u8),
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('{');
    var first = true;
    for (def.fields) |fd| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('"');
        try writeJsonEscaped(w, fd.name);
        try w.writeAll("\":");

        const field_rejected = checkFieldOwnership(fd.name, author_id, owners, rejected, allocator);

        if (std.mem.eql(u8, fd.field_type_id, "repeater")) {
            if (field_rejected) {
                try writeFieldMapValueJson(w, existing.get(fd.name));
            } else {
                try writeRepeaterJson(w, allocator, fd.sub_fields, fd.name, ctx);
                trackIfChanged(fd.name, owners, newly_acquired, allocator);
            }
        } else if (fd.sub_fields.len > 0) {
            if (field_rejected) {
                try writeFieldMapValueJson(w, existing.get(fd.name));
            } else {
                try writeGroupJson(w, allocator, fd.sub_fields, fd.name, ctx);
                trackIfChanged(fd.name, owners, newly_acquired, allocator);
            }
        } else if (fd.multi) {
            try writeFieldMapValueJson(w, existing.get(fd.name));
        } else {
            const existing_value = existing.get(fd.name);
            const existing_str: []const u8 = if (existing_value) |v| switch (v) {
                .text => |s| s,
                else => "",
            } else "";
            const validated = validateField(ctx, existing_str, fd.name, fd.name, author_id, entry_id, owners, rejected, newly_acquired);
            try writeFieldJson(w, fd.field_type_id, validated);
        }
    }
    try w.writeByte('}');

    return buf.toOwnedSlice(allocator);
}

pub fn checkFieldOwnership(
    name: []const u8,
    author_id: ?[]const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    rejected: *std.ArrayListUnmanaged(RejectedField),
    allocator: Allocator,
) bool {
    if (owners == null) return false;
    const own = owners.?;
    const field_info = own.get(name) orelse return false;
    const owner_id = field_info.changed_by_id orelse return false;
    const aid = author_id orelse return false;
    if (std.mem.eql(u8, owner_id, aid)) return false;
    rejected.append(allocator, .{
        .field = name,
        .owner_name = field_info.changed_by orelse "another user",
    }) catch {};
    return true;
}

pub fn trackIfChanged(
    name: []const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    newly_acquired: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
) void {
    const is_unowned = owners == null or !owners.?.contains(name);
    if (is_unowned) {
        newly_acquired.append(allocator, name) catch {};
    }
}

/// Get field ownership for an entry: field key -> owner info.
pub fn getFieldOwnership(allocator: Allocator, db: *Db, entry_id: []const u8) !?std.StringHashMapUnmanaged(cms.FieldComparison) {
    var ver_stmt = try db.prepare(
        "SELECT current_version_id, published_version_id FROM content_entries WHERE id = ?1",
    );
    defer ver_stmt.deinit();
    try ver_stmt.bindText(1, entry_id);
    if (!try ver_stmt.step()) return null;

    const current_vid_raw = ver_stmt.columnText(0) orelse return null;
    const published_vid_raw = ver_stmt.columnText(1) orelse return null;
    if (std.mem.eql(u8, current_vid_raw, published_vid_raw)) return null;

    const cur_vid = try allocator.dupe(u8, current_vid_raw);
    defer allocator.free(cur_vid);
    const pub_vid = try allocator.dupe(u8, published_vid_raw);
    defer allocator.free(pub_vid);

    const published_data = try cms.getPublishedData(allocator, db, entry_id) orelse return null;
    defer allocator.free(published_data);

    var data_stmt = try db.prepare("SELECT data_json FROM content_versions WHERE id = ?1");
    defer data_stmt.deinit();
    try data_stmt.bindText(1, cur_vid);
    if (!try data_stmt.step()) return null;
    const current_data = try allocator.dupe(u8, data_stmt.columnText(0) orelse "{}");
    defer allocator.free(current_data);

    const fields = try cms.compareVersionFields(allocator, published_data, current_data);
    cms.populateFieldAuthors(allocator, db, fields, cur_vid, pub_vid);

    var map: std.StringHashMapUnmanaged(cms.FieldComparison) = .{};
    for (fields) |f| {
        if (f.changed and f.changed_by_id != null) {
            map.put(allocator, f.key, f) catch continue;
        }
    }
    return map;
}

/// Validate a single field against ownership. Returns the value to use.
pub fn validateField(
    ctx: *Context,
    existing_value: []const u8,
    form_name: []const u8,
    json_key: []const u8,
    author_id: ?[]const u8,
    entry_id: []const u8,
    owners: ?std.StringHashMapUnmanaged(cms.FieldComparison),
    rejected: *std.ArrayListUnmanaged(RejectedField),
    newly_acquired: *std.ArrayListUnmanaged([]const u8),
) []const u8 {
    const submitted = ctx.formValue(form_name) orelse return existing_value;

    if (author_id) |aid| {
        switch (presence.checkOwnershipOverride(entry_id, json_key, aid)) {
            .owner => return submitted,
            .not_owner => {
                rejected.append(ctx.allocator, .{
                    .field = json_key,
                    .owner_name = "another user",
                }) catch {};
                return existing_value;
            },
            .none => {},
        }
    }

    if (owners) |own| {
        if (own.get(json_key)) |field_info| {
            if (author_id) |aid| {
                if (field_info.changed_by_id) |owner_id| {
                    if (!std.mem.eql(u8, owner_id, aid)) {
                        rejected.append(ctx.allocator, .{
                            .field = json_key,
                            .owner_name = field_info.changed_by orelse "another user",
                        }) catch {};
                        return existing_value;
                    }
                }
            }
            return submitted;
        }
    }

    if (!std.mem.eql(u8, submitted, existing_value)) {
        newly_acquired.append(ctx.allocator, json_key) catch {};
    }
    return submitted;
}

/// Build autosave JSON response with optional rejected_fields info.
pub fn buildAutosaveResponse(allocator: Allocator, status: []const u8, rejected: []const RejectedField) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\"status\":\"");
    try w.writeAll(status);
    try w.writeAll("\",\"saved\":true");

    if (rejected.len > 0) {
        try w.writeAll(",\"rejected_fields\":[");
        for (rejected, 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"field\":\"");
            try writeJsonEscaped(w, r.field);
            try w.writeAll("\",\"owner\":\"");
            try writeJsonEscaped(w, r.owner_name);
            try w.writeAll("\"}");
        }
        try w.writeByte(']');
    }

    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}
