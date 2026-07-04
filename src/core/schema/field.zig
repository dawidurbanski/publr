//! Field aggregator — re-exports types and builder functions from
//! `field/*.zig` submodules. `@import("field").String(...)` etc. continue to
//! resolve unchanged; nothing in the call sites needs to change.
//!
//! Tests stay inline here rather than in a sibling `field.test.zig` because
//! pulling a separate test target into `build.zig` was more wiring than the
//! organization win was worth.

const std = @import("std");

const def = @import("field/def.zig");
const text = @import("field/text.zig");
const ref = @import("field/ref.zig");
const choice = @import("field/choice.zig");
const image_mod = @import("field/image.zig");
const number = @import("field/number.zig");
const web = @import("field/web.zig");
const taxonomy_mod = @import("field/taxonomy.zig");
const zt = @import("field/zig_type.zig");
const container = @import("field/container.zig");

// Types
pub const RenderContext = def.RenderContext;
pub const StorageHint = def.StorageHint;
pub const MetaValueType = def.MetaValueType;
pub const Position = def.Position;
pub const TranslatableMode = def.TranslatableMode;
pub const FieldDef = def.FieldDef;

// Helpers
pub const humanize = def.humanize;
pub const noValidation = def.noValidation;
pub const noRender = def.noRender;
pub const requiredCheck = def.requiredCheck;

// Scalar builders
pub const String = text.String;
pub const Text = text.Text;
pub const Slug = ref.Slug;
pub const Ref = ref.Ref;
pub const Select = choice.Select;
pub const Boolean = choice.Boolean;
pub const DateTime = choice.DateTime;
pub const Image = image_mod.Image;
pub const Integer = number.Integer;
pub const Number = number.Number;
pub const RichText = web.RichText;
pub const Email = web.Email;
pub const Url = web.Url;
pub const Taxonomy = taxonomy_mod.Taxonomy;

// Comptime type derivation
pub const zigTypeFor = zt.zigTypeFor;
pub const GenerateSubStruct = zt.GenerateSubStruct;

// Container builders
pub const Group = container.Group;
pub const Repeater = container.Repeater;

// =============================================================================
// Tests
// =============================================================================

test "humanize converts snake_case to Title Case" {
    comptime {
        if (!std.mem.eql(u8, "Featured Image", humanize("featured_image"))) unreachable;
        if (!std.mem.eql(u8, "Title", humanize("title"))) unreachable;
        if (!std.mem.eql(u8, "Published At", humanize("published_at"))) unreachable;
    }
}

test "String field validates max_length" {
    const field = String("title", .{ .max_length = 5 });
    try std.testing.expect(field.validate("hello") == null);
    try std.testing.expect(field.validate("hello!") != null);
}

test "String field validates required" {
    const field = String("title", .{ .required = true });
    try std.testing.expect(field.validate("") != null);
    try std.testing.expect(field.validate("hello") == null);
}

test "Integer field validates range" {
    const field = Integer("count", .{ .min = 0, .max = 100 });
    try std.testing.expect(field.validate("50") == null);
    try std.testing.expect(field.validate("-1") != null);
    try std.testing.expect(field.validate("101") != null);
    try std.testing.expect(field.validate("abc") != null);
}

test "Slug field validates characters" {
    const field = Slug("slug", .{});
    try std.testing.expect(field.validate("hello-world") == null);
    try std.testing.expect(field.validate("hello_world") == null);
    try std.testing.expect(field.validate("hello world") != null);
    try std.testing.expect(field.validate("hello!") != null);
}

test "Select field validates options" {
    const field = Select("status", .{ .options = &.{ "draft", "published" } });
    try std.testing.expect(field.validate("draft") == null);
    try std.testing.expect(field.validate("published") == null);
    try std.testing.expect(field.validate("invalid") != null);
}

test "Boolean field always validates" {
    const field = Boolean("featured", .{});
    try std.testing.expect(field.validate("true") == null);
    try std.testing.expect(field.validate("false") == null);
    try std.testing.expect(field.validate("") == null);
}

