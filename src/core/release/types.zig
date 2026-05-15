//! Public types for the release system: errors, listings, detail rows, and
//! conflict structs. Kept in one file so callers can `@import("release").Foo`
//! without paying for the rest of the module.

const std = @import("std");

/// Error returned when a release operation is blocked.
pub const ReleaseError = error{
    ReleaseNotFound,
    InvalidReleaseStatus,
    EntryModifiedSinceRelease,
};

/// Lightweight struct for pending release dropdowns.
pub const PendingReleaseOption = struct {
    id: []const u8,
    name: []const u8,
};

/// One row in the releases list view.
pub const ReleaseListItem = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    item_count: i64,
    author_email: ?[]const u8,
    created_at: i64,
};

/// One item inside a release detail view.
pub const ReleaseDetailItem = struct {
    entry_id: []const u8,
    entry_title: []const u8,
    entry_status: []const u8,
    content_type_id: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    fields: ?[]const u8,
};

/// Full release detail: header + items.
pub const ReleaseDetail = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    author_email: ?[]const u8,
    created_at: i64,
    released_at: ?i64,
    scheduled_for: ?i64,
    reverted_at: ?i64,
    items: []const ReleaseDetailItem,
};

/// Which fields of an entry are in pending releases (for the editor sidebar).
pub const EntryReleaseFieldInfo = struct {
    release_id: []const u8,
    release_name: []const u8,
    fields: ?[]const u8, // JSON array of field names, or null for full publish
    scheduled_for: ?i64 = null,
};

/// A single field conflict in a release.
pub const ReleaseFieldConflict = struct {
    entry_id: []const u8,
    entry_title: []const u8,
    field_name: []const u8,
    release_value: []const u8,
    current_value: []const u8,
};
