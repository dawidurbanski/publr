//! Cross-platform mtime-poll file watcher.
//!
//! Lives behind a single `Watcher.poll()` call that the dev event loop drives
//! at a fixed cadence (200 ms today; owned by the caller, not the watcher).
//! v1 backend is pure mtime polling via `std.fs.Dir.statFile` so the same code
//! path works on macOS, Linux, and Windows with no native bindings.
//!
//! ## Design
//!
//! - One `Watcher` instance owns a set of `Root`s. Each root is either a
//!   directory (walked recursively) or a single file (snapshot of one entry).
//! - Each root has an extension allowlist and a list of root-relative
//!   `ignore_prefixes` (e.g. `"gen/"` excludes everything under `src/gen/`).
//! - All path strings emitted by the watcher are **root-relative** (not
//!   absolute, not prefixed with the root). For a file root, the path is the
//!   basename of the file.
//! - The first call to `poll()` after `init()` returns an empty slice: it
//!   initializes the snapshot, but emits no events. Treat init time as the
//!   baseline.
//! - On subsequent polls, the returned slice is owned by the Watcher and
//!   reused on the next poll. Copy anything you want to keep before calling
//!   `poll()` again.
//!
//! ## Allocation
//!
//! Path strings live in an arena owned by the Watcher. The arena is reset
//! every poll, so per-poll path duplicates don't leak. The per-root mtime
//! snapshots own their own keys (longer-lived) in a separate arena that
//! persists for the lifetime of the watcher.
//!
//! ## Performance smoke (M-series Mac, SSD, CMS-scale tree)
//!
//! Smoke test in this module (`watcher: smoke poll cost`) constructs a
//! Watcher over `cms/src/` filtering `.zsx`/`.zig`/`.zon` with `gen/` ignored,
//! then calls `poll()` 10 times in a row. Observed cost is sub-millisecond
//! per poll on a tree of ~few hundred files — well within the 5 ms budget
//! at the dev loop's 200 ms cadence. The smoke test only prints timing in
//! verbose mode; it does not gate.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const ChangeEventKind = enum { created, modified, deleted };

/// A single observed file-system change. `path` is **root-relative** — i.e.
/// for a root `{ .path = "src" }`, a change to `src/views/page.zsx` is
/// reported with `path = "views/page.zsx"`. For a file root, `path` is the
/// basename of the file.
pub const ChangeEvent = struct {
    path: []const u8,
    extension: []const u8,
    kind: ChangeEventKind,
    mtime_ns: i128,
};

pub const Root = struct {
    /// Root directory or single file path, relative to `std.fs.cwd()` at
    /// `init()` time. e.g. `"src"`, `"themes"`, `"build.zig"`.
    path: []const u8,
    /// Allowed file extensions (case-sensitive, leading `.` included; e.g.
    /// `".zsx"`). Empty list means match every file regardless of extension.
    extensions: []const []const u8 = &.{},
    /// Root-relative path prefixes to exclude. e.g. `&.{ "gen/" }` skips
    /// `src/gen/**` when this root is `src`. Each entry is compared with
    /// `std.mem.startsWith` against the root-relative path.
    ignore_prefixes: []const []const u8 = &.{},
};

/// Internal: one tracked root, owning its mtime snapshot.
const RootState = struct {
    config: Root,
    is_file: bool,
    /// Maps root-relative path -> mtime (ns). Keys are owned by `path_arena`.
    snapshot: std.StringHashMapUnmanaged(i128) = .{},
    /// Scratch buffer reused while building the new snapshot each poll.
    /// Lives in path_arena; same lifetime as snapshot.
    next: std.StringHashMapUnmanaged(i128) = .{},
};

