//! Runtime CSS recompilation from rendered HTML.
//!
//! Build-time JIT (cms/build/theme.zig) reads `css_classes.txt` — the
//! transpiler's static scan of `class="…"` literals in source. That misses
//! DS components which assemble class strings from Zig consts and backticks:
//!
//!     class={`${@raw base} ${@raw size_classes} ${@raw props.class}`}
//!
//! So a `<Button>` invocation whose final HTML carries `bg-primary
//! text-primary-foreground rounded-md px-4` never trips the build scan,
//! and after a hot swap the new classes have no CSS rules attached.
//!
//! Fix: after every fast-path HMR swap, re-extract classes from the just-
//! rendered HTML (ground truth — exactly what the browser will see) and
//! recompile. The result lands in an in-memory override slot read by the
//! static handler in dev mode; the browser refetches `/static/admin.css`
//! after the existing `broadcastCss` cache-bust signal.
//!
//! Production is untouched: the build-time CSS embedded in the binary is
//! still the source of truth when the runtime override is empty.

const std = @import("std");
const jit = @import("jit");

// Themes are merged at comptime: built-in Tailwind palette first, then
// DS semantic palette layered on top so utilities like `bg-card` resolve
// to `var(--card)`. Mirrors the build-time JIT compiler's setup in
// build/theme.zig so runtime swaps and `zig build` produce identical CSS
// for the same class set.
const default_theme: jit.Theme = @import("default_theme");
const ds_theme: jit.Theme = @import("ds_theme");
const merged_theme: jit.Theme = jit.extendTheme(default_theme, ds_theme);

/// Extract every class token from `class="…"` AND `data-p-class="…"`
/// attributes in the HTML. Caller owns the returned slice; deduplicated via
/// the passed-in set.
///
/// `data-p-class` carries reactive class bindings (`state -> a b; …`) whose
/// utility tokens may never appear in a static `class="…"` — the JIT must
/// still emit rules for them or a toggled class has no CSS. The value is
/// rendered HTML, so its arrow is escaped as `-&gt;`.
pub fn extractClasses(
    allocator: std.mem.Allocator,
    html: []const u8,
    out: *std.StringHashMapUnmanaged(void),
) !void {
    // `class="…"` (but NOT `data-p-class="…"` — that has its own binding
    // grammar handled below). The leading char guard rejects the latter.
    var i: usize = 0;
    while (i < html.len) {
        const idx = std.mem.indexOfPos(u8, html, i, "class=\"") orelse break;
        // Skip when this is the tail of `data-p-class="` (or any `*-class=`).
        if (idx > 0 and html[idx - 1] == '-') {
            i = idx + "class=\"".len;
            continue;
        }
        const value_start = idx + "class=\"".len;
        const end_rel = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse break;
        try addTokens(allocator, out, html[value_start..end_rel]);
        i = end_rel + 1;
    }

    // `data-p-class="state -&gt; a b; state2 -&gt; c d"` — harvest the RHS
    // class tokens of each group, splitting on the escaped arrow.
    i = 0;
    while (i < html.len) {
        const idx = std.mem.indexOfPos(u8, html, i, "data-p-class=\"") orelse break;
        const value_start = idx + "data-p-class=\"".len;
        const end_rel = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse break;
        const value = html[value_start..end_rel];
        const arrow: []const u8 = if (std.mem.indexOf(u8, value, "-&gt;") != null) "-&gt;" else "->";
        var segs = std.mem.splitSequence(u8, value, arrow);
        _ = segs.next(); // leading state ref before the first arrow
        while (segs.next()) |seg| {
            const classes = if (std.mem.indexOfScalar(u8, seg, ';')) |semi| seg[0..semi] else seg;
            try addTokens(allocator, out, classes);
        }
        i = end_rel + 1;
    }
}

