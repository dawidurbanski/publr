const std = @import("std");
const db = @import("../lib/db.zig");
const http = @import("../lib/http.zig");
const auth_state = @import("../lib/auth.zig");

/// What every HTTP handler reaches through `ctx.user_data`: the open database, the
/// process's auth state, the io the operations run on, and the folder of the browser
/// build when serving it.
pub const Site = struct {
    connection: *db.Db,
    auth: *auth_state.State,
    io: std.Io,
    static_dir: ?[]const u8 = null,

    pub fn of(ctx: *const http.Context) *Site {
        std.debug.assert(ctx.user_data != null);

        const site: *Site = @ptrCast(@alignCast(ctx.user_data.?));

        std.debug.assert(site.connection.transaction_depth == 0);

        return site;
    }
};
