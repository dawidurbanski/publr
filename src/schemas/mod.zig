//! Core Schemas Module.
//!
//! After task 05, this module is mostly a shell: the only built-in schema
//! is `media` (used by the media upload pipeline). Content types (Post,
//! Page, etc.) are installed at runtime through `publr starter add` or
//! plugin registration — none ship as compile-in defaults.

const std = @import("std");
const content_type = @import("content_type");
const ContentTypeDef = content_type.ContentTypeDef;

// Media schema (not a content type, but follows same field system).
// Stays as a named module because it's also consumed by db_init, the main
// exe, the WASM build, and admin plugins.
pub const media = @import("schema_media");
pub const Media = media.Media;

/// No compile-in content types ship with core. Starters and plugins
/// populate the runtime registry at boot. Kept as an empty slice so
/// downstream comptime iterations (`for (content_type_defs) |…|`) compile.
pub const content_type_defs: []const ContentTypeDef = &.{};

/// No reserved type-id prefixes ship with core. The runtime registry's
/// own duplicate check (`register` returns `DuplicateContentType`) is
/// what guards against collisions.
pub const reserved_ids: []const []const u8 = &.{};

/// Stub: kept for source compatibility — there are no built-in reserved
/// ids any more, so the answer is always false.
pub fn isReserved(_: []const u8) bool {
    return false;
}

test "schemas: public API coverage" {
    _ = content_type_defs;
    _ = reserved_ids;
    _ = isReserved;
    _ = Media;
}

test "Media schema has expected fields" {
    try std.testing.expect(Media.getField("alt_text") != null);
    try std.testing.expect(Media.getField("caption") != null);
    try std.testing.expect(Media.getField("credit") != null);
    try std.testing.expect(Media.getField("focal_point") != null);

    const filterable = Media.getFilterableFields();
    try std.testing.expect(filterable.len == 1);
    try std.testing.expectEqualStrings("credit", filterable[0].name);
}

test "content_type_defs is empty out of the box" {
    try std.testing.expectEqual(@as(usize, 0), content_type_defs.len);
}
