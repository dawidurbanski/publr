//! Per-render prop persistence for the HMR fast path.
//!
//! Generated views (when transpiled with `--hmr-capture-props`) emit
//!     try @import("hmr").captureProps("<route>:<Fn>", props);
//! as the first statement in every public component body. This module
//! is the receiver: it serializes `props` to a `.zon` file keyed by the
//! current request's route, so the hot-swap loop (task-06) can later
//! re-render `Fn` with the values that were last passed to it from a
//! route handler.
//!
//! ## Lifecycle
//!
//! Dev startup calls `setDevMode(true)`, which wipes `hmr_dir/` so
//! stale entries from a prior session don't leak into the new one.
//! The HTTP middleware (`hmr.middleware`) allocates a `RequestContext`
//! per request, binds it to the threadlocal `current_request`, and
//! pre-wipes that route's per-route subdir so each render's files start
//! from scratch. `captureProps` increments the per-request sequence
//! counter (one global counter per request — different views in the same
//! request share the sequence space) and writes the file.
//!
//! ## File layout
//!
//!   .publr/hmr/<route_hash>/<name_safe>-<seq>.zon
//!
//! - `route_hash` is a short FNV-1a hash of the request path (8 hex chars).
//! - `name_safe` is the captureProps name with `/` and `:` replaced by `-`.
//! - `seq` is a per-request monotonic counter (0, 1, 2 …) incremented
//!   each call regardless of view name. Task-06 reads them back in name
//!   order, picking the lowest free seq per re-render.
//!
//! ## Error handling
//!
//! No error path propagates to the caller — capture is best-effort.
//! Unserializable prop types (anything matching `containsAnytype`,
//! function pointers, opaque/anyopaque) are skipped at comptime with a
//! warning. I/O failures (dir create, write) log and continue.
//!
//! ## Why threadlocal
//!
//! `captureProps` is invoked from generated code that knows nothing
//! about request context — threading it explicitly would require
//! changing every view's signature. CMS handles each request on its
//! own thread (see `http_server/connection.zig`), so threadlocal storage
//! is the standard ambient-scope mechanism. If CMS ever moves to
//! coroutines on a shared thread, this needs revisiting.

const std = @import("std");

// =============================================================================
// Module state
// =============================================================================

/// Set once at startup. When false, `captureProps` is a no-op for any
/// caller. The HTTP middleware also gates itself on this so production
/// builds skip the per-request bookkeeping entirely.
var dev_mode: bool = false;

/// Root directory for written .zon files. Default is `.publr/hmr`;
/// tests override via `setHmrDir`.
var hmr_dir: []const u8 = ".publr/hmr";

pub fn setDevMode(b: bool) void {
    dev_mode = b;
    if (b) wipeHmrDir();
}

pub fn isDevMode() bool {
    return dev_mode;
}

/// Override the metadata root. Caller owns the storage (we don't dupe).
/// Intended for tests that want to point at a tmpDir.
pub fn setHmrDir(path: []const u8) void {
    hmr_dir = path;
}

pub fn getHmrDir() []const u8 {
    return hmr_dir;
}

fn wipeHmrDir() void {
    std.fs.cwd().deleteTree(hmr_dir) catch |err| {
        std.log.warn("[hmr] wipe of {s} failed: {s}", .{ hmr_dir, @errorName(err) });
    };
}

// =============================================================================
// Threadlocal request context
// =============================================================================

pub const RequestContext = struct {
    route_path: []const u8,
    seq: u32 = 0,
};

threadlocal var current_request: ?*RequestContext = null;

pub fn beginRequest(ctx: *RequestContext) void {
    current_request = ctx;
}

pub fn endRequest() void {
    current_request = null;
}

/// Test-only access. Production callers should use begin/end.
pub fn currentRequest() ?*RequestContext {
    return current_request;
}

// =============================================================================
// Public capture entry point
// =============================================================================

/// Capture a per-render snapshot of `props` for view `name`.
///
/// `name` is the "<route>:<Fn>" string the transpiler embedded at the
/// callsite, e.g. `"admin/dashboard:Dashboard"`.
///
/// This function never propagates errors to the caller — the render
/// must continue regardless. The signature still returns `!void` to
/// match what generated views already emit (`try @import("hmr")…`).
pub fn captureProps(comptime name: []const u8, props: anytype) !void {
    if (!dev_mode) return;
    const ctx = current_request orelse return;

    const T = @TypeOf(props);

    // Comptime gate: skip types we know std.zon.serialize would
    // reject. Without this check, the call below would fail to compile
    // for any view taking `anytype` props (transpile already audited
    // six such views in task-02).
    if (comptime !isSerializable(T)) {
        std.log.warn(
            "[hmr] capture-skip: {s} \u{2014} prop type {s} not zon-serializable",
            .{ name, @typeName(T) },
        );
        return;
    }

    captureInner(name, props, ctx) catch |err| {
        std.log.warn(
            "[hmr] capture failed: {s} \u{2014} {s}",
            .{ name, @errorName(err) },
        );
    };
}

