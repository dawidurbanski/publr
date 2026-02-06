//! Media Schema Definition
//!
//! Defines the metadata fields stored in the media.data JSON column.
//! Uses the same field system as content types.

const field = @import("field");
const content_type = @import("content_type");

/// Media metadata schema — fields stored in media.data JSON
pub const Media = content_type.ContentType("media", "Media", &.{
    // Alt text for accessibility
    field.String("alt_text", .{ .display = "Alt Text" }),

    // Caption displayed below media
    field.Text("caption", .{}),

    // Credit/attribution (filterable for queries like "all photos by X")
    field.String("credit", .{ .filterable = true }),

    // Focal point for smart cropping (e.g. "50,30" as x,y percentages)
    field.String("focal_point", .{ .display = "Focal Point" }),
});
