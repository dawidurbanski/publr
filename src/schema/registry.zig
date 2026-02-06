//! Schema Registry
//!
//! Merges content types from all three layers:
//! 1. Core schemas (src/schemas/) - reserved names like post, page, author
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
const SchemaSource = content_type_mod.SchemaSource;

// Import core schemas
const core_schemas = @import("schemas");

/// Content type entry in registry
pub const ContentTypeEntry = struct {
    /// Content type identifier (e.g., "post", "ecommerce:product")
    id: []const u8,
    /// Human-readable name
    display_name: []const u8,
    /// Source layer
    source: SchemaSource,
    /// Field definitions
    fields: []const FieldDef,
};

/// All registered content types
pub const content_types = buildContentTypeRegistry();

/// Build the content type registry at comptime
fn buildContentTypeRegistry() []const ContentTypeEntry {
    comptime {
        var entries: [3]ContentTypeEntry = undefined;
        var count: usize = 0;

        // Add core schemas
        entries[count] = .{
            .id = core_schemas.Post.type_id,
            .display_name = core_schemas.Post.display_name,
            .source = .core,
            .fields = core_schemas.Post.schema,
        };
        count += 1;

        entries[count] = .{
            .id = core_schemas.Page.type_id,
            .display_name = core_schemas.Page.display_name,
            .source = .core,
            .fields = core_schemas.Page.schema,
        };
        count += 1;

        entries[count] = .{
            .id = core_schemas.Author.type_id,
            .display_name = core_schemas.Author.display_name,
            .source = .core,
            .fields = core_schemas.Author.schema,
        };
        count += 1;

        // TODO: Add plugin schemas (auto-prefixed)
        // TODO: Add instance schemas (with conflict detection)

        const result = entries[0..count].*;
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
    try std.testing.expect(content_types.len >= 3);

    // Check that core types are present
    try std.testing.expect(findById("post") != null);
    try std.testing.expect(findById("page") != null);
    try std.testing.expect(findById("author") != null);
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
    try std.testing.expect(isReserved("author"));
}

test "isReserved returns false for non-core types" {
    try std.testing.expect(!isReserved("recipe"));
    try std.testing.expect(!isReserved("product"));
}

test "getBySource returns only core types" {
    const core = getBySource(.core);
    try std.testing.expect(core.len == 3);
    for (core) |ct| {
        try std.testing.expect(ct.source == .core);
    }
}

test "getAllTaxonomyIds returns unique taxonomy IDs" {
    const taxonomies = getAllTaxonomyIds();
    // Post has category and tag
    try std.testing.expect(taxonomies.len >= 2);
}
