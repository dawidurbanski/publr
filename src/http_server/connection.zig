const std = @import("std");
const Method = @import("router").Method;
const Router = @import("router").Router;
const tpl = @import("tpl");

/// Request header - imported from middleware
const RequestHeader = @import("middleware").RequestHeader;

/// Max request body size (2MB — enough for 1MB upload + multipart overhead)
const max_body_size: usize = 2 * 1024 * 1024;

var configured_router: ?*Router = null;
var active_connections: ?*std.atomic.Value(u32) = null;

pub fn configure(router: *Router, active_counter: *std.atomic.Value(u32)) void {
    configured_router = router;
    active_connections = active_counter;
}

pub fn handleConnectionThread(stream: std.net.Stream) void {
    if (active_connections) |counter| {
        _ = counter.fetchAdd(1, .acq_rel);
    }
    defer {
        tpl.resetArena();
        if (active_connections) |counter| {
            _ = counter.fetchSub(1, .acq_rel);
        }
        stream.close();
    }

    handleConnection(stream) catch |err| {
        std.debug.print("Request error: {}\n", .{err});
    };
}

fn handleConnection(stream: std.net.Stream) !void {
    var buf: [8192]u8 = undefined;

    // Read until we have the full headers (look for \r\n\r\n)
    var total_read: usize = 0;
    var header_end: usize = 0;
    while (total_read < buf.len) {
        const n = try stream.read(buf[total_read..]);
        if (n == 0) break;
        total_read += n;

        // Check if we have the end of headers
        if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |pos| {
            header_end = pos + 4;
            break;
        }
    }
    if (total_read == 0) return;

    // If we filled the buffer without finding end of headers, reject request
    if (header_end == 0) {
        try sendResponse(stream, "431 Request Header Fields Too Large", "text/plain", "Request headers too large");
        return;
    }

    const request_headers = buf[0..header_end];

    // Parse first line: "GET /path HTTP/1.1"
    var lines = std.mem.splitScalar(u8, request_headers, '\n');
    const first_line = lines.first();

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method_str = parts.next() orelse "GET";
    const raw_path = parts.next() orelse "/";

    // Split path and query string — router matches on path only
    const qi = std.mem.indexOfScalar(u8, raw_path, '?');
    const path = if (qi) |i| raw_path[0..i] else raw_path;
    const query: ?[]const u8 = if (qi) |i| raw_path[i + 1 ..] else null;

    const method = Method.fromString(method_str) orelse .GET;

    // Parse headers and look for Content-Length
    var headers: [32]RequestHeader = undefined;
    var header_count: usize = 0;
    var content_length: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) break; // Empty line marks end of headers

        if (std.mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
            if (header_count < headers.len) {
                const name = trimmed[0..colon_pos];
                const value = trimmed[colon_pos + 2 ..];
                headers[header_count] = .{
                    .name = name,
                    .value = value,
                };
                header_count += 1;

                // Check for Content-Length
                if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                    content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                }
            }
        }
    }

    // Read body — use stack buffer for small requests, heap for large ones
    var heap_body: ?[]u8 = null;
    defer if (heap_body) |hb| std.heap.page_allocator.free(hb);

    var body: ?[]const u8 = null;

    if (content_length > 0) {
        if (content_length > max_body_size) {
            try sendResponse(stream, "413 Content Too Large", "text/plain", "Request body too large");
            return;
        }

        const already_read = total_read - header_end;

        if (header_end + content_length <= buf.len) {
            // Small body — fits in stack buffer
            while (total_read < header_end + content_length) {
                const n = try stream.read(buf[total_read..]);
                if (n == 0) break;
                total_read += n;
            }
            if (header_end < total_read) {
                body = buf[header_end..total_read];
            }
        } else {
            // Large body — allocate on heap
            const body_buf = std.heap.page_allocator.alloc(u8, content_length) catch {
                try sendResponse(stream, "413 Content Too Large", "text/plain", "Request body too large");
                return;
            };
            heap_body = body_buf;

            // Copy bytes already read past the headers
            if (already_read > 0) {
                @memcpy(body_buf[0..already_read], buf[header_end..total_read]);
            }

            // Read the rest
            var body_read = already_read;
            while (body_read < content_length) {
                const n = stream.read(body_buf[body_read..content_length]) catch break;
                if (n == 0) break;
                body_read += n;
            }
            body = body_buf[0..body_read];
        }
    } else {
        // No Content-Length but might have partial body from header read
        if (header_end < total_read) {
            body = buf[header_end..total_read];
        }
    }

    const router = configured_router orelse {
        try sendResponse(stream, "500 Internal Server Error", "text/plain", "Server not initialized");
        return;
    };
    try router.dispatch(method, path, stream, headers[0..header_count], body, query);
}

fn sendResponse(
    stream: std.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    _ = try stream.write(header);
    _ = try stream.write(body);
}
