const std = @import("std");
const field = @import("field.zig");

const Def = field.Def;
const Problems = field.Problems;
const Value = std.json.Value;

pub const string_len_max: u32 = 64 << 10;
pub const text_len_max: u32 = 4 << 20;
pub const id_len_max: u32 = 64;
pub const repeater_items_max: u32 = 1000;

pub fn validate_document(defs: []const Def, document: Value, problems: *Problems) void {
    std.debug.assert(defs.len <= field.fields_max);
    std.debug.assert(problems.len <= field.problems_max);

    const object = switch (document) {
        .object => |object| object,
        else => {
            problems.add("", "document must be a JSON object");

            return;
        },
    };

    for (defs) |def| {
        const value = object.get(def.name);
        validate_field(def, value, def.name, problems);
    }

    var keys = object.iterator();

    while (keys.next()) |entry| {
        if (find(defs, entry.key_ptr.*) == null) {
            problems.add(entry.key_ptr.*, "unknown field");
        }
    }
}

fn find(defs: []const Def, name: []const u8) ?*const Def {
    std.debug.assert(name.len <= string_len_max);
    std.debug.assert(defs.len <= field.fields_max);

    for (defs) |*def| {
        if (std.mem.eql(u8, def.name, name)) {
            return def;
        }
    }

    return null;
}

fn validate_field(def: Def, value: ?Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(problems.len <= field.problems_max);

    const present = value != null and value.? != .null;

    if (!present) {
        if (def.required) {
            problems.add(path, "required");
        }

        return;
    }

    if (def.many) {
        validate_many(def, value.?, path, problems);

        return;
    }

    validate_one(def, value.?, path, problems);
}

fn validate_many(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.many);
    std.debug.assert(path.len > 0);

    const items = switch (value) {
        .array => |array| array.items,
        else => {
            problems.add(path, "expected a list");

            return;
        },
    };

    if (items.len > repeater_items_max) {
        problems.add(path, "too many items");

        return;
    }

    if (def.required and items.len == 0) {
        problems.add(path, "required");
    }

    for (items) |item| {
        validate_one(def, item, path, problems);
    }
}

fn validate_one(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(problems.len <= field.problems_max);

    switch (def.kind) {
        .string, .slug, .email, .url, .text, .richtext, .select => validate_text(
            def,
            value,
            path,
            problems,
        ),
        .boolean => {
            if (value != .bool) {
                problems.add(path, "expected true or false");
            }
        },
        .integer, .datetime => validate_integer(def, value, path, problems),
        .number => validate_number(def, value, path, problems),
        .image, .reference => validate_id(value, path, problems),
        .group => validate_group(def, value, path, problems),
        .repeater => validate_repeater(def, value, path, problems),
    }
}

fn validate_text(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(field.column_of(def.kind) != .int);
    std.debug.assert(path.len > 0);

    const text = switch (value) {
        .string => |text| text,
        else => {
            problems.add(path, "expected text");

            return;
        },
    };
    const long_kind = def.kind == .text or def.kind == .richtext;
    const len_max = if (long_kind) text_len_max else string_len_max;

    if (text.len > len_max) {
        problems.add(path, "too long");

        return;
    }

    if (def.options.min_len) |min_len| {
        if (text.len < min_len) {
            problems.add(path, "too short");
        }
    }

    if (def.options.max_len) |max_len| {
        if (text.len > max_len) {
            problems.add(path, "too long");
        }
    }

    switch (def.kind) {
        .slug => {
            if (!valid_slug(text)) {
                problems.add(path, "slug must be [a-z0-9] and hyphens");
            }
        },
        .email => {
            if (std.mem.indexOfScalar(u8, text, '@') == null or text.len < 3) {
                problems.add(path, "not an email");
            }
        },
        .url => {
            const http = std.mem.startsWith(u8, text, "http://");
            const https = std.mem.startsWith(u8, text, "https://");

            if (!http and !https) {
                problems.add(path, "url must start with http:// or https://");
            }
        },
        .select => {
            if (!contains(def.options.choices, text)) {
                problems.add(path, "not one of the choices");
            }
        },
        else => {},
    }
}

fn validate_integer(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.kind == .integer or def.kind == .datetime);
    std.debug.assert(path.len > 0);

    const number = switch (value) {
        .integer => |number| number,
        else => {
            problems.add(path, "expected a whole number");

            return;
        },
    };
    const as_float: f64 = @floatFromInt(number);

    if (def.kind == .datetime and number < 0) {
        problems.add(path, "datetime is milliseconds since 1970");
    }

    check_range(def, as_float, path, problems);
}

fn validate_number(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.kind == .number);
    std.debug.assert(path.len > 0);

    const number: f64 = switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => {
            problems.add(path, "expected a number");

            return;
        },
    };

    check_range(def, number, path, problems);
}

