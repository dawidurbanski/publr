//! Post Content Type - Core Schema
//!
//! The default blog post content type. Core schemas use the same API as plugins -
//! no special treatment.

const content_type = @import("content_type");
const field = @import("field");

/// Blog post content type
pub const Post = content_type.ContentType("post", .{ .name = "Blog Post" }, &.{
    // Title is promoted to entries.title column
    field.String("title", .{ .required = true, .max_length = 200 }),

    // URL slug, auto-generated from title
    field.Slug("slug", .{ .source = "title", .required = true }),

    // Main content body
    field.Text("body", .{ .required = true }),

    // Reference to author
    field.Ref("author", .{ .to = "author" }),

    // Taxonomies (stored in entry_terms)
    field.Taxonomy("category", .{}),
    field.Taxonomy("tag", .{}),

    // Publication status
    field.Select("status", .{
        .options = &.{ "draft", "published", "archived" },
        .default_value = "draft",
        .filterable = true,
    }),

    // Publication date (filterable for queries)
    field.DateTime("published_at", .{ .filterable = true }),

    // Featured flag
    field.Boolean("featured", .{ .default_value = false }),

    // Featured image (media reference)
    field.Image("featured_image", .{}),

    // SEO meta description
    field.Text("meta_description", .{ .display = "Meta Description" }),
});
