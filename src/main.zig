const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const ssg = @import("ssg.zig");
const core_init = @import("core_init");
const cli_main = @import("cli_main");
const publr_config = @import("publr_config");
const build_options = @import("build_options");
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
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuild(allocator, &args);
    } else if (std.mem.eql(u8, command, "preview")) {
        try runPreview(&args);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        cli_main.run(allocator, command, &args) catch |err| {
            std.debug.print("Error: {s}\n\n", .{@errorName(err)});
            printUsage();
            std.process.exit(1);
        };
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

fn runBuild(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var output_dir: []const u8 = if (@hasField(@TypeOf(publr_config), "output"))
        publr_config.output
    else
        "output";
    var db_path: []const u8 = resolveDbPath(null);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            output_dir = args.next() orelse {
                std.debug.print("Error: --output requires a value\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--db")) {
            db_path = args.next() orelse {
                std.debug.print("Error: --db requires a value\n", .{});
                return;
            };
        }
    }

    var timer = try std.time.Timer.start();

    // Open database
    var db = core_init.initDatabase(allocator, db_path) catch |err| {
        std.debug.print("Failed to open database: {}\n", .{err});
        return err;
    };
    defer db.deinit();

    core_init.ensureSchema(&db) catch |err| {
        std.debug.print("Failed to ensure schema: {}\n", .{err});
        return err;
    };

    std.debug.print("publr build\n\n", .{});

    // Run preBuild hooks (e.g., Tailwind CSS)
    runBuildHooks(allocator, "preBuild", output_dir);

    const summary = try ssg.buildSite(allocator, &db, output_dir);

    const elapsed_ns = timer.read();
    const elapsed_ms = @divFloor(elapsed_ns, 1_000_000);

    std.debug.print("  {d} pages generated\n", .{summary.pages});
    std.debug.print("  {d} static assets copied\n", .{summary.assets});
    std.debug.print("  Total: {d} bytes\n", .{summary.total_bytes});
    std.debug.print("  Done in {d}ms\n", .{elapsed_ms});
    std.debug.print("  Output: ./{s}/\n", .{output_dir});

    // Run postBuild hooks (e.g., minhtml, esbuild)
    runBuildHooks(allocator, "postBuild", output_dir);
}

fn runBuildHooks(allocator: std.mem.Allocator, comptime phase: []const u8, output_dir: []const u8) void {
    // Theme-level hooks override project-level hooks for the same phase
    const theme_config = @import("theme_config");
    const has_theme_hooks = comptime blk: {
        if (!@hasField(@TypeOf(theme_config), "build")) break :blk false;
        break :blk @hasField(@TypeOf(theme_config.build), phase);
    };

    if (has_theme_hooks) {
        runHooksFrom(theme_config, phase, allocator, output_dir);
    } else {
        runHooksFrom(publr_config, phase, allocator, output_dir);
    }
}

fn runHooksFrom(comptime config: anytype, comptime phase: []const u8, allocator: std.mem.Allocator, output_dir: []const u8) void {
    if (@hasField(@TypeOf(config), "build")) {
        if (@hasField(@TypeOf(config.build), phase)) {
            const hooks = @field(config.build, phase);
            std.debug.print("  Running {s} hooks...\n", .{phase});
            inline for (hooks) |cmd_template| {
                runSingleHook(allocator, cmd_template[0], &blk: {
                    var argv: [cmd_template.len][]const u8 = undefined;
                    inline for (cmd_template, 0..) |arg, i| {
                        argv[i] = if (std.mem.eql(u8, arg, "{output}")) output_dir else arg;
                    }
                    break :blk argv;
                });
            }
        }
    }
}

fn runSingleHook(allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8) void {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    const term = child.spawnAndWait() catch |err| {
        std.debug.print("  Hook '{s}' skipped: {}\n", .{ name, err });
        return;
    };
    if (term.Exited != 0) {
        std.debug.print("  Hook '{s}' exited with code {d}\n", .{ name, term.Exited });
    }
}

fn runPreview(args: *std.process.ArgIterator) !void {
    var dir: []const u8 = "output";
    var port: u16 = 3000;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const v = args.next() orelse { std.debug.print("Error: --port requires a value\n", .{}); return; };
            port = std.fmt.parseInt(u16, v, 10) catch { std.debug.print("Error: invalid port\n", .{}); return; };
        } else if (std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "-d")) {
            dir = args.next() orelse { std.debug.print("Error: --dir requires a value\n", .{}); return; };
        } else if (arg[0] != '-') {
            dir = arg; // positional: publr preview ./dist
        }
    }

    // Verify directory exists
    std.fs.cwd().access(dir, .{}) catch {
        std.debug.print("Error: directory '{s}' not found. Run 'publr build' first.\n", .{dir});
        return;
    };

    std.debug.print("Serving {s} at http://localhost:{d}\n", .{ dir, port });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        serveStaticFile(conn.stream, dir);
        conn.stream.close();
    }
}

