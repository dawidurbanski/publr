//! The HMR swap loop. Consumes `watcher.ChangeEvent`s, drives the
//! parse + manifestEqual + setL + broadcast cycle for `.zsx` saves,
//! and falls back to a slow-path rebuild broadcast for everything else
//! (structural `.zsx` changes, `.zig`/`.zon`/`.publr`/`.css` saves).
//!
//! Task-06 of the cms-hmr-fast-path epic. Plumbing only — actual
//! WS broadcast (task-07) and dev-loop integration (task-08) wire in
//! later; this module exposes a `Broadcaster` callback the loop
//! invokes once it's decided what to do.
//!
//! ## Decision flow per event
//!
//! 1. `.deleted` kind → ignored. (Deleting a `.zsx` is a weird edit;
//!    if the view is actually rendered post-delete the slow path will
//!    catch it on the next request.)
//! 2. `.zsx` extension, `.created`/`.modified` → fast-path attempt:
//!    - Read source, `zsx.parseAll` → `[]Manifest` (source order).
//!    - Apply `spliceDomAttribute` to each (build-time parity).
//!    - For each registry Entry whose `source_path` matches the event
//!      path, find the parsed manifest by function name. If any pair
//!      compares structurally unequal → slow path the file.
//!    - If all pairs are equal: concat the per-fn literals in source
//!      order (the emitter does the same — see `zsx.emitFile`'s hmr
//!      branch — so slot offsets align with the entries' setL).
//!    - For each Entry: list its persisted prop snapshots via
//!      `hmr.listMetadataForView`, re-render each via the codegen'd
//!      `render_from_zon` trampoline, and broadcast the resulting HTML.
//!      Slow-path-only entries (whose trampoline returns
//!      `error.PropTypeUnresolvable`) are logged and skipped.
//! 3. Any other extension → broadcast `rebuild` with the source path.
//!
//! The whole `handle()` call is wrapped in a `std.Thread.Mutex` to
//! guard against pathological re-entrancy. The dev loop is
//! single-threaded today, but task-08 may tee watcher events to
//! multiple consumers and we'd rather not race into setL.

const std = @import("std");
const Allocator = std.mem.Allocator;

const watcher = @import("watcher");
const view_registry_runtime = @import("view_registry_runtime");
const hmr = @import("hmr");
const zsx = @import("zsx");
const css_jit = @import("css_jit");
const runtime_css = @import("runtime_css");

const Entry = view_registry_runtime.Entry;

// =============================================================================
// Public types
// =============================================================================

pub const SwapDecision = enum { fast, slow, ignored };

pub const SwapTelemetry = struct {
    view_name: []const u8,
    decision: SwapDecision,
    parse_ns: u64 = 0,
    equal_ns: u64 = 0,
    set_l_ns: u64 = 0,
    render_ns: u64 = 0,
    broadcast_ns: u64 = 0,
};

/// Type-erased broadcaster callback. Task-07 wires the real WS
/// implementation; tests pass a mock that records calls.
pub const Broadcaster = struct {
    ctx: ?*anyopaque = null,
    swap_fn: *const fn (ctx: ?*anyopaque, view_name: []const u8, html: []const u8) anyerror!void,
    rebuild_fn: *const fn (ctx: ?*anyopaque, names: []const []const u8) anyerror!void,
};

