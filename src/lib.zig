//! Mechanisms that know nothing about content: SQLite, HTTP, authentication primitives,
//! ids, text, HTML escaping, error reporting.

pub const db = @import("lib/db.zig");
pub const http = @import("lib/http.zig");
pub const auth = @import("lib/auth.zig");
pub const id = @import("lib/id.zig");
pub const text = @import("lib/text.zig");
pub const html = @import("lib/html.zig");
pub const report = @import("lib/report.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
