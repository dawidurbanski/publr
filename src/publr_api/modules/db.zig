//! Database Plugin API
//!
//! Re-exports core database types for plugin use. Plugins receive `*Db` from
//! the auth system and use it for queries.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! fn query(db: *publr.Db) !void {
//!     var stmt = try db.prepare("SELECT * FROM entries WHERE id = ?1");
//!     defer stmt.deinit();
//!     try stmt.bindText(1, "hello");
//!     _ = try stmt.step();
//! }
//! ```

const db = @import("db");

pub const Db = db.Db;
pub const Statement = db.Statement;
pub const Error = db.Db.Error;
