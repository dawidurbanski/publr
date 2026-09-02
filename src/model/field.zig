const std = @import("std");

pub const name_len_max: u32 = 64;
pub const label_len_max: u32 = 128;
pub const fields_max: u32 = 64;
pub const depth_max: u32 = 3;
pub const choices_max: u32 = 256;

pub const Kind = enum {
    string,
    text,
    richtext,
    slug,
    email,
    url,
    boolean,
    integer,
    number,
    datetime,
    select,
    image,
    reference,
    group,
    repeater,
};

pub const Position = enum { main, side };

pub const Column = enum { text, int, real, ref, long };

pub const Options = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    min_len: ?u32 = null,
    max_len: ?u32 = null,
    choices: []const []const u8 = &.{},
    source: []const u8 = "",
    to: []const u8 = "",
    rows: ?u32 = null,
};

pub const Def = struct {
    name: []const u8,
    label: []const u8,
    kind: Kind,
    required: bool = false,
    searchable: bool = false,
    /// Declared in code by the type's owner: shown, never edited or removed by hand.
    locked: bool = false,
    many: bool = false,
    position: Position = .main,
    options: Options = .{},
    fields: []const Def = &.{},
};

pub const Problem = struct { path: []const u8, message: []const u8 };

pub const problems_max: u32 = 64;
pub const path_len_max: u32 = 256;

pub const Problems = struct {
    items: [problems_max]Problem = undefined,
    paths: [problems_max][path_len_max]u8 = undefined,
    len: u32 = 0,
    overflowed: bool = false,

    pub fn add(problems: *Problems, path: []const u8, message: []const u8) void {
        std.debug.assert(message.len > 0);
        std.debug.assert(problems.len <= problems_max);

        if (problems.len == problems_max) {
            problems.overflowed = true;

            return;
        }

        const kept = @min(path.len, path_len_max);
        const slot = &problems.paths[problems.len];

        @memcpy(slot[0..kept], path[0..kept]);
        problems.items[problems.len] = .{ .path = slot[0..kept], .message = message };
        problems.len += 1;
    }

    pub fn slice(problems: *const Problems) []const Problem {
        std.debug.assert(problems.len <= problems_max);
        std.debug.assert(problems.items.len == problems_max);

        return problems.items[0..problems.len];
    }

    pub fn is_empty(problems: *const Problems) bool {
        std.debug.assert(problems.len <= problems_max);
        std.debug.assert(!problems.overflowed or problems.len == problems_max);

        return problems.len == 0;
    }
};

pub fn column_of(kind: Kind) Column {
    std.debug.assert(kind != .group and kind != .repeater);

    const column: Column = switch (kind) {
        .string, .slug, .email, .url, .select => .text,
        .integer, .boolean, .datetime => .int,
        .number => .real,
        .image, .reference => .ref,
        .text, .richtext => .long,
        .group, .repeater => unreachable,
    };

    std.debug.assert(column != .real or kind == .number);

    return column;
}

pub fn is_leaf(kind: Kind) bool {
    const leaf = kind != .group and kind != .repeater;

    std.debug.assert(leaf or kind == .group or kind == .repeater);
    std.debug.assert(!leaf or (kind != .group and kind != .repeater));

    return leaf;
}

pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    for (name, 0..) |char, index| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';

        if (!(lower or char == '_' or (digit and index > 0))) {
            return false;
        }
    }

    std.debug.assert(name.len <= name_len_max);

    return name[0] >= 'a' and name[0] <= 'z';
}

pub fn validate_defs(defs: []const Def, depth: u32, problems: *Problems) void {
    validate_defs_in(defs, depth, false, problems);
}

fn validate_defs_in(
    defs: []const Def,
    depth: u32,
    inside_repeater: bool,
    problems: *Problems,
) void {
    std.debug.assert(depth <= depth_max);
    std.debug.assert(problems.len <= problems_max);

    if (defs.len > fields_max) {
        problems.add("fields", "too many fields");

        return;
    }

    for (defs, 0..) |def, index| {
        validate_def(def, depth, inside_repeater, problems);

        for (defs[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, def.name)) {
                problems.add(def.name, "duplicate field name");
            }
        }
    }
}

