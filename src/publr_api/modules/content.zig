//! Content Plugin API
//!
//! Re-exports content lifecycle operations (save, delete, archive, unpublish).
//! NOT included: internal sync functions, ID generation helpers.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const entry = try publr.content.saveEntry(schemas.Post, allocator, db, id, data, .{});
//! try publr.content.deleteEntry(db, entry_id);
//! ```

const cms = @import("cms");

// =========================================================================
// Types
// =========================================================================

pub const Entry = cms.Entry;
pub const Status = cms.Status;
pub const SaveOptions = cms.SaveOptions;
pub const EntryLifecycleError = cms.EntryLifecycleError;

// =========================================================================
// CRUD Operations
// =========================================================================

pub const saveEntry = cms.saveEntry;
pub const deleteEntry = cms.deleteEntry;
pub const archiveEntry = cms.archiveEntry;
pub const unpublishEntry = cms.unpublishEntry;

// =========================================================================
// Static Functions
// =========================================================================

pub const generateId = cms.generateId;
