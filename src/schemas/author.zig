//! Author Content Type - Core Schema
//!
//! Author profiles that can be referenced from posts.

const content_type = @import("content_type");
const field = @import("field");

/// Author profile content type
pub const Author = content_type.ContentType("author", .{ .name = "Author" }, &.{
    // Author display name
    field.String("name", .{ .required = true, .max_length = 100 }),

    // URL slug for author archive pages
    field.Slug("slug", .{ .source = "name", .required = true }),

    // Email address (not displayed publicly by default)
    field.Email("email", .{ .display = "Email Address" }),

    // Short biography
    field.Text("bio", .{ .display = "Biography" }),

    // Author avatar/photo
    field.Image("avatar", .{}),

    // Social links
    field.Url("website", .{ .display = "Website URL" }),
    field.String("twitter", .{ .display = "Twitter Handle" }),
    field.String("github", .{ .display = "GitHub Username" }),

    // Link to user account (optional - authors don't have to be users)
    field.Ref("user", .{ .to = "user", .display = "User Account" }),
});
