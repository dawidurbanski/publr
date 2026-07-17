//! Browser dev server — minimal static-file HTTP for the WASM CMS preview.
//!
//! Replaces the previous `vite` setup with a small Zig server. Tradeoffs:
//!   - No HMR. Reload the page after `zig build browser` rebuilds the WASM.
//!   - No npm. `sql.js` was a dependency that never landed in any code path
//!     (the WASM bundles SQLite directly and persists to OPFS).
//!
//! Serves three roots from the project tree, in this order:
//!   /               -> browser/index.html
//!   /cms-runtime.js -> browser/cms-runtime.js
//!   /cms-worker.js  -> browser/cms-worker.js
//!   /cms.wasm       -> zig-out/browser/cms.wasm (built by `zig build browser`)
//!   /static/scripts/publr{,-query,-position,-focus}.js -> lib/publr/* (vendored runtime)
//!   /static/*       -> static/*
//!
//! Sets COOP=same-origin and COEP=credentialless headers (matching the prior
//! vite config) so cross-origin assets like gravatar load while keeping the
//! page eligible for cross-origin isolation if SharedArrayBuffer is ever
//! needed.

const std = @import("std");

const default_port: u16 = 5173;
const read_buf_size: usize = 8 * 1024;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // program name

    var port: u16 = default_port;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch port;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const next = args.next() orelse continue;
            port = std.fmt.parseInt(u16, next, 10) catch port;
        }
    }

    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("dev_server: listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("dev_server: serving browser/, zig-out/browser/cms.wasm, and static/\n", .{});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("dev_server: accept error: {}\n", .{err});
            continue;
        };
        handleConnection(allocator, conn) catch |err| {
            std.debug.print("dev_server: connection error: {}\n", .{err});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    var buf: [read_buf_size]u8 = undefined;
    const n = try conn.stream.read(&buf);
    if (n == 0) return;

    const req = buf[0..n];
    const first_line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
    const request_line = req[0..first_line_end];

    // Request line is "METHOD path HTTP/1.1"
    var it = std.mem.splitScalar(u8, request_line, ' ');
    const method = it.next() orelse return;
    const raw_path = it.next() orelse return;

    if (!std.mem.eql(u8, method, "GET")) {
        try writeStatus(conn.stream, "405 Method Not Allowed", "text/plain", "Method not allowed");
        return;
    }

    // Strip query string.
    const path = blk: {
        if (std.mem.indexOfScalar(u8, raw_path, '?')) |q| break :blk raw_path[0..q];
        break :blk raw_path;
    };

    try serveFile(allocator, conn.stream, path);
}

fn serveFile(allocator: std.mem.Allocator, stream: std.net.Stream, path: []const u8) !void {
    const fs_path = resolvePath(path) orelse {
        std.debug.print("dev_server: 404 (no route for) {s}\n", .{path});
        try writeStatus(stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };

    const file = std.fs.cwd().openFile(fs_path, .{}) catch |err| {
        std.debug.print("dev_server: 404 (open '{s}' failed: {s}) for {s}\n", .{ fs_path, @errorName(err), path });
        try writeStatus(stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };
    defer file.close();

    const max_size: usize = 64 * 1024 * 1024;
    const body = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(body);

    const mime = mimeFor(fs_path);

    // Status + headers
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Cross-Origin-Opener-Policy: same-origin\r\n" ++
            "Cross-Origin-Embedder-Policy: credentialless\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Connection: close\r\n\r\n",
        .{ mime, body.len },
    );
    _ = try stream.write(header);
    _ = try stream.write(body);
}

/// Map a request path to a filesystem path under the project root. Returns
/// null for paths that don't map to anything we serve.
fn resolvePath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/")) return "browser/index.html";

    // The vendored PublrJS runtime lives in lib/publr/ on disk (not authored
    // by the CMS) but is SERVED under /static/scripts/ — same URLs the
    // DS-built modules import by absolute specifier.
    const vendored_runtime = [_][]const u8{
        "/static/scripts/publr.js",
        "/static/scripts/publr-query.js",
        "/static/scripts/publr-position.js",
        "/static/scripts/publr-focus.js",
    };
    for (vendored_runtime, 0..) |v, i| {
        if (std.mem.eql(u8, path, v)) {
            const targets = [_][]const u8{
                "lib/publr/publr.js",
                "lib/publr/publr-query.js",
                "lib/publr/publr-position.js",
                "lib/publr/publr-focus.js",
            };
            return targets[i];
        }
    }

    // /static/* -> static/*
    if (std.mem.startsWith(u8, path, "/static/")) {
        // Strip leading slash. We trust the path layout — the dev server is
        // bound to 127.0.0.1 and the file open will fail safely on traversal.
        return path[1..];
    }

    // /cms.wasm comes from the WASM build output.
    if (std.mem.eql(u8, path, "/cms.wasm")) return "zig-out/browser/cms.wasm";

    // Explicit browser/ assets the WASM shell needs.
    const allowed = [_][]const u8{ "/cms-runtime.js", "/cms-worker.js", "/index.html" };
    for (allowed) |a| {
        if (std.mem.eql(u8, path, a)) {
            return resolveBrowser(path[1..]);
        }
    }

    // Drop favicon noise — browsers fetch it regardless of <link>.
    if (std.mem.eql(u8, path, "/favicon.ico")) return null;

    // SPA fallback: paths that don't look like static assets (no file
    // extension) hand back index.html so the WASM app can route them
    // client-side. Path traversal isn't a concern — we still return a
    // fixed filename.
    if (path.len > 1 and path[0] == '/') {
        const has_ext = std.mem.lastIndexOfScalar(u8, path, '.') != null;
        if (!has_ext) return "browser/index.html";
    }
    return null;
}

threadlocal var browser_path_buf: [128]u8 = undefined;

fn resolveBrowser(tail: []const u8) ?[]const u8 {
    const result = std.fmt.bufPrint(&browser_path_buf, "browser/{s}", .{tail}) catch return null;
    return result;
}

const mimeFor = @import("mime").fromPath;

fn writeStatus(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var buf: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    _ = try stream.write(head);
    _ = try stream.write(body);
}
