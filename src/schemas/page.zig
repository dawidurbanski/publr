//! Page Content Type - Core Schema
//!
//! Static pages for "About", "Contact", etc. Similar to posts but with different
//! default behaviors (no categories/tags, no author).

const content_type = @import("content_type");
const field = @import("field");

/// Static page content type
pub const Page = content_type.ContentType("page", .{ .name = "Page", .handle = "pages" }, &.{
    // Title is promoted to entries.title column
    field.String("title", .{ .required = true, .max_length = 200 }),

    // URL slug, auto-generated from title
    field.Slug("slug", .{ .source = "title", .required = true }),

    // Main content body
    field.Text("body", .{ .required = true }),

    // Featured image (media reference)
    field.Image("featured_image", .{}),

    // Sort order for menu placement
    field.Integer("sort_order", .{
        .display = "Menu Order",
        .min = 0,
        .filterable = true,
    }),

    // Parent page for hierarchical structure
    field.Ref("parent", .{ .to = "page", .display = "Parent Page" }),

    // Show in navigation menu
    field.Boolean("show_in_menu", .{ .default_value = true, .display = "Show in Menu" }),

    // SEO meta description
    field.Text("meta_description", .{ .display = "Meta Description" }),

    // FAQ section
    field.Repeater("faq", .{ .label = "FAQ" }, &.{
        field.String("question", .{ .required = true }),
        field.Text("answer", .{ .required = true }),
    }),
});