test "fields default to independent translatable mode" {
    const s = String("title", .{});
    try std.testing.expect(s.translatable_mode == .independent);

    const t = Text("body", .{});
    try std.testing.expect(t.translatable_mode == .independent);

    const sel = Select("status", .{ .options = &.{"draft"} });
    try std.testing.expect(sel.translatable_mode == .independent);
}

test "Ref fields are always synced (non-translatable)" {
    const r = Ref("author", .{ .to = "author" });
    try std.testing.expect(r.translatable_mode == .synced);
}

test "Image fields default to synced mode" {
    const img = Image("avatar", .{});
    try std.testing.expect(img.translatable_mode == .synced);
}

test "Image fields support with_fallback mode" {
    const img = Image("hero", .{ .translatable_mode = .with_fallback });
    try std.testing.expect(img.translatable_mode == .with_fallback);
}

test "RichText field validates required" {
    const rt = RichText("body", .{ .required = true });
    try std.testing.expect(rt.validate("") != null);
    try std.testing.expect(rt.validate("<p>Hello</p>") == null);
    try std.testing.expect(rt.validate("plain text") == null);
    try std.testing.expectEqualStrings("richtext", rt.field_type_id);
}

test "RichText field accepts any content when not required" {
    const rt = RichText("body", .{});
    try std.testing.expect(rt.validate("") == null);
    try std.testing.expect(rt.validate("anything") == null);
}

test "Email field validates format" {
    const e = Email("email", .{});
    try std.testing.expect(e.validate("") == null);
    try std.testing.expect(e.validate("user@example.com") == null);
    try std.testing.expect(e.validate("user@localhost") != null);
    try std.testing.expect(e.validate("noatsign") != null);
    try std.testing.expect(e.validate("@example.com") != null);
    try std.testing.expect(e.validate("user@") != null);
    try std.testing.expectEqualStrings("email", e.field_type_id);
}

test "Email field validates required" {
    const e = Email("email", .{ .required = true });
    try std.testing.expect(e.validate("") != null);
    try std.testing.expect(e.validate("user@example.com") == null);
}

test "Url field validates format" {
    const u = Url("website", .{});
    try std.testing.expect(u.validate("") == null);
    try std.testing.expect(u.validate("https://example.com") == null);
    try std.testing.expect(u.validate("http://example.com") == null);
    try std.testing.expect(u.validate("https://x") == null);
    try std.testing.expect(u.validate("example.com") != null);
    try std.testing.expect(u.validate("ftp://example.com") != null);
    try std.testing.expect(u.validate("https://") != null);
    try std.testing.expect(u.validate("http://") != null);
    try std.testing.expectEqualStrings("url", u.field_type_id);
}

test "Url field validates required" {
    const u = Url("website", .{ .required = true });
    try std.testing.expect(u.validate("") != null);
    try std.testing.expect(u.validate("https://example.com") == null);
}

test "Group generates nested struct type" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{}),
        Text("meta_description", .{}),
    });

    try std.testing.expectEqualStrings("group", group.field_type_id);
    try std.testing.expectEqualStrings("seo", group.name);
    try std.testing.expectEqualStrings("Seo", group.display_name);
    try std.testing.expect(group.sub_fields.len == 2);

    const info = @typeInfo(zigTypeFor(group));
    try std.testing.expect(info == .@"struct");
    try std.testing.expect(info.@"struct".fields.len == 2);
    try std.testing.expectEqualStrings("meta_title", info.@"struct".fields[0].name);
    try std.testing.expectEqualStrings("meta_description", info.@"struct".fields[1].name);
}

test "Group JSON round-trip" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
        String("meta_description", .{}),
    });

    const json =
        \\{"meta_title":"Hello","meta_description":"World"}
    ;

    const parsed = try std.json.parseFromSlice(zigTypeFor(group), std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello", parsed.value.meta_title);
    try std.testing.expect(parsed.value.meta_description != null);
    try std.testing.expectEqualStrings("World", parsed.value.meta_description.?);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try buf.writer(std.testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});
    try std.testing.expectEqualStrings(json, buf.items);
}

