//! Recompilation endpoint: POST /admin/system/recompile
//!
//! Shells out to zig build (external source tree at ~/.publr/src/),
//! performs atomic binary swap via symlink, triggers process restart
//! via exit code 100 (supervisor protocol).

const std = @import("std");
const mw = @import("middleware");

const Context = mw.Context;

/// Set by handleRecompile on success — checked by main accept loop to trigger exit(100).
pub var restart_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// POST /admin/system/recompile
pub fn handleRecompile(ctx: *Context) !void {
    const allocator = ctx.allocator;

    // Read zigExecutable from publr.zon — if absent, this is agency mode
    const zig_path = readConfigValue(allocator, "zigExecutable") orelse {
        ctx.response.setStatus("400 Bad Request");
        return jsonError(ctx, "Recompilation not available. Set zigExecutable in publr.zon to enable.");
    };

    // Check if Zig compiler actually exists at configured path
    std.fs.accessAbsolute(zig_path, .{}) catch {
        ctx.response.setStatus("400 Bad Request");
        return jsonError(ctx, "Zig compiler not found at configured path. Check zigExecutable in publr.zon.");
    };

    // Resolve source tree: configurable via publr.zon, falls back to ~/.publr/src/
    const source_path = readConfigValue(allocator, "sourcePath") orelse blk: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
            return jsonError(ctx, "Cannot determine HOME directory");
        };
        break :blk std.fs.path.join(allocator, &.{ home, ".publr/src" }) catch {
            return jsonError(ctx, "Path allocation failed");
        };
    };

    const build_file = std.fs.path.join(allocator, &.{ source_path, "build.zig" }) catch {
        return jsonError(ctx, "Path allocation failed");
    };

    // Check source tree exists
    std.fs.accessAbsolute(build_file, .{}) catch {
        return jsonError(ctx, "CMS source tree not found. Set sourcePath in publr.zon or re-run the install script.");
    };

    const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch {
        return jsonError(ctx, "Cannot resolve working directory");
    };
    const config_path = std.fs.path.join(allocator, &.{ cwd_path, "publr.zon" }) catch {
        return jsonError(ctx, "Path allocation failed");
    };
    const plugins_path = std.fs.path.join(allocator, &.{ cwd_path, "plugins" }) catch {
        return jsonError(ctx, "Path allocation failed");
    };

    // Build -D flags
    const config_flag = std.fmt.allocPrint(allocator, "-Dconfig-path={s}", .{config_path}) catch {
        return jsonError(ctx, "Allocation failed");
    };
    const plugins_flag = std.fmt.allocPrint(allocator, "-Dplugins-path={s}", .{plugins_path}) catch {
        return jsonError(ctx, "Allocation failed");
    };
    const project_flag = std.fmt.allocPrint(allocator, "-Dproject-dir={s}", .{cwd_path}) catch {
        return jsonError(ctx, "Allocation failed");
    };

    // Separate output directory so we never overwrite zig-out/bin/publr (used by dev runner)
    const prefix_path = std.fs.path.join(allocator, &.{ source_path, ".publr" }) catch {
        return jsonError(ctx, "Path allocation failed");
    };

    std.debug.print("[publr] Recompiling...\n", .{});

    // Spawn zig build
    var child = std.process.Child.init(
        &.{
            zig_path,
            "build",
            "--build-file",
            build_file,
            "--prefix",
            prefix_path,
            config_flag,
            plugins_flag,
            project_flag,
            "-Doptimize=Debug",
        },
        allocator,
    );
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stdin_behavior = .Ignore;

    child.spawn() catch {
        return jsonError(ctx, "Failed to spawn zig build process");
    };

    // Read all stderr before wait() to avoid pipe buffer deadlock
    var stderr_buf: std.ArrayList(u8) = .{};
    defer stderr_buf.deinit(allocator);

    if (child.stderr) |stderr_file| {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr_file.read(&read_buf) catch break;
            if (n == 0) break;
            stderr_buf.appendSlice(allocator, read_buf[0..n]) catch break;
        }
    }

    const term = child.wait() catch {
        return jsonError(ctx, "Failed to wait for zig build process");
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        std.debug.print("[publr] Build failed (exit {d})\n", .{exit_code});
        return jsonBuildError(ctx, allocator, stderr_buf.items);
    }

    std.debug.print("[publr] Build succeeded, swapping binary...\n", .{});

    // Build succeeded — perform atomic binary swap
    const zig_out_binary = std.fs.path.join(allocator, &.{ prefix_path, "bin/publr" }) catch {
        return jsonError(ctx, "Path allocation failed");
    };

    binarySwap(allocator, zig_out_binary) catch |err| {
        std.debug.print("[publr] Binary swap failed: {}\n", .{err});
        return jsonError(ctx, "Binary swap failed");
    };

    // Success response
    ctx.response.setContentType("application/json");
    ctx.response.setBody("{\"success\":true}");

    // Signal main accept loop to exit(100) after this response is sent
    restart_requested.store(true, .release);
}

/// POST /admin/system/config — update a config value in publr.zon, then recompile
pub fn handleConfigUpdate(ctx: *Context) !void {
    const key = ctx.formValue("key") orelse {
        ctx.response.setStatus("400 Bad Request");
        return jsonError(ctx, "Missing 'key' field");
    };
    const value = ctx.formValue("value") orelse {
        ctx.response.setStatus("400 Bad Request");
        return jsonError(ctx, "Missing 'value' field");
    };

    writeConfigValue(ctx.allocator, key, value) catch {
        return jsonError(ctx, "Failed to update publr.zon");
    };

    // Chain into recompile
    return handleRecompile(ctx);
}

