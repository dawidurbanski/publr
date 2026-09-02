const std = @import("std");
const builtin = @import("builtin");
const publr = @import("publr");

const app = publr.app;
const cli = publr.cli;
const registry = publr.registry;
const report = publr.report;
const sdk = publr.sdk;
const version = publr.version;

const db_path_default = "data/publr.db";
const args_max: u32 = 128;

pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch |err| std.debug.print("stdout: {t}\n", .{err});

    var args_storage: [args_max][]const u8 = undefined;
    const args = try collect_args(init, &args_storage);

    std.debug.assert(args.len <= args_max);
    std.debug.assert(db_path_default.len > 0);

    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) {
        try out.print("publr {s}\n", .{version});
        return 0;
    }

    var db_path: [:0]const u8 = db_path_default;
    var rest = args;

    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--db")) {
        db_path = try init.arena.allocator().dupeZ(u8, rest[1]);
        rest = rest[2..];
    }

    if (rest.len >= 1 and std.mem.eql(u8, rest[0], "serve")) {
        if (builtin.os.tag == .wasi) {
            return error.Unsupported;
        }

        return publr.serve.run(init, db_path, rest[1..]);
    }

    var application: app.App = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    const arena_bytes = try init.gpa.alloc(u8, app.request_arena_bytes);
    defer init.gpa.free(arena_bytes);

    var fixed = std.heap.FixedBufferAllocator.init(arena_bytes);

    return cli.CLI(registry.SDK).run(.{
        .db = &application.connection,
        .io = init.io,
        .arena = fixed.allocator(),
        .auth = &application.auth,
        .now_ms = sdk.context.wall_clock_ms(init.io),
        .password_env = init.environ_map.get("PUBLR_PASSWORD"),
    }, rest, out) catch |err| {
        report.err("publr: {s}", .{@errorName(err)});
        return 1;
    };
}

fn collect_args(init: std.process.Init, storage: *[args_max][]const u8) ![]const []const u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());
    var count: u32 = 0;

    _ = iterator.next();

    while (iterator.next()) |arg| : (count += 1) {
        if (count == args_max) {
            return error.TooManyArguments;
        }
        storage[count] = arg;
    }

    std.debug.assert(count <= args_max);
    std.debug.assert(storage.len == args_max);

    return storage[0..count];
}
