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
const mw = @import("middleware");

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

/// HTTP action hook — fires from the admin action dispatcher before the
/// default behavior. Hook can mutate the request/response: setting a 4xx
/// status short-circuits the default. Distinct from the data-layer `Hooks`
/// above (which run from the storage layer with no request context).
pub const ContentActionHookFn = *const fn (ctx: *mw.Context, type_id: []const u8, entry_id: []const u8) anyerror!void;

/// HTTP-aware hooks corresponding to the eight admin actions wired by
/// `content_actions.registerDefaults`. Each is optional; null = use default
/// behavior with no pre-hook.
pub const HttpHooks = struct {
    on_create: ?ContentActionHookFn = null,
    on_update: ?ContentActionHookFn = null,
    on_delete: ?ContentActionHookFn = null,
    on_publish: ?ContentActionHookFn = null,
    on_unpublish: ?ContentActionHookFn = null,
    on_autosave: ?ContentActionHookFn = null,
    on_discard: ?ContentActionHookFn = null,
    on_restore: ?ContentActionHookFn = null,
};

/// Content type configuration
pub const Config = struct {
    /// Human-readable name (e.g., "Blog Post", "Author")
    name: []const u8,
    /// URL handle for theme routing (e.g., "blog" for /blog/:slug).
    /// Defaults to the content type ID if not set.
    handle: ?[]const u8 = null,
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
    /// Optional lifecycle hooks (data layer — runs from storage).
    hooks: Hooks = .{},
    /// Optional HTTP-aware hooks — run from the admin action dispatcher
    /// before the default behavior for each `content.<verb>` action.
    http_hooks: HttpHooks = .{},
    /// Editor plugin id used to render this content type's entry edit page.
    /// Built-in: "form" (default). Future: "block", "gutenberg", etc.
    /// Resolved against the registry in `src/editors.zig` at task-03 dispatch time.
    editor: []const u8 = "form",
};

