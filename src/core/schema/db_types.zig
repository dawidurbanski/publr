//! DB-defined content type loader.
//!
//! Reads `content_types` rows persisted by the admin UI (or seeded by the
//! starter CLI in task 05) and reconstructs `ContentTypeDef` values for the
//! runtime registry. Fields come back as a JSON array embedded in the
//! `fields` column.
//!
//! Native + compile-in plugins keep their function-pointer `hooks` and
//! `http_hooks`; DB-defined descriptors land with the default null hooks
//! — runtime hook delivery is the WASM plugin SDK's job (separate epic).

const std = @import("std");
const Db = @import("db").Db;
const content_type_mod = @import("content_type");
const field_mod = @import("field");

const ContentTypeDef = content_type_mod.ContentTypeDef;
const FieldDef = field_mod.FieldDef;

const Allocator = std.mem.Allocator;

pub const LoadError = error{
    InvalidFieldsJson,
    UnknownFieldType,
    OutOfMemory,
    BindFailed,
    StepFailed,
    PrepareFailed,
    ExecFailed,
};

/// Load every row from `content_types` and return them as `ContentTypeDef`
/// values. The returned slice is allocator-owned; the descriptors borrow
/// strings into an arena attached to the loader's allocator — call
/// `freeAll` to release.
pub fn loadAll(allocator: Allocator, db: *Db) ![]ContentTypeDef {
    var stmt = try db.prepare(
        \\SELECT id, slug, name, name_plural, icon, fields, localized, locales, workflow, internal, is_taxonomy
        \\FROM content_types
        \\ORDER BY id
    );
    defer stmt.deinit();

    var out: std.ArrayListUnmanaged(ContentTypeDef) = .{};
    errdefer out.deinit(allocator);

    while (try stmt.step()) {
        const id = try allocator.dupe(u8, stmt.columnText(0) orelse continue);
        const slug = try allocator.dupe(u8, stmt.columnText(1) orelse id);
        const name = try allocator.dupe(u8, stmt.columnText(2) orelse "");
        const name_plural_raw = stmt.columnText(3) orelse "";
        const name_plural = try allocator.dupe(u8, if (name_plural_raw.len > 0) name_plural_raw else name);
        const icon_raw = stmt.columnText(4);
        const icon: ?[]const u8 = if (icon_raw) |s| if (s.len > 0) try allocator.dupe(u8, s) else null else null;
        const fields_json = stmt.columnText(5) orelse "[]";

        const fields = try parseFields(allocator, fields_json);

        const localized = stmt.columnInt(6) != 0;
        const locales = parseLocales(allocator, stmt.columnText(7)) catch &[_][]const u8{};
        const workflow: ?[]const u8 = if (stmt.columnText(8)) |s| if (s.len > 0) try allocator.dupe(u8, s) else null else null;
        const internal_flag = stmt.columnInt(9) != 0;
        const is_taxonomy = stmt.columnInt(10) != 0;

        try out.append(allocator, .{
            .type_id = id,
            .display_name = name,
            .display_name_plural = name_plural,
            .handle = slug,
            .icon = icon,
            .localized = localized,
            .locales = locales,
            .workflow = workflow,
            .internal = internal_flag,
            .taxonomy = if (is_taxonomy) .{} else null,
            .fields = fields,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn parseLocales(allocator: Allocator, csv: ?[]const u8) ![][]const u8 {
    const text = csv orelse return &[_][]const u8{};
    if (text.len == 0) return &[_][]const u8{};

    var list: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return list.toOwnedSlice(allocator);
}

fn parseFields(allocator: Allocator, json_text: []const u8) ![]FieldDef {
    // DB-stored field arrays don't carry function pointers — runtime
    // validate/render comes from `field_types.opsFor(field_type_id)` once
    // task 04 wires the lookup table in. For now, fields go through the
    // builders' default no-op render/validate which is fine for read-only
    // surfaces; saving DB-defined entries is a follow-up.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidFieldsJson;

    var out: std.ArrayListUnmanaged(FieldDef) = .{};
    errdefer out.deinit(allocator);

    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidFieldsJson;
        const obj = item.object;
        const name = (obj.get("name") orelse return error.InvalidFieldsJson).string;
        const type_id = (obj.get("type") orelse obj.get("field_type_id") orelse return error.InvalidFieldsJson).string;

        // For the loader stub: only `name` and `field_type_id` survive the
        // round-trip; validators/renderers fall through to the no-op
        // defaults. A richer schema (filterable/searchable/required) is
        // task 04's job.
        const display_raw = if (obj.get("display_name")) |v| (if (v == .string) v.string else name) else name;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .display_name = try allocator.dupe(u8, display_raw),
            .field_type_id = try allocator.dupe(u8, type_id),
            .validate = noopValidate,
            .render = noopRender,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn noopValidate(_: []const u8) ?[]const u8 {
    return null;
}

fn noopRender(_: std.io.AnyWriter, _: field_mod.RenderContext) anyerror!void {}

test "loadAll returns empty slice for an empty content_types table" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();
    try db.exec(
        \\CREATE TABLE content_types (
        \\    id TEXT PRIMARY KEY, slug TEXT NOT NULL, name TEXT NOT NULL,
        \\    name_plural TEXT NOT NULL DEFAULT '', icon TEXT NOT NULL DEFAULT 'bookmark',
        \\    fields TEXT NOT NULL, source TEXT NOT NULL,
        \\    localized INTEGER NOT NULL DEFAULT 0, locales TEXT, workflow TEXT,
        \\    internal INTEGER NOT NULL DEFAULT 0, is_taxonomy INTEGER NOT NULL DEFAULT 0
        \\)
    );

    const defs = try loadAll(std.testing.allocator, &db);
    defer std.testing.allocator.free(defs);
    try std.testing.expectEqual(@as(usize, 0), defs.len);
}
