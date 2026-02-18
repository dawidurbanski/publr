//! Media Query Plugin API
//!
//! Re-exports media listing, counting, and date query functions.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const count = try publr.media_query.countMedia(db, .{});
//! const items = try publr.media_query.listMedia(allocator, db, .{ .limit = 20 });
//! ```

const query = @import("media_query");

// =========================================================================
// Types
// =========================================================================

pub const DatePeriod = query.DatePeriod;

// =========================================================================
// List Functions
// =========================================================================

pub const listMedia = query.listMedia;
pub const listMediaByFolderAndTags = query.listMediaByFolderAndTags;
pub const listMediaByTerm = query.listMediaByTerm;
pub const listMediaByTerms = query.listMediaByTerms;
pub const listUnsortedMedia = query.listUnsortedMedia;
pub const listUnreviewedMedia = query.listUnreviewedMedia;

// =========================================================================
// Count Functions
// =========================================================================

pub const countMedia = query.countMedia;
pub const countUnreviewedMedia = query.countUnreviewedMedia;
pub const countUnsortedMedia = query.countUnsortedMedia;
pub const countTagInContext = query.countTagInContext;
pub const countFolderInContext = query.countFolderInContext;
pub const countAllInContext = query.countAllInContext;
pub const countUnsortedInContext = query.countUnsortedInContext;

// =========================================================================
// Date Queries
// =========================================================================

pub const getDistinctDatePeriods = query.getDistinctDatePeriods;
pub const getDistinctYears = query.getDistinctYears;
pub const getMonthsForYear = query.getMonthsForYear;