/// Default no-op broadcaster — `init` accepts a real one; this is here
/// as a convenience for tests / placeholder wiring.
pub fn noopBroadcaster() Broadcaster {
    const S = struct {
        fn swap(_: ?*anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn rebuild(_: ?*anyopaque, _: []const []const u8) anyerror!void {}
    };
    return .{
        .ctx = null,
        .swap_fn = &S.swap,
        .rebuild_fn = &S.rebuild,
    };
}

// =============================================================================
// Loop
// =============================================================================

pub const Loop = struct {
    allocator: Allocator,
    broadcaster: Broadcaster,

    /// Long-lived arena for new-L slices fed into `setL`. Old L slices
    /// must survive past the swap until no in-flight render references
    /// them; in `--dev` swaps are rare and the data is tiny, so we
    /// accumulate into a single arena that resets only on `deinit`.
    /// Follow-up (task-08+): swap to a generation-counter scheme so we
    /// can reclaim once we know no thread is in-flight.
    new_l_arena: std.heap.ArenaAllocator,

    /// Prefix to prepend to root-relative watcher paths to form the
    /// registry's `source_path`. The watcher root in dev is `"src"`,
    /// so events arrive as `"views/admin/dashboard.zsx"` and the
    /// registry stores `"src/views/admin/dashboard.zsx"`. Configurable
    /// for tests that want a different layout.
    view_root_prefix: []const u8 = "src/",

    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator, broadcaster: Broadcaster) Loop {
        return .{
            .allocator = allocator,
            .broadcaster = broadcaster,
            .new_l_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.new_l_arena.deinit();
    }

    pub const HandleResult = struct {
        /// True when at least one event needs the dev orchestrator to
        /// fire `triggerRebuild` (slow path on `.zsx`, fast-path failure,
        /// or any non-`.zsx` change). The swap loop has already
        /// broadcast `{control:"rebuild"}` to clients for the affected
        /// names; the orchestrator's job is to actually run `zig build`
        /// + `execvpe`.
        needs_rebuild: bool = false,
    };

    /// Drive the swap decisions for one tick of watcher events.
    /// Returns whether the caller should follow up with `triggerRebuild`.
    pub fn handle(self: *Loop, events: []const watcher.ChangeEvent) !HandleResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result: HandleResult = .{};
        for (events) |ev| {
            if (try self.handleOne(ev)) result.needs_rebuild = true;
        }
        return result;
    }

    fn handleOne(self: *Loop, ev: watcher.ChangeEvent) !bool {
        // Deletions are rare and unusual for a `.zsx` edit cycle; let
        // the slow path catch them on next render if needed.
        if (ev.kind == .deleted) return false;

        if (std.mem.eql(u8, ev.extension, ".zsx")) {
            const needs_rebuild = self.handleZsx(ev) catch |err| {
                std.log.warn(
                    "[hmr] fast-path errored on {s}: {s} — falling back to rebuild",
                    .{ ev.path, @errorName(err) },
                );
                // We don't know which views were affected, so broadcast
                // an empty names list. Client shows the pill, then does
                // a full reload on disconnect (pending_refetch empty →
                // pollReady falls into `location.reload()`).
                try self.broadcastRebuild(&.{});
                return true; // unknown failure mode — be safe, rebuild
            };
            return needs_rebuild;
        }

        // Anything else (`.zig`, `.zon`, `.publr`, ...): full rebuild.
        // No view-level refetch possible — client reloads on disconnect.
        try self.broadcastRebuild(&.{});
        return true;
    }

    /// Broadcast `{control:"rebuild", names:[...]}`. `names` are
    /// registry entry names (e.g. `"admin/variables:List"`) — the same
    /// strings the client passes to `/__hmr/render?name=` for post-rebuild
    /// refetch. An empty slice signals "rebuild but no view to refetch",
    /// which makes the client fall back to a full reload via the
    /// `/__dev/ready` polling path.
    fn broadcastRebuild(self: *Loop, names: []const []const u8) !void {
        try self.broadcaster.rebuild_fn(self.broadcaster.ctx, names);
    }

    fn handleZsx(self: *Loop, ev: watcher.ChangeEvent) !bool {
        // Per-event scratch arena. Holds the source bytes, parsed
        // manifest interior (until `deinit` below), and the rendered
        // HTML buffers. Distinct from `new_l_arena` which keeps L slices
        // alive past the call.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        // Resolve the registry's source_path key for this event.
        const source_path = try std.fs.path.join(
            sa,
            &.{ self.view_root_prefix, ev.path },
        );

        // Collect entries that belong to this file. The registry is
        // small (<100 entries); a linear scan is fine.
        const file_entries = try collectEntriesForFile(sa, source_path);
        if (file_entries.len == 0) {
            std.log.debug(
                "[hmr] no registry entries for {s} — slow-path",
                .{source_path},
            );
            // No registry entries means we can't construct view-level
            // refetch names. Broadcast an empty list; the client falls
            // back to a full page reload via `/__dev/ready` after the
            // rebuild restarts the server.
            try self.broadcastRebuild(&.{});
            return true;
        }

        // Read the fresh source.
        const src = std.fs.cwd().readFileAlloc(sa, source_path, 16 * 1024 * 1024) catch |err| {
            std.log.warn("[hmr] read failed {s}: {s}", .{ source_path, @errorName(err) });
            return err;
        };

        // Parse all functions in the file.
        var parse_timer = try std.time.Timer.start();
        const manifests = zsx.parseAll(sa, src) catch |err| {
            std.log.warn(
                "[hmr] parse failed {s}: {s}",
                .{ source_path, @errorName(err) },
            );
            // Treat parse errors as transient — author probably mid-edit.
            // Don't trigger a rebuild yet; wait for the next save.
            return false;
        };
        const parse_ns = parse_timer.read();

        // We don't deinit manifests individually because they're in the
        // scratch arena; their interior frees happen when `scratch`
        // deinits. (manifest.deinit() would free into `sa`, redundant.)

        // Match each entry to its parsed manifest by function name. We
        // need this pairing BEFORE the splice so the runtime can write
        // the SAME data-component value the build-time emit wrote
        // (`<view_name>:<fn_name>` = `entry.name`). Without this, the
        // freshly-parsed literals would carry `data-component="<fn_name>"`
        // and `setL(fresh.literals)` would shift the attribute out from
        // under the client's selector.
        var pairs = try sa.alloc(?usize, file_entries.len);
        for (file_entries, 0..) |entry, i| {
            pairs[i] = findManifestByName(manifests, fnNameOfEntry(entry));
        }

        // Apply the splice now that we know each manifest's registry name.
        for (file_entries, pairs) |entry, mi_opt| {
            if (mi_opt) |mi| {
                try zsx.emit_mod.spliceDomAttribute(sa, &manifests[mi], entry.name);
            }
        }

        // Decide whether this edit is fast-path-able: per-function
        // `manifestEqual` (tier-1). Any structural OR component-attr change
        // → rebuild (component attrs are baked inline). A missing match
        // (renamed or removed fn) is structural → rebuild.
        var equal_timer = try std.time.Timer.start();
        var fast_path: bool = true;
        for (file_entries, pairs) |entry, mi_opt| {
            const mi = mi_opt orelse {
                fast_path = false;
                break;
            };
            if (!zsx.manifestEqual(entry.manifest.*, manifests[mi])) {
                fast_path = false;
                break;
            }
        }
        const equal_ns = equal_timer.read();

        if (!fast_path) {
            std.log.info(
                "[hmr] structural change in {s} — slow-path rebuild",
                .{source_path},
            );
            // Send the affected entry names so the client can refetch
            // them after the rebuild restart. The client's
            // pending_refetch is keyed by entry.name (= the same string
            // /__hmr/render?name= looks up).
            const entry_names = try sa.alloc([]const u8, file_entries.len);
            for (file_entries, 0..) |entry, i| entry_names[i] = entry.name;
            try self.broadcastRebuild(entry_names);
            return true;
        }

        // Build file-wide L: concatenate each function's literals in
        // source order. parseAll returns manifests in source order, and
        // `emitFile`'s hmr branch accumulates `slot_offset` the same way,
        // so this matches the slot indices the codegen emitted. Allocate
        // into `new_l_arena` so the slice outlives this call.
        const la = self.new_l_arena.allocator();
        var total: usize = 0;
        for (manifests) |m| total += m.literals.len;

        const new_l = try la.alloc([]const u8, total);
        var off: usize = 0;
        for (manifests) |m| {
            for (m.literals) |lit| {
                new_l[off] = try la.dupe(u8, lit);
                off += 1;
            }
        }

        // All entries in a file share the same `setL` (file-scoped),
        // but call it via each entry's pointer for explicitness — the
        // pointers compare equal and the function is idempotent.
        var set_l_timer = try std.time.Timer.start();
        file_entries[0].setL(new_l);
        const set_l_ns = set_l_timer.read();

        // For each entry: re-render every persisted prop snapshot and
        // broadcast the HTML. Accumulate the rendered HTML across all
        // entries so we can run the runtime CSS JIT once at the end —
        // DS components assemble class strings from Zig consts and
        // backticks, so the build-time scan misses classes that only
        // exist post-render.
        var render_ns: u64 = 0;
        var broadcast_ns: u64 = 0;
        var instances_rendered: usize = 0;
        var all_rendered: std.ArrayList(u8) = .{};
        defer all_rendered.deinit(sa);

        for (file_entries) |entry| {
            const metas = try hmr.listMetadataForView(sa, entry.name);
            if (metas.len == 0) continue;

            for (metas) |meta| {
                const zon_bytes = std.fs.cwd().readFileAlloc(
                    sa,
                    meta.file_path,
                    1 * 1024 * 1024,
                ) catch |err| {
                    std.log.warn(
                        "[hmr] meta read failed {s}: {s}",
                        .{ meta.file_path, @errorName(err) },
                    );
                    continue;
                };

                var html: std.ArrayList(u8) = .{};
                defer html.deinit(sa);

                var rt = try std.time.Timer.start();
                entry.render_from_zon(&html, zon_bytes, sa) catch |err| {
                    if (err == error.PropTypeUnresolvable) {
                        std.log.info(
                            "[hmr] entry {s} is slow-path-only — skipping",
                            .{entry.name},
                        );
                        break; // skip remaining metas for this entry
                    }
                    std.log.warn(
                        "[hmr] render failed {s}: {s}",
                        .{ entry.name, @errorName(err) },
                    );
                    continue;
                };
                render_ns += rt.read();
                instances_rendered += 1;
                try all_rendered.appendSlice(sa, html.items);
                try all_rendered.append(sa, '\n');

                var bt = try std.time.Timer.start();
                self.broadcaster.swap_fn(
                    self.broadcaster.ctx,
                    entry.name,
                    html.items,
                ) catch |err| {
                    std.log.warn(
                        "[hmr] broadcast failed {s}: {s}",
                        .{ entry.name, @errorName(err) },
                    );
                };
                broadcast_ns += bt.read();
            }
        }

        // Runtime CSS recompile from the just-rendered HTML. Bytes go
        // into the runtime_css holder via std.heap.page_allocator (its
        // owner). The static handler will serve these next time the
        // browser fetches admin.css (after the WS css-bump signal).
        if (all_rendered.items.len > 0) {
            const new_css = css_jit.compileFromHtml(std.heap.page_allocator, all_rendered.items) catch |err| blk: {
                std.log.warn("[hmr] css recompile failed: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (new_css) |css| runtime_css.set(css);
        }

        std.log.info(
            "[hmr] file={s} equal={d} parsed={d}us set_l={d}us instances_rendered={d} broadcast={d}us",
            .{
                source_path,
                file_entries.len,
                parse_ns / std.time.ns_per_us,
                set_l_ns / std.time.ns_per_us,
                instances_rendered,
                broadcast_ns / std.time.ns_per_us,
            },
        );

        // equal_ns isn't currently consumed beyond this scope;
        // SwapTelemetry exists for task-08 to feed dev-mode UI.
        _ = equal_ns;

        // Fast path completed (setL + per-instance swap broadcasts). No
        // rebuild needed — the running binary's `L` table now reflects
        // the edit.
        return false;
    }
};

// =============================================================================
// Helpers
// =============================================================================

/// Linear scan over the registry; returns all entries whose
/// `source_path` matches.
fn collectEntriesForFile(alloc: Allocator, source_path: []const u8) ![]const *const Entry {
    const all = view_registry_runtime.iter();
    var out: std.ArrayList(*const Entry) = .{};
    errdefer out.deinit(alloc);
    for (all) |*e| {
        if (std.mem.eql(u8, e.source_path, source_path)) {
            try out.append(alloc, e);
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// Extract the function name part of an entry's `name`. Entries are
/// `"<dir>:<Fn>"` — the function name is the suffix after the last `:`.
fn fnNameOfEntry(entry: *const Entry) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, entry.name, ':')) |i| {
        return entry.name[i + 1 ..];
    }
    return entry.name;
}

/// Find the index of the manifest whose name matches `fn_name`.
fn findManifestByName(manifests: []const zsx.manifest_mod.Manifest, fn_name: []const u8) ?usize {
    for (manifests, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, fn_name)) return i;
    }
    return null;
}


// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// We need a synthetic Entry. The real `Entry` type comes from the
// generated `view_registry` module which is empty when -Dhmr=false;
// to test the loop in isolation, we wrap a synthetic registry view
// inside the same struct definition. Instead, the tests below take
// the "real" Entry type (zero-entries in test builds) and exercise the
// helper functions directly, plus a parallel `LoopForTest` that
// accepts an explicit `[]const *const Entry` to side-step the global
// registry.
//
// This keeps the production code reading from the global registry
// (correct at runtime in -Dhmr=true) while letting tests inject
// arbitrary entries.

/// Test-only handle that lets the harness inject `file_entries` and
/// bypass `view_registry_runtime.iter()`. Mirrors `Loop` and reuses
/// its inner machinery via duplicated code; keeping it private to the
/// test block.
const LoopForTest = struct {
    allocator: Allocator,
    broadcaster: Broadcaster,
    new_l_arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex = .{},
    view_root_prefix: []const u8 = "src/",
    /// Injected entries — keyed by source_path.
    injected: std.StringHashMap([]const *const Entry),

    fn init(allocator: Allocator, broadcaster: Broadcaster) LoopForTest {
        return .{
            .allocator = allocator,
            .broadcaster = broadcaster,
            .new_l_arena = std.heap.ArenaAllocator.init(allocator),
            .injected = std.StringHashMap([]const *const Entry).init(allocator),
        };
    }

    fn deinit(self: *LoopForTest) void {
        var it = self.injected.iterator();
        while (it.next()) |kv| self.allocator.free(kv.value_ptr.*);
        self.injected.deinit();
        self.new_l_arena.deinit();
    }

    fn putEntries(self: *LoopForTest, source_path: []const u8, entries: []const *const Entry) !void {
        const dup = try self.allocator.dupe(*const Entry, entries);
        try self.injected.put(source_path, dup);
    }

    fn handle(self: *LoopForTest, events: []const watcher.ChangeEvent) !Loop.HandleResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result: Loop.HandleResult = .{};
        for (events) |ev| {
            if (try self.handleOne(ev)) result.needs_rebuild = true;
        }
        return result;
    }

    fn handleOne(self: *LoopForTest, ev: watcher.ChangeEvent) !bool {
        if (ev.kind == .deleted) return false;

        if (std.mem.eql(u8, ev.extension, ".zsx")) {
            const needs_rebuild = self.handleZsx(ev) catch |err| {
                std.log.warn(
                    "[hmr-test] fast-path errored on {s}: {s}",
                    .{ ev.path, @errorName(err) },
                );
                try self.broadcastRebuild(&.{ev.path});
                return true;
            };
            return needs_rebuild;
        }

        try self.broadcastRebuild(&.{ev.path});
        return true;
    }

    fn broadcastRebuild(self: *LoopForTest, names: []const []const u8) !void {
        try self.broadcaster.rebuild_fn(self.broadcaster.ctx, names);
    }

    fn handleZsx(self: *LoopForTest, ev: watcher.ChangeEvent) !bool {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const source_path = try std.fs.path.join(sa, &.{ self.view_root_prefix, ev.path });
        const file_entries = self.injected.get(source_path) orelse {
            // Fall through to slow path — no entries registered for the file.
            try self.broadcastRebuild(&.{source_path});
            return true;
        };

        const src = try std.fs.cwd().readFileAlloc(sa, source_path, 16 * 1024 * 1024);

        const manifests = zsx.parseAll(sa, src) catch |err| {
            std.log.warn("[hmr-test] parse failed: {s}", .{@errorName(err)});
            return false;
        };

        var pairs = try sa.alloc(?usize, file_entries.len);
        for (file_entries, 0..) |entry, i| {
            pairs[i] = findManifestByName(manifests, fnNameOfEntry(entry));
        }

        // Splice with entry.name so runtime data-component value matches
        // what the build-time emit wrote.
        for (file_entries, pairs) |entry, mi_opt| {
            if (mi_opt) |mi| {
                try zsx.emit_mod.spliceDomAttribute(sa, &manifests[mi], entry.name);
            }
        }

        var all_equal: bool = true;
        for (file_entries, pairs) |entry, mi_opt| {
            const mi = mi_opt orelse {
                all_equal = false;
                break;
            };
            if (!zsx.manifestEqual(entry.manifest.*, manifests[mi])) {
                all_equal = false;
                break;
            }
        }

        if (!all_equal) {
            const entry_names = try sa.alloc([]const u8, file_entries.len);
            for (file_entries, 0..) |entry, i| entry_names[i] = entry.name;
            try self.broadcastRebuild(entry_names);
            return true;
        }

        const la = self.new_l_arena.allocator();
        var total: usize = 0;
        for (manifests) |m| total += m.literals.len;
        const new_l = try la.alloc([]const u8, total);
        var off: usize = 0;
        for (manifests) |m| {
            for (m.literals) |lit| {
                new_l[off] = try la.dupe(u8, lit);
                off += 1;
            }
        }
        file_entries[0].setL(new_l);

        for (file_entries) |entry| {
            const metas = try hmr.listMetadataForView(sa, entry.name);
            if (metas.len == 0) continue;
            for (metas) |meta| {
                const zon_bytes = std.fs.cwd().readFileAlloc(sa, meta.file_path, 1024 * 1024) catch continue;
                var html: std.ArrayList(u8) = .{};
                defer html.deinit(sa);
                entry.render_from_zon(&html, zon_bytes, sa) catch |err| {
                    if (err == error.PropTypeUnresolvable) {
                        std.log.info("[hmr-test] {s} slow-path-only", .{entry.name});
                        break;
                    }
                    continue;
                };
                self.broadcaster.swap_fn(self.broadcaster.ctx, entry.name, html.items) catch {};
            }
        }
        return false;
    }
};

