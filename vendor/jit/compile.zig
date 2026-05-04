/// Compile pipeline — wires theme + parser + utility table + variant table
/// into a single CSS string output.
///
/// Public API: `compile(allocator, comptime theme, classes) -> ![]u8`.
///
/// Output structure (Phase 1):
///
///   :root {
///     --token: value;
///     ...
///   }
///   @layer utilities {
///     .escaped\\:class { property: value; ... }
///     ...
///   }
///
/// At-rule wrapping (e.g., `@media`, `@supports`) wraps individual utility
/// rules — not the whole `@layer` — to preserve cascade behavior.
///
/// Sort: classes are sorted via `sort.sortClasses` before emission so the
/// output order is deterministic and cascade-correct.
///
/// Modifier semantics (e.g. `bg-red-500/50` opacity): not yet wired. Color
/// utilities are out of task-05's Phase-1 scope; opacity-via-color-mix lands
/// when colors are ported.

const std = @import("std");
const candidate = @import("candidate.zig");
const theme = @import("theme.zig");
const utilities = @import("utilities.zig");
const variants = @import("variants.zig");
const sort = @import("sort.zig");

pub const CompileError = error{
    OutOfMemory,
    /// Raised when input contains a Tailwind directive Publr JIT does not
    /// support (`@apply`, `@import`, `@source`, `@utility`, `@variant`,
    /// `@custom-variant`). Callers that parse user CSS should pair this with
    /// `unsupportedFeatureMessage(directive)` for a migration-friendly
    /// diagnostic. `compile()` itself takes pre-tokenized class strings and
    /// has no path to raise it today; the variant exists so future user-CSS
    /// entry points (loaders, plugin hosts) error consistently. See
    /// `.claude/plans/jit-tailwind-engine/epic.md` "Not in scope".
    UnsupportedFeature,
};

/// Migration message for an unsupported Tailwind directive. Returns a stable,
/// user-facing string keyed on the directive name (with or without the leading
/// `@`). Returns `null` for unknown names — caller is responsible for falling
/// back to a generic message.
pub fn unsupportedFeatureMessage(directive: []const u8) ?[]const u8 {
    const name = if (directive.len > 0 and directive[0] == '@') directive[1..] else directive;
    if (std.mem.eql(u8, name, "apply")) return msg_apply;
    if (std.mem.eql(u8, name, "import")) return msg_import;
    if (std.mem.eql(u8, name, "source")) return msg_source;
    if (std.mem.eql(u8, name, "utility")) return msg_utility;
    if (std.mem.eql(u8, name, "variant")) return msg_variant;
    if (std.mem.eql(u8, name, "custom-variant")) return msg_custom_variant;
    return null;
}

const msg_apply =
    "Publr JIT does not support @apply. Migration: rewrite the rule to " ++
    "apply utility classes directly in HTML, or define the equivalent CSS by hand.";
const msg_import =
    "Publr JIT does not support @import. Migration: inline the imported CSS, " ++
    "or compose stylesheets at the build/serve layer outside the JIT.";
const msg_source =
    "Publr JIT does not support @source. Migration: class strings are collected " ++
    "from ZSX/.publr templates at build time — no file scanner is invoked. " ++
    "Remove the directive; the JIT will pick up classes via the transpiler manifest.";
const msg_utility =
    "Publr JIT does not support @utility. Migration: add the utility to " ++
    "jit/src/utilities.zig (comptime table) and rebuild — runtime utility " ++
    "registration is intentionally out of scope.";
const msg_variant =
    "Publr JIT does not support @variant. Migration: add the variant to " ++
    "jit/src/variants.zig (comptime table) and rebuild — runtime variant " ++
    "registration is intentionally out of scope.";
const msg_custom_variant =
    "Publr JIT does not support @custom-variant. Migration: add the variant to " ++
    "jit/src/variants.zig (comptime table) and rebuild — runtime variant " ++
    "registration is intentionally out of scope.";

