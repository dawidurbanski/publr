//! Media Plugin API
//!
//! Re-exports media CRUD operations and types.
//! NOT included: parseMediaRow (internal SQL row parsing).
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const record = try publr.media.getMedia(allocator, db, media_id);
//! try publr.media.deleteMedia(db, media_id);
//! ```

const media = @import("media");

// =========================================================================
// Types
// =========================================================================

pub const MediaRecord = media.MediaRecord;
pub const CreateMediaInput = media.CreateMediaInput;
pub const UploadInput = media.UploadInput;
pub const FocalPoint = media.FocalPoint;
pub const MediaListOptions = media.MediaListOptions;
pub const Visibility = media.Visibility;
pub const StorageBackend = media.StorageBackend;
pub const ImageParams = media.ImageParams;

// =========================================================================
// CRUD Operations
// =========================================================================

pub const createMedia = media.createMedia;
pub const getMedia = media.getMedia;
pub const updateMedia = media.updateMedia;
pub const uploadMedia = media.uploadMedia;
pub const deleteMedia = media.deleteMedia;
pub const fullDeleteMedia = media.fullDeleteMedia;
pub const toggleMediaVisibility = media.toggleMediaVisibility;
pub const getFocalPoint = media.getFocalPoint;
pub const mediaExistsByStorageKey = media.mediaExistsByStorageKey;

// =========================================================================
// Sync Helpers
// =========================================================================

pub const markMediaSynced = media.markMediaSynced;
pub const syncMediaMeta = media.syncMediaMeta;
pub const flagMediaMissing = media.flagMediaMissing;

// =========================================================================
// Static Functions
// =========================================================================

pub const slugify = media.slugify;
pub const generateMediaId = media.generateMediaId;
