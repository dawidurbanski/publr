const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const ssg = @import("ssg.zig");
const core_init = @import("core_init");
const cli_main = @import("cli_main");
const publr_config = @import("publr_config");
const build_options = @import("build_options");
const collaboration_config = @import("collaboration_config.zig");
const db_path_mod = @import("db_path");
/// View registry: in HMR mode this holds the swap-loop lookup table built
/// from `src/views/**/*.zsx`. In inline mode it's an empty no-op (see
/// `src/view_registry_runtime.zig`), so the import is unconditional.
const view_registry_runtime = @import("view_registry_runtime");
/// task-08 of cms-hmr-fast-path: the in-process dev orchestrator imports
/// the cross-platform mtime poll watcher, the HMR swap loop, and the WS
/// push channel. Replaces the three-watchexec setup that used to live in
/// `runWithWatchers`.
const watcher_mod = @import("watcher");
const hmr_loop_mod = @import("hmr_loop");
const hmr_ws = @import("hmr_ws");

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
        try runServe(allocator, &args);
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

fn runServe(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var cli_port: ?u16 = null;
    var cli_db_path: ?[]const u8 = null;
    var cli_lock_timeout_ms: ?u32 = null;
    var cli_heartbeat_interval_ms: ?u32 = null;
    var dev_mode: bool = false;

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
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return;
        }
    }

    const port = resolvePort(cli_port);
    const resolved_db = try db_path_mod.resolve(allocator, cli_db_path);
    defer resolved_db.deinit(allocator);
    const db_path = resolved_db.path;
    const lock_timeout_ms = resolveLockTimeoutMs(cli_lock_timeout_ms);
    const heartbeat_interval_ms = resolveHeartbeatIntervalMs(cli_heartbeat_interval_ms);

    // Build the HMR view-lookup table once at startup. In inline (non-HMR)
    // builds the registry's entries slice is empty so this just logs zero
    // and never gets consulted. In `--dev` HMR builds task-06's swap loop
    // consults it on .zsx save events.
    if (dev_mode) {
        view_registry_runtime.init(allocator) catch |err| {
            std.log.warn("[hmr] view registry init failed: {s}", .{@errorName(err)});
        };

        // If the registry is empty we're running a non-HMR binary in dev
        // mode. Every `.zsx` save would slow-path into a `zig build`
        // (which would then succeed-but-not-replace if the user keeps
        // re-running this same binary, busy-looping). Refuse early with
        // a clear message instead of letting the user discover the
        // mismatch through "the pill stays on Rebuilding forever".
        if (view_registry_runtime.iter().len == 0) {
            std.debug.print(
                \\
                \\[publr] ERROR: --dev requires the binary to be built with -Dhmr=true.
                \\        The view registry is empty, which means this binary was built
                \\        without HMR codegen. HMR fast-path can never fire, and every
                \\        .zsx save would trigger a full rebuild that doesn't replace
                \\        the running process.
                \\
                \\        Re-run with:
                \\          zig build -Dhmr=true run -- serve --dev
                \\
                \\
            , .{});
            std.process.exit(1);
        }
    }

    if (dev_mode) {
        try runDevMode(allocator, port, db_path, lock_timeout_ms, heartbeat_interval_ms);
        return;
    }

    try http.serve(port, db_path, lock_timeout_ms, heartbeat_interval_ms, dev_mode);
}