fn captureInner(
    comptime name: []const u8,
    props: anytype,
    ctx: *RequestContext,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const route_hash = fnvHash(ctx.route_path);
    const route_hash_str = try std.fmt.allocPrint(alloc, "{x:0>8}", .{route_hash});

    const seq = ctx.seq;
    ctx.seq += 1;

    const name_safe = try sanitizeName(alloc, name);
    const file_name = try std.fmt.allocPrint(alloc, "{s}-{d}.zon", .{ name_safe, seq });

    const route_dir_rel = try std.fs.path.join(alloc, &.{ hmr_dir, route_hash_str });
    try std.fs.cwd().makePath(route_dir_rel);

    const file_path = try std.fs.path.join(alloc, &.{ route_dir_rel, file_name });

    // Serialize to an in-memory buffer first, then write atomically.
    // Allocating writer keeps us off the std.fs.File writer (which has
    // different drain semantics) and lets us decide whether to write
    // anything at all when serialization fails.
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    // std.zon API path: `std.zon.stringify` is the submodule, `.serialize`
    // is the public entry. Validated against zig 0.15.2 std/zon.zig.
    try std.zon.stringify.serialize(props, .{}, &aw.writer);

    var f = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(aw.written());
}

// =============================================================================
// HTTP middleware
// =============================================================================
//
// The middleware is exposed as a small struct so http.zig can wire it
// up via its existing `router.use(fn)` pattern. We don't import the
// router module here (keeps `hmr` self-contained — task spec calls for
// no cross-deps); instead http.zig writes the small adapter that calls
// `hmr.requestBegin` / `hmr.requestEnd`.

/// Allocate a RequestContext on `arena` and bind it. Returns the
/// pointer so the caller can `defer hmr.endRequest()`. Wipes the
/// route's per-route directory so each render starts clean.
///
/// No-op (returns null) when not in dev mode.
pub fn requestBegin(arena: std.mem.Allocator, route_path: []const u8) ?*RequestContext {
    if (!dev_mode) return null;

    const ctx = arena.create(RequestContext) catch |err| {
        std.log.warn("[hmr] ctx alloc failed: {s}", .{@errorName(err)});
        return null;
    };
    ctx.* = .{ .route_path = route_path, .seq = 0 };

    // Wipe stale per-route files. Any failure is non-fatal — worst case
    // we leak last-render's leftovers, which the swap loop will see as
    // extra entries (harmless; they won't match any view).
    wipeRouteDir(route_path);

    beginRequest(ctx);
    return ctx;
}

pub fn requestEnd() void {
    endRequest();
}

fn wipeRouteDir(route_path: []const u8) void {
    var buf: [256]u8 = undefined;
    const route_hash_str = std.fmt.bufPrint(
        &buf,
        "{x:0>8}",
        .{fnvHash(route_path)},
    ) catch return;

    var path_buf: [512]u8 = undefined;
    const route_dir = std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}",
        .{ hmr_dir, route_hash_str },
    ) catch return;

    std.fs.cwd().deleteTree(route_dir) catch {};
}

// =============================================================================
// Metadata listing (task-06 — consumed by the swap loop)
// =============================================================================

/// Resolved descriptor for one persisted prop snapshot. `file_path` is
/// the absolute-ish path under `hmr_dir/<route_hash>/`, suitable to
/// pass to `std.fs.cwd().readFileAlloc`. Strings are owned by the
/// caller-passed allocator (in practice an arena that the swap loop
/// drops after the call).
pub const ResolvedMetadata = struct {
    route_hash: []const u8,
    name: []const u8,
    seq: u32,
    file_path: []const u8,
};

