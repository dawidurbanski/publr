const std = @import("std");
const db = @import("../lib/db.zig");
const Caller = @import("caller.zig").Caller;
const AuthState = @import("../lib/auth.zig").State;
const Notice = @import("middleware.zig").Event.Notice;

pub const OperationId = u64;
pub const request_id_len_max: u32 = 64;

pub const Notify = *const fn (ctx: *Ctx, notice: Notice) void;

pub const Ctx = struct {
    caller: Caller,
    db: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    auth: *AuthState,
    request_id: []const u8 = "",
    parent: ?OperationId = null,
    now_ms: i64,
    next_operation_id: OperationId = 1,
    notify: ?Notify = null,

    pub fn init(options: Options) Ctx {
        std.debug.assert(options.request_id.len <= request_id_len_max);
        std.debug.assert(options.now_ms >= 0);

        return .{
            .caller = options.caller,
            .db = options.db,
            .io = options.io,
            .arena = options.arena,
            .auth = options.auth,
            .request_id = options.request_id,
            .now_ms = options.now_ms,
        };
    }

    pub fn notice(ctx: *Ctx, name: []const u8, subject: []const u8) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.parent != null);

        const emit = ctx.notify orelse return;
        emit(ctx, .{ .operation_id = ctx.parent.?, .name = name, .subject = subject });
    }

    pub fn allocate_operation_id(ctx: *Ctx) OperationId {
        const id = ctx.next_operation_id;
        std.debug.assert(id != 0);

        ctx.next_operation_id += 1;
        std.debug.assert(ctx.next_operation_id > id);

        return id;
    }

    pub const Options = struct {
        caller: Caller,
        db: *db.Db,
        io: std.Io,
        arena: std.mem.Allocator,
        auth: *AuthState,
        request_id: []const u8 = "",
        now_ms: i64 = 0,
    };
};

pub fn wall_clock_ms(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    const ms: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    std.debug.assert(ms >= 0);
    std.debug.assert(ms < std.math.maxInt(i64) / 2);

    return ms;
}

test "operation ids are unique and increasing within a ctx" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var auth_state: AuthState = undefined;
    const params = @import("../lib/auth.zig").password.params_test;
    try auth_state.init(std.testing.allocator, std.testing.io, .{ .params = params });
    defer auth_state.deinit();

    var buffer: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var ctx = Ctx.init(.{
        .caller = .system,
        .db = &fixture.connection,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .auth = &auth_state,
    });

    const first = ctx.allocate_operation_id();
    const second = ctx.allocate_operation_id();

    try std.testing.expect(second > first);
    try std.testing.expectEqual(@as(?OperationId, null), ctx.parent);
    try std.testing.expect(wall_clock_ms(std.testing.io) > 1_700_000_000_000);
}
