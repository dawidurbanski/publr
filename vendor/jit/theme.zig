/// Theme — Publr JIT's comptime theme model.
///
/// Decision (locked 2026-05-02): theme is comptime-only. `theme.zon` imports
/// at comptime, no runtime override layer ever. See:
///   - .claude/plans/jit-tailwind-engine/epic.md (Theme model section)
///   - memory/project_jit_theme_comptime.md
///
/// Schema choice: flat `[]const Token` mirroring CSS custom properties 1:1.
///   - Trivial to author + diff in ZON.
///   - Trivial to merge (override matching `name`, append new).
///   - Trivial to emit (`:root { --name: value; ... }`).
///   - Order in ZON = order in `:root` output, so both sides are deterministic.
///
/// Lookups are O(n) over the array. With ~400 default + ~tens of user tokens
/// the array is small enough that this is fine. Future optimization: build a
/// comptime hash map from the array at JIT build time if profiling shows
/// lookups dominate.

const std = @import("std");

pub const Token = struct {
    /// CSS-custom-property name *without* the leading `--`.
    /// Examples: "spacing", "color-red-500", "breakpoint-md", "font-sans".
    name: []const u8,
    /// Raw CSS value (no leading/trailing whitespace).
    /// Examples: "0.25rem", "oklch(63.7% 0.237 25.331)", "Switzer, system-ui, sans-serif".
    value: []const u8,
};

pub const Theme = struct {
    tokens: []const Token,
};

/// Merge two themes at comptime. `override`'s tokens replace `base`'s tokens
/// whose `name` matches; `override`'s remaining tokens are appended in source
/// order. Result preserves the relative order of `base` tokens that survive.
///
/// Must be called at comptime (both args comptime, both ZON-imported).
pub fn extendTheme(comptime base: Theme, comptime override: Theme) Theme {
    comptime {
        // ~419 default tokens × 419 = ~175k branch traversals just for the
        // base loop, plus the second pass — well over the default 1000 quota.
        // Generous quota: 5M handles base ~5000 × override ~1000.
        @setEvalBranchQuota(5_000_000);
        var merged: [base.tokens.len + override.tokens.len]Token = undefined;
        var len: usize = 0;

        // Walk base; for each token, look for an override with the same name.
        // If found, take the override's value; if not, take base's.
        for (base.tokens) |bt| {
            var replaced = false;
            for (override.tokens) |ot| {
                if (std.mem.eql(u8, bt.name, ot.name)) {
                    merged[len] = ot;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) merged[len] = bt;
            len += 1;
        }

        // Append override tokens that weren't matches against base.
        for (override.tokens) |ot| {
            var was_match = false;
            for (base.tokens) |bt| {
                if (std.mem.eql(u8, bt.name, ot.name)) {
                    was_match = true;
                    break;
                }
            }
            if (!was_match) {
                merged[len] = ot;
                len += 1;
            }
        }

        const final = merged[0..len].*;
        return Theme{ .tokens = &final };
    }
}

/// Runtime sibling of `extendTheme`. Same merge semantics — base tokens
/// preserve order; override values win for matching names; override-only
/// tokens append in source order. Caller owns the returned `tokens` slice
/// (the slice itself; the inner Token strings are borrowed from `base` /
/// `override` and live as long as those do).
///
/// Used by the CLI when `--theme=<path>` provides a user theme parsed at
/// runtime (`std.zon.parse.fromSlice`) — the comptime path can't run when
/// either side isn't comptime-known.
pub fn extendThemeRuntime(
    allocator: std.mem.Allocator,
    base: Theme,
    override: Theme,
) !Theme {
    var out: std.ArrayListUnmanaged(Token) = .{};
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, base.tokens.len + override.tokens.len);

    // Walk base; for each token, look for an override with the same name.
    for (base.tokens) |bt| {
        var replaced = false;
        for (override.tokens) |ot| {
            if (std.mem.eql(u8, bt.name, ot.name)) {
                out.appendAssumeCapacity(ot);
                replaced = true;
                break;
            }
        }
        if (!replaced) out.appendAssumeCapacity(bt);
    }

    // Append override tokens that weren't matches against base.
    for (override.tokens) |ot| {
        var was_match = false;
        for (base.tokens) |bt| {
            if (std.mem.eql(u8, bt.name, ot.name)) {
                was_match = true;
                break;
            }
        }
        if (!was_match) out.appendAssumeCapacity(ot);
    }

    return Theme{ .tokens = try out.toOwnedSlice(allocator) };
}