/// Scan `hmr_dir/*/<safe_name>-*.zon` for view `name` and return the
/// matches sorted by ascending `seq`. `name` is the captureProps key
/// (e.g. `"admin/dashboard:Dashboard"`); the sanitization is applied
/// internally so callers don't need to know about the `/`→`-` swap.
///
/// Returns an empty slice if no metadata exists. The caller-provided
/// allocator owns the returned slice and every interior string.
pub fn listMetadataForView(
    allocator: std.mem.Allocator,
    name: []const u8,
) ![]const ResolvedMetadata {
    var out: std.ArrayListUnmanaged(ResolvedMetadata) = .{};
    errdefer out.deinit(allocator);

    const name_safe = try sanitizeName(allocator, name);
    defer allocator.free(name_safe);

    var root = std.fs.cwd().openDir(hmr_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.toOwnedSlice(allocator),
        else => return err,
    };
    defer root.close();

    var root_it = root.iterate();
    while (try root_it.next()) |sub| {
        if (sub.kind != .directory) continue;
        // Iterate files inside each route_hash dir.
        var sub_dir = root.openDir(sub.name, .{ .iterate = true }) catch continue;
        defer sub_dir.close();

        var f_it = sub_dir.iterate();
        while (try f_it.next()) |fent| {
            if (fent.kind != .file) continue;
            if (!std.mem.endsWith(u8, fent.name, ".zon")) continue;
            // Match `<name_safe>-<seq>.zon`.
            if (!std.mem.startsWith(u8, fent.name, name_safe)) continue;
            const rest = fent.name[name_safe.len..];
            if (rest.len < 2 or rest[0] != '-') continue;
            // Strip `.zon`.
            const tail = rest[1 .. rest.len - 4];
            const seq = std.fmt.parseInt(u32, tail, 10) catch continue;

            const file_path = try std.fs.path.join(allocator, &.{ hmr_dir, sub.name, fent.name });
            errdefer allocator.free(file_path);
            const route_hash_dup = try allocator.dupe(u8, sub.name);
            errdefer allocator.free(route_hash_dup);
            const name_dup = try allocator.dupe(u8, name);
            errdefer allocator.free(name_dup);

            try out.append(allocator, .{
                .route_hash = route_hash_dup,
                .name = name_dup,
                .seq = seq,
                .file_path = file_path,
            });
        }
    }

    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort(ResolvedMetadata, slice, {}, struct {
        fn lt(_: void, a: ResolvedMetadata, b: ResolvedMetadata) bool {
            return a.seq < b.seq;
        }
    }.lt);
    return slice;
}

// =============================================================================
// Comptime serializability check
// =============================================================================

/// Return true iff `T` can be passed to `std.zon.serialize` without a
/// compile error. The std module rejects (per its docstring):
///   - `type`, `void` (except as a union payload), `noreturn`
///   - error sets / error unions
///   - untagged unions
///   - non-exhaustive enums
///   - many-pointers / C-pointers
///   - opaque (including `anyopaque`)
///   - async frames
///   - function pointers
///
/// `anytype` parameters aren't a `@TypeOf` thing — by the time we're
/// here the prop type is concrete. But generated views that take
/// `anytype` end up with anonymous structs whose fields may themselves
/// be functions or pointers to opaques, so we recurse.
fn isSerializable(comptime T: type) bool {
    return comptime serializableInner(T, 0);
}

