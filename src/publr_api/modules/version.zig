//! Version Plugin API
//!
//! Re-exports version history, comparison, restoration, and formatting.
//! NOT included: jsonValueToString, writeEscaped (internal formatting helpers).
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const versions = try publr.version.listVersions(allocator, db, entry_id, .{});
//! const time_str = try publr.version.formatRelativeTime(allocator, timestamp);
//! ```

const version = @import("version");

// =========================================================================
// Types
// =========================================================================

pub const Version = version.Version;
pub const FieldComparison = version.FieldComparison;

// =========================================================================
// Version Operations
// =========================================================================

pub const listVersions = version.listVersions;
pub const getVersion = version.getVersion;
pub const restoreVersion = version.restoreVersion;
pub const restoreVersionWithData = version.restoreVersionWithData;

// =========================================================================
// Comparison & Formatting
// =========================================================================

pub const compareVersionFields = version.compareVersionFields;
pub const populateFieldAuthors = version.populateFieldAuthors;
pub const diffVersions = version.diffVersions;
pub const formatRelativeTime = version.formatRelativeTime;
pub const pruneVersions = version.pruneVersions;
