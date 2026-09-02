const std = @import("std");
const app = @import("../app.zig");
const report = @import("../lib/report.zig");
const routes = @import("routes.zig");
const http = @import("../lib/http.zig");

const port_default: u16 = 8080;
const browser_port_default: u16 = 8081;
const port_search_max: u16 = 20;
const browser_dir_default = "zig-out/browser";
const loopback: [4]u8 = .{ 127, 0, 0, 1 };

const Flags = struct {
    port: ?u16 = null,
    browser_dir: ?[]const u8 = null,
    exit: ?u8 = null,
};

pub fn run(init: std.process.Init, db_path: [:0]const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(port_default > 0);

    const flags = parse_flags(args);

    if (flags.exit) |code| {
        return code;
    }

    const port = flags.port;
    const browser_dir = flags.browser_dir;

    var application: app.App = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    var site: routes.Site = .{
        .connection = &application.connection,
        .auth = &application.auth,
        .io = init.io,
        .static_dir = browser_dir,
    };
    const first_port = port orelse if (browser_dir != null) browser_port_default else port_default;
    const search_span: u16 = if (port == null) port_search_max else 0;
    var options: http.Options = if (browser_dir != null) .{
        .address = loopback,
        .port = first_port,
        .connections_max = 8,
        .request_bytes_max = 64 << 10,
        .response_bytes_max = 4 << 20,
    } else .{
        .address = loopback,
        .port = first_port,
        .connections_max = 64,
        .request_bytes_max = 64 << 10,
        .response_bytes_max = 256 << 10,
    };

    var server = start_server(init.gpa, &options, search_span) catch |err| {
        return switch (err) {
            error.AddressInUse => usage_port_in_use(@max(first_port, 1), search_span),
            else => err,
        };
    };
    defer server.deinit();

    server.user_data = &site;

    if (browser_dir != null) {
        routes.register_static(server.router());
    } else {
        routes.register(server.router());
    }

    const bound = try server.bound_port();

    if (browser_dir) |dir| {
        std.debug.print("publr serving the browser build from {s} on http://127.0.0.1:{d}/\n", .{
            dir,
            bound,
        });
    } else {
        std.debug.print("publr listening on http://127.0.0.1:{d}\n", .{bound});
    }

    try server.enable_shutdown_signals();
    try server.listen();

    return 0;
}

const help =
    \\Usage: publr [--db <path>] serve [--port <n>] [--browser [<dir>]]
    \\
    \\  --port <n>        Listen on this exact port (default: 8080, or 8081 with --browser;
    \\                    without --port the next free port up to +20 is used)
    \\  --browser [<dir>] Serve the in-browser build statically (default zig-out/browser)
    \\  -h, --help        Print this help
    \\
;

fn parse_flags(args: []const []const u8) Flags {
    std.debug.assert(args.len < 64);

    var flags: Flags = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index == args.len) {
                return .{ .exit = usage("--port needs a value") };
            }
            flags.port = std.fmt.parseInt(u16, args[index], 10) catch
                return .{ .exit = usage("--port must be a number (0 picks a free port)") };
        } else if (std.mem.eql(u8, arg, "--browser")) {
            flags.browser_dir = browser_dir_default;
            if (index + 1 < args.len and !std.mem.startsWith(u8, args[index + 1], "--")) {
                index += 1;
                flags.browser_dir = args[index];
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{help});
            return .{ .exit = 0 };
        } else {
            report.err("publr serve: unknown flag \"{s}\"", .{arg});
            std.debug.print("{s}", .{help});
            return .{ .exit = 2 };
        }
    }

    std.debug.assert(index == args.len);

    return flags;
}

fn start_server(
    gpa: std.mem.Allocator,
    options: *http.Options,
    search_span: u16,
) http.App.Error!http.App {
    std.debug.assert(search_span <= port_search_max);
    std.debug.assert(options.port > 0 or search_span == 0);

    const first_port = options.port;
    var attempt: u16 = 0;

    while (attempt <= search_span) : (attempt += 1) {
        options.port = first_port + attempt;
        if (options.port < first_port) {
            return error.AddressInUse;
        }

        return http.App.init(gpa, options.*) catch |err| {
            if (err == error.AddressInUse and attempt < search_span) {
                continue;
            }

            return err;
        };
    }

    unreachable;
}

fn usage_port_in_use(first_port: u16, search_span: u16) u8 {
    std.debug.assert(first_port > 0);
    std.debug.assert(search_span <= port_search_max);

    if (search_span == 0) {
        report.err("publr serve: port {d} is already in use; pick another with --port <n>", .{
            first_port,
        });
    } else {
        report.err("publr serve: ports {d}-{d} are all in use; free one or use --port <n>", .{
            first_port,
            first_port + search_span,
        });
    }

    return 1;
}

fn usage(message: []const u8) u8 {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len < 200);

    report.err("publr serve: {s}", .{message});
    std.debug.print("{s}", .{help});

    return 2;
}