/// Output options for `compile()`. Defaults preserve the readable, indented
/// form library callers/tests expect; the CLI flips `minify` on for production
/// builds. Whitespace-only minification: declarations are kept one-per-line in
/// the source emit order, but indents and the spaces around `:`/`{` are dropped
/// and trailing newlines are squeezed. Color shortening, numeric trimming, and
/// shorthand merging are out of scope — see the discussion in
/// `memory/project_jit_minify_scope.md`.
pub const Options = struct {
    minify: bool = false,
};

/// Compile a list of class strings into a CSS document.
/// `theme` is comptime; user themes typically come from `extendTheme(default, user)`.
///
/// Theme tree-shaking: only theme tokens actually referenced by the emitted
/// utility rules (or transitively referenced by other emitted tokens) appear
/// in the `:root { ... }` block. Building 413 default tokens for a single
/// `flex` class is wasteful — we emit only what's used.
pub fn compile(
    allocator: std.mem.Allocator,
    t: theme.Theme,
    classes: []const []const u8,
    options: Options,
) CompileError![]u8 {
    const nl: []const u8 = if (options.minify) "" else "\n";
    const sp: []const u8 = if (options.minify) "" else " ";
    const ind2: []const u8 = if (options.minify) "" else "  ";
    // 1. Sort classes (cascade-correct ordering).
    const joined = try joinClasses(allocator, classes);
    defer allocator.free(joined);
    const sorted = sort.sortClasses(allocator, joined, "") catch |err| switch (err) {
        sort.SortError.OutOfMemory => return CompileError.OutOfMemory,
        sort.SortError.NotImplemented => return CompileError.UnsupportedFeature,
    };
    defer allocator.free(sorted);

    // 2. Emit utility rules into a buffer. We emit them first (without :root)
    //    so we can scan the buffer for `var(--token)` references and tree-shake
    //    the theme to only what's actually used.
    var utility_block = std.array_list.Managed(u8).init(allocator);
    defer utility_block.deinit();

    try utility_block.print("@layer utilities{s}{{{s}", .{ sp, nl });
    var class_iter = std.mem.tokenizeAny(u8, sorted, " ");
    while (class_iter.next()) |class_name| {
        try emitClassRule(allocator, t, class_name, &utility_block, options);
    }
    try utility_block.print("}}{s}", .{nl});

    // 3. Tree-shake the theme: collect var(--*) references in utility output,
    //    then transitively expand to include any theme tokens those tokens
    //    reference (e.g., `--default-font-family` includes `--font-sans`).
    var used_tokens = std.StringHashMap(void).init(allocator);
    defer used_tokens.deinit();
    try collectVarRefs(utility_block.items, &used_tokens);

    var changed = true;
    while (changed) {
        changed = false;
        for (t.tokens) |tok| {
            if (used_tokens.contains(tok.name)) {
                var iter = VarRefIterator{ .input = tok.value, .pos = 0 };
                while (iter.next()) |name| {
                    const result = try used_tokens.getOrPut(name);
                    if (!result.found_existing) changed = true;
                }
            }
        }
    }

    // 4. Emit final document: :root { only-used tokens } + utility block.
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    if (used_tokens.count() > 0) {
        try out.print(":root{s}{{{s}", .{ sp, nl });
        for (t.tokens) |tok| {
            if (used_tokens.contains(tok.name)) {
                try out.print("{s}--{s}:{s}{s};{s}", .{ ind2, tok.name, sp, tok.value, nl });
            }
        }
        try out.print("}}{s}", .{nl});
    }
    try out.appendSlice(utility_block.items);

    return out.toOwnedSlice();
}

