//! Nested Type Validation Tests
//!
//! Validates that @Type-generated nested structs work correctly with std.json.
//! This is a blocking validation for the container-fields epic — Group and
//! Repeater depend on these patterns working.
//!
//! Tests cover: nested structs, slices of structs, optionals, nested-in-nested,
//! and combined patterns (Repeater containing Group).

const std = @import("std");
const testing = std.testing;

// =============================================================================
// Helpers — mirrors GenerateDataStruct pattern from content_type.zig
// =============================================================================

/// Generate a struct type from field name/type pairs at comptime.
/// Simulates what GenerateDataStruct does with FieldDef.zig_type.
fn MakeStruct(comptime fields: []const struct { []const u8, type }) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, 0..) |f, i| {
        struct_fields[i] = .{
            .name = f[0] ++ "",
            .type = f[1],
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(f[1]),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Generate a struct with optional fields (default null).
fn MakeOptionalStruct(comptime fields: []const struct { []const u8, type }) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, 0..) |f, i| {
        const OptType = if (@typeInfo(f[1]) == .optional) f[1] else ?f[1];
        struct_fields[i] = .{
            .name = f[0] ++ "",
            .type = OptType,
            .default_value_ptr = @as(?*const anyopaque, @ptrCast(&@as(OptType, null))),
            .is_comptime = false,
            .alignment = @alignOf(OptType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

// =============================================================================
// Test 1: Nested struct via @Type — simulates Group
// =============================================================================

test "nested struct: @Type struct containing @Type struct" {
    const Inner = MakeStruct(&.{
        .{ "a", []const u8 },
        .{ "b", i64 },
    });

    const Outer = MakeStruct(&.{
        .{ "group", Inner },
    });

    const info = @typeInfo(Outer);
    try testing.expect(info == .@"struct");
    try testing.expect(info.@"struct".fields.len == 1);
    try testing.expectEqualStrings("group", info.@"struct".fields[0].name);

    // Verify the nested field is itself a struct
    const field_info = @typeInfo(info.@"struct".fields[0].type);
    try testing.expect(field_info == .@"struct");
    try testing.expect(field_info.@"struct".fields.len == 2);
}

// =============================================================================
// Test 2: Struct with []NestedStruct field — simulates Repeater
// =============================================================================

test "slice of structs: @Type struct containing []@Type struct" {
    const Item = MakeStruct(&.{
        .{ "a", []const u8 },
    });

    const Container = MakeStruct(&.{
        .{ "items", []Item },
    });

    const info = @typeInfo(Container);
    try testing.expect(info == .@"struct");

    const field_type = info.@"struct".fields[0].type;
    const slice_info = @typeInfo(field_type);
    try testing.expect(slice_info == .pointer);
    try testing.expect(slice_info.pointer.size == .slice);
}

// =============================================================================
// Test 3: JSON parse nested struct — Group shape
// =============================================================================

test "json parse: nested struct from JSON object" {
    const Inner = MakeStruct(&.{
        .{ "a", []const u8 },
        .{ "b", i64 },
    });

    const Outer = MakeStruct(&.{
        .{ "group", Inner },
    });

    const json =
        \\{"group": {"a": "hello", "b": 42}}
    ;

    const parsed = try std.json.parseFromSlice(Outer, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("hello", parsed.value.group.a);
    try testing.expect(parsed.value.group.b == 42);
}

// =============================================================================
// Test 4: JSON parse slice of structs — Repeater shape
// =============================================================================

test "json parse: slice of structs from JSON array" {
    const Item = MakeStruct(&.{
        .{ "a", []const u8 },
    });

    const Container = MakeStruct(&.{
        .{ "items", []Item },
    });

    const json =
        \\{"items": [{"a": "x"}, {"a": "y"}]}
    ;

    const parsed = try std.json.parseFromSlice(Container, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.items.len == 2);
    try testing.expectEqualStrings("x", parsed.value.items[0].a);
    try testing.expectEqualStrings("y", parsed.value.items[1].a);
}

// =============================================================================
// Test 5: JSON serialization round-trip for both shapes
// =============================================================================

test "json serialize: nested struct round-trips through JSON" {
    const Inner = MakeStruct(&.{
        .{ "a", []const u8 },
        .{ "b", i64 },
    });

    const Outer = MakeStruct(&.{
        .{ "group", Inner },
    });

    const json =
        \\{"group":{"a":"hello","b":42}}
    ;

    const parsed = try std.json.parseFromSlice(Outer, testing.allocator, json, .{});
    defer parsed.deinit();

    // Serialize back
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try buf.writer(testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});

    try testing.expectEqualStrings(json, buf.items);
}

test "json serialize: slice of structs round-trips through JSON" {
    const Item = MakeStruct(&.{
        .{ "a", []const u8 },
    });

    const Container = MakeStruct(&.{
        .{ "items", []Item },
    });

    const json =
        \\{"items":[{"a":"x"},{"a":"y"}]}
    ;

    const parsed = try std.json.parseFromSlice(Container, testing.allocator, json, .{});
    defer parsed.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try buf.writer(testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});

    try testing.expectEqualStrings(json, buf.items);
}

// =============================================================================
// Test 6: Optional nested struct — ?NestedStruct
// =============================================================================

test "json parse: optional nested struct parses from object" {
    const Inner = MakeStruct(&.{
        .{ "a", []const u8 },
        .{ "b", i64 },
    });

    const Outer = MakeOptionalStruct(&.{
        .{ "group", Inner },
    });

    const json =
        \\{"group": {"a": "hello", "b": 42}}
    ;

    const parsed = try std.json.parseFromSlice(Outer, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.group != null);
    try testing.expectEqualStrings("hello", parsed.value.group.?.a);
    try testing.expect(parsed.value.group.?.b == 42);
}

test "json parse: optional nested struct parses from null" {
    const Inner = MakeStruct(&.{
        .{ "a", []const u8 },
        .{ "b", i64 },
    });

    const Outer = MakeOptionalStruct(&.{
        .{ "group", Inner },
    });

    const json =
        \\{"group": null}
    ;

    const parsed = try std.json.parseFromSlice(Outer, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.group == null);
}

test "json parse: optional nested struct defaults to null when missing" {
    const Inner = MakeStruct(&.{
        .{ "a", []const u8 },
        .{ "b", i64 },
    });

    const Outer = MakeOptionalStruct(&.{
        .{ "group", Inner },
    });

    const json = "{}";

    const parsed = try std.json.parseFromSlice(Outer, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.group == null);
}

// =============================================================================
// Test 7: Optional slice — ?[]NestedStruct
// =============================================================================

test "json parse: optional slice parses from array" {
    const Item = MakeStruct(&.{
        .{ "a", []const u8 },
    });

    const Container = MakeOptionalStruct(&.{
        .{ "items", []Item },
    });

    const json =
        \\{"items": [{"a": "x"}, {"a": "y"}]}
    ;

    const parsed = try std.json.parseFromSlice(Container, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.items != null);
    try testing.expect(parsed.value.items.?.len == 2);
    try testing.expectEqualStrings("x", parsed.value.items.?[0].a);
}

test "json parse: optional slice parses from null" {
    const Item = MakeStruct(&.{
        .{ "a", []const u8 },
    });

    const Container = MakeOptionalStruct(&.{
        .{ "items", []Item },
    });

    const json =
        \\{"items": null}
    ;

    const parsed = try std.json.parseFromSlice(Container, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.items == null);
}

test "json parse: optional slice defaults to null when missing" {
    const Item = MakeStruct(&.{
        .{ "a", []const u8 },
    });

    const Container = MakeOptionalStruct(&.{
        .{ "items", []Item },
    });

    const json = "{}";

    const parsed = try std.json.parseFromSlice(Container, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.items == null);
}

// =============================================================================
// Test 8: Nested-in-nested — Group inside Group
// =============================================================================

test "nested-in-nested: struct containing struct containing struct" {
    const Deepest = MakeStruct(&.{
        .{ "value", []const u8 },
    });

    const Middle = MakeStruct(&.{
        .{ "deep", Deepest },
        .{ "label", []const u8 },
    });

    const Top = MakeStruct(&.{
        .{ "mid", Middle },
        .{ "title", []const u8 },
    });

    const json =
        \\{"mid": {"deep": {"value": "innermost"}, "label": "middle"}, "title": "top"}
    ;

    const parsed = try std.json.parseFromSlice(Top, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("top", parsed.value.title);
    try testing.expectEqualStrings("middle", parsed.value.mid.label);
    try testing.expectEqualStrings("innermost", parsed.value.mid.deep.value);

    // Round-trip serialization
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try buf.writer(testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});

    // Re-parse serialized output and verify
    const reparsed = try std.json.parseFromSlice(Top, testing.allocator, buf.items, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings("innermost", reparsed.value.mid.deep.value);
}

// =============================================================================
// Test 9: Slice of structs with nested struct — Repeater with Group inside
// =============================================================================

test "repeater with group: slice of structs containing nested struct" {
    const Appearance = MakeStruct(&.{
        .{ "style", []const u8 },
        .{ "icon", []const u8 },
    });

    const NavItem = MakeStruct(&.{
        .{ "label", []const u8 },
        .{ "url", []const u8 },
        .{ "appearance", Appearance },
    });

    const Nav = MakeStruct(&.{
        .{ "items", []NavItem },
    });

    const json =
        \\{"items": [{"label": "Products", "url": "/products", "appearance": {"style": "highlighted", "icon": "star"}}, {"label": "About", "url": "/about", "appearance": {"style": "default", "icon": "info"}}]}
    ;

    const parsed = try std.json.parseFromSlice(Nav, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.items.len == 2);
    try testing.expectEqualStrings("Products", parsed.value.items[0].label);
    try testing.expectEqualStrings("highlighted", parsed.value.items[0].appearance.style);
    try testing.expectEqualStrings("star", parsed.value.items[0].appearance.icon);
    try testing.expectEqualStrings("About", parsed.value.items[1].label);
    try testing.expectEqualStrings("default", parsed.value.items[1].appearance.style);

    // Round-trip
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try buf.writer(testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});

    const reparsed = try std.json.parseFromSlice(Nav, testing.allocator, buf.items, .{});
    defer reparsed.deinit();
    try testing.expect(reparsed.value.items.len == 2);
    try testing.expectEqualStrings("star", reparsed.value.items[0].appearance.icon);
}

// =============================================================================
// Bonus: Mixed required/optional with nested — simulates real ContentType
// =============================================================================

test "mixed: required title with optional group and optional repeater" {
    const SeoGroup = MakeStruct(&.{
        .{ "meta_title", []const u8 },
        .{ "meta_description", []const u8 },
    });

    const FaqItem = MakeStruct(&.{
        .{ "question", []const u8 },
        .{ "answer", []const u8 },
    });

    // Build struct mimicking GenerateDataStruct: title required, seo/faq optional
    const fields: [3]std.builtin.Type.StructField = .{
        .{
            .name = "title",
            .type = []const u8,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf([]const u8),
        },
        .{
            .name = "seo",
            .type = ?SeoGroup,
            .default_value_ptr = @as(?*const anyopaque, @ptrCast(&@as(?SeoGroup, null))),
            .is_comptime = false,
            .alignment = @alignOf(?SeoGroup),
        },
        .{
            .name = "faq",
            .type = ?[]FaqItem,
            .default_value_ptr = @as(?*const anyopaque, @ptrCast(&@as(?[]FaqItem, null))),
            .is_comptime = false,
            .alignment = @alignOf(?[]FaqItem),
        },
    };

    const Data = @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });

    // Full data
    {
        const json =
            \\{"title": "My Page", "seo": {"meta_title": "SEO Title", "meta_description": "Desc"}, "faq": [{"question": "Q1", "answer": "A1"}]}
        ;

        const parsed = try std.json.parseFromSlice(Data, testing.allocator, json, .{});
        defer parsed.deinit();

        try testing.expectEqualStrings("My Page", parsed.value.title);
        try testing.expect(parsed.value.seo != null);
        try testing.expectEqualStrings("SEO Title", parsed.value.seo.?.meta_title);
        try testing.expect(parsed.value.faq != null);
        try testing.expect(parsed.value.faq.?.len == 1);
        try testing.expectEqualStrings("Q1", parsed.value.faq.?[0].question);
    }

    // Minimal data — only required field
    {
        const json =
            \\{"title": "Minimal"}
        ;

        const parsed = try std.json.parseFromSlice(Data, testing.allocator, json, .{});
        defer parsed.deinit();

        try testing.expectEqualStrings("Minimal", parsed.value.title);
        try testing.expect(parsed.value.seo == null);
        try testing.expect(parsed.value.faq == null);
    }
}
