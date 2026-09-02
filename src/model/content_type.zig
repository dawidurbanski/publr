//! A content type as data: its definition (handle, names, fields), how it is checked, and
//! how it is written to and read from JSON. No database.

const std = @import("std");
const ids = @import("../lib/id.zig");
pub const field = @import("field.zig");

pub const handle_len_max: u32 = 64;
pub const name_len_max: u32 = 128;
pub const editor_len_max: u32 = 64;
pub const definition_bytes_max: u32 = 1 << 20;
pub const id_len = ids.len;
pub const statuses_max: u32 = 64;

pub const Def = struct {
    handle: []const u8,
    name: []const u8,
    name_plural: []const u8,
    icon: []const u8 = "",
    public: bool = false,
    /// Owned by the core or a plugin: its declared fields are locked, only fields added
    /// by hand can change.
    system: bool = false,
    /// The plugin that declared it (its manifest name), empty for hand-made types.
    owner: []const u8 = "",
    editor: []const u8 = "form",
    editor_config: []const u8 = "{}",
    title_field: []const u8 = "title",
    statuses: []const []const u8 = &.{},
    fields: []const field.Def,
};

pub fn validate_def(def: Def, problems: *field.Problems) void {
    std.debug.assert(problems.len <= field.problems_max);
    std.debug.assert(handle_len_max > 0);

    if (!field.valid_name(def.handle) or def.handle.len > handle_len_max) {
        problems.add("handle", "handle must be [a-z][a-z0-9_]*, up to 64 characters");
    }

    if (def.name.len == 0 or def.name.len > name_len_max) {
        problems.add("name", "name must be 1 to 128 characters");
    }

    if (def.name_plural.len == 0 or def.name_plural.len > name_len_max) {
        problems.add("name_plural", "name_plural must be 1 to 128 characters");
    }

    if (def.editor.len == 0 or def.editor.len > editor_len_max) {
        problems.add("editor", "editor must be 1 to 64 characters");
    }

    if (def.statuses.len > statuses_max) {
        problems.add("statuses", "too many statuses");
    }

    if (def.fields.len == 0) {
        problems.add("fields", "a content type needs at least one field");
    }

    field.validate_defs(def.fields, 0, problems);

    const title = find_field(def.fields, def.title_field);

    if (title == null) {
        problems.add("title_field", "title_field must name a top-level field");
    } else if (title.?.kind != .string and title.?.kind != .slug) {
        problems.add("title_field", "title_field must be a string field");
    }
}

pub fn find_field(fields: []const field.Def, name: []const u8) ?*const field.Def {
    std.debug.assert(fields.len <= field.fields_max);

    for (fields) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) {
            return candidate;
        }
    }

    return null;
}

/// Everything here fails like the database does, plus `Invalid` for a definition that is
/// not the JSON we expect.
pub const Error = error{ Invalid, OutOfMemory };

pub fn encode(arena: std.mem.Allocator, def: Def) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.fields.len > 0);

    return std.json.Stringify.valueAlloc(arena, def, .{}) catch error.OutOfMemory;
}

pub fn decode(arena: std.mem.Allocator, text: []const u8) Error!Def {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= definition_bytes_max);

    const options: std.json.ParseOptions = .{ .allocate = .alloc_always };

    return std.json.parseFromSliceLeaky(Def, arena, text, options) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };
}

/// A type's id is derived from its handle, so the same declared type gets the same id
/// in every database (environments, parity harnesses); a renamed type keeps its id.
pub const id_of = ids.derived;

pub const test_post: Def = .{
    .handle = "post",
    .name = "Post",
    .name_plural = "Posts",
    .public = true,
    .fields = &.{
        .{ .name = "title", .label = "Title", .kind = .string, .required = true },
        .{ .name = "slug", .label = "Slug", .kind = .slug, .options = .{ .source = "title" } },
        .{ .name = "body", .label = "Body", .kind = .richtext, .searchable = true },
        .{ .name = "views", .label = "Views", .kind = .integer },
        .{
            .name = "tags",
            .label = "Tags",
            .kind = .reference,
            .many = true,
            .options = .{ .to = "tag" },
        },
    },
};

test "definition validation" {
    var problems: field.Problems = .{};
    validate_def(test_post, &problems);
    try std.testing.expect(problems.is_empty());

    var bad: field.Problems = .{};
    const wrong: Def = .{
        .handle = "Post",
        .name = "",
        .name_plural = "Posts",
        .title_field = "nope",
        .fields = &.{.{ .name = "body", .label = "Body", .kind = .text }},
    };
    validate_def(wrong, &bad);
    try std.testing.expectEqual(@as(u32, 3), bad.len);
}
