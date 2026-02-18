//! Taxonomy Plugin API
//!
//! Re-exports term/taxonomy management for media folders and tags.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const folders = try publr.taxonomy.listTerms(allocator, db, publr.taxonomy.tax_media_folders);
//! try publr.taxonomy.addTermToMedia(db, media_id, term_id);
//! ```

const taxonomy = @import("taxonomy");

// =========================================================================
// Types
// =========================================================================

pub const TermRecord = taxonomy.TermRecord;

// =========================================================================
// Constants
// =========================================================================

pub const tax_media_folders = taxonomy.tax_media_folders;
pub const tax_media_tags = taxonomy.tax_media_tags;

// =========================================================================
// Term CRUD
// =========================================================================

pub const createTerm = taxonomy.createTerm;
pub const listTerms = taxonomy.listTerms;
pub const renameTerm = taxonomy.renameTerm;
pub const deleteTerm = taxonomy.deleteTerm;
pub const moveTermParent = taxonomy.moveTermParent;
pub const deleteTermWithReparent = taxonomy.deleteTermWithReparent;
pub const termExists = taxonomy.termExists;
pub const getDescendantFolderIds = taxonomy.getDescendantFolderIds;

// =========================================================================
// Media-Term Relationships
// =========================================================================

pub const syncMediaTerms = taxonomy.syncMediaTerms;
pub const addTermToMedia = taxonomy.addTermToMedia;
pub const removeTermFromMedia = taxonomy.removeTermFromMedia;
pub const replaceMediaFolder = taxonomy.replaceMediaFolder;
pub const getMediaTermIds = taxonomy.getMediaTermIds;
pub const getMediaTermNames = taxonomy.getMediaTermNames;
pub const countMediaInTerm = taxonomy.countMediaInTerm;
pub const countMediaInFolderRecursive = taxonomy.countMediaInFolderRecursive;

// =========================================================================
// Static Functions
// =========================================================================

pub const slugify = taxonomy.slugify;
pub const generateTermId = taxonomy.generateTermId;