/// Tokenize a class string into `out` (deduped, duped). Splits on whitespace
/// AND '+' (the `data-p-class` group wire format, `a+b`) — but NEVER inside
/// `[...]`, so bracketed arbitrary values keep their internal '+'/spaces
/// (e.g. `w-[calc(100%+1rem)]` stays one token).
fn addTokens(
    allocator: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged(void),
    value: []const u8,
) !void {
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '[' => depth += 1,
            ']' => {
                if (depth > 0) depth -= 1;
            },
            ' ', '\t', '\r', '\n', '+' => {
                if (depth == 0) {
                    if (i > start) try addOneToken(allocator, out, value[start..i]);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    if (value.len > start) try addOneToken(allocator, out, value[start..value.len]);
}

fn addOneToken(
    allocator: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged(void),
    tok: []const u8,
) !void {
    const gop = try out.getOrPut(allocator, tok);
    if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, tok);
}

/// One-shot: extract classes from `html`, compile against the merged
/// theme, return the resulting `@layer utilities { … }` bytes. Caller
/// owns the slice.
pub fn compileFromHtml(
    allocator: std.mem.Allocator,
    html: []const u8,
) ![]u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
    }
    try extractClasses(allocator, html, &seen);

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var it = seen.keyIterator();
    while (it.next()) |k| try list.append(allocator, k.*);

    return try jit.compile(allocator, merged_theme, list.items, .{});
}

const testing = std.testing;

test "extractClasses: pulls tokens out of class=\"…\" attributes" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    const html = "<div class=\"flex items-center gap-2\"><span class=\"text-sm\">hi</span></div>";
    try extractClasses(testing.allocator, html, &seen);
    try testing.expect(seen.contains("flex"));
    try testing.expect(seen.contains("items-center"));
    try testing.expect(seen.contains("gap-2"));
    try testing.expect(seen.contains("text-sm"));
    try testing.expectEqual(@as(u32, 4), seen.count());
}

test "extractClasses: harvests reactive tokens from data-p-class (escaped arrow)" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    // Rendered HTML: compact arrow escaped to `-&gt;`, groups by ';', classes
    // within a group joined by '+' (the transpiler wire format).
    const html = "<div data-p-class=\"vivid-&gt;bg-fuchsia-500+text-yellow-200;outlined-&gt;ring-4+ring-emerald-400\" class=\"base p-8\">x</div>";
    try extractClasses(testing.allocator, html, &seen);
    // RHS class tokens from both groups are picked up…
    try testing.expect(seen.contains("bg-fuchsia-500"));
    try testing.expect(seen.contains("text-yellow-200"));
    try testing.expect(seen.contains("ring-4"));
    try testing.expect(seen.contains("ring-emerald-400"));
    // …the static class="…" is still scanned…
    try testing.expect(seen.contains("base"));
    try testing.expect(seen.contains("p-8"));
    // …and the state refs (LHS) are NOT treated as classes.
    try testing.expect(!seen.contains("vivid"));
    try testing.expect(!seen.contains("outlined"));
}

test "extractClasses: '+' split is bracket-aware (arbitrary values survive)" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    // A '+' INSIDE brackets must not split; a '+' between classes must.
    const html = "<div data-p-class=\"on-&gt;w-[calc(100%+1rem)]+text-red-500\" class=\"grid-cols-[repeat(2,1fr)]\">x</div>";
    try extractClasses(testing.allocator, html, &seen);
    try testing.expect(seen.contains("w-[calc(100%+1rem)]")); // internal '+' preserved
    try testing.expect(seen.contains("text-red-500")); // group '+' split
    try testing.expect(seen.contains("grid-cols-[repeat(2,1fr)]")); // static class intact
}

test "extractClasses: deduplicates across attributes" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    const html = "<a class=\"px-4 py-2\"></a><b class=\"px-4 text-bold\"></b>";
    try extractClasses(testing.allocator, html, &seen);
    try testing.expectEqual(@as(u32, 3), seen.count());
}
