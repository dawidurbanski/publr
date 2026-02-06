//! Core Schemas Module
//!
//! Aggregates all core content type schemas. These are the built-in content types
//! that come with Publr CMS.

const content_type = @import("content_type");
const ContentType = content_type.ContentType;

// Import core content types
pub const post = @import("schema_post");
pub const page = @import("schema_page");
pub const author = @import("schema_author");

/// Core content types - these names are reserved and cannot be used by instance schemas
pub const Post = post.Post;
pub const Page = page.Page;
pub const Author = author.Author;

/// Array of all core content type IDs (for conflict detection)
pub const reserved_ids = [_][]const u8{
    Post.type_id,
    Page.type_id,
    Author.type_id,
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
    try std.testing.expectEqualStrings("author", Author.type_id);
}

test "core content types have display names" {
    try std.testing.expectEqualStrings("Blog Post", Post.display_name);
    try std.testing.expectEqualStrings("Page", Page.display_name);
    try std.testing.expectEqualStrings("Author", Author.display_name);
}

test "isReserved returns true for core types" {
    try std.testing.expect(isReserved("post"));
    try std.testing.expect(isReserved("page"));
    try std.testing.expect(isReserved("author"));
}

test "isReserved returns false for non-core types" {
    try std.testing.expect(!isReserved("recipe"));
    try std.testing.expect(!isReserved("product"));
    try std.testing.expect(!isReserved("event"));
}

test "Post schema has expected fields" {
    // Check Post has required fields
    try std.testing.expect(Post.getField("title") != null);
    try std.testing.expect(Post.getField("slug") != null);
    try std.testing.expect(Post.getField("body") != null);
    try std.testing.expect(Post.getField("author") != null);

    // Check Post has taxonomies
    const taxonomies = Post.getTaxonomyFields();
    try std.testing.expect(taxonomies.len == 2);
}

test "Page schema has expected fields" {
    try std.testing.expect(Page.getField("title") != null);
    try std.testing.expect(Page.getField("slug") != null);
    try std.testing.expect(Page.getField("body") != null);
    try std.testing.expect(Page.getField("parent") != null);
}

test "Author schema has expected fields" {
    try std.testing.expect(Author.getField("name") != null);
    try std.testing.expect(Author.getField("slug") != null);
    try std.testing.expect(Author.getField("email") != null);
    try std.testing.expect(Author.getField("bio") != null);
}