// ----- Recording broadcaster -----

const Recorder = struct {
    allocator: Allocator,
    swap_calls: std.ArrayList(SwapCall) = .{},
    rebuild_calls: std.ArrayList([]const u8) = .{},
    /// Count of `rebuild_fn` invocations, regardless of `names` payload.
    /// `rebuild_calls.items.len` only counts non-empty broadcasts, so a
    /// non-`.zsx` event (which broadcasts empty names) wouldn't otherwise
    /// be observable.
    rebuild_call_count: usize = 0,

    const SwapCall = struct { name: []const u8, html: []const u8 };

    fn init(allocator: Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Recorder) void {
        for (self.swap_calls.items) |c| {
            self.allocator.free(c.name);
            self.allocator.free(c.html);
        }
        self.swap_calls.deinit(self.allocator);
        for (self.rebuild_calls.items) |s| self.allocator.free(s);
        self.rebuild_calls.deinit(self.allocator);
    }

    fn broadcaster(self: *Recorder) Broadcaster {
        return .{
            .ctx = self,
            .swap_fn = &swapFn,
            .rebuild_fn = &rebuildFn,
        };
    }

    fn swapFn(ctx: ?*anyopaque, name: []const u8, html: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        const name_dup = try self.allocator.dupe(u8, name);
        const html_dup = try self.allocator.dupe(u8, html);
        try self.swap_calls.append(self.allocator, .{ .name = name_dup, .html = html_dup });
    }

    fn rebuildFn(ctx: ?*anyopaque, names: []const []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.rebuild_call_count += 1;
        for (names) |n| {
            const n_dup = try self.allocator.dupe(u8, n);
            try self.rebuild_calls.append(self.allocator, n_dup);
        }
    }
};

