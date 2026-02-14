//! Core Schemas Module
//!
//! Aggregates all core content type schemas. These are the built-in content types
//! that come with Publr CMS.

const content_type = @import("content_type");
const ContentType = content_type.ContentType;

// Import core content types
pub const post = @import("schema_post");
pub const page = @import("schema_page");

// Media schema (not a content type, but follows same field system)
pub const media = @import("schema_media");
pub const Media = media.Media;

/// Core content types - these names are reserved and cannot be used by instance schemas
pub const Post = post.Post;
pub const Page = page.Page;

/// All content types available for generic admin.
/// Iterate with `inline for` to dispatch by type_id at comptime.
pub const content_types = .{ Post, Page };

/// Array of all core content type IDs (for conflict detection)
pub const reserved_ids = [_][]const u8{
    Post.type_id,
    Page.type_id,
};

/// Check if a content type ID is reserved (core)
pub fn isReserved(id: []const u8) bool {
    inline for (reserved_ids) |reserved| {
        if (std.mem.eql(u8, id, reserved)) return true;
    }
    return false;
}

const std = @import("std");

// =============================================================================
// Tests
// =============================================================================

test "core content types have correct IDs" {
    try std.testing.expectEqualStrings("post", Post.type_id);
    try std.testing.expectEqualStrings("page", Page.type_id);
}

test "core content types have display names" {
    try std.testing.expectEqualStrings("Blog Post", Post.display_name);
    try std.testing.expectEqualStrings("Page", Page.display_name);
}

test "isReserved returns true for core types" {
    try std.testing.expect(isReserved("post"));
    try std.testing.expect(isReserved("page"));
}

test "isReserved returns false for non-core types" {
    try std.testing.expect(!isReserved("recipe"));
    try std.testing.expect(!isReserved("product"));
    try std.testing.expect(!isReserved("event"));
    try std.testing.expect(!isReserved("author"));
}

test "Post schema has expected fields" {
    try std.testing.expect(Post.getField("title") != null);
    try std.testing.expect(Post.getField("slug") != null);
    try std.testing.expect(Post.getField("body") != null);
    try std.testing.expect(Post.getField("author") != null);

    const taxonomies = Post.getTaxonomyFields();
    try std.testing.expect(taxonomies.len == 2);
}

test "Page schema has expected fields" {
    try std.testing.expect(Page.getField("title") != null);
    try std.testing.expect(Page.getField("slug") != null);
    try std.testing.expect(Page.getField("body") != null);
    try std.testing.expect(Page.getField("parent") != null);
}

test "Media schema has expected fields" {
    try std.testing.expect(Media.getField("alt_text") != null);
    try std.testing.expect(Media.getField("caption") != null);
    try std.testing.expect(Media.getField("credit") != null);
    try std.testing.expect(Media.getField("focal_point") != null);

    // Credit should be filterable
    const filterable = Media.getFilterableFields();
    try std.testing.expect(filterable.len == 1);
    try std.testing.expectEqualStrings("credit", filterable[0].name);
}
