//! Starter: Static Page content type.
//!
//! Pure-data `ContentTypeDef` produced through the runtime registration
//! API — same code path third-party plugins use. Installed via
//! `publr starter add page`.

const content_type = @import("content_type");
const field = @import("field");

pub const def: content_type.ContentTypeDef = content_type.contentType(.{
    .type_id = "page",
    .display_name = "Page",
    .display_name_plural = "Pages",
    .handle = "pages",
    .icon = "file-04",
    .fields = &.{
        field.String("title", .{ .required = true, .max_length = 200 }),
        field.Slug("slug", .{ .source = "title", .required = true }),
        field.Text("body", .{ .required = true }),
        field.Image("featured_image", .{}),
        field.Integer("sort_order", .{
            .display = "Menu Order",
            .min = 0,
            .filterable = true,
        }),
        field.Ref("parent", .{ .to = "page", .display = "Parent Page" }),
        field.Boolean("show_in_menu", .{ .default_value = true, .display = "Show in Menu" }),
        field.Text("meta_description", .{ .display = "Meta Description" }),
        field.Repeater("faq", .{ .label = "FAQ" }, &.{
            field.String("question", .{ .required = true }),
            field.Text("answer", .{ .required = true }),
        }),
    },
});