/// Iterator over `var(--name)` references in a CSS string.
const VarRefIterator = struct {
    input: []const u8,
    pos: usize,

    fn next(self: *VarRefIterator) ?[]const u8 {
        while (self.pos < self.input.len) {
            const start = std.mem.indexOfPos(u8, self.input, self.pos, "var(--") orelse {
                self.pos = self.input.len;
                return null;
            };
            const name_start = start + "var(--".len;
            // Token name ends at the first non-ident char (`,`, `)`, ` `, etc.).
            var i = name_start;
            while (i < self.input.len) : (i += 1) {
                const c = self.input[i];
                const is_ident = (c >= 'a' and c <= 'z') or
                    (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or
                    c == '-' or c == '_';
                if (!is_ident) break;
            }
            self.pos = i;
            if (i > name_start) return self.input[name_start..i];
        }
        return null;
    }
};

fn collectVarRefs(input: []const u8, set: *std.StringHashMap(void)) !void {
    var iter = VarRefIterator{ .input = input, .pos = 0 };
    while (iter.next()) |name| {
        _ = try set.getOrPut(name);
    }
}

fn joinClasses(allocator: std.mem.Allocator, classes: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (classes) |c| total += c.len;
    if (classes.len > 1) total += classes.len - 1;
    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (classes, 0..) |c, i| {
        if (i > 0) {
            out[pos] = ' ';
            pos += 1;
        }
        @memcpy(out[pos .. pos + c.len], c);
        pos += c.len;
    }
    return out;
}

fn emitClassRule(
    allocator: std.mem.Allocator,
    t: theme.Theme,
    class_name: []const u8,
    out: *std.array_list.Managed(u8),
    options: Options,
) CompileError!void {
    const nl: []const u8 = if (options.minify) "" else "\n";
    const sp: []const u8 = if (options.minify) "" else " ";
    const ind2: []const u8 = if (options.minify) "" else "  ";
    const ind4: []const u8 = if (options.minify) "" else "    ";
    const cands = candidate.parseCandidate(allocator, class_name) catch |err| switch (err) {
        error.OutOfMemory => return CompileError.OutOfMemory,
    };
    defer candidate.freeCandidates(allocator, cands);

    // Iterate yielded interpretations; pick the first that resolves via the
    // new utilities.zig table (architecturally clean path).
    for (cands) |c| {
        const resolved = utilities.resolveCandidate(allocator, t, c) catch |err| switch (err) {
            error.OutOfMemory => return CompileError.OutOfMemory,
        };
        if (resolved == null) continue;
        defer utilities.freeResolvedUtility(allocator, resolved.?);

        // Marker classes (e.g. `peer`, `group`) resolve successfully but
        // emit no declarations. They exist to be referenced by compound
        // variants (`peer-*`, `group-*`) on sibling/ancestor elements.
        // Skip rule emission so we don't produce empty `.peer { }` blocks.
        if (resolved.?.declarations.len == 0) return;

        // Wrap with variants.
        const cand_variants = switch (c) {
            .static_c => |s| s.variants,
            .functional => |f| f.variants,
            .arbitrary => |a| a.variants,
        };
        const wrapped = variants.applyVariants(allocator, t, cand_variants, class_name) catch |err| switch (err) {
            error.OutOfMemory => return CompileError.OutOfMemory,
            error.UnknownVariant => return, // skip silently — unsupported variant
        };
        defer variants.freeWrappedRule(allocator, wrapped);

        // Emit at-rule open wrappers.
        for (wrapped.at_rules) |ar| {
            try out.print("{s}@{s} {s}{s}{{{s}", .{ ind2, ar.name, ar.condition, sp, nl });
        }

        // Emit the rule. If the utility carries a selector_suffix
        // (e.g. ` > :not(:last-child)` for `space-x-N`), append it before
        // opening the declaration block.
        try out.appendSlice(ind2);
        try out.appendSlice(wrapped.selector);
        if (resolved.?.selector_suffix) |sfx| try out.appendSlice(sfx);
        try out.print("{s}{{{s}", .{ sp, nl });
        for (resolved.?.declarations) |d| {
            if (resolved.?.important) {
                try out.print("{s}{s}:{s}{s} !important;{s}", .{ ind4, d.property, sp, d.value, nl });
            } else {
                try out.print("{s}{s}:{s}{s};{s}", .{ ind4, d.property, sp, d.value, nl });
            }
        }
        try out.print("{s}}}{s}", .{ ind2, nl });

        // Emit at-rule close wrappers.
        for (wrapped.at_rules) |_| {
            try out.print("{s}}}{s}", .{ ind2, nl });
        }

        return; // first resolved wins
    }

    // No interpretation matched. Class is silently skipped — same behavior
    // as truly unknown utility names. Callers wanting strict-mode "unknown
    // class" diagnostics can detect by diffing input class set vs emitted
    // selectors; out of scope here.
}

// ── Tests ───────────────────────────────────────────────────────────────────

const tst = std.testing;

const test_theme = theme.Theme{ .tokens = &.{
    .{ .name = "spacing", .value = "0.25rem" },
    .{ .name = "color-red-500", .value = "oklch(0.637 0.237 25.331)" },
    .{ .name = "breakpoint-md", .value = "48rem" },
    .{ .name = "font-sans", .value = "Switzer, system-ui, sans-serif" },
} };

test "compile: empty class list emits empty layer (no :root needed)" {
    const css = try compile(tst.allocator, test_theme, &.{}, .{});
    defer tst.allocator.free(css);
    // No utility rules → no var() refs → no :root block emitted (tree-shaking).
    try tst.expect(std.mem.indexOf(u8, css, ":root {") == null);
    try tst.expect(std.mem.indexOf(u8, css, "@layer utilities {") != null);
}

test "compile: theme tree-shaking — only referenced tokens emitted" {
    // size-12 references --spacing; nothing else referenced.
    const css = try compile(tst.allocator, test_theme, &.{"size-12"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "--spacing: 0.25rem") != null);
    // Other test_theme tokens (--color-red-500, --font-sans, --breakpoint-md)
    // should NOT be emitted because nothing references them.
    try tst.expect(std.mem.indexOf(u8, css, "--color-red-500") == null);
    try tst.expect(std.mem.indexOf(u8, css, "--font-sans") == null);
}

test "compile: breakpoint @media uses literal value (var() is illegal there)" {
    // CSS forbids `var()` in @media feature value position, so breakpoint
    // variants substitute the literal theme value at emit time. As a side
    // effect the breakpoint token isn't reached by tree-shaking via @media
    // refs — it only appears in :root if some utility uses it via `var()`.
    const css = try compile(tst.allocator, test_theme, &.{"md:flex"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "@media (min-width: 48rem) {") != null);
    try tst.expect(std.mem.indexOf(u8, css, "@media (min-width: var(") == null);
    try tst.expect(std.mem.indexOf(u8, css, "--color-red-500") == null);
}

test "compile: single static utility" {
    const css = try compile(tst.allocator, test_theme, &.{"flex"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, ".flex {") != null);
    try tst.expect(std.mem.indexOf(u8, css, "display: flex;") != null);
}

test "compile: functional utility (size-N)" {
    const css = try compile(tst.allocator, test_theme, &.{"size-12"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, ".size-12 {") != null);
    try tst.expect(std.mem.indexOf(u8, css, "width: calc(var(--spacing) * 12);") != null);
    try tst.expect(std.mem.indexOf(u8, css, "height: calc(var(--spacing) * 12);") != null);
}

test "compile: hover variant wraps selector" {
    const css = try compile(tst.allocator, test_theme, &.{"hover:flex"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, ".hover\\:flex:hover {") != null);
    try tst.expect(std.mem.indexOf(u8, css, "display: flex;") != null);
}

test "compile: breakpoint variant wraps in @media" {
    const css = try compile(tst.allocator, test_theme, &.{"md:flex"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "@media (min-width: 48rem) {") != null);
    try tst.expect(std.mem.indexOf(u8, css, ".md\\:flex {") != null);
}

test "compile: sort order — inset-2 before flex (bucket 13 < 20)" {
    const css = try compile(tst.allocator, test_theme, &.{ "flex", "inset-2" }, .{});
    defer tst.allocator.free(css);
    const inset_idx = std.mem.indexOf(u8, css, ".inset-2 {").?;
    const flex_idx = std.mem.indexOf(u8, css, ".flex {").?;
    try tst.expect(inset_idx < flex_idx);
}

test "compile: unknown class is skipped silently" {
    const css = try compile(tst.allocator, test_theme, &.{ "totally-made-up", "flex" }, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "totally-made-up") == null);
    try tst.expect(std.mem.indexOf(u8, css, ".flex {") != null);
}

