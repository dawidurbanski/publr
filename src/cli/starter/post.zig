//! Starter: Blog Post content type.
//!
//! Pure-data `ContentTypeDef` produced through the runtime registration
//! API — same code path third-party plugins use. Installed via
//! `publr starter add post`.

const content_type = @import("content_type");
const field = @import("field");

pub const def: content_type.ContentTypeDef = content_type.contentType(.{
    .type_id = "post",
    .display_name = "Blog Post",
    .display_name_plural = "Blog Posts",
    .handle = "posts",
    .icon = "bookmark",
    .fields = &.{
        field.String("title", .{ .required = true, .max_length = 200 }),
        field.Slug("slug", .{ .source = "title", .required = true }),
        field.Text("body", .{ .required = true }),
        field.Ref("author", .{ .to = "author" }),
        field.Taxonomy("category", .{}),
        field.Taxonomy("tag", .{}),
        field.DateTime("published_at", .{ .filterable = true }),
        field.Boolean("featured", .{ .default_value = false }),
        field.Image("featured_image", .{}),
        field.Text("meta_description", .{ .display = "Meta Description" }),
    },
});