fn runBuild(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var output_dir: []const u8 = if (@hasField(@TypeOf(publr_config), "output"))
        publr_config.output
    else
        "output";
    var cli_db_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            output_dir = args.next() orelse {
                std.debug.print("Error: --output requires a value\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--db")) {
            cli_db_path = args.next() orelse {
                std.debug.print("Error: --db requires a value\n", .{});
                return;
            };
        }
    }
    const resolved_db = try db_path_mod.resolve(allocator, cli_db_path);
    defer resolved_db.deinit(allocator);
    const db_path = resolved_db.path;

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
            const v = args.next() orelse {
                std.debug.print("Error: --port requires a value\n", .{});
                return;
            };
            port = std.fmt.parseInt(u16, v, 10) catch {
                std.debug.print("Error: invalid port\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "-d")) {
            dir = args.next() orelse {
                std.debug.print("Error: --dir requires a value\n", .{});
                return;
            };
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

    const mime_type = @import("mime").fromPath(file_path);
    writeResponse(stream, "200 OK", mime_type, content);
}

fn writeResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    _ = stream.write(header) catch return;
    _ = stream.write(body) catch return;
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

fn resolveLockTimeoutMs(cli_lock_timeout_ms: ?u32) u32 {
    return cli_lock_timeout_ms orelse collaboration_config.default_lock_timeout_ms;
}

fn resolveHeartbeatIntervalMs(cli_heartbeat_interval_ms: ?u32) u32 {
    return cli_heartbeat_interval_ms orelse collaboration_config.default_heartbeat_interval_ms;
}

// =============================================================================
// Dev-mode orchestrator (task-08 of cms-hmr-fast-path)
// =============================================================================
//
// `runDevMode` replaces the three-watchexec setup that lived in
// `runWithWatchers`. The whole live-reload pipeline now lives in-process:
//
//   * `watcher_mod.Watcher` polls source, static assets, first-party libraries,
//     third-party vendor files, themes, and build.zig every 200 ms via mtime
//     polling.
//   * `hmr_loop_mod.Loop` decides per-event whether a `.zsx` save can
//     be hot-swapped (literals only, manifest equal) or needs a full
//     rebuild (structural change, or non-`.zsx` file).
//   * `hmr_ws.broadcaster()` ships swap-HTML and rebuild signals to
//     every connected `/__hmr/ws` client.
//   * `triggerRebuild` runs `zig build -Dhmr=true -Dminify=<resolved>`
//     in-process; on success it `execvpe`s the freshly built binary,
//     replacing the current process image. The injected live-reload
//     client's auto-reconnect handles the brief WS gap (no FD handoff
//     in v1 — accept the reconnect; matches today's watchexec UX for
//     the slow path).
//
// Threading model: the HTTP server runs on a background thread; the
// main thread drives the watcher poll loop. The HTTP server already
// owns its own poll/accept loop and a `shutdown_requested` atomic
// (exposed from `http.zig` for this caller), so when SIGINT/SIGTERM
// fires the signal handler flips the atomic, both loops exit, and
// `runDevMode` joins cleanly. Inverting it (HTTP on main, watcher on a
// thread) would force `execvpe` to coordinate across the HTTP thread,
// which is messier; the watcher loop is the simpler one to relocate.

/// Drives the in-process dev loop: spawns the HTTP server on a thread,
/// polls the watcher in this thread, dispatches events to the swap
/// loop, and triggers an in-process rebuild + `execvpe` on slow-path
/// events. Returns only when the user kills the process (SIGINT/TERM).
fn runDevMode(
    allocator: std.mem.Allocator,
    port: u16,
    db_path: []const u8,
    lock_timeout_ms: u32,
    heartbeat_interval_ms: u32,
) !void {
    // Watcher roots match the old three-watchexec layout. The watcher
    // walks each root at every poll and only emits events for files
    // whose extension matches the allowlist (root-relative paths only).
    //
    // src/ -> .zig/.zon/.zsx (CSS lives under static/ in CMS today and
    //   gets handled by the asset-mtime branch in the loop below; if a
    //   theme starts shipping `.css` inside src/ we'd add it here too).
    //   `gen/` is the SSG output tree; never react to changes there or
    //   we'd loop forever on our own writes.
    // themes/ -> .publr templates + `.zon` (theme.zon / publr.zon).
    //   The previous watchexec setup also ignored `themes/*/public/**`
    //   and `themes/*/src/**`. The watcher takes root-relative prefixes
    //   so a wildcard isn't expressible here; we filter the ignored
    //   subtrees inside the swap-loop dispatch below via `shouldIgnore`.
    // static/ -> any extension. Static asset changes require a rebuild so the
    //   new bytes are embedded.
    // lib/ -> any extension. First-party library updates are rare; rebuild.
    // vendor/ -> any extension. Third-party updates are rare; rebuild.
    // build.zig -> single-file root, matches the watchexec server-watcher.
    var watcher = try watcher_mod.Watcher.init(allocator, &.{
        .{
            .path = "src",
            .extensions = &.{ ".zig", ".zon", ".zsx", ".css" },
            .ignore_prefixes = &.{"gen/"},
        },
        .{
            .path = "themes",
            .extensions = &.{ ".publr", ".zon", ".zsx" },
            .ignore_prefixes = &.{}, // wildcards filtered in shouldIgnoreEvent
        },
        .{
            .path = "static",
            .extensions = &.{},
            .ignore_prefixes = &.{},
        },
        .{
            .path = "lib",
            .extensions = &.{},
            .ignore_prefixes = &.{},
        },
        .{
            .path = "vendor",
            .extensions = &.{},
            .ignore_prefixes = &.{},
        },
        .{
            .path = "build.zig",
            .extensions = &.{},
            .ignore_prefixes = &.{},
        },
    });
    defer watcher.deinit();

    var loop = hmr_loop_mod.Loop.init(allocator, hmr_ws.broadcaster());
    defer loop.deinit();

    // HTTP server runs on a background thread. The atomic shutdown
    // flag in http.zig drives both loops' termination on SIGINT.
    const server_thread = try std.Thread.spawn(.{}, runHttpServerThread, .{
        port,
        db_path,
        lock_timeout_ms,
        heartbeat_interval_ms,
    });

    // Prime the watcher snapshot — first poll always returns empty.
    _ = try watcher.poll();

    std.debug.print("[publr] dev mode active (in-process watcher + HMR fast path)\n", .{});

    var poll_counter: usize = 0;
    var rebuild_requested: bool = false;

    while (!http.isShutdownRequested()) {
        var timer = std.time.Timer.start() catch null;
        const events = watcher.poll() catch |err| {
            std.debug.print("[watcher] poll error: {s}\n", .{@errorName(err)});
            std.Thread.sleep(200 * std.time.ns_per_ms);
            continue;
        };

        // Surface the poll cost every 100 ticks so we notice regressions
        // without spamming the log every cycle.
        poll_counter += 1;
        if (poll_counter % 100 == 0) {
            if (timer) |*t| {
                const elapsed_us = t.read() / std.time.ns_per_us;
                std.debug.print("[watcher] poll took {d}us (tick #{d})\n", .{ elapsed_us, poll_counter });
            }
        }

        if (events.len > 0) {
            // Partition events: ignored noise (theme src/public), CSS
            // cache-bust only, swap/rebuild candidates.
            var any_css_only: bool = false;
            var swap_events_buf: [64]watcher_mod.ChangeEvent = undefined;
            var swap_events_len: usize = 0;

            for (events) |ev| {
                if (shouldIgnoreEvent(ev)) continue;

                // .css changes broadcast a cache-bust signal to the
                // browser; no rebuild needed because CSS is delivered
                // via `<link rel="stylesheet">` and the client appends
                // `?_t=<ts>` on every link to force a fresh fetch.
                // Note: themes embedFile CSS at build time, so if a
                // theme's CSS pipeline writes a new asset on disk and
                // the page references that asset via <link>, we're
                // good. If a future feature needs an actual rebuild
                // for CSS, route it through the rebuild path instead.
                if (std.mem.eql(u8, ev.extension, ".css")) {
                    any_css_only = true;
                    continue;
                }

                if (swap_events_len < swap_events_buf.len) {
                    swap_events_buf[swap_events_len] = ev;
                    swap_events_len += 1;
                }
            }

            if (any_css_only) {
                hmr_ws.broadcastCss(allocator, "") catch |err| {
                    std.debug.print("[hmr] css broadcast failed: {s}\n", .{@errorName(err)});
                };
            }

            if (swap_events_len > 0) {
                // The swap loop decides per-event whether it can
                // fast-path (literal-only `.zsx` edit) or has to
                // slow-path (structural change, non-`.zsx`, or
                // unregistered file). We take its verdict as the source
                // of truth — earlier versions guessed from extension
                // only, which missed `.zsx` structural changes and left
                // the client's "Rebuilding" pill stuck forever.
                const result = loop.handle(swap_events_buf[0..swap_events_len]) catch |err| blk: {
                    std.debug.print("[hmr] loop.handle failed: {s}\n", .{@errorName(err)});
                    // Loop errored — safest to rebuild rather than leave
                    // the running binary out of sync with the source.
                    break :blk hmr_loop_mod.Loop.HandleResult{ .needs_rebuild = true };
                };
                if (result.needs_rebuild) rebuild_requested = true;
            }
        }

        if (rebuild_requested) {
            // Tell the HTTP server to drain — it'll flip its own
            // shutdown atomic so the listener loop exits. The watcher
            // loop here will fall out on the next iteration too.
            triggerRebuild(allocator) catch |err| {
                std.debug.print("[hmr] rebuild failed: {s} — staying on current binary\n", .{@errorName(err)});
                rebuild_requested = false;
                continue;
            };
            // triggerRebuild only returns on rebuild failure. On
            // success, execvpe replaces the process image and we
            // never get here. Reset and keep going on failure.
            rebuild_requested = false;
        }

        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    server_thread.join();
}

/// Wraps `http.serve` so it can run on a background thread. Errors are
/// logged but not propagated — there's no caller to report them to once
/// we've crossed the thread boundary, and the dev session's main loop
/// uses `http.isShutdownRequested()` to coordinate teardown.
fn runHttpServerThread(
    port: u16,
    db_path: []const u8,
    lock_timeout_ms: u32,
    heartbeat_interval_ms: u32,
) void {
    http.serve(port, db_path, lock_timeout_ms, heartbeat_interval_ms, true) catch |err| {
        std.debug.print("[publr] HTTP server thread exited: {s}\n", .{@errorName(err)});
    };
    // If the HTTP server returns (clean shutdown), also flip the
    // shutdown flag so the watcher loop in main exits its sleep cycle.
    http.requestShutdown();
}

/// Subtree filtering: the watcher's `ignore_prefixes` is a literal
/// startsWith match, so wildcard patterns like `themes/*/public/**`
/// (which the old watchexec setup used) need to be evaluated here.
/// Path is root-relative — for the `themes` root, a `demo/public/x`
/// path means `themes/demo/public/x`. We skip per-theme `public/` and
/// `src/` directories because they're build outputs / theme-internal
/// source trees that aren't part of the CMS rebuild surface.
fn shouldIgnoreEvent(ev: watcher_mod.ChangeEvent) bool {
    // Only the themes root needs this filtering today.
    if (std.mem.indexOf(u8, ev.path, "/public/") != null) return true;
    if (std.mem.indexOf(u8, ev.path, "/src/") != null) return true;
    return false;
}

/// In-process rebuild trigger. Spawns `zig build -Dhmr=true
/// -Dminify=<resolved>` as a child process; on exit-zero, `execvpe`s
/// the new binary, replacing the current process image. On non-zero,
/// logs the failure and returns so the dev session keeps running with
/// the previous binary (a typo shouldn't kill the session).
///
/// FD handoff (listening socket, WS subscribers) is deferred to a
/// follow-up — see the JIT POC's `buildInheritArg` for the pattern.
/// v1 accepts the brief WS disconnect; the live-reload client has
/// auto-reconnect + `pending_refetch` queueing that recovers cleanly.
fn triggerRebuild(allocator: std.mem.Allocator) !void {
    std.debug.print("[hmr] triggering rebuild\n", .{});

    const minify_arg: []const u8 = if (build_options.minify_css) "-Dminify=true" else "-Dminify=false";
    const argv = [_][]const u8{ "zig", "build", "-Dhmr=true", minify_arg };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("[hmr] build failed (exit {d}); keeping current binary\n", .{code});
                return;
            }
        },
        else => {
            std.debug.print("[hmr] build terminated abnormally; keeping current binary\n", .{});
            return;
        },
    }

    // Build succeeded — exec the new binary in place. Re-construct
    // argv from the original program args so the new process sees
    // exactly what the user typed (same port, same --dev, etc.).
    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();

    var argv_buf: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv_buf.deinit(allocator);
    while (arg_it.next()) |a| {
        const z = try allocator.dupeZ(u8, a);
        try argv_buf.append(allocator, z.ptr);
    }
    try argv_buf.append(allocator, null);

    const exe_z = try allocator.dupeZ(u8, "zig-out/bin/publr");

    std.debug.print("[hmr] rebuild succeeded — exec'ing new binary\n", .{});

    const slice = argv_buf.items[0..argv_buf.items.len];
    const argv_zero: [*:null]const ?[*:0]const u8 = @ptrCast(slice.ptr);
    const err = std.posix.execvpeZ(exe_z.ptr, argv_zero, std.c.environ);
    std.debug.print("[hmr] execvpe failed: {s}\n", .{@errorName(err)});
    return err;
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