test "compile: color tree-shaking emits only used color tokens" {
    // bg-red-500 + text-gray-950 — :root should contain those two color tokens
    // (gray-950 isn't in test_theme; we use the colors that are).
    const css = try compile(tst.allocator, test_theme, &.{"bg-red-500"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "--color-red-500: oklch(0.637 0.237 25.331)") != null);
    // The full palette is NOT in test_theme so this check is implicitly true,
    // but we verify nothing else from the test theme leaked in:
    try tst.expect(std.mem.indexOf(u8, css, "--font-sans") == null);
    try tst.expect(std.mem.indexOf(u8, css, "--breakpoint-md") == null);
    try tst.expect(std.mem.indexOf(u8, css, "--spacing") == null);
}

test "compile: bg-red-500/50 emits color-mix() in :root + utility" {
    const css = try compile(tst.allocator, test_theme, &.{"bg-red-500/50"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "--color-red-500") != null);
    try tst.expect(std.mem.indexOf(u8, css, "color-mix(in srgb, var(--color-red-500) 50%, transparent)") != null);
}

test "compile: !important emits `!important` after value (trailing form)" {
    const css = try compile(tst.allocator, test_theme, &.{"size-12!"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "width: calc(var(--spacing) * 12) !important;") != null);
    try tst.expect(std.mem.indexOf(u8, css, "height: calc(var(--spacing) * 12) !important;") != null);
}

