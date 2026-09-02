const std = @import("std");
const db = @import("lib/db.zig");
const auth = @import("lib/auth.zig");
const registry = @import("app/registry.zig");
const sdk = @import("sdk.zig");

pub const db_heap_bytes: u32 = 64 << 20;
pub const request_arena_bytes: u32 = 4 << 20;

pub const App = struct {
    gpa: std.mem.Allocator,
    heap: []align(8) u8,
    runtime: db.Runtime,
    connection: db.Db,
    auth: auth.State,

    pub fn init(app: *App, process: std.process.Init, db_path: [:0]const u8) !void {
        std.debug.assert(db_path.len > 0);
        std.debug.assert(db_heap_bytes >= db.heap_bytes_min);

        try ensure_parent_dir(process.io, db_path);

        app.gpa = process.gpa;
        app.heap = try process.gpa.alignedAlloc(u8, .@"8", db_heap_bytes);
        errdefer process.gpa.free(app.heap);

        app.runtime = try db.Runtime.init(.{ .heap = app.heap });
        errdefer app.runtime.deinit();

        app.connection = try db.open(&app.runtime, db_path);
        errdefer app.connection.close();

        try db.schema.apply(&app.connection);
        try registry.SDK.apply_schemas(&app.connection);
        try app.auth.init(process.gpa, process.io, .{});
        errdefer app.auth.deinit();

        try app.apply_declared_types(process);

        std.debug.assert(app.runtime.open_count == 1);
    }

    fn apply_declared_types(app: *App, process: std.process.Init) !void {
        std.debug.assert(app.connection.transaction_depth == 0);
        std.debug.assert(request_arena_bytes > 0);

        var arena_state = std.heap.ArenaAllocator.init(process.gpa);
        defer arena_state.deinit();

        var ctx = sdk.Ctx.init(.{
            .caller = .system,
            .db = &app.connection,
            .io = process.io,
            .arena = arena_state.allocator(),
            .auth = &app.auth,
            .now_ms = sdk.context.wall_clock_ms(process.io),
        });

        try registry.SDK.bootstrap(&ctx);
    }

    pub fn deinit(app: *App) void {
        std.debug.assert(app.runtime.open_count == 1);
        std.debug.assert(app.connection.transaction_depth == 0);

        app.auth.deinit();
        app.connection.close();
        app.runtime.deinit();
        app.gpa.free(app.heap);
        app.* = undefined;
    }
};

fn ensure_parent_dir(io: std.Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);

    const parent = std.fs.path.dirname(path) orelse return;

    if (parent.len == 0) {
        return;
    }

    std.debug.assert(parent.len < path.len);

    try std.Io.Dir.cwd().createDirPath(io, parent);
}