fn check_range(def: Def, number: f64, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(!std.math.isNan(number));

    if (def.options.min) |min| {
        if (number < min) {
            problems.add(path, "below the minimum");
        }
    }

    if (def.options.max) |max| {
        if (number > max) {
            problems.add(path, "above the maximum");
        }
    }
}

fn validate_id(value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(id_len_max > 0);

    switch (value) {
        .string => |text| {
            if (text.len == 0 or text.len > id_len_max) {
                problems.add(path, "expected an id");
            }
        },
        else => problems.add(path, "expected an id"),
    }
}

fn validate_group(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.kind == .group);
    std.debug.assert(path.len > 0);

    const object = switch (value) {
        .object => |object| object,
        else => {
            problems.add(path, "expected an object");

            return;
        },
    };

    for (def.fields) |child| {
        var path_buffer: [field.path_len_max]u8 = undefined;
        const child_path = std.fmt.bufPrint(
            &path_buffer,
            "{s}.{s}",
            .{ path, child.name },
        ) catch path;

        validate_field(child, object.get(child.name), child_path, problems);
    }
}

fn validate_repeater(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.kind == .repeater);
    std.debug.assert(path.len > 0);

    const items = switch (value) {
        .array => |array| array.items,
        else => {
            problems.add(path, "expected a list");

            return;
        },
    };

    if (items.len > repeater_items_max) {
        problems.add(path, "too many items");

        return;
    }

    for (items, 0..) |item, index| {
        var path_buffer: [field.path_len_max]u8 = undefined;
        const item_path = std.fmt.bufPrint(&path_buffer, "{s}[{d}]", .{ path, index }) catch path;
        const as_group: Def = .{
            .name = def.name,
            .label = def.label,
            .kind = .group,
            .fields = def.fields,
        };

        validate_group(as_group, item, item_path, problems);
    }
}

pub fn valid_slug(text: []const u8) bool {
    std.debug.assert(string_len_max > 0);

    if (text.len == 0 or text.len > string_len_max) {
        return false;
    }

    for (text, 0..) |char, index| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';
        const hyphen = char == '-' and index > 0 and index + 1 < text.len;

        if (!(lower or digit or hyphen)) {
            return false;
        }
    }

    return true;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(list.len <= field.choices_max);
    std.debug.assert(item.len <= string_len_max);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

const test_defs = [_]Def{
    .{
        .name = "title",
        .label = "Title",
        .kind = .string,
        .required = true,
        .options = .{ .max_len = 10 },
    },
    .{ .name = "slug", .label = "Slug", .kind = .slug },
    .{ .name = "count", .label = "Count", .kind = .integer, .options = .{ .min = 0, .max = 5 } },
    .{
        .name = "kind",
        .label = "Kind",
        .kind = .select,
        .options = .{ .choices = &.{ "a", "b" } },
    },
    .{
        .name = "tags",
        .label = "Tags",
        .kind = .reference,
        .many = true,
        .options = .{ .to = "tag" },
    },
    .{ .name = "gallery", .label = "Gallery", .kind = .repeater, .fields = &.{
        .{ .name = "image", .label = "Image", .kind = .image, .required = true },
    } },
    .{ .name = "seo", .label = "SEO", .kind = .group, .fields = &.{
        .{ .name = "description", .label = "Description", .kind = .text },
    } },
};

fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text[0] == '{');

    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "a valid document passes; every kind of mistake is reported at its path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ok: Problems = .{};
    const good = try parse(arena,
        \\{"title":"Hello","slug":"hello-1","count":3,"kind":"a","tags":["t1","t2"],
        \\ "gallery":[{"image":"m1"}],"seo":{"description":"x"}}
    );
    validate_document(&test_defs, good, &ok);
    try std.testing.expect(ok.is_empty());

    var bad: Problems = .{};
    const wrong = try parse(arena,
        \\{"title":"way too long title","slug":"Bad Slug","count":9,"kind":"z","tags":"t1",
        \\ "gallery":[{}],"seo":{"description":5},"extra":1}
    );
    validate_document(&test_defs, wrong, &bad);
    try std.testing.expectEqual(@as(u32, 8), bad.len);
    try std.testing.expectEqualStrings("gallery[0].image", bad.items[5].path);
    try std.testing.expectEqualStrings("required", bad.items[5].message);
    try std.testing.expectEqualStrings("seo.description", bad.items[6].path);
    try std.testing.expectEqualStrings("extra", bad.items[7].path);

    var missing: Problems = .{};
    validate_document(&test_defs, try parse(arena, "{}"), &missing);
    try std.testing.expectEqual(@as(u32, 1), missing.len);
    try std.testing.expectEqualStrings("title", missing.items[0].path);
}