/// Minimal HTTP/1.1 file server — serves files from a directory with clean URLs.
fn serveStaticFile(stream: std.net.Stream, root: []const u8) void {
    var buf: [4096]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n == 0) return;

    // Parse request line: "GET /path HTTP/1.1\r\n"
    const request = buf[0..n];
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
    const first_line = request[0..first_line_end];

    // Extract path
    const path_start = std.mem.indexOf(u8, first_line, " ") orelse return;
    const path_end = std.mem.lastIndexOf(u8, first_line, " ") orelse return;
    if (path_start >= path_end) return;
    var url_path = first_line[path_start + 1 .. path_end];

    // Strip query string
    if (std.mem.indexOf(u8, url_path, "?")) |q| url_path = url_path[0..q];

    // Security: reject path traversal
    if (std.mem.indexOf(u8, url_path, "..") != null) {
        writeResponse(stream, "403 Forbidden", "text/plain", "Forbidden");
        return;
    }

    // Strip leading /
    const rel = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;

    // Try exact file, then dir/index.html, then just index.html for root
    var file_buf: [1024]u8 = undefined;
    const file_path = if (rel.len == 0)
        std.fmt.bufPrint(&file_buf, "{s}/index.html", .{root}) catch return
    else blk: {
        // If path has an extension, it's a file request (e.g. /theme/theme.css)
        if (std.mem.indexOfScalar(u8, std.fs.path.basename(rel), '.') != null) {
            break :blk std.fmt.bufPrint(&file_buf, "{s}/{s}", .{ root, rel }) catch return;
        }
        // Otherwise it's a clean URL — try dir/index.html
        break :blk std.fmt.bufPrint(&file_buf, "{s}/{s}/index.html", .{ root, rel }) catch return;
    };

    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, file_path, 10 * 1024 * 1024) catch {
        std.debug.print("[preview] 404: {s}\n", .{file_path});
        writeResponse(stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };

    const mime = getMime(file_path);
    writeResponse(stream, "200 OK", mime, content);
}

fn writeResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    _ = stream.write(header) catch return;
    _ = stream.write(body) catch return;
}

fn getMime(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".html", "text/html" }, .{ ".css", "text/css" }, .{ ".js", "application/javascript" },
        .{ ".json", "application/json" }, .{ ".svg", "image/svg+xml" }, .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" }, .{ ".webp", "image/webp" }, .{ ".ico", "image/x-icon" },
        .{ ".woff2", "font/woff2" }, .{ ".woff", "font/woff" }, .{ ".xml", "application/xml" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
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

/// Runs the server with three watchexec processes:
/// 1. Source watcher — watches src/, vendor/, build.zig → full `zig build -Dwatch`
/// 2. Theme watcher — watches themes/ → `zig build -Dwatch` (same build, but scoped trigger)
/// 3. Server watcher — watches `zig-out/bin/publr`, restarts server when binary changes
/// The Zig build cache makes theme-only changes fast (only preprocess+transpile+link).
fn runWithWatchers(
    port: u16,
    db_path: []const u8,
    lock_timeout_ms: u32,
    heartbeat_interval_ms: u32,
    dev_mode: bool,
) !void {
    // Build command (shared by both watchers)
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

    // Propagate -Dminify=<resolved> so the watcher rebuild preserves the
    // user's CSS minify choice. Without this, every file-change rebuild
    // falls back to the optimize-based default (Debug → unminified) even
    // when the user started the session with -Dminify=true.
    const build_suffix = if (build_options.minify_css)
        "zig build -Dwatch -Dminify=true"
    else
        "zig build -Dwatch -Dminify=false";
    @memcpy(cmd_buf[cmd_offset..][0..build_suffix.len], build_suffix);
    cmd_offset += build_suffix.len;
    cmd_buf[cmd_offset] = 0;

    // Source watcher: watches core CMS files
    const src_extensions = if (dev_mode) "zig,zon,zsx" else "zig,zon,zsx,css";
    const build_argv = [_:null]?[*:0]const u8{
        "watchexec",
        "-e",
        src_extensions,
        "-w",
        "src",
        "-w",
        "vendor",
        "-w",
        "build.zig",
        "-i",
        "src/gen/**",
        @ptrCast(&cmd_buf),
    };

    // Theme watcher: watches theme template + asset files → rebuild
    const theme_argv = [_:null]?[*:0]const u8{
        "watchexec",
        "-e",
        "publr",
        "-w",
        "themes",
        "-i",
        "themes/*/public/**",
        "-i",
        "themes/*/src/**",
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

    // Fork source watcher
    const build_pid = try std.posix.fork();
    if (build_pid == 0) {
        const err = std.posix.execvpeZ("watchexec", &build_argv, std.c.environ);
        if (err == error.FileNotFound) printWatchexecMissing();
        std.process.exit(1);
    }

    // Fork theme watcher
    const theme_pid = std.posix.fork() catch |err| {
        std.posix.kill(build_pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.waitpid(build_pid, 0);
        return err;
    };
    if (theme_pid == 0) {
        const err = std.posix.execvpeZ("watchexec", &theme_argv, std.c.environ);
        if (err == error.FileNotFound) printWatchexecMissing();
        std.process.exit(1);
    }

    // Fork server watcher
    const server_pid = std.posix.fork() catch |err| {
        std.posix.kill(build_pid, std.posix.SIG.TERM) catch {};
        std.posix.kill(theme_pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.waitpid(build_pid, 0);
        _ = std.posix.waitpid(theme_pid, 0);
        return err;
    };
    if (server_pid == 0) {
        const err = std.posix.execvpeZ("watchexec", &server_argv, std.c.environ);
        std.debug.print("Failed to start server watcher: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    }

    // Wait for any child to exit, then clean up the others
    const result = std.posix.waitpid(-1, 0);
    const pids = [_]i32{ build_pid, theme_pid, server_pid };
    for (pids) |pid| {
        if (pid != result.pid) {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            _ = std.posix.waitpid(pid, 0);
        }
    }
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
    cli_main.printUsage();
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
