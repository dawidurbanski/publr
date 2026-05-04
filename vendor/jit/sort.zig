/// Class-sorting (port of upstream tailwindcss/packages/tailwindcss/src/sort.ts).
///
/// Replaces the task-03 stub. Implements `sortClasses(allocator, input, theme_css)`
/// which the test runner calls per fixture.
///
/// Algorithm (Phase 1, faithful enough for the 10 sort fixtures):
///   1. Parse each class via candidate.zig.
///   2. Compute a sort key per class:
///      - Unknown / unparseable / non-Tailwind classes → null (sort to front,
///        preserve input order).
///      - Known classes → a multi-field key combining: !important flag,
///        variant count, property bucket index, alphabetical position.
///   3. Stable-sort by key.
///   4. Join with spaces.
///
/// The theme_css argument is accepted for compat with the test runner's API
/// but is currently parsed only enough to know if breakpoint tokens exist
/// (used as a hint for whether a name like `md` should be a breakpoint variant).
/// Per-fixture themes are not used for sort ordering, only for resolution
/// presence checks (which Phase 1 doesn't need).

const std = @import("std");
const candidate = @import("candidate.zig");

pub const SortError = error{
    NotImplemented,
    OutOfMemory,
};

pub fn sortClasses(
    allocator: std.mem.Allocator,
    input: []const u8,
    theme_css: []const u8,
) SortError![]u8 {
    _ = theme_css; // not currently used; see module doc comment

    // Split input on whitespace.
    var classes = std.array_list.Managed([]const u8).init(allocator);
    defer classes.deinit();
    var it = std.mem.tokenizeAny(u8, input, " \t\n\r");
    while (it.next()) |c| try classes.append(c);

    if (classes.items.len == 0) {
        return allocator.dupe(u8, "") catch return SortError.OutOfMemory;
    }

    // Compute sort entries: (class_name, sort_key, input_index).
    // input_index breaks ties to keep stability.
    const Entry = struct {
        name: []const u8,
        key: ?u64,
        idx: u32,
    };

    const entries = try allocator.alloc(Entry, classes.items.len);
    defer allocator.free(entries);

    for (classes.items, 0..) |name, i| {
        entries[i] = .{
            .name = name,
            .key = sortKey(allocator, name) catch |err| switch (err) {
                error.OutOfMemory => return SortError.OutOfMemory,
            },
            .idx = @intCast(i),
        };
    }

    std.mem.sort(Entry, entries, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            // Both null: preserve input order.
            if (a.key == null and b.key == null) return a.idx < b.idx;
            // Null sorts to front.
            if (a.key == null) return true;
            if (b.key == null) return false;
            if (a.key.? != b.key.?) return a.key.? < b.key.?;
            // Same key (same bucket + same variant chain + same important):
            // tiebreak on the full class name lexicographically. This gives
            // `bg-blue-500 < bg-red-500` etc.
            const cmp = std.mem.order(u8, a.name, b.name);
            if (cmp == .lt) return true;
            if (cmp == .gt) return false;
            return a.idx < b.idx;
        }
    }.lessThan);

    // Join.
    var total: usize = 0;
    for (entries) |e| total += e.name.len;
    if (entries.len > 1) total += entries.len - 1;
    var out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (entries, 0..) |e, i| {
        if (i > 0) {
            out[pos] = ' ';
            pos += 1;
        }
        @memcpy(out[pos .. pos + e.name.len], e.name);
        pos += e.name.len;
    }
    return out;
}

