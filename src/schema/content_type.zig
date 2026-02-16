//! ContentType Comptime Function
//!
//! Generates typed content type structs from field definitions at compile time.
//! The generated type includes a Data struct that can be used for JSON parsing
//! and template rendering.
//!
//! Example:
//! ```zig
//! const Post = ContentType("post", .{ .name = "Blog Post", .localized = true }, &.{
//!     field.String("title", .{ .required = true }),
//!     field.Text("body", .{ .required = true }),
//! });
//!
//! // Post.type_id == "post"
//! // Post.display_name == "Blog Post"
//! // Post.localized == true
//! // Post.Data has fields: title: []const u8, body: []const u8
//! ```

const std = @import("std");
const field_mod = @import("field");
const FieldDef = field_mod.FieldDef;

/// Schema source layer - for tracking where schemas come from
pub const SchemaSource = enum {
    /// Built into CMS core
    core,
    /// From a plugin (will be prefixed with plugin name)
    plugin,
    /// Project-specific (from schema.zig in project root)
    instance,
};

/// Optional taxonomy behavior for a content type.
pub const TaxonomyConfig = struct {
    hierarchical: bool = false,
};

/// Field-level permission contract declared at comptime.
pub const FieldPermission = struct {
    field: []const u8,
    read_capability: ?[]const u8 = null,
    write_capability: ?[]const u8 = null,
};

/// Lifecycle hook context passed to plugin hooks.
pub const HookContext = struct {
    entry_id: []const u8,
    content_type: []const u8,
    locale: []const u8,
    status: []const u8,
    author_id: ?[]const u8 = null,
};

/// Lifecycle hooks a content type can implement.
pub const Hooks = struct {
    on_save: ?*const fn (allocator: std.mem.Allocator, ctx: HookContext, data_json: []const u8) anyerror!void = null,
    on_publish: ?*const fn (allocator: std.mem.Allocator, ctx: HookContext, data_json: []const u8) anyerror!void = null,
    on_archive: ?*const fn (allocator: std.mem.Allocator, ctx: HookContext, data_json: []const u8) anyerror!void = null,
    on_merge: ?*const fn (allocator: std.mem.Allocator, ctx: HookContext, data_json: []const u8) anyerror!void = null,
};

/// Content type configuration
pub const Config = struct {
    /// Human-readable name (e.g., "Blog Post", "Author")
    name: []const u8,
    /// Optional plural display name used in admin list contexts
    name_plural: ?[]const u8 = null,
    /// Optional icon identifier for admin navigation
    icon: ?[]const u8 = null,
    /// Whether this content type supports localization (i18n)
    localized: bool = false,
    /// Explicit locales available for this content type.
    /// When provided, requires `.localized = true`.
    locales: ?[]const []const u8 = null,
    /// Workflow identifier. Null means the implicit default workflow.
    workflow: ?[]const u8 = null,
    /// Internal types are hidden from "new content" menus.
    internal: bool = false,
    /// Marks this content type as a taxonomy term model.
    taxonomy: ?TaxonomyConfig = null,
    /// Optional admin list field order.
    admin_list_fields: []const []const u8 = &.{},
    /// Optional field-level permission declarations.
    field_permissions: []const FieldPermission = &.{},
    /// Optional lifecycle hooks.
    hooks: Hooks = .{},
};