// ----- Test view harness -----
//
// Synthesizes a minimal "view": baked manifest from a known `.zsx`
// source, a `setL` that records calls, and a `render_from_zon` that
// concatenates the current L slots into `out`.

const TestView = struct {
    var captured_L: []const []const u8 = &.{};
    var set_l_call_count: usize = 0;
    var force_unresolvable: bool = false;

    fn reset() void {
        captured_L = &.{};
        set_l_call_count = 0;
        force_unresolvable = false;
    }

    fn setL(new_L: []const []const u8) void {
        captured_L = new_L;
        set_l_call_count += 1;
    }

    fn renderFromZon(
        out: *std.ArrayList(u8),
        zon_bytes: []const u8,
        alloc: Allocator,
    ) anyerror!void {
        _ = zon_bytes;
        if (force_unresolvable) return error.PropTypeUnresolvable;
        for (captured_L) |lit| try out.appendSlice(alloc, lit);
    }
};

/// Build a baked manifest for a known source. Lives in `arena`.
fn bakedManifest(arena: Allocator, src: []const u8) !zsx.manifest_mod.Manifest {
    return try zsx.parse(arena, src);
}

// =============================================================================
// CwdGuard — chdir into a tmp dir for the test scope, restore on exit.
// =============================================================================

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

// =============================================================================
// Tests
// =============================================================================