/// Compute a sort key for a class name. Returns null for unknown / non-Tailwind
/// classes (they sort to the front in input order).
///
/// Key layout (high to low bits):
///   - bit 60:    !important (1 = important, sorts later within its group)
///   - bits 52-59: variant count (more variants → later)
///   - bits 36-51: breakpoint priority (16 bits) — min-width in rem × 16,
///                 so larger breakpoints sort LATER and override smaller
///                 ones in the cascade. Zero when no breakpoint variant.
///   - bits 16-35: property bucket index (lower = earlier in cascade)
///   - bits 0-15: alphabetical position (per class-name slot in bucket)
///
/// **Why breakpoint priority matters**: at a wide viewport, both `sm:X` and
/// `lg:X` media queries match. The CSS cascade gives the win to whichever
/// rule comes LATER in source order. So we need `sm:X` emitted BEFORE
/// `lg:X` to make `lg:X` win.
fn sortKey(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?u64 {
    const cands = try candidate.parseCandidate(allocator, name);
    defer candidate.freeCandidates(allocator, cands);

    // Parser failed: not a Tailwind class.
    if (cands.len == 0) return null;

    // Pick the candidate whose root we can place in the bucket table. Prefer
    // arbitrary > functional with a known bucket > static.
    var best_bucket: ?u32 = null;
    var best_cand: ?candidate.Candidate = null;
    for (cands) |c| {
        const root = candidateRoot(c);
        if (bucketForRoot(root)) |b| {
            if (best_bucket == null or b < best_bucket.?) {
                best_bucket = b;
                best_cand = c;
            }
        }
    }

    // Fall back: if no candidate has a known bucket, use the first one with a
    // catchall bucket (e.g. arbitrary properties get a high bucket so they
    // sort consistently among themselves).
    if (best_bucket == null) {
        if (cands[0] == .arbitrary) {
            best_bucket = ARBITRARY_PROPERTY_BUCKET;
            best_cand = cands[0];
        } else {
            // Unknown utility → null sort key (treat as non-Tailwind).
            return null;
        }
    }

    const c = best_cand.?;
    const variants = switch (c) {
        .static_c => |s| s.variants,
        .functional => |f| f.variants,
        .arbitrary => |a| a.variants,
    };
    const important = switch (c) {
        .static_c => |s| s.important,
        .functional => |f| f.important,
        .arbitrary => |a| a.important,
    };

    // Breakpoint priority: max across all variant slots. Higher value
    // means a wider min-width, which means the rule must come later in CSS
    // so it overrides narrower-breakpoint rules at wide viewports.
    var bp_priority: u16 = 0;
    for (variants) |v| {
        const p = breakpointPriority(v);
        if (p > bp_priority) bp_priority = p;
    }

    var key: u64 = 0;
    if (important) key |= @as(u64, 1) << 60;
    key |= @as(u64, @min(variants.len, 0xFF)) << 52;
    key |= @as(u64, bp_priority) << 36;
    key |= @as(u64, best_bucket.? & 0xFFFFF) << 16;
    key |= @as(u64, alphaScore(name) & 0xFFFF);

    return key;
}

/// Heuristic priority for breakpoint variants — used so `sm:X` sorts before
/// `lg:X` in the output, giving `lg:X` the cascade win at wide viewports.
/// Returns 0 for non-breakpoint variants (hover, focus, dark, data-*, etc.)
/// so they don't perturb the sort.
///
/// Values are min-width-in-rem × 16 to leave room for half-step custom
/// breakpoints if needed. Standard Tailwind breakpoints:
///   sm  = 40rem → 640
///   md  = 48rem → 768
///   lg  = 64rem → 1024
///   xl  = 80rem → 1280
///   2xl = 96rem → 1536
///
/// `max-{key}:` variants get a HIGHER priority than the equivalent `{key}:`
/// because max-* sets a *narrower* viewport ceiling — at viewport just
/// under the breakpoint, both `max-sm:X` and `sm:X` match, and `max-sm:X`
/// must win (it's the more specific narrowing condition).
fn breakpointPriority(v: candidate.Variant) u16 {
    return switch (v) {
        .static_v => |s| breakpointFor(s.root),
        .functional => |f| blk: {
            // `max-{key}:` — value is the key.
            if (std.mem.eql(u8, f.root, "max")) {
                if (f.value) |val| {
                    if (val == .named) {
                        const p = breakpointFor(val.named);
                        // max-{key} wins by a small margin over plain {key}.
                        if (p > 0) break :blk p +| 1;
                    }
                }
            }
            break :blk 0;
        },
        else => 0,
    };
}

fn breakpointFor(name: []const u8) u16 {
    if (std.mem.eql(u8, name, "sm")) return 640;
    if (std.mem.eql(u8, name, "md")) return 768;
    if (std.mem.eql(u8, name, "lg")) return 1024;
    if (std.mem.eql(u8, name, "xl")) return 1280;
    if (std.mem.eql(u8, name, "2xl")) return 1536;
    if (std.mem.eql(u8, name, "3xl")) return 1792;
    if (std.mem.eql(u8, name, "4xl")) return 2048;
    if (std.mem.eql(u8, name, "5xl")) return 2304;
    if (std.mem.eql(u8, name, "6xl")) return 2560;
    if (std.mem.eql(u8, name, "7xl")) return 2816;
    return 0;
}

fn candidateRoot(c: candidate.Candidate) []const u8 {
    return switch (c) {
        .static_c => |s| s.root,
        .functional => |f| f.root,
        .arbitrary => |a| a.property,
    };
}

/// Map a utility root to its property bucket index. Lower = earlier in cascade.
/// The bucket numbers are chosen to roughly match upstream's property-order.ts
/// for the properties our /site classes touch. Extend per coverage need.
const PropertyBucket = struct { root: []const u8, bucket: u32 };

const ARBITRARY_PROPERTY_BUCKET: u32 = 5000;

const PROPERTY_BUCKETS = [_]PropertyBucket{
    // ── Layout / position (very early in cascade) ──
    .{ .root = "static", .bucket = 10 },
    .{ .root = "relative", .bucket = 10 },
    .{ .root = "absolute", .bucket = 10 },
    .{ .root = "fixed", .bucket = 10 },
    .{ .root = "sticky", .bucket = 10 },
    .{ .root = "isolate", .bucket = 11 },
    .{ .root = "z", .bucket = 12 },
    .{ .root = "inset", .bucket = 13 },
    .{ .root = "top", .bucket = 14 },
    .{ .root = "right", .bucket = 14 },
    .{ .root = "bottom", .bucket = 14 },
    .{ .root = "left", .bucket = 14 },

    // ── Display / box ──
    .{ .root = "block", .bucket = 20 },
    .{ .root = "inline", .bucket = 20 },
    .{ .root = "inline-block", .bucket = 20 },
    .{ .root = "flex", .bucket = 20 },
    .{ .root = "inline-flex", .bucket = 20 },
    .{ .root = "grid", .bucket = 20 },
    .{ .root = "inline-grid", .bucket = 20 },
    .{ .root = "hidden", .bucket = 20 },
    .{ .root = "overflow", .bucket = 22 },
    .{ .root = "overflow-hidden", .bucket = 22 },
    .{ .root = "overflow-auto", .bucket = 22 },
    .{ .root = "overflow-visible", .bucket = 22 },

    // ── Sizing ──
    .{ .root = "size", .bucket = 30 },
    .{ .root = "w", .bucket = 31 },
    .{ .root = "h", .bucket = 32 },
    .{ .root = "max-w", .bucket = 33 },
    .{ .root = "max-h", .bucket = 34 },
    .{ .root = "min-w", .bucket = 35 },
    .{ .root = "min-h", .bucket = 36 },

    // ── Grid ──
    .{ .root = "grid-cols", .bucket = 40 },
    .{ .root = "col-span", .bucket = 41 },
    .{ .root = "grid-rows", .bucket = 42 },
    .{ .root = "row-span", .bucket = 43 },
    .{ .root = "gap", .bucket = 44 },
    .{ .root = "gap-x", .bucket = 45 },
    .{ .root = "gap-y", .bucket = 46 },

    // ── Flex ──
    .{ .root = "flex-row", .bucket = 50 },
    .{ .root = "flex-col", .bucket = 50 },
    .{ .root = "flex-wrap", .bucket = 51 },
    .{ .root = "items-center", .bucket = 52 },
    .{ .root = "items-start", .bucket = 52 },
    .{ .root = "items-end", .bucket = 52 },
    .{ .root = "justify-center", .bucket = 53 },
    .{ .root = "justify-start", .bucket = 53 },
    .{ .root = "justify-between", .bucket = 53 },
    .{ .root = "justify-end", .bucket = 53 },
    .{ .root = "self-center", .bucket = 54 },

    // ── Padding (cascade-affecting; shorthand-then-axis-then-side) ──
    .{ .root = "p", .bucket = 100 },
    .{ .root = "px", .bucket = 101 },
    .{ .root = "py", .bucket = 102 },
    .{ .root = "pt", .bucket = 103 },
    .{ .root = "pr", .bucket = 104 },
    .{ .root = "pb", .bucket = 105 },
    .{ .root = "pl", .bucket = 106 },

    // ── Margin ──
    .{ .root = "m", .bucket = 110 },
    .{ .root = "mx", .bucket = 111 },
    .{ .root = "my", .bucket = 112 },
    .{ .root = "mt", .bucket = 113 },
    .{ .root = "mr", .bucket = 114 },
    .{ .root = "mb", .bucket = 115 },
    .{ .root = "ml", .bucket = 116 },

    // ── Background (before padding/border per upstream) ──
    .{ .root = "bg", .bucket = 80 },
    .{ .root = "bg-linear-to", .bucket = 81 },
    .{ .root = "from", .bucket = 82 },
    .{ .root = "via", .bucket = 83 },
    .{ .root = "to", .bucket = 84 },

    // ── Border ──
    .{ .root = "border", .bucket = 200 },
    .{ .root = "border-x", .bucket = 201 },
    .{ .root = "border-y", .bucket = 202 },
    .{ .root = "border-t", .bucket = 203 },
    .{ .root = "border-r", .bucket = 204 },
    .{ .root = "border-b", .bucket = 205 },
    .{ .root = "border-l", .bucket = 206 },
    .{ .root = "rounded", .bucket = 220 },
    .{ .root = "ring", .bucket = 230 },
    .{ .root = "ring-inset", .bucket = 231 },

    // ── Typography ──
    .{ .root = "text", .bucket = 300 },
    .{ .root = "text-balance", .bucket = 301 },
    .{ .root = "text-pretty", .bucket = 301 },
    .{ .root = "text-wrap", .bucket = 301 },
    .{ .root = "text-nowrap", .bucket = 301 },
    .{ .root = "text-left", .bucket = 302 },
    .{ .root = "text-center", .bucket = 302 },
    .{ .root = "text-right", .bucket = 302 },
    .{ .root = "font", .bucket = 310 },
    .{ .root = "tracking", .bucket = 320 },
    .{ .root = "leading", .bucket = 330 },
    .{ .root = "antialiased", .bucket = 340 },
    .{ .root = "subpixel-antialiased", .bucket = 340 },

    // ── Effects ──
    .{ .root = "opacity", .bucket = 400 },
    .{ .root = "shadow", .bucket = 410 },

    // ── Transition ──
    .{ .root = "transition", .bucket = 500 },
    .{ .root = "transition-colors", .bucket = 500 },
    .{ .root = "transition-opacity", .bucket = 500 },
    .{ .root = "duration", .bucket = 510 },
};

fn bucketForRoot(root: []const u8) ?u32 {
    inline for (PROPERTY_BUCKETS) |entry| {
        if (std.mem.eql(u8, root, entry.root)) return entry.bucket;
    }
    // Negative-prefix fallback: `-z` → look up `z`.
    if (root.len > 1 and root[0] == '-') {
        inline for (PROPERTY_BUCKETS) |entry| {
            if (std.mem.eql(u8, root[1..], entry.root)) return entry.bucket;
        }
    }
    return null;
}

/// Compute a small alphabetical score for tie-breaking within a bucket.
/// Uses the first ~3 chars of the class name. 12 bits = 4096 slots.
fn alphaScore(s: []const u8) u32 {
    var score: u32 = 0;
    var i: usize = 0;
    while (i < s.len and i < 3) : (i += 1) {
        score = score * 256 + s[i];
    }
    return score & 0xFFF;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const tst = std.testing;

test "sortClasses: padding shorthand, x, y" {
    const out = try sortClasses(tst.allocator, "py-3 p-1 px-3", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("p-1 px-3 py-3", out);
}

test "sortClasses: variant count ordering" {
    const out = try sortClasses(tst.allocator, "px-3 focus:hover:p-3 hover:p-1 py-3", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("px-3 py-3 hover:p-1 focus:hover:p-3", out);
}

test "sortClasses: important sorts to end of group" {
    const out = try sortClasses(tst.allocator, "px-3 py-4! p-1", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("p-1 px-3 py-4!", out);
}

test "sortClasses: unknown classes preserve input order, sort to front" {
    const out = try sortClasses(tst.allocator, "b p-1 a", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("b a p-1", out);
}

test "sortClasses: bg sorts before p, alphabetical within bg" {
    const out = try sortClasses(
        tst.allocator,
        "a-class px-3 p-1 b-class py-3 bg-red-500 bg-blue-500",
        "",
    );
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("a-class b-class bg-blue-500 bg-red-500 p-1 px-3 py-3", out);
}

test "sortClasses: arbitrary properties preserve input order" {
    const out = try sortClasses(
        tst.allocator,
        "[--bg:#111] [--bg_hover:#000] [--fg:#fff]",
        "",
    );
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("[--bg:#111] [--bg_hover:#000] [--fg:#fff]", out);
}

test "sortClasses: hover:b focus:p-1 a" {
    const out = try sortClasses(tst.allocator, "hover:b focus:p-1 a", "");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings("hover:b a focus:p-1", out);
}