/// Content type definition with metadata and generated Data struct
pub fn ContentType(
    comptime id: []const u8,
    comptime config: Config,
    comptime fields: []const FieldDef,
) type {
    // Validate at comptime
    if (id.len == 0) {
        @compileError("Content type id cannot be empty");
    }
    if (config.name.len == 0) {
        @compileError("Content type display name cannot be empty");
    }

    if (config.locales) |locales| {
        if (locales.len == 0) {
            @compileError("Content type locales cannot be empty when provided");
        }
        if (!config.localized) {
            @compileError("Content type .locales requires .localized = true");
        }
    }

    inline for (config.admin_list_fields) |name| {
        if (!hasField(fields, name)) {
            @compileError("admin_list_fields contains unknown field: " ++ name);
        }
    }

    inline for (config.field_permissions) |perm| {
        if (!hasField(fields, perm.field)) {
            @compileError("field_permissions references unknown field: " ++ perm.field);
        }
    }

    return struct {
        /// Content type identifier (e.g., "post", "author")
        pub const type_id = id;

        /// Human-readable name (e.g., "Blog Post", "Author")
        pub const display_name = config.name;

        /// Human-readable plural label
        pub const display_name_plural = config.name_plural orelse defaultPlural(config.name);

        /// Optional icon identifier
        pub const icon = config.icon orelse "bookmark";

        /// Whether this content type supports localization
        pub const localized = config.localized;

        /// Per-content-type available locales.
        pub const available_locales: []const []const u8 = config.locales orelse &.{};

        /// Workflow identifier. Null means default workflow is used.
        pub const workflow = config.workflow;

        /// Internal types are hidden in content creation menus.
        pub const internal = config.internal;

        /// Optional taxonomy behavior config.
        pub const taxonomy = config.taxonomy;

        /// True when this content type acts as a taxonomy term model.
        pub const is_taxonomy = config.taxonomy != null;

        /// Optional admin list field order.
        pub const admin_list_fields = config.admin_list_fields;

        /// Field-level permission declarations.
        pub const field_permissions = config.field_permissions;

        /// Lifecycle hooks for this content type.
        pub const hooks = config.hooks;

        /// Array of field definitions
        pub const schema = fields;

        /// Generated data struct from field definitions
        pub const Data = GenerateDataStruct(fields);

        /// Source layer (default core, overridden by registry)
        pub const source: SchemaSource = .core;

        /// Parse JSON into typed Data struct
        pub fn parseData(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(Data) {
            return std.json.parseFromSlice(
                Data,
                allocator,
                json,
                .{ .ignore_unknown_fields = true },
            );
        }

        /// Parse JSON with existing Value (for streaming/chunked parsing)
        pub fn parseDataFromValue(allocator: std.mem.Allocator, value: std.json.Value) !Data {
            return std.json.parseFromValue(
                Data,
                allocator,
                value,
                .{ .ignore_unknown_fields = true },
            );
        }

        /// Serialize Data struct to JSON
        pub fn stringifyData(allocator: std.mem.Allocator, data: Data) ![]u8 {
            var list: std.ArrayListUnmanaged(u8) = .{};
            errdefer list.deinit(allocator);
            try list.writer(allocator).print("{f}", .{std.json.fmt(data, .{})});
            return list.toOwnedSlice(allocator);
        }

        /// Get field definition by name
        pub fn getField(comptime field_name: []const u8) ?FieldDef {
            inline for (fields) |f| {
                if (comptime std.mem.eql(u8, f.name, field_name)) {
                    return f;
                }
            }
            return null;
        }

        /// Get field definition by name at runtime
        pub fn getFieldRuntime(field_name: []const u8) ?FieldDef {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    return f;
                }
            }
            return null;
        }

        /// Get field-level permission declaration by field name.
        pub fn getFieldPermissionRuntime(field_name: []const u8) ?FieldPermission {
            for (config.field_permissions) |perm| {
                if (std.mem.eql(u8, perm.field, field_name)) {
                    return perm;
                }
            }
            return null;
        }

        /// Get fields that are locale-specific (`independent` or `with_fallback`).
        pub fn getLocaleSpecificFields() []const FieldDef {
            comptime {
                var count: usize = 0;
                for (fields) |f| {
                    if (f.translatable_mode != .synced) count += 1;
                }

                var result: [count]FieldDef = undefined;
                var i: usize = 0;
                for (fields) |f| {
                    if (f.translatable_mode != .synced) {
                        result[i] = f;
                        i += 1;
                    }
                }
                const final = result;
                return &final;
            }
        }

        /// Get fields that are synced across locales (`translatable_mode = .synced`).
        pub fn getSyncedFields() []const FieldDef {
            comptime {
                var count: usize = 0;
                for (fields) |f| {
                    if (f.translatable_mode == .synced) count += 1;
                }

                var result: [count]FieldDef = undefined;
                var i: usize = 0;
                for (fields) |f| {
                    if (f.translatable_mode == .synced) {
                        result[i] = f;
                        i += 1;
                    }
                }
                const final = result;
                return &final;
            }
        }

        /// Get fields using default-locale fallback semantics.
        pub fn getFallbackFields() []const FieldDef {
            comptime {
                var count: usize = 0;
                for (fields) |f| {
                    if (f.translatable_mode == .with_fallback) count += 1;
                }

                var result: [count]FieldDef = undefined;
                var i: usize = 0;
                for (fields) |f| {
                    if (f.translatable_mode == .with_fallback) {
                        result[i] = f;
                        i += 1;
                    }
                }
                const final = result;
                return &final;
            }
        }

        /// Get all filterable fields (for entry_meta sync)
        pub fn getFilterableFields() []const FieldDef {
            comptime {
                var count: usize = 0;
                for (fields) |f| {
                    if (f.storage == .data_and_meta) count += 1;
                }

                var result: [count]FieldDef = undefined;
                var i: usize = 0;
                for (fields) |f| {
                    if (f.storage == .data_and_meta) {
                        result[i] = f;
                        i += 1;
                    }
                }
                const final = result;
                return &final;
            }
        }

        /// Get all taxonomy fields (for entry_terms sync)
        pub fn getTaxonomyFields() []const FieldDef {
            comptime {
                var count: usize = 0;
                for (fields) |f| {
                    if (f.storage == .taxonomy) count += 1;
                }

                var result: [count]FieldDef = undefined;
                var i: usize = 0;
                for (fields) |f| {
                    if (f.storage == .taxonomy) {
                        result[i] = f;
                        i += 1;
                    }
                }
                const final = result;
                return &final;
            }
        }
    };
}