/// Look up a token by `name`. Returns the value, or null if absent.
/// Comptime-callable when called with comptime args; runtime-fine for
/// JIT-internal lookups during compile.
pub fn lookup(theme: Theme, name: []const u8) ?[]const u8 {
    for (theme.tokens) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.value;
    }
    return null;
}

/// Emit `:root { --token: value; ... }` for the merged theme.
/// Caller owns returned bytes. UTF-8, LF-terminated.
pub fn emitCssVariables(allocator: std.mem.Allocator, theme: Theme) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    const w = buf.writer();
    try w.writeAll(":root {\n");
    for (theme.tokens) |t| {
        try w.print("  --{s}: {s};\n", .{ t.name, t.value });
    }
    try w.writeAll("}\n");

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "extendTheme overrides matching tokens, appends new ones" {
    const base = Theme{ .tokens = &.{
        .{ .name = "spacing", .value = "0.25rem" },
        .{ .name = "font-sans", .value = "ui-sans-serif" },
        .{ .name = "color-red-500", .value = "oklch(0.637 ... old)" },
    } };
    const override = Theme{ .tokens = &.{
        .{ .name = "font-sans", .value = "Switzer, system-ui" },
        .{ .name = "radius-4xl", .value = "2rem" }, // new
    } };

    const merged = comptime extendTheme(base, override);

    // base order preserved for surviving tokens
    try std.testing.expectEqual(@as(usize, 4), merged.tokens.len);
    try std.testing.expectEqualStrings("spacing", merged.tokens[0].name);
    try std.testing.expectEqualStrings("0.25rem", merged.tokens[0].value);
    // override of font-sans took effect
    try std.testing.expectEqualStrings("font-sans", merged.tokens[1].name);
    try std.testing.expectEqualStrings("Switzer, system-ui", merged.tokens[1].value);
    // un-overridden token survives
    try std.testing.expectEqualStrings("color-red-500", merged.tokens[2].name);
    // new token appended
    try std.testing.expectEqualStrings("radius-4xl", merged.tokens[3].name);
    try std.testing.expectEqualStrings("2rem", merged.tokens[3].value);
}

test "extendTheme with empty override returns base unchanged" {
    const base = Theme{ .tokens = &.{
        .{ .name = "spacing", .value = "0.25rem" },
    } };
    const empty = Theme{ .tokens = &.{} };
    const merged = comptime extendTheme(base, empty);
    try std.testing.expectEqual(@as(usize, 1), merged.tokens.len);
    try std.testing.expectEqualStrings("spacing", merged.tokens[0].name);
}

test "extendTheme with empty base returns override" {
    const empty = Theme{ .tokens = &.{} };
    const override = Theme{ .tokens = &.{
        .{ .name = "font-sans", .value = "Switzer" },
    } };
    const merged = comptime extendTheme(empty, override);
    try std.testing.expectEqual(@as(usize, 1), merged.tokens.len);
    try std.testing.expectEqualStrings("Switzer", merged.tokens[0].value);
}

test "lookup finds existing tokens" {
    const theme = Theme{ .tokens = &.{
        .{ .name = "spacing", .value = "0.25rem" },
        .{ .name = "font-sans", .value = "Switzer" },
    } };
    try std.testing.expectEqualStrings("0.25rem", lookup(theme, "spacing").?);
    try std.testing.expectEqualStrings("Switzer", lookup(theme, "font-sans").?);
    try std.testing.expectEqual(@as(?[]const u8, null), lookup(theme, "missing"));
}

test "emitCssVariables produces deterministic :root block" {
    const theme = Theme{ .tokens = &.{
        .{ .name = "spacing", .value = "0.25rem" },
        .{ .name = "color-red-500", .value = "oklch(0.637 0.237 25.331)" },
        .{ .name = "font-sans", .value = "Switzer, system-ui, sans-serif" },
    } };
    const css = try emitCssVariables(std.testing.allocator, theme);
    defer std.testing.allocator.free(css);

    const expected =
        ":root {\n" ++
        "  --spacing: 0.25rem;\n" ++
        "  --color-red-500: oklch(0.637 0.237 25.331);\n" ++
        "  --font-sans: Switzer, system-ui, sans-serif;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, css);
}

test "emitCssVariables on empty theme produces empty block" {
    const empty = Theme{ .tokens = &.{} };
    const css = try emitCssVariables(std.testing.allocator, empty);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(":root {\n}\n", css);
}