test "hmr_loop: .css event triggers slow-path rebuild broadcast" {
    const alloc = testing.allocator;

    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var loop = Loop.init(alloc, rec.broadcaster());
    defer loop.deinit();

    const events = [_]watcher.ChangeEvent{
        .{ .path = "static/app.css", .extension = ".css", .kind = .modified, .mtime_ns = 0 },
    };
    _ = try loop.handle(&events);

    try testing.expectEqual(@as(usize, 0), rec.swap_calls.items.len);
    // Non-`.zsx` events broadcast empty names (client falls back to a
    // full reload on disconnect). The broadcaster still fired exactly
    // once, but no individual entry names were recorded.
    try testing.expectEqual(@as(usize, 1), rec.rebuild_call_count);
    try testing.expectEqual(@as(usize, 0), rec.rebuild_calls.items.len);
}

test "hmr_loop: .deleted .zsx event is ignored (no broadcasts)" {
    const alloc = testing.allocator;

    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var loop = Loop.init(alloc, rec.broadcaster());
    defer loop.deinit();

    const events = [_]watcher.ChangeEvent{
        .{ .path = "views/admin/dashboard.zsx", .extension = ".zsx", .kind = .deleted, .mtime_ns = 0 },
    };
    _ = try loop.handle(&events);

    try testing.expectEqual(@as(usize, 0), rec.swap_calls.items.len);
    try testing.expectEqual(@as(usize, 0), rec.rebuild_calls.items.len);
}