fn serializableInner(comptime T: type, comptime depth: u8) bool {
    if (depth > 8) return true; // recursion guard; trust the compiler past here
    return switch (@typeInfo(T)) {
        .void, .type, .noreturn => false,
        .error_set, .error_union => false,
        .@"opaque" => false,
        .@"fn" => false,
        .frame, .@"anyframe" => false,
        .@"union" => |u| blk: {
            if (u.tag_type == null) break :blk false;
            for (u.fields) |f| {
                if (!serializableInner(f.type, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .@"enum" => |e| e.is_exhaustive,
        .pointer => |p| switch (p.size) {
            .many, .c => false,
            // Single-item pointers to functions / opaques are out, as
            // are pointers whose child fails the recursive check.
            .one => serializableInner(p.child, depth + 1),
            .slice => serializableInner(p.child, depth + 1),
        },
        .array => |a| serializableInner(a.child, depth + 1),
        .optional => |o| serializableInner(o.child, depth + 1),
        .@"struct" => |s| blk: {
            for (s.fields) |f| {
                if (!serializableInner(f.type, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .vector => |v| serializableInner(v.child, depth + 1),
        else => true,
    };
}

// =============================================================================
// Helpers
// =============================================================================

/// FNV-1a 32-bit. Plenty for our 8-hex-char route bucket; collisions
/// only cause "wrong directory probed", never corruption.
fn fnvHash(s: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (s) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

/// Replace `/` and `:` with `-` so the captureProps name string can
/// land directly in a file name on every supported platform.
fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = switch (c) {
            '/', ':', '\\' => '-',
            else => c,
        };
    }
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Push hmr_dir at a temp location for the duration of a test. Restores
/// the previous values on deinit so tests don't leak state across runs.
const TestEnv = struct {
    prev_dir: []const u8,
    prev_dev_mode: bool,
    tmp: testing.TmpDir,
    abs_dir: []u8,

    fn init(alloc: std.mem.Allocator) !TestEnv {
        var tmp = testing.tmpDir(.{});
        const abs_dir = try tmp.dir.realpathAlloc(alloc, ".");
        const prev_dir = hmr_dir;
        const prev_dev_mode = dev_mode;
        hmr_dir = abs_dir;
        dev_mode = true;
        current_request = null;
        return .{
            .prev_dir = prev_dir,
            .prev_dev_mode = prev_dev_mode,
            .tmp = tmp,
            .abs_dir = abs_dir,
        };
    }

    fn deinit(self: *TestEnv, alloc: std.mem.Allocator) void {
        hmr_dir = self.prev_dir;
        dev_mode = self.prev_dev_mode;
        current_request = null;
        alloc.free(self.abs_dir);
        self.tmp.cleanup();
    }

    /// Path joined under the tmp hmr_dir.
    fn pathUnder(self: *TestEnv, alloc: std.mem.Allocator, sub: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.abs_dir, sub });
    }
};

test "hmr: captureProps writes a .zon file for the active request" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    var ctx: RequestContext = .{ .route_path = "/admin/dashboard", .seq = 0 };
    beginRequest(&ctx);
    defer endRequest();

    try captureProps("admin/dashboard:Dashboard", .{ .count = 42, .label = "ok" });

    const hash = fnvHash("/admin/dashboard");
    const hash_str = try std.fmt.allocPrint(alloc, "{x:0>8}", .{hash});
    defer alloc.free(hash_str);

    const expected = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}/admin-dashboard-Dashboard-0.zon",
        .{ env.abs_dir, hash_str },
    );
    defer alloc.free(expected);

    var f = try std.fs.cwd().openFile(expected, .{});
    defer f.close();
    var buf: [1024]u8 = undefined;
    const n = try f.readAll(&buf);
    const content = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, content, ".count") != null);
    try testing.expect(std.mem.indexOf(u8, content, "42") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"ok\"") != null);
    try testing.expectEqual(@as(u32, 1), ctx.seq);
}

test "hmr: sequential captures bump the request seq counter" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    var ctx: RequestContext = .{ .route_path = "/x", .seq = 0 };
    beginRequest(&ctx);
    defer endRequest();

    try captureProps("X:Foo", .{ .v = 1 });
    try captureProps("X:Foo", .{ .v = 2 });

    const hash_str = try std.fmt.allocPrint(alloc, "{x:0>8}", .{fnvHash("/x")});
    defer alloc.free(hash_str);

    const f0_path = try std.fmt.allocPrint(alloc, "{s}/{s}/X-Foo-0.zon", .{ env.abs_dir, hash_str });
    defer alloc.free(f0_path);
    const f1_path = try std.fmt.allocPrint(alloc, "{s}/{s}/X-Foo-1.zon", .{ env.abs_dir, hash_str });
    defer alloc.free(f1_path);

    var f0 = try std.fs.cwd().openFile(f0_path, .{});
    f0.close();
    var f1 = try std.fs.cwd().openFile(f1_path, .{});
    f1.close();
    try testing.expectEqual(@as(u32, 2), ctx.seq);
}

test "hmr: unsupported prop type (function field) skipped without error" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    var ctx: RequestContext = .{ .route_path = "/y", .seq = 0 };
    beginRequest(&ctx);
    defer endRequest();

    // anytype-equivalent: a struct with a function-pointer field is
    // exactly the shape std.zon.serialize would reject at compile time.
    const Callback = *const fn () void;
    const NoOp = struct {
        fn doNothing() void {}
    };
    const props = .{ .cb = @as(Callback, &NoOp.doNothing) };

    try captureProps("Y:Cb", props);

    // No file written, seq not incremented.
    const hash_str = try std.fmt.allocPrint(alloc, "{x:0>8}", .{fnvHash("/y")});
    defer alloc.free(hash_str);
    const route_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ env.abs_dir, hash_str });
    defer alloc.free(route_dir);

    // The dir shouldn't exist yet (captureInner never ran).
    const dir_open = std.fs.cwd().openDir(route_dir, .{});
    try testing.expectError(error.FileNotFound, dir_open);
    try testing.expectEqual(@as(u32, 0), ctx.seq);
}