fn validate_def(def: Def, depth: u32, inside_repeater: bool, problems: *Problems) void {
    std.debug.assert(depth <= depth_max);
    std.debug.assert(problems.len <= problems_max);

    if (def.searchable and def.kind != .string and def.kind != .text and def.kind != .richtext) {
        problems.add(def.name, "only string, text and richtext fields can be searchable");
    }

    if (inside_repeater and (def.kind == .repeater or (def.many and def.kind == .reference))) {
        problems.add(def.name, "a repeater cannot contain another repeated field");
    }

    if (!valid_name(def.name)) {
        problems.add(def.name, "field name must be [a-z][a-z0-9_]*, up to 64 characters");
    }

    if (def.label.len == 0 or def.label.len > label_len_max) {
        problems.add(def.name, "label must be 1 to 128 characters");
    }

    if (def.many and def.kind != .reference and def.kind != .repeater) {
        problems.add(def.name, "only reference and repeater fields can be many");
    }

    switch (def.kind) {
        .select => {
            if (def.options.choices.len == 0 or def.options.choices.len > choices_max) {
                problems.add(def.name, "select needs 1 to 256 choices");
            }
        },
        .reference => {
            if (def.options.to.len == 0) {
                problems.add(def.name, "reference needs options.to (a content type handle)");
            }
        },
        .group, .repeater => {
            if (def.fields.len == 0) {
                problems.add(def.name, "group and repeater need child fields");
            }

            if (depth == depth_max) {
                problems.add(def.name, "fields nest too deep");
            } else {
                validate_defs_in(
                    def.fields,
                    depth + 1,
                    inside_repeater or def.kind == .repeater,
                    problems,
                );
            }
        },
        else => {
            if (def.fields.len != 0) {
                problems.add(def.name, "only group and repeater have child fields");
            }
        },
    }
}

test "column mapping and names" {
    try std.testing.expectEqual(Column.text, column_of(.string));
    try std.testing.expectEqual(Column.int, column_of(.datetime));
    try std.testing.expectEqual(Column.real, column_of(.number));
    try std.testing.expectEqual(Column.ref, column_of(.image));
    try std.testing.expectEqual(Column.long, column_of(.richtext));
    try std.testing.expect(!is_leaf(.repeater));
    try std.testing.expect(valid_name("title"));
    try std.testing.expect(valid_name("seo_title2"));
    try std.testing.expect(!valid_name("Title"));
    try std.testing.expect(!valid_name("2nd"));
    try std.testing.expect(!valid_name(""));
}

test "definitions: duplicates, select without choices, nesting depth" {
    var problems: Problems = .{};
    const good = [_]Def{
        .{ .name = "title", .label = "Title", .kind = .string, .required = true },
        .{
            .name = "tags",
            .label = "Tags",
            .kind = .reference,
            .many = true,
            .options = .{ .to = "tag" },
        },
        .{ .name = "gallery", .label = "Gallery", .kind = .repeater, .fields = &.{
            .{ .name = "image", .label = "Image", .kind = .image },
            .{ .name = "caption", .label = "Caption", .kind = .string },
        } },
    };
    validate_defs(&good, 0, &problems);
    try std.testing.expect(problems.is_empty());

    var bad_problems: Problems = .{};
    const bad = [_]Def{
        .{ .name = "title", .label = "Title", .kind = .string },
        .{ .name = "title", .label = "Again", .kind = .text },
        .{ .name = "kind", .label = "Kind", .kind = .select },
        .{ .name = "author", .label = "Author", .kind = .reference },
        .{ .name = "many_text", .label = "Many", .kind = .text, .many = true },
        .{ .name = "views", .label = "Views", .kind = .integer, .searchable = true },
        .{ .name = "faq", .label = "FAQ", .kind = .repeater, .fields = &.{
            .{
                .name = "links",
                .label = "Links",
                .kind = .reference,
                .many = true,
                .options = .{ .to = "x" },
            },
        } },
    };
    validate_defs(&bad, 0, &bad_problems);
    try std.testing.expectEqual(@as(u32, 6), bad_problems.len);

    var deep_problems: Problems = .{};
    const level4 = [_]Def{.{ .name = "v", .label = "V", .kind = .string }};
    const level3 = [_]Def{.{ .name = "z", .label = "Z", .kind = .group, .fields = &level4 }};
    const level2 = [_]Def{.{ .name = "y", .label = "Y", .kind = .group, .fields = &level3 }};
    const level1 = [_]Def{.{ .name = "x", .label = "X", .kind = .group, .fields = &level2 }};
    const deep = [_]Def{.{ .name = "w", .label = "W", .kind = .group, .fields = &level1 }};
    validate_defs(&deep, 0, &deep_problems);
    try std.testing.expect(!deep_problems.is_empty());
}
