//! Schema Registry
//!
//! Merges content types from all three layers:
//! 1. Core schemas (src/schemas/) - reserved names like post, page
//! 2. Plugin schemas - auto-prefixed with plugin name (e.g., ecommerce:product)
//! 3. Instance schemas (schema.zig in project root)
//!
//! Conflict handling:
//! - Plugin schemas are prefixed: no conflicts possible between plugins
//! - Instance conflicts with core: compile error
//! - Instance conflicts with itself: compile error
//! - No silent overrides

const std = @import("std");
const field_mod = @import("field");
const content_type_mod = @import("content_type");

const FieldDef = field_mod.FieldDef;
const Position = field_mod.Position;
const TranslatableMode = field_mod.TranslatableMode;
const SchemaSource = content_type_mod.SchemaSource;

// Import core schemas
const core_schemas = @import("schemas");

/// Content type entry in registry
pub const ContentTypeEntry = struct {
    /// Content type identifier (e.g., "post", "ecommerce:product")
    id: []const u8,
    /// Human-readable name
    display_name: []const u8,
    /// Human-readable plural name
    display_name_plural: []const u8 = "",
    /// Source layer
    source: SchemaSource,
    /// Whether this content type is localized
    localized: bool = false,
    /// Available locales for this content type
    available_locales: []const []const u8 = &.{},
    /// Workflow identifier (null means default)
    workflow: ?[]const u8 = null,
    /// Hidden from content creation menus
    internal: bool = false,
    /// Taxonomy marker
    is_taxonomy: bool = false,
    /// Icon id used in admin navigation
    icon: []const u8 = "bookmark",
    /// Field definitions
    fields: []const FieldDef,
};

pub const FieldInfo = struct {
    name: []const u8,
    display_name: []const u8,
    field_type: []const u8,
    required: bool,
    translatable_mode: TranslatableMode,
    position: Position,
};

pub const TypeInfo = struct {
    id: []const u8,
    display_name: []const u8,
    display_name_plural: []const u8,
    icon: []const u8,
    localized: bool,
    internal: bool,
    is_taxonomy: bool,
    fields: []const FieldInfo,
};

/// All registered content types
pub const content_types = buildContentTypeRegistry();
pub const registered_types: []const TypeInfo = buildTypeInfoRegistry();

/// Build the content type registry at comptime
fn buildContentTypeRegistry() []const ContentTypeEntry {
    comptime {
        var entries: [2]ContentTypeEntry = undefined;
        var count: usize = 0;

        // Add core schemas
        entries[count] = .{
            .id = core_schemas.Post.type_id,
            .display_name = core_schemas.Post.display_name,
            .display_name_plural = core_schemas.Post.display_name_plural,
            .source = .core,
            .localized = core_schemas.Post.localized,
            .available_locales = core_schemas.Post.available_locales,
            .workflow = core_schemas.Post.workflow,
            .internal = core_schemas.Post.internal,
            .is_taxonomy = core_schemas.Post.is_taxonomy,
            .icon = core_schemas.Post.icon,
            .fields = core_schemas.Post.schema,
        };
        count += 1;

        entries[count] = .{
            .id = core_schemas.Page.type_id,
            .display_name = core_schemas.Page.display_name,
            .display_name_plural = core_schemas.Page.display_name_plural,
            .source = .core,
            .localized = core_schemas.Page.localized,
            .available_locales = core_schemas.Page.available_locales,
            .workflow = core_schemas.Page.workflow,
            .internal = core_schemas.Page.internal,
            .is_taxonomy = core_schemas.Page.is_taxonomy,
            .icon = core_schemas.Page.icon,
            .fields = core_schemas.Page.schema,
        };
        count += 1;

        // TODO: Add plugin schemas (auto-prefixed)
        // TODO: Add instance schemas (with conflict detection)

        const result = entries[0..count].*;
        return &result;
    }
}

fn buildTypeInfoRegistry() []const TypeInfo {
    comptime {
        var infos: [content_types.len]TypeInfo = undefined;
        for (content_types, 0..) |ct, i| {
            var fields: [ct.fields.len]FieldInfo = undefined;
            for (ct.fields, 0..) |field, fi| {
                fields[fi] = .{
                    .name = field.name,
                    .display_name = field.display_name,
                    .field_type = field.field_type_id,
                    .required = field.required,
                    .translatable_mode = field.translatable_mode,
                    .position = field.position,
                };
            }
            const finalized_fields = fields;
            infos[i] = .{
                .id = ct.id,
                .display_name = ct.display_name,
                .display_name_plural = ct.display_name_plural,
                .icon = ct.icon,
                .localized = ct.localized,
                .internal = ct.internal,
                .is_taxonomy = ct.is_taxonomy,
                .fields = &finalized_fields,
            };
        }
        const result = infos;
        return &result;
    }
}

/// Find content type by ID
pub fn findById(comptime id: []const u8) ?ContentTypeEntry {
    inline for (content_types) |ct| {
        if (comptime std.mem.eql(u8, ct.id, id)) {
            return ct;
        }
    }
    return null;
}