test "hmr_loop: structurally-different fresh manifest triggers rebuild (not swap)" {
    const alloc = testing.allocator;
    TestView.reset();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    // Write a fresh source: <p>{x + 1}</p> — different expression body.
    try tmp.dir.makePath("src/views");
    try tmp.dir.writeFile(.{
        .sub_path = "src/views/foo.zsx",
        .data = "pub fn Foo(x: i32) void { <p>{x + 1}</p> }",
    });

    // Build a baked manifest from a DIFFERENT source — `{x}` instead of `{x + 1}`.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var baked = try bakedManifest(aa, "pub fn Foo(x: i32) void { <p>{x}</p> }");

    // Synthesize an entry pointing at the baked manifest + TestView.setL/render.
    const entry = try aa.create(Entry);
    entry.* = .{
        .name = "foo:Foo",
        .source_path = "src/views/foo.zsx",
        .manifest = &baked,
        .setL = &TestView.setL,
        .render_from_zon = &TestView.renderFromZon,
    };

    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var loop = LoopForTest.init(alloc, rec.broadcaster());
    defer loop.deinit();
    try loop.putEntries("src/views/foo.zsx", &.{entry});

    const events = [_]watcher.ChangeEvent{
        .{ .path = "views/foo.zsx", .extension = ".zsx", .kind = .modified, .mtime_ns = 0 },
    };
    _ = try loop.handle(&events);

    try testing.expectEqual(@as(usize, 0), rec.swap_calls.items.len);
    // Structural change in a registered file: broadcast the affected
    // entry names so the client can refetch them by registry key after
    // the rebuild restart.
    try testing.expectEqual(@as(usize, 1), rec.rebuild_call_count);
    try testing.expectEqual(@as(usize, 1), rec.rebuild_calls.items.len);
    try testing.expectEqualStrings("foo:Foo", rec.rebuild_calls.items[0]);
    try testing.expectEqual(@as(usize, 0), TestView.set_l_call_count);
}

test "hmr_loop: manifestEqual=true with no metadata files calls setL but no broadcasts" {
    const alloc = testing.allocator;
    TestView.reset();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    // Same source baked as fresh.
    const src_text = "pub fn Foo() void { <p>hello</p> }";
    try tmp.dir.makePath("src/views");
    try tmp.dir.writeFile(.{ .sub_path = "src/views/foo.zsx", .data = src_text });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var baked = try bakedManifest(aa, src_text);
    // Apply the same splice the swap loop does so manifestEqual holds.
    try zsx.emit_mod.spliceDomAttribute(aa, &baked, "foo:Foo");

    const entry = try aa.create(Entry);
    entry.* = .{
        .name = "foo:Foo",
        .source_path = "src/views/foo.zsx",
        .manifest = &baked,
        .setL = &TestView.setL,
        .render_from_zon = &TestView.renderFromZon,
    };

    // Point hmr at an empty subdir.
    const prev_hmr = hmr.getHmrDir();
    defer hmr.setHmrDir(prev_hmr);
    try tmp.dir.makePath(".publr/hmr");
    hmr.setHmrDir(".publr/hmr");

    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var loop = LoopForTest.init(alloc, rec.broadcaster());
    defer loop.deinit();
    try loop.putEntries("src/views/foo.zsx", &.{entry});

    const events = [_]watcher.ChangeEvent{
        .{ .path = "views/foo.zsx", .extension = ".zsx", .kind = .modified, .mtime_ns = 0 },
    };
    _ = try loop.handle(&events);

    try testing.expectEqual(@as(usize, 0), rec.swap_calls.items.len);
    try testing.expectEqual(@as(usize, 0), rec.rebuild_calls.items.len);
    try testing.expectEqual(@as(usize, 1), TestView.set_l_call_count);
    try testing.expect(TestView.captured_L.len > 0);
    // First literal should be the spliced root <p>.
    try testing.expect(std.mem.indexOf(u8, TestView.captured_L[0], "data-component=\"foo:Foo\"") != null);
}

test "hmr_loop: manifestEqual=true with one metadata file → swap broadcast fires" {
    const alloc = testing.allocator;
    TestView.reset();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    const src_text = "pub fn Foo() void { <p>hello</p> }";
    try tmp.dir.makePath("src/views");
    try tmp.dir.writeFile(.{ .sub_path = "src/views/foo.zsx", .data = src_text });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var baked = try bakedManifest(aa, src_text);
    try zsx.emit_mod.spliceDomAttribute(aa, &baked, "foo:Foo");

    const entry = try aa.create(Entry);
    entry.* = .{
        .name = "foo:Foo",
        .source_path = "src/views/foo.zsx",
        .manifest = &baked,
        .setL = &TestView.setL,
        .render_from_zon = &TestView.renderFromZon,
    };

    // Drop one captureProps-style metadata file under .publr/hmr/<hash>/.
    const prev_hmr = hmr.getHmrDir();
    defer hmr.setHmrDir(prev_hmr);
    try tmp.dir.makePath(".publr/hmr/aabbccdd");
    hmr.setHmrDir(".publr/hmr");
    try tmp.dir.writeFile(.{
        .sub_path = ".publr/hmr/aabbccdd/foo-Foo-0.zon",
        .data = ".{}",
    });

    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var loop = LoopForTest.init(alloc, rec.broadcaster());
    defer loop.deinit();
    try loop.putEntries("src/views/foo.zsx", &.{entry});

    const events = [_]watcher.ChangeEvent{
        .{ .path = "views/foo.zsx", .extension = ".zsx", .kind = .modified, .mtime_ns = 0 },
    };
    _ = try loop.handle(&events);

    try testing.expectEqual(@as(usize, 0), rec.rebuild_calls.items.len);
    try testing.expectEqual(@as(usize, 1), rec.swap_calls.items.len);
    try testing.expectEqualStrings("foo:Foo", rec.swap_calls.items[0].name);
    try testing.expect(rec.swap_calls.items[0].html.len > 0);
    try testing.expect(std.mem.indexOf(u8, rec.swap_calls.items[0].html, "data-component=\"foo:Foo\"") != null);
}