/// Read a string value from publr.zon config in the current directory.
/// Looks for `.key = "value"` pattern and returns the value, or null if not found.
fn readConfigValue(allocator: std.mem.Allocator, comptime key: []const u8) ?[]const u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, "publr.zon", 64 * 1024) catch return null;
    const needle = "." ++ key;
    const pos = std.mem.indexOf(u8, content, needle) orelse return null;
    const after = content[pos + needle.len ..];
    // Skip whitespace and '='
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t' or after[i] == '\n' or after[i] == '\r' or after[i] == '=')) : (i += 1) {}
    if (i >= after.len or after[i] != '"') return null;
    i += 1; // skip opening quote
    const start = i;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    if (i >= after.len) return null;
    return allocator.dupe(u8, after[start..i]) catch null;
}

/// Write a string value to publr.zon config. Replaces existing `.key = "old"` with new value.
fn writeConfigValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const cwd = std.fs.cwd();
    const content = try cwd.readFileAlloc(allocator, "publr.zon", 64 * 1024);

    // Find .key
    const needle = std.fmt.allocPrint(allocator, ".{s}", .{key}) catch return error.OutOfMemory;
    const pos = std.mem.indexOf(u8, content, needle) orelse return error.KeyNotFound;

    // Find the opening quote after key
    const after_key = pos + needle.len;
    var i: usize = after_key;
    while (i < content.len and content[i] != '"') : (i += 1) {}
    if (i >= content.len) return error.InvalidFormat;
    const quote_start = i;

    // Find closing quote
    i += 1;
    while (i < content.len and content[i] != '"') : (i += 1) {}
    if (i >= content.len) return error.InvalidFormat;
    const quote_end = i + 1; // inclusive of closing quote

    // Build new content: before + "new_value" + after
    var result: std.ArrayList(u8) = .{};
    const w = result.writer(allocator);
    try w.writeAll(content[0..quote_start]);
    try w.writeByte('"');
    try w.writeAll(value);
    try w.writeByte('"');
    try w.writeAll(content[quote_end..]);

    // Write back atomically
    var file = try cwd.createFile("publr.zon", .{});
    defer file.close();
    try file.writeAll(result.items);
}

/// Atomic binary swap: copy new binary → temp symlink → rename over ./publr → delete old
fn binarySwap(allocator: std.mem.Allocator, new_binary_path: []const u8) !void {
    const cwd = std.fs.cwd();

    // Read current symlink target so we can delete the old binary later
    var old_target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_target = cwd.readLink("publr", &old_target_buf) catch null;

    // Timestamped binary name
    const ts: u64 = @intCast(std.time.timestamp());
    const build_name = try std.fmt.allocPrint(allocator, "publr-{d}", .{ts});

    // Copy new binary from source tree's zig-out to project directory
    {
        const source = try std.fs.openFileAbsolute(new_binary_path, .{});
        defer source.close();

        var dest = try cwd.createFile(build_name, .{ .mode = 0o755 });
        defer dest.close();

        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try source.read(&buf);
            if (n == 0) break;
            try dest.writeAll(buf[0..n]);
        }
    }

    // Atomic symlink swap
    cwd.deleteFile("publr.tmp") catch {};
    try cwd.symLink(build_name, "publr.tmp", .{});
    try cwd.rename("publr.tmp", "publr");

    std.debug.print("[publr] Binary swapped: publr -> {s}\n", .{build_name});

    // Delete old binary (the one the symlink previously pointed to)
    if (old_target) |old| {
        cwd.deleteFile(old) catch {};
    }
}

/// Return a JSON error response with properly escaped compiler output
fn jsonBuildError(ctx: *Context, allocator: std.mem.Allocator, stderr: []const u8) void {
    var json: std.ArrayList(u8) = .{};
    // Don't deinit — body slice must survive until response is written.
    // Allocator is the router's GPA; leak is small and per-request.
    const w = json.writer(allocator);
    w.writeAll("{\"success\":false,\"error\":") catch return jsonError(ctx, "JSON encoding failed");
    writeJsonString(w, stderr) catch return jsonError(ctx, "JSON encoding failed");
    w.writeByte('}') catch return jsonError(ctx, "JSON encoding failed");

    ctx.response.setContentType("application/json");
    ctx.response.setBody(json.items);
}

/// Return a simple JSON error response (for internal messages with no special chars)
fn jsonError(ctx: *Context, msg: []const u8) void {
    var json: std.ArrayList(u8) = .{};
    // Don't deinit — body slice must survive until response is written.
    const w = json.writer(ctx.allocator);
    w.writeAll("{\"success\":false,\"error\":") catch {
        ctx.response.setContentType("application/json");
        ctx.response.setBody("{\"success\":false,\"error\":\"Internal error\"}");
        return;
    };
    writeJsonString(w, msg) catch {
        ctx.response.setContentType("application/json");
        ctx.response.setBody("{\"success\":false,\"error\":\"Internal error\"}");
        return;
    };
    w.writeByte('}') catch {
        ctx.response.setContentType("application/json");
        ctx.response.setBody("{\"success\":false,\"error\":\"Internal error\"}");
        return;
    };

    ctx.response.setContentType("application/json");
    ctx.response.setBody(json.items);
}

/// Write a JSON-escaped string (with surrounding quotes)
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u00{x:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}
