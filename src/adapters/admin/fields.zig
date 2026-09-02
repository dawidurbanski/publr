const std = @import("std");
const admin = @import("../admin.zig");
const model = @import("../../model.zig");

const Page = admin.Page;
const Form = admin.Form;
const Error = admin.Error;
const Def = model.field.Def;
const Value = std.json.Value;

pub const json_bytes_max: u32 = 1 << 20;

/// One input per top-level field; groups, repeaters and `many` fields are edited as JSON.
pub fn render(page: *Page, fields: []const Def, document: ?Value) Error!void {
    std.debug.assert(fields.len > 0);
    std.debug.assert(fields.len <= model.field.fields_max);

    for (fields) |def| {
        const current: ?Value = if (document) |doc| doc.object.get(def.name) else null;

        try page.raw("<p><label>");
        try page.text(def.label);

        if (def.required) {
            try page.raw(" *");
        }

        try page.raw("<br>");

        if (is_json_edited(def)) {
            try render_json(page, def, current);
        } else {
            try render_scalar(page, def, current);
        }

        try page.raw("</label></p>\n");
    }
}

fn is_json_edited(def: Def) bool {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(def.label.len > 0);

    return def.many or def.kind == .group or def.kind == .repeater;
}

fn render_json(page: *Page, def: Def, current: ?Value) Error!void {
    std.debug.assert(is_json_edited(def));
    std.debug.assert(def.name.len > 0);

    try page.raw("<textarea name=\"");
    try page.text(def.name);
    try page.raw("\" rows=\"6\" cols=\"80\" placeholder=\"JSON\">");

    if (current) |value| {
        const arena = page.out.allocator;
        const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch {
            return error.OutOfMemory;
        };

        try page.text(text);
    }

    try page.raw("</textarea>");
}

fn render_scalar(page: *Page, def: Def, current: ?Value) Error!void {
    std.debug.assert(!is_json_edited(def));
    std.debug.assert(model.field.is_leaf(def.kind));

    switch (def.kind) {
        .text, .richtext => {
            try page.raw("<textarea name=\"");
            try page.text(def.name);
            try page.raw("\" rows=\"8\" cols=\"80\">");
            try text_of(page, current);
            try page.raw("</textarea>");
        },
        .boolean => {
            const checked = current != null and current.? == .bool and current.?.bool;

            try page.raw("<input type=\"checkbox\" value=\"1\" name=\"");
            try page.text(def.name);
            try page.raw(if (checked) "\" checked>" else "\">");
        },
        .select => try render_select(page, def, current),
        .integer, .number, .datetime => {
            try page.raw("<input type=\"number\" step=\"any\" name=\"");
            try page.text(def.name);
            try page.raw("\" value=\"");
            try text_of(page, current);
            try page.raw("\">");
        },
        else => {
            try page.raw("<input name=\"");
            try page.text(def.name);
            try page.raw("\" size=\"60\" value=\"");
            try text_of(page, current);
            const closing: []const u8 = if (def.kind == .slug)
                "\" placeholder=\"generated when empty\">"
            else
                "\">";

            try page.raw(closing);
        },
    }
}

fn render_select(page: *Page, def: Def, current: ?Value) Error!void {
    std.debug.assert(def.kind == .select);
    std.debug.assert(def.options.choices.len <= 1000);

    const chosen: ?[]const u8 = if (current != null and current.? == .string)
        current.?.string
    else
        null;

    try page.raw("<select name=\"");
    try page.text(def.name);
    try page.raw("\"><option value=\"\"></option>");

    for (def.options.choices) |choice| {
        const selected = chosen != null and std.mem.eql(u8, chosen.?, choice);

        try page.raw(if (selected) "<option selected>" else "<option>");
        try page.text(choice);
        try page.raw("</option>");
    }

    try page.raw("</select>");
}

fn text_of(page: *Page, current: ?Value) Error!void {
    std.debug.assert(json_bytes_max > 0);
    std.debug.assert(page.out.written().len > 0);

    const value = current orelse return;

    switch (value) {
        .string => |text| try page.text(text),
        .integer => |number| try page.print("{d}", .{number}),
        .float => |number| try page.print("{d}", .{number}),
        .bool => |flag| try page.raw(if (flag) "true" else "false"),
        else => {},
    }
}

/// The form fields back into a JSON document for the record operations.
pub fn document_of(arena: std.mem.Allocator, fields: []const Def, form: *const Form) ?[]const u8 {
    std.debug.assert(fields.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    var object: std.json.ObjectMap = .empty;

    for (fields) |def| {
        const value = (value_of(arena, def, form) catch return null) orelse continue;

        object.put(arena, def.name, value) catch return null;
    }

    return std.json.Stringify.valueAlloc(arena, Value{ .object = object }, .{}) catch null;
}

/// Null when the field was left empty; an error when what was typed does not parse.
fn value_of(arena: std.mem.Allocator, def: Def, form: *const Form) error{Invalid}!?Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    if (def.kind == .boolean) {
        return .{ .bool = form.get(def.name) != null };
    }

    const text = form.text(def.name) orelse return null;

    if (is_json_edited(def)) {
        if (text.len > json_bytes_max) {
            return error.Invalid;
        }

        return std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch error.Invalid;
    }

    return switch (def.kind) {
        .integer, .datetime => .{
            .integer = std.fmt.parseInt(i64, text, 10) catch return error.Invalid,
        },
        .number => .{ .float = std.fmt.parseFloat(f64, text) catch return error.Invalid },
        else => .{ .string = text },
    };
}