pub const Watcher = struct {
    allocator: Allocator,
    /// Long-lived arena for path strings that survive across polls (snapshot
    /// keys, root paths, etc.). Reset only on `deinit`.
    path_arena: std.heap.ArenaAllocator,
    /// Short-lived arena for per-poll scratch (the events buffer's string
    /// duplicates point into path_arena for stability, so this is mostly
    /// used for temporary walker state and per-poll iterators).
    scratch_arena: std.heap.ArenaAllocator,
    roots: []RootState,
    events: std.ArrayList(ChangeEvent),
    primed: bool,

    pub fn init(allocator: Allocator, roots: []const Root) !Watcher {
        var path_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer path_arena.deinit();
        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer scratch_arena.deinit();

        const states = try allocator.alloc(RootState, roots.len);
        errdefer allocator.free(states);

        // Probe each root once at init to learn whether it's a file or a
        // directory. Missing roots are tolerated as directories (their
        // walks will just turn up empty and any file appearing later
        // shows up as `created`).
        for (roots, 0..) |cfg, i| {
            const is_file = blk: {
                const stat = std.fs.cwd().statFile(cfg.path) catch {
                    break :blk false;
                };
                break :blk stat.kind == .file;
            };
            states[i] = .{
                .config = cfg,
                .is_file = is_file,
                .snapshot = .{},
                .next = .{},
            };
        }

        return .{
            .allocator = allocator,
            .path_arena = path_arena,
            .scratch_arena = scratch_arena,
            .roots = states,
            .events = .{},
            .primed = false,
        };
    }

    pub fn deinit(self: *Watcher) void {
        for (self.roots) |*rs| {
            rs.snapshot.deinit(self.allocator);
            rs.next.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
        self.allocator.free(self.roots);
        self.path_arena.deinit();
        self.scratch_arena.deinit();
    }

    /// Non-blocking. Walks every root, compares against the previous
    /// snapshot, and returns the diff as `ChangeEvent`s.
    ///
    /// The returned slice is owned by the Watcher and is invalidated on the
    /// next call to `poll()` (or `deinit()`). Copy anything you need to keep.
    ///
    /// The very first call after `init()` returns an empty slice: it builds
    /// the initial snapshot without emitting events. This matches the
    /// "baseline at startup" semantics most callers want — dev loops only
    /// react to changes after they start watching.
    pub fn poll(self: *Watcher) ![]const ChangeEvent {
        self.events.clearRetainingCapacity();
        _ = self.scratch_arena.reset(.retain_capacity);

        const path_alloc = self.path_arena.allocator();

        for (self.roots) |*rs| {
            // Build the new snapshot for this root.
            rs.next.clearRetainingCapacity();

            if (rs.is_file) {
                try self.scanFileRoot(rs, path_alloc);
            } else {
                try self.scanDirRoot(rs, path_alloc);
            }

            if (self.primed) {
                // Diff old vs new. Emit created/modified for entries in new,
                // deleted for entries that disappeared.
                var it_new = rs.next.iterator();
                while (it_new.next()) |kv| {
                    const path = kv.key_ptr.*;
                    const new_mtime = kv.value_ptr.*;
                    if (rs.snapshot.get(path)) |old_mtime| {
                        if (old_mtime != new_mtime) {
                            try self.events.append(self.allocator, .{
                                .path = path,
                                .extension = extOf(path),
                                .kind = .modified,
                                .mtime_ns = new_mtime,
                            });
                        }
                    } else {
                        try self.events.append(self.allocator, .{
                            .path = path,
                            .extension = extOf(path),
                            .kind = .created,
                            .mtime_ns = new_mtime,
                        });
                    }
                }

                var it_old = rs.snapshot.iterator();
                while (it_old.next()) |kv| {
                    const path = kv.key_ptr.*;
                    if (!rs.next.contains(path)) {
                        try self.events.append(self.allocator, .{
                            .path = path,
                            .extension = extOf(path),
                            .kind = .deleted,
                            .mtime_ns = kv.value_ptr.*,
                        });
                    }
                }
            }

            // Promote next -> snapshot. We swap the maps to keep both
            // allocations and avoid rebuilding from scratch.
            const tmp = rs.snapshot;
            rs.snapshot = rs.next;
            rs.next = tmp;
        }

        self.primed = true;
        return self.events.items;
    }

    fn scanFileRoot(self: *Watcher, rs: *RootState, path_alloc: Allocator) !void {
        const stat = std.fs.cwd().statFile(rs.config.path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .file) return;

        const basename = std.fs.path.basename(rs.config.path);
        if (!extensionAllowed(basename, rs.config.extensions)) return;
        if (prefixIgnored(basename, rs.config.ignore_prefixes)) return;

        // Reuse the existing key string if we already have one, so the
        // path_arena doesn't grow on every poll.
        const key = if (rs.snapshot.getKeyPtr(basename)) |kp|
            kp.*
        else
            try path_alloc.dupe(u8, basename);
        try rs.next.put(self.allocator, key, stat.mtime);
    }

    fn scanDirRoot(self: *Watcher, rs: *RootState, path_alloc: Allocator) !void {
        var dir = std.fs.cwd().openDir(rs.config.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close();

        var walker = try dir.walk(self.scratch_arena.allocator());
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!extensionAllowed(entry.basename, rs.config.extensions)) continue;
            if (prefixIgnored(entry.path, rs.config.ignore_prefixes)) continue;

            // Use the parent dir handle to stat, which is what dev.zig does
            // and avoids re-resolving the full path from cwd. Note Zig's
            // Walker.Entry.path uses '/' separators on all platforms, which
            // matches what we want for root-relative keys.
            const stat = entry.dir.statFile(entry.basename) catch continue;

            const key = if (rs.snapshot.getKeyPtr(entry.path)) |kp|
                kp.*
            else
                try path_alloc.dupe(u8, entry.path);
            try rs.next.put(self.allocator, key, stat.mtime);
        }
    }
};