/// Find content type by ID at runtime
pub fn findByIdRuntime(id: []const u8) ?ContentTypeEntry {
    for (content_types) |ct| {
        if (std.mem.eql(u8, ct.id, id)) {
            return ct;
        }
    }
    return null;
}

pub fn getTypeInfo(type_id: []const u8) ?TypeInfo {
    for (registered_types) |info| {
        if (std.mem.eql(u8, info.id, type_id)) return info;
    }
    return null;
}

/// Get all content type IDs
pub fn getIds() []const []const u8 {
    comptime {
        var ids: [content_types.len][]const u8 = undefined;
        for (content_types, 0..) |ct, i| {
            ids[i] = ct.id;
        }
        const result = ids;
        return &result;
    }
}

/// Get all core content type IDs (reserved names)
pub fn getCoreIds() []const []const u8 {
    return &core_schemas.reserved_ids;
}

/// Check if an ID is a reserved core content type
pub fn isReserved(id: []const u8) bool {
    return core_schemas.isReserved(id);
}

/// Get content types by source
pub fn getBySource(comptime source: SchemaSource) []const ContentTypeEntry {
    comptime {
        var count: usize = 0;
        for (content_types) |ct| {
            if (ct.source == source) count += 1;
        }

        var result: [count]ContentTypeEntry = undefined;
        var i: usize = 0;
        for (content_types) |ct| {
            if (ct.source == source) {
                result[i] = ct;
                i += 1;
            }
        }
        const final = result;
        return &final;
    }
}

/// All taxonomy IDs used across all content types (computed at comptime)
pub const all_taxonomy_ids: []const []const u8 = computeTaxonomyIds();

fn computeTaxonomyIds() []const []const u8 {
    comptime {
        // First pass: count unique taxonomy IDs
        var seen: [64][]const u8 = undefined;
        var seen_count: usize = 0;

        for (content_types) |ct| {
            for (ct.fields) |f| {
                if (f.storage == .taxonomy) {
                    if (f.taxonomy_id) |tax_id| {
                        var found = false;
                        for (seen[0..seen_count]) |s| {
                            if (std.mem.eql(u8, s, tax_id)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            seen[seen_count] = tax_id;
                            seen_count += 1;
                        }
                    }
                }
            }
        }

        const result = seen[0..seen_count].*;
        return &result;
    }
}

/// Get all taxonomy IDs (legacy function - use all_taxonomy_ids constant)
pub fn getAllTaxonomyIds() []const []const u8 {
    return all_taxonomy_ids;
}

// =============================================================================
// Tests
// =============================================================================

test "content_types includes core schemas" {
    try std.testing.expect(content_types.len >= 2);

    // Check that core types are present
    try std.testing.expect(findById("post") != null);
    try std.testing.expect(findById("page") != null);
}

test "findById returns correct content type" {
    const post = findById("post").?;
    try std.testing.expectEqualStrings("post", post.id);
    try std.testing.expectEqualStrings("Blog Post", post.display_name);
    try std.testing.expect(post.source == .core);
}

test "findById returns null for unknown type" {
    try std.testing.expect(findById("unknown") == null);
}

test "getIds returns all content type IDs" {
    const ids = getIds();
    try std.testing.expect(ids.len == content_types.len);
}

test "isReserved returns true for core types" {
    try std.testing.expect(isReserved("post"));
    try std.testing.expect(isReserved("page"));
}

test "isReserved returns false for non-core types" {
    try std.testing.expect(!isReserved("recipe"));
    try std.testing.expect(!isReserved("product"));
}

test "getBySource returns only core types" {
    const core = getBySource(.core);
    try std.testing.expect(core.len == 2);
    for (core) |ct| {
        try std.testing.expect(ct.source == .core);
    }
}

test "getAllTaxonomyIds returns unique taxonomy IDs" {
    const taxonomies = getAllTaxonomyIds();
    // Post has category and tag
    try std.testing.expect(taxonomies.len >= 2);
}

test "registered_types contains all content types" {
    try std.testing.expectEqual(content_types.len, registered_types.len);
    try std.testing.expect(getTypeInfo("post") != null);
    try std.testing.expect(getTypeInfo("page") != null);
}

test "getTypeInfo returns correct fields for post" {
    const info = getTypeInfo("post").?;
    try std.testing.expectEqualStrings("post", info.id);
    try std.testing.expect(info.fields.len > 0);

    var has_title = false;
    for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "title")) {
            has_title = true;
            try std.testing.expect(field.required);
        }
    }
    try std.testing.expect(has_title);
}

test "getTypeInfo returns null for unknown type" {
    try std.testing.expect(getTypeInfo("unknown_type") == null);
}

test "FieldInfo captures required and translatable flags" {
    const info = getTypeInfo("post").?;
    for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "title")) {
            try std.testing.expect(field.required);
        }
        if (std.mem.eql(u8, field.name, "author")) {
            try std.testing.expect(field.translatable_mode == .synced);
        }
    }
}

test "registry: public API coverage" {
    _ = findById;
    _ = findByIdRuntime;
    _ = getTypeInfo;
    _ = getIds;
    _ = getCoreIds;
    _ = isReserved;
    _ = getBySource;
    _ = getAllTaxonomyIds;
}
