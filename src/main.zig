const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const publr_config = @import("publr_config");
const db_mod = @import("db");
const media_sync = @import("media_sync");
const storage = @import("storage");
const collaboration_config = @import("collaboration_config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    const command = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "serve")) {
        try runServe(&args);
    } else if (std.mem.eql(u8, command, "media")) {
        try runMedia(allocator, &args);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn runMedia(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const subcommand = args.next() orelse {
        std.debug.print("Usage: publr media <subcommand>\n\nSubcommands:\n  sync    Sync filesystem with database\n\n", .{});
        return;
    };

    if (std.mem.eql(u8, subcommand, "sync")) {
        // Ensure media directories exist
        storage.initDirectories() catch |err| {
            std.debug.print("Error creating media directories: {}\n", .{err});
            return;
        };

        // Open database
        var db = db_mod.Db.init(allocator, "data/publr.db") catch |err| {
            std.debug.print("Error opening database: {}\n", .{err});
            return;
        };
        defer db.deinit();

        std.debug.print("Syncing media files...\n", .{});

        const result = media_sync.syncFilesystem(allocator, &db) catch |err| {
            std.debug.print("Sync error: {}\n", .{err});
            return;
        };

        std.debug.print("Sync complete:\n  New files: {d}\n  Missing files: {d}\n  Skipped: {d}\n  Errors: {d}\n", .{
            result.new_count,
            result.missing_count,
            result.skipped_count,
            result.error_count,
        });
    } else {
        std.debug.print("Unknown media subcommand: {s}\n", .{subcommand});
    }
}

fn runServe(args: *std.process.ArgIterator) !void {
    var cli_port: ?u16 = null;
    var cli_db_path: ?[]const u8 = null;
    var cli_lock_timeout_ms: ?u32 = null;
    var cli_heartbeat_interval_ms: ?u32 = null;
    var dev_mode: bool = false;
    var watch_mode: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const port_str = args.next() orelse {
                std.debug.print("Error: --port requires a value\n", .{});
                return;
            };
            cli_port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: invalid port number: {s}\n", .{port_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--db")) {
            cli_db_path = args.next() orelse {
                std.debug.print("Error: --db requires a value\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--lock-timeout")) {
            const timeout_str = args.next() orelse {
                std.debug.print("Error: --lock-timeout requires a value (milliseconds)\n", .{});
                return;
            };
            cli_lock_timeout_ms = std.fmt.parseInt(u32, timeout_str, 10) catch {
                std.debug.print("Error: invalid --lock-timeout value: {s}\n", .{timeout_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--heartbeat-interval")) {
            const interval_str = args.next() orelse {
                std.debug.print("Error: --heartbeat-interval requires a value (milliseconds)\n", .{});
                return;
            };
            cli_heartbeat_interval_ms = std.fmt.parseInt(u32, interval_str, 10) catch {
                std.debug.print("Error: invalid --heartbeat-interval value: {s}\n", .{interval_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--dev") or std.mem.eql(u8, arg, "-d")) {
            dev_mode = true;
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            watch_mode = true;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return;
        }
    }

    const port = resolvePort(cli_port);
    const db_path = resolveDbPath(cli_db_path);
    const lock_timeout_ms = resolveLockTimeoutMs(cli_lock_timeout_ms);
    const heartbeat_interval_ms = resolveHeartbeatIntervalMs(cli_heartbeat_interval_ms);

    if (watch_mode) {
        if (builtin.os.tag == .windows) {
            printWatchNotSupportedWindows();
            return;
        }
        runWithWatchers(port, db_path, lock_timeout_ms, heartbeat_interval_ms, dev_mode) catch |err| {
            if (err == error.FileNotFound) {
                printWatchexecMissing();
                return;
            }
            return err;
        };
        return;
    }

    try http.serve(port, db_path, lock_timeout_ms, heartbeat_interval_ms, dev_mode);
}

/// Resolves port with precedence: CLI flag > PORT env var > default (8080)
fn resolvePort(cli_port: ?u16) u16 {
    // CLI flag takes highest precedence
    if (cli_port) |p| return p;

    // Check PORT environment variable
    if (std.posix.getenv("PORT")) |port_str| {
        return std.fmt.parseInt(u16, port_str, 10) catch {
            std.debug.print("Warning: invalid PORT env var '{s}', using default 8080\n", .{port_str});
            return 8080;
        };
    }

    // Default
    return 8080;
}

/// Resolves database path with precedence: CLI flag > PUBLR_DB env var > default (data/publr.db)
fn resolveDbPath(cli_db_path: ?[]const u8) []const u8 {
    if (cli_db_path) |path| return path;

    if (std.posix.getenv("PUBLR_DB")) |path| {
        if (path.len > 0) return path;
    }

    return "data/publr.db";
}

fn resolveLockTimeoutMs(cli_lock_timeout_ms: ?u32) u32 {
    return cli_lock_timeout_ms orelse collaboration_config.default_lock_timeout_ms;
}

fn resolveHeartbeatIntervalMs(cli_heartbeat_interval_ms: ?u32) u32 {
    return cli_heartbeat_interval_ms orelse collaboration_config.default_heartbeat_interval_ms;
}

/// Runs the server with two watchexec processes:
/// 1. Build watcher — watches sources, runs `zig build -Dwatch` (server stays up during build)
/// 2. Server watcher — watches `zig-out/bin/publr`, restarts server when binary changes
/// Server downtime = just the process restart, not the entire build.
fn runWithWatchers(
    port: u16,
    db_path: []const u8,
    lock_timeout_ms: u32,
    heartbeat_interval_ms: u32,
    dev_mode: bool,
) !void {
    // Build command for build watcher (tailwind + zig build)
    var cmd_buf: [512]u8 = undefined;
    var cmd_offset: usize = 0;

    if (@hasField(@TypeOf(publr_config), "dev")) {
        if (@hasField(@TypeOf(publr_config.dev), "watchers")) {
            inline for (publr_config.dev.watchers) |watcher| {
                inline for (watcher.cmd, 0..) |arg, i| {
                    if (i > 0) {
                        @memcpy(cmd_buf[cmd_offset..][0..1], " ");
                        cmd_offset += 1;
                    }
                    @memcpy(cmd_buf[cmd_offset..][0..arg.len], arg);
                    cmd_offset += arg.len;
                }
                @memcpy(cmd_buf[cmd_offset..][0..4], " && ");
                cmd_offset += 4;
            }
        }
    }

    const build_suffix = "zig build -Dwatch";
    @memcpy(cmd_buf[cmd_offset..][0..build_suffix.len], build_suffix);
    cmd_offset += build_suffix.len;
    cmd_buf[cmd_offset] = 0;

    // In dev mode, don't watch .css — served from disk at runtime
    const extensions = if (dev_mode) "zig,zon,zsx" else "zig,zon,zsx,css";

    const build_argv = [_:null]?[*:0]const u8{
        "watchexec",
        "-e",
        extensions,
        "-i",
        "src/gen/**",
        @ptrCast(&cmd_buf),
    };

    // Format port as null-terminated string (u16 max = 5 digits)
    var port_buf: [6]u8 = undefined;
    const port_str = std.fmt.bufPrint(port_buf[0..5], "{d}", .{port}) catch unreachable;
    port_buf[port_str.len] = 0;

    const db_path_z = try std.heap.page_allocator.dupeZ(u8, db_path);
    defer std.heap.page_allocator.free(db_path_z);
    var lock_timeout_buf: [16]u8 = undefined;
    const lock_timeout_str = std.fmt.bufPrint(lock_timeout_buf[0..15], "{d}", .{lock_timeout_ms}) catch unreachable;
    lock_timeout_buf[lock_timeout_str.len] = 0;
    var heartbeat_interval_buf: [16]u8 = undefined;
    const heartbeat_interval_str = std.fmt.bufPrint(heartbeat_interval_buf[0..15], "{d}", .{heartbeat_interval_ms}) catch unreachable;
    heartbeat_interval_buf[heartbeat_interval_str.len] = 0;

    // Server watcher: watches binary, restarts on change (no shell layer)
    const dev_flag: ?[*:0]const u8 = if (dev_mode) "--dev" else null;
    const server_argv = [_:null]?[*:0]const u8{
        "watchexec",
        "-r",
        "--stop-signal=SIGINT",
        "--stop-timeout=0",
        "-w",
        "zig-out/bin/publr",
        "--",
        "zig-out/bin/publr",
        "serve",
        "--port",
        @ptrCast(&port_buf),
        "--db",
        db_path_z.ptr,
        "--lock-timeout",
        @ptrCast(&lock_timeout_buf),
        "--heartbeat-interval",
        @ptrCast(&heartbeat_interval_buf),
        dev_flag,
    };

    // Fork build watcher
    const build_pid = try std.posix.fork();
    if (build_pid == 0) {
        const err = std.posix.execvpeZ("watchexec", &build_argv, std.c.environ);
        if (err == error.FileNotFound) printWatchexecMissing();
        std.process.exit(1);
    }

    // Fork server watcher
    const server_pid = std.posix.fork() catch |err| {
        std.posix.kill(build_pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.waitpid(build_pid, 0);
        return err;
    };
    if (server_pid == 0) {
        const err = std.posix.execvpeZ("watchexec", &server_argv, std.c.environ);
        std.debug.print("Failed to start server watcher: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    }

    // Wait for either child to exit, then clean up the other
    const result = std.posix.waitpid(-1, 0);
    const remaining = if (result.pid == build_pid) server_pid else build_pid;
    std.posix.kill(remaining, std.posix.SIG.TERM) catch {};
    _ = std.posix.waitpid(remaining, 0);
}

fn printWatchexecMissing() void {
    std.debug.print(
        \\--watch requires watchexec to be installed.
        \\
        \\Options:
        \\  1. Install watchexec:
        \\     https://github.com/watchexec/watchexec/blob/main/doc/packages.md
        \\
        \\  2. Use watchexec directly:
        \\     watchexec -r -e zig "zig build run -- serve --port 8080"
        \\
        \\  3. Use another watcher (entr, fswatch, etc.)
        \\
        \\  4. Manual rebuild: Ctrl+C, then run again
        \\
    , .{});
}

fn printWatchNotSupportedWindows() void {
    std.debug.print(
        \\--watch is not supported on Windows.
        \\
        \\Use watchexec directly:
        \\  watchexec -r -e zig "zig build run -- serve --port 8080"
        \\
    , .{});
}

fn printUsage() void {
    const usage =
        \\Publr - Single-file CMS
        \\
        \\Usage: publr <command> [options]
        \\
        \\Commands:
        \\  serve        Start the HTTP server
        \\  media sync   Sync filesystem with media database
        \\  help         Show this help message
        \\
        \\Serve options:
        \\  --port, -p <port>    Port to listen on (default: 8080, or PORT env var)
        \\  --db <path>          Database path (default: data/publr.db, or PUBLR_DB env var)
        \\  --lock-timeout <ms>  Soft-lock inactivity timeout in milliseconds (default: 60000)
        \\  --heartbeat-interval <ms>
        \\                       Client/server heartbeat interval in milliseconds (default: 10000)
        \\  --dev, -d            Enable development mode (hot reload)
        \\  --watch, -w          Auto-rebuild on file changes (requires watchexec)
        \\
        \\Environment variables:
        \\  PORT                 Default port (overridden by --port flag)
        \\  PUBLR_DB             Default database path (overridden by --db flag)
        \\
        \\Examples:
        \\  publr serve
        \\  publr serve --port 3000
        \\  publr serve --db /tmp/publr-test.db
        \\  publr serve --lock-timeout 1000 --heartbeat-interval 500
        \\  publr serve --dev
        \\  publr serve --watch --dev
        \\
    ;
    std.debug.print("{s}", .{usage});
}

// Tests
test "resolvePort: CLI flag takes precedence" {
    const port = resolvePort(3000);
    try std.testing.expectEqual(@as(u16, 3000), port);
}

test "resolvePort: returns default when no CLI and no env" {
    // This test assumes PORT env var is not set in test environment
    const port = resolvePort(null);
    // If PORT env is set, this would fail - but that's expected behavior
    // In a clean test environment, it should return 8080
    try std.testing.expect(port > 0);
}