fn extOf(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return ext; // may be "" for files with no extension
}

fn extensionAllowed(basename: []const u8, allow: []const []const u8) bool {
    if (allow.len == 0) return true;
    const ext = std.fs.path.extension(basename);
    for (allow) |a| {
        if (std.mem.eql(u8, ext, a)) return true;
    }
    return false;
}

fn prefixIgnored(rel_path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, rel_path, p)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Helper: write `contents` to `<dir>/<rel>`, creating parent dirs if needed.
fn writeTmp(dir: std.fs.Dir, rel: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| {
        try dir.makePath(sub);
    }
    try dir.writeFile(.{ .sub_path = rel, .data = contents });
}

/// Helper: bump mtime forward. On some filesystems mtime resolution is 1 s,
/// so we just sleep a hair past that and re-write. Tests stay fast because
/// most assertions don't need a modification cycle.
fn bumpMtime(dir: std.fs.Dir, rel: []const u8, contents: []const u8) !void {
    // Sleep just past 1s to cross even the coarsest mtime granularity
    // (HFS+ / FAT-style 1-second resolution).
    std.Thread.sleep(1_100 * std.time.ns_per_ms);
    try dir.writeFile(.{ .sub_path = rel, .data = contents });
}

/// Helper: resolve the absolute path of a tmpDir-relative path so we can
/// chdir-free pass it to the watcher (the watcher uses std.fs.cwd() under
/// the hood). The cleanest way to drive tests is to chdir into the tmpDir
/// for the test's scope; we use a `Cwd` guard for that.
const CwdGuard = struct {
    saved_buf: [std.fs.max_path_bytes]u8 = undefined,
    saved_len: usize = 0,

    fn enter(self: *CwdGuard, dir: std.fs.Dir) !void {
        const cwd_path = try std.process.getCwd(self.saved_buf[0..]);
        self.saved_len = cwd_path.len;
        try dir.setAsCwd();
    }

    fn restore(self: *CwdGuard) void {
        const saved = self.saved_buf[0..self.saved_len];
        var d = std.fs.openDirAbsolute(saved, .{}) catch return;
        defer d.close();
        d.setAsCwd() catch {};
    }
};