fn hasField(comptime fields: []const FieldDef, comptime field_name: []const u8) bool {
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, field_name)) return true;
    }
    return false;
}

fn defaultPlural(comptime name: []const u8) []const u8 {
    if (name.len == 0) return name;
    if (name[name.len - 1] == 's') return name;
    return name ++ "s";
}

/// Generate a struct type from field definitions at comptime
fn GenerateDataStruct(comptime fields: []const FieldDef) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, 0..) |f, i| {
        // Determine the Zig type for this field
        // Required fields are non-optional, optional fields are wrapped in ?T
        const FieldType = if (f.required)
            f.zig_type
        else
            // If the type is already optional, use it as-is
            if (@typeInfo(f.zig_type) == .optional)
                f.zig_type
            else
                ?f.zig_type;

        // Create the struct field
        struct_fields[i] = .{
            .name = f.name ++ "", // Ensure we have a proper string literal
            .type = FieldType,
            .default_value_ptr = if (f.required)
                null
            else
                // Default to null for optional fields
                @as(?*const anyopaque, @ptrCast(&@as(FieldType, null))),
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
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
// Tests
// =============================================================================

test "ContentType generates correct type_id and display_name" {
    const Post = ContentType("post", .{ .name = "Blog Post" }, &.{});
    try std.testing.expectEqualStrings("post", Post.type_id);
    try std.testing.expectEqualStrings("Blog Post", Post.display_name);
    try std.testing.expectEqualStrings("Blog Posts", Post.display_name_plural);
    try std.testing.expect(!Post.localized);
}

test "ContentType config with localized and locales" {
    const Post = ContentType("post", .{
        .name = "Blog Post",
        .localized = true,
        .locales = &.{ "en", "fr" },
        .workflow = "editorial_review",
    }, &.{});

    try std.testing.expect(Post.localized);
    try std.testing.expect(Post.available_locales.len == 2);
    try std.testing.expectEqualStrings("en", Post.available_locales[0]);
    try std.testing.expectEqualStrings("editorial_review", Post.workflow.?);
}

test "ContentType Data struct has correct fields" {
    const field = field_mod;
    const Post = ContentType("post", .{ .name = "Test Post" }, &.{
        field.String("title", .{ .required = true }),
        field.Text("body", .{ .required = true }),
        field.Boolean("featured", .{}),
    });

    // Check that Data struct exists and has expected fields
    const DataInfo = @typeInfo(Post.Data);
    try std.testing.expect(DataInfo == .@"struct");

    const struct_info = DataInfo.@"struct";
    try std.testing.expect(struct_info.fields.len == 3);

    // Check field names
    try std.testing.expectEqualStrings("title", struct_info.fields[0].name);
    try std.testing.expectEqualStrings("body", struct_info.fields[1].name);
    try std.testing.expectEqualStrings("featured", struct_info.fields[2].name);
}

test "ContentType Data parses JSON correctly" {
    const field = field_mod;
    const Article = ContentType("article", .{ .name = "Article" }, &.{
        field.String("title", .{ .required = true }),
        field.Integer("views", .{}),
    });

    const json =
        \\{"title": "Hello World", "views": 42}
    ;

    const parsed = try Article.parseData(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello World", parsed.value.title);
    try std.testing.expect(parsed.value.views.? == 42);
}

test "ContentType Data handles missing optional fields" {
    const field = field_mod;
    const Article = ContentType("article", .{ .name = "Article" }, &.{
        field.String("title", .{ .required = true }),
        field.Integer("views", .{}),
    });

    const json =
        \\{"title": "Hello World"}
    ;

    const parsed = try Article.parseData(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello World", parsed.value.title);
    try std.testing.expect(parsed.value.views == null);
}

test "ContentType translatable mode helpers return expected fields" {
    const field = field_mod;
    const Article = ContentType("article", .{ .name = "Article" }, &.{
        field.String("title", .{ .required = true }),
        field.Ref("author", .{ .to = "author" }),
        field.Image("hero", .{ .translatable_mode = .with_fallback }),
    });

    const locale_specific = Article.getLocaleSpecificFields();
    try std.testing.expect(locale_specific.len == 2);

    const synced = Article.getSyncedFields();
    try std.testing.expect(synced.len == 1);
    try std.testing.expectEqualStrings("author", synced[0].name);

    const fallback = Article.getFallbackFields();
    try std.testing.expect(fallback.len == 1);
    try std.testing.expectEqualStrings("hero", fallback[0].name);
}

test "ContentType field permission metadata is exposed" {
    const field = field_mod;
    const Article = ContentType("article", .{
        .name = "Article",
        .field_permissions = &.{
            .{ .field = "title", .write_capability = "content.article.title.write" },
        },
    }, &.{
        field.String("title", .{ .required = true }),
        field.Text("body", .{}),
    });

    const perm = Article.getFieldPermissionRuntime("title");
    try std.testing.expect(perm != null);
    try std.testing.expectEqualStrings("content.article.title.write", perm.?.write_capability.?);
    try std.testing.expect(Article.getFieldPermissionRuntime("body") == null);
}

test "getFilterableFields returns correct fields" {
    const field = field_mod;
    const Car = ContentType("car", .{ .name = "Car" }, &.{
        field.String("name", .{ .required = true }),
        field.Integer("year", .{ .filterable = true }),
        field.Number("price", .{ .filterable = true }),
        field.Text("description", .{}),
    });

    const filterable = Car.getFilterableFields();
    try std.testing.expect(filterable.len == 2);
    try std.testing.expectEqualStrings("year", filterable[0].name);
    try std.testing.expectEqualStrings("price", filterable[1].name);
}

test "getTaxonomyFields returns correct fields" {
    const field = field_mod;
    const Post = ContentType("post", .{ .name = "Post" }, &.{
        field.String("title", .{ .required = true }),
        field.Taxonomy("category", .{}),
        field.Taxonomy("tag", .{}),
    });

    const taxonomies = Post.getTaxonomyFields();
    try std.testing.expect(taxonomies.len == 2);
    try std.testing.expectEqualStrings("category", taxonomies[0].name);
    try std.testing.expectEqualStrings("tag", taxonomies[1].name);
}