test "Nested Group (Group inside Group)" {
    const inner = Group("og", .{}, &.{
        String("title", .{}),
        String("image", .{}),
    });

    const outer = Group("seo", .{}, &.{
        String("meta_title", .{}),
        inner,
    });

    const info = @typeInfo(zigTypeFor(outer));
    try std.testing.expect(info == .@"struct");
    try std.testing.expect(info.@"struct".fields.len == 2);

    const inner_type_info = @typeInfo(zigTypeFor(inner));
    try std.testing.expect(inner_type_info == .@"struct");
    try std.testing.expect(inner_type_info.@"struct".fields.len == 2);
}

test "Optional Group parses null and object" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
    });

    const Wrapper = GenerateSubStruct(&.{group});

    {
        const json =
            \\{"seo":{"meta_title":"Hello"}}
        ;
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.seo != null);
        try std.testing.expectEqualStrings("Hello", parsed.value.seo.?.meta_title);
    }

    {
        const json = "{}";
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.seo == null);
    }
}

test "Group validation is no-op at group level" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
    });

    try std.testing.expect(group.validate("") == null);
    try std.testing.expect(group.validate("anything") == null);
}

test "Group render emits fieldset" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
    });

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try group.render(buf.writer(std.testing.allocator).any(), .{
        .name = "seo",
        .display_name = "SEO",
        .value = null,
        .required = false,
        .allocator = std.testing.allocator,
    });

    const html = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, html, "<fieldset class=\"field-group") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-field=\"seo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "SEO") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"seo.meta_title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "</fieldset>") != null);
}

test "Group render populates sub-field values from JSON" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{}),
    });

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try group.render(buf.writer(std.testing.allocator).any(), .{
        .name = "seo",
        .display_name = "SEO",
        .value = "{\"meta_title\":\"Hello World\"}",
        .required = false,
        .allocator = std.testing.allocator,
    });

    const html = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"Hello World\"") != null);
}

test "Conditional Group has condition config" {
    const group = Group("seo", .{ .label = "SEO Settings" }, &.{
        String("meta_title", .{}),
    });

    try std.testing.expectEqualStrings("SEO Settings", group.display_name);
    try std.testing.expectEqualStrings("group", group.field_type_id);
}

test "Repeater generates slice type" {
    const repeater = Repeater("questions", .{}, &.{
        String("question", .{ .required = true }),
        Text("answer", .{ .required = true }),
    });

    try std.testing.expectEqualStrings("repeater", repeater.field_type_id);
    try std.testing.expectEqualStrings("questions", repeater.name);
    try std.testing.expect(repeater.sub_fields.len == 2);

    const info = @typeInfo(zigTypeFor(repeater));
    try std.testing.expect(info == .pointer);
    try std.testing.expect(info.pointer.size == .slice);

    const elem_info = @typeInfo(info.pointer.child);
    try std.testing.expect(elem_info == .@"struct");
    try std.testing.expect(elem_info.@"struct".fields.len == 2);
    try std.testing.expectEqualStrings("question", elem_info.@"struct".fields[0].name);
    try std.testing.expectEqualStrings("answer", elem_info.@"struct".fields[1].name);
}

test "Repeater JSON round-trip" {
    const repeater = Repeater("questions", .{}, &.{
        String("question", .{ .required = true }),
        String("answer", .{ .required = true }),
    });

    const Wrapper = GenerateSubStruct(&.{repeater});

    const json =
        \\{"questions":[{"question":"What?","answer":"A CMS."},{"question":"How?","answer":"Zig."}]}
    ;

    const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.questions.len == 2);
    try std.testing.expectEqualStrings("What?", parsed.value.questions[0].question);
    try std.testing.expectEqualStrings("A CMS.", parsed.value.questions[0].answer);
    try std.testing.expectEqualStrings("How?", parsed.value.questions[1].question);
    try std.testing.expectEqualStrings("Zig.", parsed.value.questions[1].answer);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try buf.writer(std.testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});
    try std.testing.expectEqualStrings(json, buf.items);
}

