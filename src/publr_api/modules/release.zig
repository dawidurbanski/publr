//! Release Plugin API
//!
//! Re-exports release management operations — publishing, reverting,
//! scheduling, batch releases, and pending release queries.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! try publr.release.publishEntry(allocator, db, entry_id, author_id, null);
//! const releases = try publr.release.listReleases(allocator, db, .{});
//! ```

const release = @import("release");

// =========================================================================
// Types
// =========================================================================

pub const ReleaseError = release.ReleaseError;
pub const PendingReleaseOption = release.PendingReleaseOption;
pub const ReleaseListItem = release.ReleaseListItem;
pub const ReleaseDetailItem = release.ReleaseDetailItem;
pub const ReleaseDetail = release.ReleaseDetail;
pub const EntryReleaseFieldInfo = release.EntryReleaseFieldInfo;

// =========================================================================
// Release Operations
// =========================================================================

pub const getEntryVersionId = release.getEntryVersionId;
pub const getPublishedData = release.getPublishedData;
pub const discardToPublished = release.discardToPublished;
pub const mergeJsonFields = release.mergeJsonFields;
pub const publishEntry = release.publishEntry;
pub const revertRelease = release.revertRelease;
pub const reReleaseReverted = release.reReleaseReverted;
pub const scheduleRelease = release.scheduleRelease;

// =========================================================================
// Batch Release Operations
// =========================================================================

pub const createPendingRelease = release.createPendingRelease;
pub const addToRelease = release.addToRelease;
pub const removeFromRelease = release.removeFromRelease;
pub const archiveRelease = release.archiveRelease;
pub const publishBatchRelease = release.publishBatchRelease;
pub const publishBatchReleaseWithSkips = release.publishBatchReleaseWithSkips;
pub const ReleaseFieldConflict = release.ReleaseFieldConflict;
pub const detectReleaseConflicts = release.detectReleaseConflicts;

// =========================================================================
// Release Queries
// =========================================================================

pub const listReleases = release.listReleases;
pub const getRelease = release.getRelease;
pub const listPendingReleases = release.listPendingReleases;
pub const getEntryPendingReleaseIds = release.getEntryPendingReleaseIds;
pub const getEntryPendingReleaseFields = release.getEntryPendingReleaseFields;

// =========================================================================
// Static Functions
// =========================================================================

pub const generateReleaseId = release.generateReleaseId;