test "compile: !important on multi-decl utility marks all" {
    const css = try compile(tst.allocator, test_theme, &.{"truncate!"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, "overflow: hidden !important;") != null);
    try tst.expect(std.mem.indexOf(u8, css, "text-overflow: ellipsis !important;") != null);
    try tst.expect(std.mem.indexOf(u8, css, "white-space: nowrap !important;") != null);
}

test "compile: peer / group marker classes emit no rule" {
    const css = try compile(tst.allocator, test_theme, &.{ "peer", "group", "flex" }, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, ".peer ") == null);
    try tst.expect(std.mem.indexOf(u8, css, ".group ") == null);
    // `flex` still emits.
    try tst.expect(std.mem.indexOf(u8, css, ".flex {") != null);
}

test "compile: space-x-N appends selector_suffix" {
    const css = try compile(tst.allocator, test_theme, &.{"space-x-4"}, .{});
    defer tst.allocator.free(css);
    try tst.expect(std.mem.indexOf(u8, css, ".space-x-4 > :not(:last-child) {") != null);
    try tst.expect(std.mem.indexOf(u8, css, "margin-right: calc(var(--spacing) * 4);") != null);
}

test "unsupportedFeatureMessage covers every documented directive" {
    for ([_][]const u8{ "apply", "import", "source", "utility", "variant", "custom-variant" }) |d| {
        try tst.expect(unsupportedFeatureMessage(d) != null);
        // Same lookup with leading `@` resolves to the same message.
        var with_at_buf: [32]u8 = undefined;
        with_at_buf[0] = '@';
        @memcpy(with_at_buf[1 .. 1 + d.len], d);
        try tst.expectEqualStrings(
            unsupportedFeatureMessage(d).?,
            unsupportedFeatureMessage(with_at_buf[0 .. 1 + d.len]).?,
        );
    }
    try tst.expect(unsupportedFeatureMessage("nonsense") == null);
}