test "Empty Repeater parses to empty slice" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{ .required = true }),
    });

    const Wrapper = GenerateSubStruct(&.{repeater});

    {
        const json =
            \\{"items":[]}
        ;
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.items.len == 0);
    }

    {
        const json = "{}";
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.items.len == 0);
    }
}

test "Repeater with Group inside — JSON round-trip" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{ .required = true }),
        Group("appearance", .{}, &.{
            String("style", .{}),
            String("icon", .{}),
        }),
    });

    const Wrapper = GenerateSubStruct(&.{repeater});

    const json =
        \\{"items":[{"label":"Products","appearance":{"style":"bold","icon":"star"}}]}
    ;

    const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.items.len == 1);
    try std.testing.expectEqualStrings("Products", parsed.value.items[0].label);
    try std.testing.expect(parsed.value.items[0].appearance != null);
    try std.testing.expectEqualStrings("bold", parsed.value.items[0].appearance.?.style.?);
}

test "Repeater inside Group — JSON round-trip" {
    const group = Group("nav", .{}, &.{
        String("title", .{ .required = true }),
        Repeater("links", .{}, &.{
            String("label", .{ .required = true }),
            String("url", .{ .required = true }),
        }),
    });

    const Wrapper = GenerateSubStruct(&.{group});

    const json =
        \\{"nav":{"title":"Main Nav","links":[{"label":"Home","url":"/"},{"label":"About","url":"/about"}]}}
    ;

    const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.nav != null);
    try std.testing.expectEqualStrings("Main Nav", parsed.value.nav.?.title);
    try std.testing.expect(parsed.value.nav.?.links.len == 2);
    try std.testing.expectEqualStrings("Home", parsed.value.nav.?.links[0].label);
}

test "Nested Repeater within max_depth" {
    const repeater = Repeater("sections", .{ .max_depth = 2 }, &.{
        String("title", .{ .required = true }),
        Repeater("items", .{}, &.{
            String("label", .{ .required = true }),
        }),
    });

    try std.testing.expectEqualStrings("repeater", repeater.field_type_id);
    try std.testing.expect(repeater.sub_fields.len == 2);
}

test "Repeater validation is no-op" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{ .required = true }),
    });

    try std.testing.expect(repeater.validate("") == null);
    try std.testing.expect(repeater.validate("anything") == null);
}

test "Repeater render emits container with items" {
    const repeater = Repeater("questions", .{ .min = 1, .max = 5 }, &.{
        String("question", .{ .required = true }),
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);

    try repeater.render(buf.writer(alloc).any(), .{
        .name = "questions",
        .display_name = "Questions",
        .value = "[{\"question\":\"What?\"}]",
        .required = false,
        .allocator = alloc,
    });

    const html = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"field-repeater\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-widget=\"repeater\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-min=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-max=\"5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"questions._count\" value=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"questions.0.question\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"What?\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<template data-repeater-template>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"questions.__INDEX__.question\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-add") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-up") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-down") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-remove") != null);
}

test "Repeater render with empty value" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{}),
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);

    try repeater.render(buf.writer(alloc).any(), .{
        .name = "items",
        .display_name = "Items",
        .value = null,
        .required = false,
        .allocator = alloc,
    });

    const html = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<template data-repeater-template>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"items.0.label\"") == null);
}

test "field: public API coverage" {
    _ = humanize;
    _ = String;
    _ = Text;
    _ = Slug;
    _ = Ref;
    _ = Select;
    _ = Boolean;
    _ = DateTime;
    _ = Image;
    _ = Integer;
    _ = Number;
    _ = RichText;
    _ = Email;
    _ = Url;
    _ = Taxonomy;
    _ = Group;
    _ = Repeater;
    _ = GenerateSubStruct;
}