test "hmr_loop: slow-path-only entry (PropTypeUnresolvable) skipped without crash" {
    const alloc = testing.allocator;
    TestView.reset();
    TestView.force_unresolvable = true;
    defer TestView.force_unresolvable = false;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var guard: CwdGuard = .{};
    try guard.enter(tmp.dir);
    defer guard.restore();

    const src_text = "pub fn Foo() void { <p>hello</p> }";
    try tmp.dir.makePath("src/views");
    try tmp.dir.writeFile(.{ .sub_path = "src/views/foo.zsx", .data = src_text });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var baked = try bakedManifest(aa, src_text);
    try zsx.emit_mod.spliceDomAttribute(aa, &baked, "foo:Foo");

    const entry = try aa.create(Entry);
    entry.* = .{
        .name = "foo:Foo",
        .source_path = "src/views/foo.zsx",
        .manifest = &baked,
        .setL = &TestView.setL,
        .render_from_zon = &TestView.renderFromZon,
    };

    const prev_hmr = hmr.getHmrDir();
    defer hmr.setHmrDir(prev_hmr);
    try tmp.dir.makePath(".publr/hmr/aabbccdd");
    hmr.setHmrDir(".publr/hmr");
    try tmp.dir.writeFile(.{
        .sub_path = ".publr/hmr/aabbccdd/foo-Foo-0.zon",
        .data = ".{}",
    });

    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var loop = LoopForTest.init(alloc, rec.broadcaster());
    defer loop.deinit();
    try loop.putEntries("src/views/foo.zsx", &.{entry});

    const events = [_]watcher.ChangeEvent{
        .{ .path = "views/foo.zsx", .extension = ".zsx", .kind = .modified, .mtime_ns = 0 },
    };
    _ = try loop.handle(&events);

    // setL still ran; render returned PropTypeUnresolvable so no swap.
    try testing.expectEqual(@as(usize, 1), TestView.set_l_call_count);
    try testing.expectEqual(@as(usize, 0), rec.swap_calls.items.len);
    try testing.expectEqual(@as(usize, 0), rec.rebuild_calls.items.len);
}

// Thread harness for the mutex test — needs to be a top-level fn so
// `std.Thread.spawn` can take its address.
const MutexHarness = struct {
    loop: *Loop,
    events_a: []const watcher.ChangeEvent,

    fn run(self: *MutexHarness) void {
        _ = self.loop.handle(self.events_a) catch {};
    }
};

test "hmr_loop: concurrent handle() calls serialize via the mutex" {
    const alloc = testing.allocator;

    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var loop = Loop.init(alloc, rec.broadcaster());
    defer loop.deinit();

    const events_a = [_]watcher.ChangeEvent{
        .{ .path = "a.css", .extension = ".css", .kind = .modified, .mtime_ns = 0 },
    };
    const events_b = [_]watcher.ChangeEvent{
        .{ .path = "b.css", .extension = ".css", .kind = .modified, .mtime_ns = 0 },
    };

    var h_a = MutexHarness{ .loop = &loop, .events_a = &events_a };
    var h_b = MutexHarness{ .loop = &loop, .events_a = &events_b };

    const t1 = try std.Thread.spawn(.{}, MutexHarness.run, .{&h_a});
    const t2 = try std.Thread.spawn(.{}, MutexHarness.run, .{&h_b});
    t1.join();
    t2.join();

    // Both events should have been processed (one rebuild each). The
    // events are `.css` so the broadcast carries empty names — count
    // calls, not name entries.
    try testing.expectEqual(@as(usize, 2), rec.rebuild_call_count);
    try testing.expectEqual(@as(usize, 0), rec.rebuild_calls.items.len);
}