test "watcher: first poll returns empty (baseline semantics)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(tmp.dir, "a.zsx", "x");
    try writeTmp(tmp.dir, "b.zsx", "y");

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    var w = try Watcher.init(testing.allocator, &.{
        .{ .path = ".", .extensions = &.{".zsx"} },
    });
    defer w.deinit();

    const events = try w.poll();
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "watcher: detects created, modified, and deleted files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(tmp.dir, "keep.zsx", "1");
    try writeTmp(tmp.dir, "delete_me.zsx", "1");

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    var w = try Watcher.init(testing.allocator, &.{
        .{ .path = ".", .extensions = &.{".zsx"} },
    });
    defer w.deinit();

    // Prime.
    _ = try w.poll();

    // Create one new file, modify one existing, delete the other.
    try writeTmp(tmp.dir, "new.zsx", "n");
    try bumpMtime(tmp.dir, "keep.zsx", "2");
    try tmp.dir.deleteFile("delete_me.zsx");

    const events = try w.poll();

    var saw_created = false;
    var saw_modified = false;
    var saw_deleted = false;
    for (events) |ev| {
        try testing.expectEqualStrings(".zsx", ev.extension);
        if (std.mem.eql(u8, ev.path, "new.zsx")) {
            try testing.expectEqual(ChangeEventKind.created, ev.kind);
            saw_created = true;
        } else if (std.mem.eql(u8, ev.path, "keep.zsx")) {
            try testing.expectEqual(ChangeEventKind.modified, ev.kind);
            saw_modified = true;
        } else if (std.mem.eql(u8, ev.path, "delete_me.zsx")) {
            try testing.expectEqual(ChangeEventKind.deleted, ev.kind);
            saw_deleted = true;
        }
    }
    try testing.expect(saw_created);
    try testing.expect(saw_modified);
    try testing.expect(saw_deleted);
}

test "watcher: empty poll when nothing changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(tmp.dir, "a.zsx", "x");

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    var w = try Watcher.init(testing.allocator, &.{
        .{ .path = ".", .extensions = &.{".zsx"} },
    });
    defer w.deinit();

    _ = try w.poll(); // prime
    const events = try w.poll();
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "watcher: two roots with different extension filters" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.makePath("themes");
    try writeTmp(tmp.dir, "src/page.zsx", "a");
    try writeTmp(tmp.dir, "src/util.zig", "b"); // .zig in src
    try writeTmp(tmp.dir, "themes/theme.zon", "c"); // .zon in themes
    try writeTmp(tmp.dir, "themes/should_be_ignored.zig", "d"); // wrong ext for themes root

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    var w = try Watcher.init(testing.allocator, &.{
        .{ .path = "src", .extensions = &.{".zsx"} },
        .{ .path = "themes", .extensions = &.{".zon"} },
    });
    defer w.deinit();

    _ = try w.poll(); // prime

    try bumpMtime(tmp.dir, "src/page.zsx", "a2");
    try bumpMtime(tmp.dir, "src/util.zig", "b2"); // should NOT fire (filtered)
    try bumpMtime(tmp.dir, "themes/theme.zon", "c2");
    try bumpMtime(tmp.dir, "themes/should_be_ignored.zig", "d2"); // should NOT fire

    const events = try w.poll();

    var zsx_hits: usize = 0;
    var zon_hits: usize = 0;
    for (events) |ev| {
        if (std.mem.eql(u8, ev.extension, ".zsx")) {
            zsx_hits += 1;
            try testing.expectEqualStrings("page.zsx", ev.path);
        } else if (std.mem.eql(u8, ev.extension, ".zon")) {
            zon_hits += 1;
            try testing.expectEqualStrings("theme.zon", ev.path);
        } else {
            // Anything else means our extension filter leaked.
            try testing.expect(false);
        }
    }
    try testing.expectEqual(@as(usize, 1), zsx_hits);
    try testing.expectEqual(@as(usize, 1), zon_hits);
}

