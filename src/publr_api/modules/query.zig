//! Query Plugin API
//!
//! Re-exports entry query, listing, and counting functions.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const entry = try publr.query.getEntry(schemas.Post, allocator, db, "hello-world");
//! const posts = try publr.query.listEntries(schemas.Post, allocator, db, .{ .limit = 10 });
//! ```

const query = @import("query");

// =========================================================================
// Types
// =========================================================================

pub const Entry = query.Entry;
pub const MetaOp = query.MetaOp;
pub const MetaValue = query.MetaValue;
pub const MetaFilter = query.MetaFilter;
pub const max_meta_filters = query.max_meta_filters;
pub const OrderDir = query.OrderDir;
pub const ListOptions = query.ListOptions;

// =========================================================================
// Query Functions
// =========================================================================

pub const getEntry = query.getEntry;
pub const listEntries = query.listEntries;
pub const listWithMeta = query.listWithMeta;
pub const countEntries = query.countEntries;