/// Pure-data content type descriptor.
///
/// Same shape regardless of whether the type was registered from a compile-in
/// plugin, a WASM descriptor, or a DB row. No `type` fields, no comptime-only
/// state — every value is serializable.
///
/// `hooks` and `http_hooks` carry function pointers in native builds; for
/// runtime-loaded descriptors they stay null and event delivery goes through
/// the plugin SDK subscriber table instead.
pub const ContentTypeDef = struct {
    type_id: []const u8,
    display_name: []const u8,
    display_name_plural: []const u8,
    handle: []const u8,
    icon: ?[]const u8 = null,
    localized: bool = false,
    locales: []const []const u8 = &.{},
    workflow: ?[]const u8 = null,
    internal: bool = false,
    taxonomy: ?TaxonomyConfig = null,
    fields: []const FieldDef,
    admin_list_fields: []const []const u8 = &.{},
    field_permissions: []const FieldPermission = &.{},
    hooks: Hooks = .{},
    http_hooks: HttpHooks = .{},
    /// Editor plugin id, e.g. "form" (default), "gutenberg", "block".
    editor: []const u8 = "form",

    /// Synthesize a `Data` struct type from `def.fields`. Only callable
    /// from comptime contexts — used by the data layer's compile-in fast
    /// path to typed-parse JSON into a struct of known shape.
    pub fn zigStructForData(comptime def: ContentTypeDef) type {
        return field_mod.GenerateSubStruct(def.fields);
    }

    /// Custom JSON serializer that emits only the JSON-safe descriptor
    /// fields. Skips `hooks` and `http_hooks` (function pointers can't
    /// be serialized); summarizes `fields` to name/type/required metadata.
    pub fn jsonStringify(self: ContentTypeDef, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type_id");
        try jw.write(self.type_id);
        try jw.objectField("display_name");
        try jw.write(self.display_name);
        try jw.objectField("display_name_plural");
        try jw.write(self.display_name_plural);
        try jw.objectField("handle");
        try jw.write(self.handle);
        try jw.objectField("icon");
        try jw.write(self.icon);
        try jw.objectField("localized");
        try jw.write(self.localized);
        try jw.objectField("locales");
        try jw.write(self.locales);
        try jw.objectField("workflow");
        try jw.write(self.workflow);
        try jw.objectField("internal");
        try jw.write(self.internal);
        try jw.objectField("is_taxonomy");
        try jw.write(self.taxonomy != null);
        try jw.objectField("editor");
        try jw.write(self.editor);
        try jw.objectField("fields");
        try jw.beginArray();
        for (self.fields) |f| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(f.name);
            try jw.objectField("display_name");
            try jw.write(f.display_name);
            try jw.objectField("field_type_id");
            try jw.write(f.field_type_id);
            try jw.objectField("required");
            try jw.write(f.required);
            try jw.objectField("translatable_mode");
            try jw.write(@tagName(f.translatable_mode));
            try jw.objectField("position");
            try jw.write(@tagName(f.position));
            try jw.objectField("filterable");
            try jw.write(f.filterable);
            try jw.objectField("searchable");
            try jw.write(f.searchable);
            try jw.objectField("multi");
            try jw.write(f.multi);
            try jw.objectField("taxonomy_id");
            try jw.write(f.taxonomy_id);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
};

/// Value-returning content type factory. Replaces the comptime
/// `ContentType(...)` type-factory for the runtime registry path.
///
/// Validates required fields at comptime when `config` is comptime-known
/// (the usual case for compile-in plugins). The returned `ContentTypeDef` is
/// pure data: it can be stored in a runtime hashmap, serialized to JSON, or
/// reconstructed from a DB row. No comptime-generated `Data: type`.
///
/// Plugin author usage:
/// ```zig
/// pub const book = publr.contentType(.{
///     .type_id = "book",
///     .display_name = "Book",
///     .display_name_plural = "Books",
///     .handle = "books",
///     .icon = "book",
///     .fields = &.{
///         publr.field.String("title", .{ .required = true }),
///         publr.field.String("isbn", .{ .filterable = true }),
///     },
/// });
/// ```
pub fn contentType(comptime config: anytype) ContentTypeDef {
    const T = @TypeOf(config);
    const ti = @typeInfo(T);
    if (ti != .@"struct") {
        @compileError("publr.contentType requires a struct literal config");
    }

    if (!@hasField(T, "type_id")) @compileError("publr.contentType requires .type_id");
    if (!@hasField(T, "display_name")) @compileError("publr.contentType requires .display_name");
    if (!@hasField(T, "handle")) @compileError("publr.contentType requires .handle");
    if (!@hasField(T, "fields")) @compileError("publr.contentType requires .fields");

    if (config.type_id.len == 0) @compileError("publr.contentType: type_id cannot be empty");
    if (config.display_name.len == 0) @compileError("publr.contentType: display_name cannot be empty");
    if (config.handle.len == 0) @compileError("publr.contentType: handle cannot be empty");

    const plural = if (@hasField(T, "display_name_plural")) config.display_name_plural else defaultPlural(config.display_name);

    return .{
        .type_id = config.type_id,
        .display_name = config.display_name,
        .display_name_plural = plural,
        .handle = config.handle,
        .icon = if (@hasField(T, "icon")) config.icon else null,
        .localized = if (@hasField(T, "localized")) config.localized else false,
        .locales = if (@hasField(T, "locales")) config.locales else &.{},
        .workflow = if (@hasField(T, "workflow")) config.workflow else null,
        .internal = if (@hasField(T, "internal")) config.internal else false,
        .taxonomy = if (@hasField(T, "taxonomy")) config.taxonomy else null,
        .fields = config.fields,
        .admin_list_fields = if (@hasField(T, "admin_list_fields")) config.admin_list_fields else &.{},
        .field_permissions = if (@hasField(T, "field_permissions")) config.field_permissions else &.{},
        .hooks = if (@hasField(T, "hooks")) config.hooks else .{},
        .http_hooks = if (@hasField(T, "http_hooks")) config.http_hooks else .{},
        .editor = if (@hasField(T, "editor")) config.editor else "form",
    };
}

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

        /// URL handle for theme routing. Falls back to type_id.
        pub const handle = config.handle orelse id;

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

        /// Lifecycle hooks for this content type (data layer).
        pub const hooks = config.hooks;

        /// HTTP-aware hooks for this content type — invoked by the action
        /// dispatcher before each `content.<verb>` default behavior.
        pub const http_hooks = config.http_hooks;

        /// Editor plugin id. Built-in: "form" (default).
        pub const editor = config.editor;

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
        pub fn parseDataFromValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Parsed(Data) {
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
            return comptime filterFields(fields, .locale_specific);
        }

        /// Get fields that are synced across locales (`translatable_mode = .synced`).
        pub fn getSyncedFields() []const FieldDef {
            return comptime filterFields(fields, .synced);
        }

        /// Get fields using default-locale fallback semantics.
        pub fn getFallbackFields() []const FieldDef {
            return comptime filterFields(fields, .fallback);
        }

        /// Get all filterable fields (for entry_meta sync)
        pub fn getFilterableFields() []const FieldDef {
            return comptime filterFields(fields, .filterable);
        }

        /// Get all taxonomy fields (for entry_terms sync)
        pub fn getTaxonomyFields() []const FieldDef {
            return comptime filterFields(fields, .taxonomy);
        }
    };
}

