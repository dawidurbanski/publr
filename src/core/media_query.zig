//! Media query aggregator — re-exports from media_query/*.zig submodules.
//!
//! The query functions live in topic-focused files under `media_query/`;
//! this module is just the public surface. Callers continue to use
//! `@import("media_query").listMedia(...)` etc.; nothing about the call
//! sites changes when functions move between submodules.

const list_basic = @import("media_query/list_basic.zig");
const list_by_terms = @import("media_query/list_by_terms.zig");
const list_special = @import("media_query/list_special.zig");
const count_basic = @import("media_query/count_basic.zig");
const count_context = @import("media_query/count_context.zig");
const periods = @import("media_query/periods.zig");

/// SQL filter clause + bind helpers shared across the query files.
/// Exposed for ad-hoc reuse, but most callers should rely on the existing
/// list/count entry points above.
pub const common = @import("media_query/common.zig");

// List queries
pub const listMedia = list_basic.listMedia;
pub const listMediaByFolderAndTags = list_by_terms.listMediaByFolderAndTags;
pub const listMediaByTerm = list_by_terms.listMediaByTerm;
pub const listMediaByTerms = list_by_terms.listMediaByTerms;
pub const listUnsortedMedia = list_special.listUnsortedMedia;
pub const listUnreviewedMedia = list_special.listUnreviewedMedia;

// Count queries
pub const countMedia = count_basic.countMedia;
pub const countUnreviewedMedia = count_basic.countUnreviewedMedia;
pub const countUnsortedMedia = count_basic.countUnsortedMedia;
pub const countTagInContext = count_context.countTagInContext;
pub const countFolderInContext = count_context.countFolderInContext;
pub const countAllInContext = count_context.countAllInContext;
pub const countUnsortedInContext = count_context.countUnsortedInContext;

// Date period queries
pub const DatePeriod = periods.DatePeriod;
pub const getDistinctDatePeriods = periods.getDistinctDatePeriods;
pub const getDistinctYears = periods.getDistinctYears;
pub const getMonthsForYear = periods.getMonthsForYear;

test "core media_query: public API coverage" {
    _ = listMedia;
    _ = listMediaByFolderAndTags;
    _ = listMediaByTerm;
    _ = listMediaByTerms;
    _ = listUnsortedMedia;
    _ = listUnreviewedMedia;
    _ = countMedia;
    _ = countUnreviewedMedia;
    _ = countUnsortedMedia;
    _ = countTagInContext;
    _ = countFolderInContext;
    _ = countAllInContext;
    _ = countUnsortedInContext;
    _ = getDistinctDatePeriods;
    _ = getDistinctYears;
    _ = getMonthsForYear;
    _ = common;
}

test {
    // Pull in submodule tests so they run when the test suite runs.
    _ = common;
    _ = list_basic;
    _ = list_by_terms;
    _ = list_special;
    _ = count_basic;
    _ = count_context;
    _ = periods;
}