test "hmr: no active request is a no-op" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    current_request = null;
    try captureProps("Z:NoReq", .{ .v = 1 });

    // The route dir wouldn't exist because there's no route hash to
    // compute. Spot-check the hmr_dir is empty.
    var d = try std.fs.cwd().openDir(env.abs_dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    try testing.expect((try it.next()) == null);
}

test "hmr: dev_mode = false is a no-op even with an active request" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    dev_mode = false;
    var ctx: RequestContext = .{ .route_path = "/q", .seq = 0 };
    beginRequest(&ctx);
    defer endRequest();

    try captureProps("Q:F", .{ .v = 1 });

    try testing.expectEqual(@as(u32, 0), ctx.seq);
    var d = try std.fs.cwd().openDir(env.abs_dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    try testing.expect((try it.next()) == null);
}

test "hmr: requestBegin wipes prior route files before render" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    // First render — writes one file.
    {
        var ctx: RequestContext = .{ .route_path = "/dup", .seq = 0 };
        beginRequest(&ctx);
        defer endRequest();
        try captureProps("Dup:A", .{ .x = 1 });
        try captureProps("Dup:A", .{ .x = 2 });
    }

    // Sanity: two files present.
    const hash_str = try std.fmt.allocPrint(alloc, "{x:0>8}", .{fnvHash("/dup")});
    defer alloc.free(hash_str);
    const route_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ env.abs_dir, hash_str });
    defer alloc.free(route_dir);
    {
        var d = try std.fs.cwd().openDir(route_dir, .{ .iterate = true });
        defer d.close();
        var it = d.iterate();
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 2), n);
    }

    // Second render via requestBegin — should wipe the dir, then write
    // exactly one file.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    _ = requestBegin(arena.allocator(), "/dup") orelse return error.RequestBeginReturnedNull;
    try captureProps("Dup:B", .{ .x = 3 });
    requestEnd();

    {
        var d = try std.fs.cwd().openDir(route_dir, .{ .iterate = true });
        defer d.close();
        var it = d.iterate();
        var n: usize = 0;
        var saw_b = false;
        while (try it.next()) |entry| {
            n += 1;
            if (std.mem.indexOf(u8, entry.name, "Dup-B") != null) saw_b = true;
        }
        try testing.expectEqual(@as(usize, 1), n);
        try testing.expect(saw_b);
    }
}

test "hmr: listMetadataForView returns files sorted by seq across routes" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    // Two routes, three captures total. Names mix matching + non-matching.
    var ctx_a: RequestContext = .{ .route_path = "/r-a", .seq = 0 };
    beginRequest(&ctx_a);
    try captureProps("v:Foo", .{ .x = 1 });
    try captureProps("v:Bar", .{ .x = 99 }); // different name — should be skipped
    try captureProps("v:Foo", .{ .x = 2 });
    endRequest();

    var ctx_b: RequestContext = .{ .route_path = "/r-b", .seq = 0 };
    beginRequest(&ctx_b);
    try captureProps("v:Foo", .{ .x = 3 });
    endRequest();

    const metas = try listMetadataForView(alloc, "v:Foo");
    defer {
        for (metas) |m| {
            alloc.free(m.route_hash);
            alloc.free(m.name);
            alloc.free(m.file_path);
        }
        alloc.free(metas);
    }

    // Three matching files; non-matching Bar capture excluded.
    try testing.expectEqual(@as(usize, 3), metas.len);
    // Sorted by seq ascending.
    try testing.expect(metas[0].seq <= metas[1].seq);
    try testing.expect(metas[1].seq <= metas[2].seq);
    // Each file should exist on disk.
    for (metas) |m| {
        var f = try std.fs.cwd().openFile(m.file_path, .{});
        f.close();
        try testing.expectEqualStrings("v:Foo", m.name);
    }
}

test "hmr: listMetadataForView returns empty when no metadata exists" {
    const alloc = testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    const metas = try listMetadataForView(alloc, "v:Foo");
    defer alloc.free(metas);
    try testing.expectEqual(@as(usize, 0), metas.len);
}

test "hmr: isSerializable rejects function pointer and anyopaque" {
    const Callback = *const fn () void;
    const HasFn = struct { cb: Callback };
    try testing.expect(!isSerializable(HasFn));

    const HasOpaque = struct { p: *anyopaque };
    try testing.expect(!isSerializable(HasOpaque));

    const Clean = struct { x: i32, label: []const u8 };
    try testing.expect(isSerializable(Clean));
}
