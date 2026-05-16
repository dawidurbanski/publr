//! Release Management aggregator.
//!
//! Implementation lives in `release/*.zig` submodules; this module is just
//! the public surface. `@import("release").functionName(...)` continues to
//! resolve every function it used to before the split.

const id_gen = @import("id_gen");

const types = @import("release/types.zig");
const internal = @import("release/internal.zig");
const entry_ops_mod = @import("release/entry_ops.zig");
const publish_entry_mod = @import("release/publish_entry.zig");
const revert_mod = @import("release/revert.zig");
const pending_mod = @import("release/pending.zig");
const batch_publish_mod = @import("release/batch_publish.zig");
const queries_mod = @import("release/queries.zig");
const conflicts_mod = @import("release/conflicts.zig");

/// Generate a release ID (rel_ prefix + 16 random alphanumeric chars).
pub const generateReleaseId = id_gen.generateReleaseId;

// Types
pub const ReleaseError = types.ReleaseError;
pub const PendingReleaseOption = types.PendingReleaseOption;
pub const ReleaseListItem = types.ReleaseListItem;
pub const ReleaseDetailItem = types.ReleaseDetailItem;
pub const ReleaseDetail = types.ReleaseDetail;
pub const EntryReleaseFieldInfo = types.EntryReleaseFieldInfo;
pub const ReleaseFieldConflict = types.ReleaseFieldConflict;

// Entry-level operations
pub const getEntryVersionId = entry_ops_mod.getEntryVersionId;
pub const getPublishedData = entry_ops_mod.getPublishedData;
pub const discardToPublished = entry_ops_mod.discardToPublished;
pub const mergeJsonFields = entry_ops_mod.mergeJsonFields;

// Single-entry publish
pub const publishEntry = publish_entry_mod.publishEntry;

// Revert lifecycle
pub const revertRelease = revert_mod.revertRelease;
pub const reReleaseReverted = revert_mod.reReleaseReverted;

// Pending lifecycle
pub const scheduleRelease = pending_mod.scheduleRelease;
pub const createPendingRelease = pending_mod.createPendingRelease;
pub const addToRelease = pending_mod.addToRelease;
pub const removeFromRelease = pending_mod.removeFromRelease;
pub const archiveRelease = pending_mod.archiveRelease;

// Batch publish (unified)
pub const publishBatchRelease = batch_publish_mod.publishBatchRelease;
pub const publishBatchReleaseWithSkips = batch_publish_mod.publishBatchReleaseWithSkips;

// Read-only queries
pub const listReleases = queries_mod.listReleases;
pub const getRelease = queries_mod.getRelease;
pub const listPendingReleases = queries_mod.listPendingReleases;
pub const getEntryPendingReleaseIds = queries_mod.getEntryPendingReleaseIds;
pub const getEntryPendingReleaseFields = queries_mod.getEntryPendingReleaseFields;

// Conflict detection
pub const detectReleaseConflicts = conflicts_mod.detectReleaseConflicts;

test "core release: public API coverage" {
    _ = getEntryVersionId;
    _ = getPublishedData;
    _ = discardToPublished;
    _ = mergeJsonFields;
    _ = publishEntry;
    _ = revertRelease;
    _ = reReleaseReverted;
    _ = scheduleRelease;
    _ = createPendingRelease;
    _ = addToRelease;
    _ = removeFromRelease;
    _ = archiveRelease;
    _ = publishBatchRelease;
    _ = publishBatchReleaseWithSkips;
    _ = detectReleaseConflicts;
    _ = listReleases;
    _ = getRelease;
    _ = listPendingReleases;
    _ = getEntryPendingReleaseIds;
    _ = getEntryPendingReleaseFields;
}

test {
    // Pull in submodule tests
    _ = internal;
    _ = entry_ops_mod;
    _ = publish_entry_mod;
    _ = revert_mod;
    _ = pending_mod;
    _ = batch_publish_mod;
    _ = queries_mod;
    _ = conflicts_mod;
}