fn hasField(comptime fields: []const FieldDef, comptime field_name: []const u8) bool {
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, field_name)) return true;
    }
    return false;
}

/// Selectors for `filterFields`. Each corresponds to one of the per-field
/// helper accessors on a generated ContentType.
const FieldFilter = enum {
    locale_specific,
    synced,
    fallback,
    filterable,
    taxonomy,
};

fn fieldMatches(comptime f: FieldDef, comptime which: FieldFilter) bool {
    return switch (which) {
        .locale_specific => f.translatable_mode != .synced,
        .synced => f.translatable_mode == .synced,
        .fallback => f.translatable_mode == .with_fallback,
        .filterable => f.storage == .data_and_meta,
        .taxonomy => f.storage == .taxonomy,
    };
}

/// Comptime-only helper used by ContentType accessors. Builds the slice in
/// static storage so callers can return it from a runtime function via
/// `return comptime filterFields(...)`.
fn filterFields(comptime fields: []const FieldDef, comptime which: FieldFilter) []const FieldDef {
    comptime {
        var count: usize = 0;
        for (fields) |f| if (fieldMatches(f, which)) {
            count += 1;
        };

        var result: [count]FieldDef = undefined;
        var i: usize = 0;
        for (fields) |f| if (fieldMatches(f, which)) {
            result[i] = f;
            i += 1;
        };
        const final = result;
        return &final;
    }
}

fn defaultPlural(comptime name: []const u8) []const u8 {
    if (name.len == 0) return name;
    if (name[name.len - 1] == 's') return name;
    return name ++ "s";
}

/// Generate a struct type from field definitions at comptime.
/// Delegates to the shared implementation in field.zig.
fn GenerateDataStruct(comptime fields: []const FieldDef) type {
    return field_mod.GenerateSubStruct(fields);
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

test "contentType factory: builds a ContentTypeDef value from a struct literal" {
    const field = field_mod;
    const book = contentType(.{
        .type_id = "book",
        .display_name = "Book",
        .display_name_plural = "Books",
        .handle = "books",
        .icon = "book",
        .fields = &.{
            field.String("title", .{ .required = true, .max_length = 200 }),
            field.String("isbn", .{ .filterable = true }),
            field.Text("description", .{ .searchable = true }),
        },
    });

    try std.testing.expectEqualStrings("book", book.type_id);
    try std.testing.expectEqualStrings("Book", book.display_name);
    try std.testing.expectEqualStrings("Books", book.display_name_plural);
    try std.testing.expectEqualStrings("books", book.handle);
    try std.testing.expect(book.fields.len == 3);
    try std.testing.expectEqualStrings("title", book.fields[0].name);
    try std.testing.expect(book.fields[1].filterable);
    // No FieldDef.zig_type anywhere — descriptor is pure data.
    try std.testing.expect(!@hasField(@TypeOf(book.fields[0]), "zig_type"));
}

test "contentType factory: display_name_plural defaults via defaultPlural" {
    const field = field_mod;
    const note = contentType(.{
        .type_id = "note",
        .display_name = "Note",
        .handle = "notes",
        .fields = &.{
            field.String("title", .{ .required = true }),
        },
    });
    try std.testing.expectEqualStrings("Notes", note.display_name_plural);
}

test "content_type: public API coverage" {
    _ = ContentType;
    _ = ContentTypeDef;
    _ = contentType;
    _ = @import("nested_type_validation.test.zig");
}