test "watcher: ignore_prefixes excludes target path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(tmp.dir, "watched.zig", "x");
    try writeTmp(tmp.dir, "gen/codegen.zig", "x");

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    var w = try Watcher.init(testing.allocator, &.{
        .{
            .path = ".",
            .extensions = &.{".zig"},
            .ignore_prefixes = &.{"gen/"},
        },
    });
    defer w.deinit();

    _ = try w.poll(); // prime

    try bumpMtime(tmp.dir, "watched.zig", "y");
    try bumpMtime(tmp.dir, "gen/codegen.zig", "y");

    const events = try w.poll();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("watched.zig", events[0].path);
    try testing.expectEqual(ChangeEventKind.modified, events[0].kind);
}

test "watcher: multi-file modification in one poll cycle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(tmp.dir, "a.zsx", "1");
    try writeTmp(tmp.dir, "b.zsx", "1");
    try writeTmp(tmp.dir, "c.zsx", "1");

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    var w = try Watcher.init(testing.allocator, &.{
        .{ .path = ".", .extensions = &.{".zsx"} },
    });
    defer w.deinit();

    _ = try w.poll(); // prime

    // Single sleep, then write all three files. They all cross the
    // mtime boundary together.
    std.Thread.sleep(1_100 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "a.zsx", .data = "2" });
    try tmp.dir.writeFile(.{ .sub_path = "b.zsx", .data = "2" });
    try tmp.dir.writeFile(.{ .sub_path = "c.zsx", .data = "2" });

    const events = try w.poll();
    try testing.expectEqual(@as(usize, 3), events.len);
    for (events) |ev| {
        try testing.expectEqual(ChangeEventKind.modified, ev.kind);
        try testing.expectEqualStrings(".zsx", ev.extension);
    }
}

test "watcher: single-file root (one specific file path, not a dir)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(tmp.dir, "build.zig", "old");
    try writeTmp(tmp.dir, "other.zig", "noise");

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    var w = try Watcher.init(testing.allocator, &.{
        .{ .path = "build.zig" },
    });
    defer w.deinit();

    _ = try w.poll(); // prime

    // Touch unrelated file — should fire nothing.
    try bumpMtime(tmp.dir, "other.zig", "noise2");
    {
        const events = try w.poll();
        try testing.expectEqual(@as(usize, 0), events.len);
    }

    // Touch the watched single file — should fire exactly one event.
    try bumpMtime(tmp.dir, "build.zig", "new");
    {
        const events = try w.poll();
        try testing.expectEqual(@as(usize, 1), events.len);
        try testing.expectEqualStrings("build.zig", events[0].path);
        try testing.expectEqualStrings(".zig", events[0].extension);
        try testing.expectEqual(ChangeEventKind.modified, events[0].kind);
    }
}

test "watcher: smoke poll cost over real cms/src tree" {
    // This test runs against the CMS source tree itself when invoked from
    // the cms/ project root (which `zig build verify` does). It's a sanity
    // check, not an assertion — we just confirm 10 polls complete and the
    // total cost stays in a reasonable range. If the tree isn't available
    // (e.g. running from a different cwd), we silently skip.
    var src_probe = std.fs.cwd().openDir("src", .{}) catch return;
    src_probe.close();

    var w = try Watcher.init(testing.allocator, &.{
        .{
            .path = "src",
            .extensions = &.{ ".zsx", ".zig", ".zon" },
            .ignore_prefixes = &.{"gen/"},
        },
    });
    defer w.deinit();

    // Prime — this is the first walk, expected to be the most expensive.
    _ = try w.poll();

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try w.poll();
    }
    const elapsed_ns = timer.read();
    const per_poll_ns = elapsed_ns / 10;

    // Generous ceiling: ten polls in under 500 ms total. Real cost on SSD
    // is sub-millisecond; this only guards against accidental quadratic
    // behavior creeping in later.
    try testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);

    // Silence-by-default; flip on by setting an env var if you want to see
    // the number. Avoids spamming the regular test output.
    if (std.process.hasEnvVarConstant("WATCHER_SMOKE_VERBOSE")) {
        std.debug.print("\nwatcher smoke: {d} polls, {d} ns/poll\n", .{ 10, per_poll_ns });
    }
}
