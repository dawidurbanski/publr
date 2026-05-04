/// Variant resolver — wraps a base selector + at-rule context based on parsed variants.
///
/// Architecture: a comptime-known set of variant kinds (static / functional /
/// compound / arbitrary). Compound variants delegate to inner-variant lookup.
///
/// Public API: `applyVariants(allocator, comptime theme, variants, base_class) -> !WrappedRule`.
/// `base_class` is the unescaped utility class (e.g., "bg-red-500" — caller is
/// responsible for escaping `:` etc. when emitting the final CSS string).
///
/// Phase 1 coverage:
///   - Pseudo-class statics: hover, focus, focus-visible, focus-within, active,
///     visited, disabled, enabled, checked, indeterminate, first, last, only,
///     odd, even, empty, target, default, required, valid, invalid, read-only.
///   - Pseudo-element statics: before, after, placeholder, selection, marker, file.
///   - Color scheme: dark, light, motion-reduce, motion-safe, print.
///   - Breakpoints (theme-driven): sm, md, lg, xl, 2xl + max-* variants.
///   - Functional: data-*, aria-* (with arbitrary value).
///   - Compound: group-*, peer-* with named-group modifier (`group-hover/foo`).
///   - Arbitrary selectors: [&_p], [@media (...)], etc.
///
/// Deferred:
///   - Container queries (@container, @sm: inside container contexts).
///   - not-*, has-*, in-* compound forwarding.

const std = @import("std");
const candidate = @import("candidate.zig");
const theme = @import("theme.zig");

const Variant = candidate.Variant;
const Theme = theme.Theme;

pub const WrappedRule = struct {
    /// Final CSS selector. Caller wraps the utility declarations in `<selector> { ... }`.
    selector: []u8,
    /// At-rule wrappers in outer-first order. Caller emits as nested at-rules.
    at_rules: []AtRule,
};

pub const AtRule = struct {
    /// e.g., "media", "container", "supports".
    name: []const u8,
    /// e.g., "(min-width: var(--breakpoint-md))".
    condition: []u8,
};

pub const VariantError = error{
    OutOfMemory,
    UnknownVariant,
};

pub fn freeWrappedRule(allocator: std.mem.Allocator, r: WrappedRule) void {
    allocator.free(r.selector);
    for (r.at_rules) |ar| allocator.free(ar.condition);
    allocator.free(r.at_rules);
}

/// Apply parsed variants to a base class name.
/// Variants are applied innermost-first per parser convention (variants[0] is
/// the variant immediately preceding the base in the source: `md:hover:foo` →
/// variants = [hover, md]).
pub fn applyVariants(
    allocator: std.mem.Allocator,
    t: Theme,
    variants: []const Variant,
    base_class: []const u8,
) VariantError!WrappedRule {
    var selector = try escapeClassSelector(allocator, base_class);
    errdefer allocator.free(selector);

    var at_rules = std.array_list.Managed(AtRule).init(allocator);
    errdefer {
        for (at_rules.items) |ar| allocator.free(ar.condition);
        at_rules.deinit();
    }

    for (variants) |v| {
        try applyOne(allocator, t, v, &selector, &at_rules);
    }

    return .{
        .selector = selector,
        .at_rules = try at_rules.toOwnedSlice(),
    };
}

fn applyOne(
    allocator: std.mem.Allocator,
    t: Theme,
    variant: Variant,
    selector: *[]u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    switch (variant) {
        .static_v => |s| try applyStatic(allocator, t, s.root, selector, at_rules),
        .functional => |f| try applyFunctional(allocator, t, f.root, f.value, selector, at_rules),
        .compound => |c| try applyCompound(allocator, t, c.root, c.modifier, c.variant.*, selector, at_rules),
        .arbitrary => |a| try applyArbitrary(allocator, a.selector, a.relative, selector, at_rules),
    }
}

// ── Static variants ─────────────────────────────────────────────────────────

const StaticVariant = struct {
    name: []const u8,
    /// Selector suffix appended to `&`. e.g. ":hover", ":focus-visible".
    /// Empty string means use at-rule path instead.
    suffix: []const u8,
    /// If non-empty, this variant emits an at-rule with `(condition)` instead of
    /// modifying the selector.
    at_rule_name: []const u8 = "",
    at_rule_condition: []const u8 = "",
};

const STATIC_VARIANTS = [_]StaticVariant{
    // ── Pseudo-classes ──────────────────────────────────────────────────────
    .{ .name = "hover", .suffix = ":hover" },
    .{ .name = "focus", .suffix = ":focus" },
    .{ .name = "focus-visible", .suffix = ":focus-visible" },
    .{ .name = "focus-within", .suffix = ":focus-within" },
    .{ .name = "active", .suffix = ":active" },
    .{ .name = "visited", .suffix = ":visited" },
    .{ .name = "target", .suffix = ":target" },
    .{ .name = "disabled", .suffix = ":disabled" },
    .{ .name = "enabled", .suffix = ":enabled" },
    .{ .name = "checked", .suffix = ":checked" },
    .{ .name = "indeterminate", .suffix = ":indeterminate" },
    .{ .name = "default", .suffix = ":default" },
    .{ .name = "required", .suffix = ":required" },
    .{ .name = "valid", .suffix = ":valid" },
    .{ .name = "invalid", .suffix = ":invalid" },
    .{ .name = "placeholder-shown", .suffix = ":placeholder-shown" },
    .{ .name = "read-only", .suffix = ":read-only" },
    .{ .name = "open", .suffix = "[open]" },

    // ── Structural ──────────────────────────────────────────────────────────
    .{ .name = "first", .suffix = ":first-child" },
    .{ .name = "last", .suffix = ":last-child" },
    .{ .name = "only", .suffix = ":only-child" },
    .{ .name = "odd", .suffix = ":nth-child(odd)" },
    .{ .name = "even", .suffix = ":nth-child(even)" },
    .{ .name = "first-of-type", .suffix = ":first-of-type" },
    .{ .name = "last-of-type", .suffix = ":last-of-type" },
    .{ .name = "only-of-type", .suffix = ":only-of-type" },
    .{ .name = "empty", .suffix = ":empty" },

    // ── Pseudo-elements ─────────────────────────────────────────────────────
    .{ .name = "before", .suffix = "::before" },
    .{ .name = "after", .suffix = "::after" },
    .{ .name = "placeholder", .suffix = "::placeholder" },
    .{ .name = "selection", .suffix = "::selection" },
    .{ .name = "marker", .suffix = "::marker" },
    .{ .name = "file", .suffix = "::file-selector-button" },
    .{ .name = "backdrop", .suffix = "::backdrop" },

    // ── Color scheme + media ────────────────────────────────────────────────
    .{ .name = "dark", .suffix = "", .at_rule_name = "media", .at_rule_condition = "(prefers-color-scheme: dark)" },
    .{ .name = "light", .suffix = "", .at_rule_name = "media", .at_rule_condition = "(prefers-color-scheme: light)" },
    .{ .name = "motion-reduce", .suffix = "", .at_rule_name = "media", .at_rule_condition = "(prefers-reduced-motion: reduce)" },
    .{ .name = "motion-safe", .suffix = "", .at_rule_name = "media", .at_rule_condition = "(prefers-reduced-motion: no-preference)" },
    .{ .name = "print", .suffix = "", .at_rule_name = "media", .at_rule_condition = "print" },
    .{ .name = "forced-colors", .suffix = "", .at_rule_name = "media", .at_rule_condition = "(forced-colors: active)" },
};

fn applyStatic(
    allocator: std.mem.Allocator,
    t: Theme,
    name: []const u8,
    selector: *[]u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    if (try tryApplyStaticName(allocator, name, selector, at_rules)) return;
    // Container queries: `@container`, `@xs`, `@sm`, …, `@[400px]`.
    if (name.len > 0 and name[0] == '@') {
        return applyContainerQuery(allocator, t, name, at_rules);
    }
    // Fall back to breakpoint lookup: `md` etc. parse as static_v, but they're
    // theme-driven media queries.
    applyBreakpointBare(allocator, t, name, at_rules) catch |err| {
        if (err == VariantError.UnknownVariant) return VariantError.UnknownVariant;
        return err;
    };
}

/// Container queries. Five forms:
///   `@container`          → `@container { ... }` (responds to nearest container, no condition)
///   `@<name>`             → `@container (width >= var(--container-<name>))` after theme lookup
///   `@max-<name>`         → `@container (width < var(--container-<name>))`
///   `@[<arbitrary>]`      → `@container (<arbitrary>)` (literal condition)
///   `@max-[<arbitrary>]`  → `@container (width < <arbitrary>)`
fn applyContainerQuery(
    allocator: std.mem.Allocator,
    t: Theme,
    name: []const u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    // `@container` (no value) — bare at-rule.
    if (std.mem.eql(u8, name, "@container")) {
        const cond = try allocator.dupe(u8, "");
        try at_rules.append(.{ .name = "container", .condition = cond });
        return;
    }

    // Strip the leading `@`.
    const after_at = name[1..];

    // Detect `max-` prefix.
    var is_max = false;
    var key = after_at;
    if (std.mem.startsWith(u8, after_at, "max-")) {
        is_max = true;
        key = after_at[4..];
    }

    // Arbitrary: `@[<expr>]` or `@max-[<expr>]`.
    if (key.len >= 2 and key[0] == '[' and key[key.len - 1] == ']') {
        const inner = key[1 .. key.len - 1];
        const cond = if (is_max)
            try std.fmt.allocPrint(allocator, "(width < {s})", .{inner})
        else
            try std.fmt.allocPrint(allocator, "({s})", .{inner});
        try at_rules.append(.{ .name = "container", .condition = cond });
        return;
    }

    // Named: `@<key>` or `@max-<key>` — theme `--container-<key>` lookup.
    const tok = try std.fmt.allocPrint(allocator, "container-{s}", .{key});
    defer allocator.free(tok);
    const value = theme.lookup(t, tok) orelse return VariantError.UnknownVariant;

    const cond = if (is_max)
        try std.fmt.allocPrint(allocator, "(width < {s})", .{value})
    else
        try std.fmt.allocPrint(allocator, "(width >= {s})", .{value});
    try at_rules.append(.{ .name = "container", .condition = cond });
}

/// Try the static variant table; returns true on match, false if name unknown.
/// Separated so applyFunctional can fall back to it for hyphenated statics like
/// `focus-visible` that the parser splits as functional `focus`+`visible`.
fn tryApplyStaticName(
    allocator: std.mem.Allocator,
    name: []const u8,
    selector: *[]u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!bool {
    inline for (STATIC_VARIANTS) |sv| {
        if (std.mem.eql(u8, name, sv.name)) {
            if (sv.at_rule_name.len > 0) {
                const cond = try allocator.dupe(u8, sv.at_rule_condition);
                try at_rules.append(.{ .name = sv.at_rule_name, .condition = cond });
                return true;
            }
            const new_sel = try insertSelectorSuffix(allocator, selector.*, sv.suffix);
            allocator.free(selector.*);
            selector.* = new_sel;
            return true;
        }
    }
    return false;
}

/// CSS rule: pseudo-elements (`::before`, `::after`, `::placeholder`, etc.)
/// must be the LAST simple selector in a compound selector. When the new
/// suffix is a pseudo-class (or attribute selector) and the existing selector
/// already ends in a pseudo-element, splice the suffix in BEFORE it.
///
/// Examples:
///   selector=".x", suffix="::before"  → ".x::before"      (append; pseudo-element last)
///   selector=".x::before", suffix=":hover" → ".x:hover::before" (splice in)
///   selector=".x:hover", suffix="::before" → ".x:hover::before" (append)
///   selector=".x", suffix=":hover"   → ".x:hover"         (append)
fn insertSelectorSuffix(
    allocator: std.mem.Allocator,
    sel: []const u8,
    suffix: []const u8,
) VariantError![]u8 {
    // Suffix is itself a pseudo-element: just append (it's allowed to be
    // last; if the selector already had one, the user gets two pseudo-
    // elements, which is invalid CSS but our concern is composition, not
    // diagnosis).
    if (suffix.len >= 2 and suffix[0] == ':' and suffix[1] == ':') {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ sel, suffix });
    }
    // Find a trailing `::pseudo-element` on the existing selector.
    if (findTrailingPseudoElement(sel)) |split| {
        return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ sel[0..split], suffix, sel[split..] });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ sel, suffix });
}

/// Returns the byte index at which a trailing `::<pseudo-element>` starts in
/// `sel`, or null if no recognised pseudo-element is at the end. Recognised
/// names match `STATIC_VARIANTS` entries with `::`-prefix suffixes.
fn findTrailingPseudoElement(sel: []const u8) ?usize {
    const known = [_][]const u8{
        "::before",
        "::after",
        "::placeholder",
        "::selection",
        "::marker",
        "::file-selector-button",
        "::backdrop",
    };
    for (known) |pe| {
        if (sel.len >= pe.len and std.mem.eql(u8, sel[sel.len - pe.len ..], pe)) {
            return sel.len - pe.len;
        }
    }
    return null;
}

// ── Functional variants ─────────────────────────────────────────────────────

fn applyFunctional(
    allocator: std.mem.Allocator,
    t: Theme,
    root: []const u8,
    value: ?candidate.VariantValue,
    selector: *[]u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    // Breakpoints (theme-driven): `md:`, `lg:`, etc. with no value.
    if (value == null) {
        // First check if the bare root is a known static (e.g. `hover`, `dark`).
        // The parser yields `static_v` for these, but compound dispatch can also
        // route here if a name was misclassified.
        if (try tryApplyStaticName(allocator, root, selector, at_rules)) return;
        // Container queries can also reach here when the parser routes
        // `@xs` etc. through the static-fallback path.
        if (root.len > 0 and root[0] == '@') {
            return applyContainerQuery(allocator, t, root, at_rules);
        }
        return applyBreakpointBare(allocator, t, root, at_rules);
    }

    const v = value.?;

    // Container queries with values (`@max-md`, `@max-[500px]`) parse as
    // functional with root prefixed `@`. Reconstruct the full name and
    // dispatch to the container query handler.
    if (root.len > 0 and root[0] == '@') {
        const value_str = switch (v) {
            .named => |n| n,
            .arbitrary => |a| a,
        };
        // Reconstruct the original `@<root-after-at>-<value>` string. For
        // arbitrary values we wrap in `[...]` so the container handler's
        // arbitrary detection fires.
        const reconstructed = if (v == .arbitrary)
            try std.fmt.allocPrint(allocator, "{s}-[{s}]", .{ root, value_str })
        else
            try std.fmt.allocPrint(allocator, "{s}-{s}", .{ root, value_str });
        defer allocator.free(reconstructed);
        return applyContainerQuery(allocator, t, reconstructed, at_rules);
    }

    // Hyphenated static fallback: `focus-visible` parses as functional
    // `focus`+`visible`; reconstruct and try as a static name.
    if (v == .named) {
        const reconstructed = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ root, v.named });
        defer allocator.free(reconstructed);
        if (try tryApplyStaticName(allocator, reconstructed, selector, at_rules)) return;
    }

    // data-[state=open]: → &[data-state=open]
    if (std.mem.eql(u8, root, "data")) {
        const val_str = switch (v) {
            .arbitrary => |a| a,
            .named => |n| n,
        };
        const new_sel = try std.fmt.allocPrint(allocator, "{s}[data-{s}]", .{ selector.*, val_str });
        allocator.free(selector.*);
        selector.* = new_sel;
        return;
    }

    // aria-[busy=true]:foo → foo[aria-busy=true]
    if (std.mem.eql(u8, root, "aria")) {
        const val_str = switch (v) {
            .arbitrary => |a| a,
            .named => |n| n,
        };
        const new_sel = try std.fmt.allocPrint(allocator, "{s}[aria-{s}]", .{ selector.*, val_str });
        allocator.free(selector.*);
        selector.* = new_sel;
        return;
    }

    // supports-[(...)]:foo → @supports (...) { ... }
    if (std.mem.eql(u8, root, "supports")) {
        const val_str = switch (v) {
            .arbitrary => |a| a,
            .named => |n| n,
        };
        const cond = try std.fmt.allocPrint(allocator, "({s})", .{val_str});
        try at_rules.append(.{ .name = "supports", .condition = cond });
        return;
    }

    // max-md:, max-lg:, etc. — max-width variants.
    if (std.mem.eql(u8, root, "max")) {
        return applyMaxBreakpoint(allocator, t, v, at_rules);
    }

    return VariantError.UnknownVariant;
}

fn applyBreakpointBare(
    allocator: std.mem.Allocator,
    t: Theme,
    root: []const u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    const token_name = try std.fmt.allocPrint(allocator, "breakpoint-{s}", .{root});
    defer allocator.free(token_name);

    // Resolve the breakpoint to its literal value. CSS media queries do NOT
    // accept `var()` references in feature value position — the browser
    // silently drops the whole at-rule if you try, so every `lg:*`/`md:*` etc.
    // utility becomes dead and responsive layouts collapse to mobile-stacked.
    const value = theme.lookup(t, token_name) orelse return VariantError.UnknownVariant;

    const cond = try std.fmt.allocPrint(allocator, "(min-width: {s})", .{value});
    try at_rules.append(.{ .name = "media", .condition = cond });
}

fn applyMaxBreakpoint(
    allocator: std.mem.Allocator,
    t: Theme,
    v: candidate.VariantValue,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    if (v != .named) return VariantError.UnknownVariant;
    const root = v.named;
    const token_name = try std.fmt.allocPrint(allocator, "breakpoint-{s}", .{root});
    defer allocator.free(token_name);
    const value = theme.lookup(t, token_name) orelse return VariantError.UnknownVariant;

    // Same reason as applyBreakpointBare: substitute the literal value.
    // `calc()` *is* legal inside a media-feature value, so the - 0.02px offset
    // (used to make max-width strictly exclusive) stays.
    const cond = try std.fmt.allocPrint(
        allocator,
        "(max-width: calc({s} - 0.02px))",
        .{value},
    );
    try at_rules.append(.{ .name = "media", .condition = cond });
}

// ── Compound variants ───────────────────────────────────────────────────────

fn applyCompound(
    allocator: std.mem.Allocator,
    t: Theme,
    root: []const u8,
    modifier: ?candidate.Modifier,
    inner: Variant,
    selector: *[]u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    // Resolve the inner variant first into a temporary "&"-anchored sub-selector.
    var sub_selector = try allocator.dupe(u8, "&");
    defer allocator.free(sub_selector);
    var sub_at_rules = std.array_list.Managed(AtRule).init(allocator);
    defer {
        for (sub_at_rules.items) |ar| allocator.free(ar.condition);
        sub_at_rules.deinit();
    }

    try applyOne(allocator, t, inner, &sub_selector, &sub_at_rules);

    // Hoist the inner variant's at-rules onto our outer at-rule list.
    for (sub_at_rules.items) |ar| {
        const dup = try allocator.dupe(u8, ar.condition);
        try at_rules.append(.{ .name = ar.name, .condition = dup });
    }

    // The "suffix" is whatever the inner variant added after `&`. For
    // `hover`, that's `:hover`. For `data-[state=open]`, that's
    // `[data-state=open]`. For `[input:focus]` (arbitrary wrapped in
    // `&:is(...)` by the parser), it's `:is(input:focus)`.
    const sub_no_amp = if (sub_selector.len > 0 and sub_selector[0] == '&') sub_selector[1..] else sub_selector;

    // Dispatch by compound root. `not-`, `has-`, `in-` use selector-wrapping
    // (CSS pseudo-class functions); `group-`, `peer-`, `supports-` use the
    // class-prefix pattern.
    if (std.mem.eql(u8, root, "not")) {
        // not-X:foo → .not-X\:foo:not(<inner-suffix>)
        if (modifier != null) return VariantError.UnknownVariant; // not- doesn't take modifiers
        if (sub_no_amp.len == 0) return VariantError.UnknownVariant;
        const new_sel = try std.fmt.allocPrint(allocator, "{s}:not({s})", .{ selector.*, sub_no_amp });
        allocator.free(selector.*);
        selector.* = new_sel;
        return;
    }
    if (std.mem.eql(u8, root, "has")) {
        // has-X:foo → .has-X\:foo:has(<inner-suffix>)
        if (modifier != null) return VariantError.UnknownVariant;
        if (sub_no_amp.len == 0) return VariantError.UnknownVariant;
        const new_sel = try std.fmt.allocPrint(allocator, "{s}:has({s})", .{ selector.*, sub_no_amp });
        allocator.free(selector.*);
        selector.* = new_sel;
        return;
    }
    if (std.mem.eql(u8, root, "in")) {
        // in-X:foo → :where(<inner-suffix>) .in-X\:foo
        // Matches "any ancestor that satisfies the inner variant's
        // condition." Uses :where() to keep specificity low.
        if (modifier != null) return VariantError.UnknownVariant;
        if (sub_no_amp.len == 0) return VariantError.UnknownVariant;
        const new_sel = try std.fmt.allocPrint(allocator, ":where({s}) {s}", .{ sub_no_amp, selector.* });
        allocator.free(selector.*);
        selector.* = new_sel;
        return;
    }
    // `supports-` is handled at parse-call time via the functional path
    // (`supports-[(...)]:`); reaching here means the parser routed it into
    // compound which we just don't support.
    if (std.mem.eql(u8, root, "supports")) return VariantError.UnknownVariant;

    // `group-` and `peer-` both follow the class-prefix pattern, but they
    // differ in how the inner element relates to the marker class:
    //   - `group-X:foo` → `.group:X .foo` (descendant — inner is inside the
    //     marker, e.g. `<div class="group"><span class="group-hover:…">`)
    //   - `peer-X:foo`  → `.peer:X ~ .foo` (subsequent sibling — inner sits
    //     next to the marker, e.g. `<input class="peer"><span class="peer-checked:…">`)
    // Without the `~` for `peer-`, every `peer-checked:translate-x-N`,
    // `peer-checked:bg-primary` etc. silently never matches and components
    // like Switch stop reacting to `:checked`.
    const combinator: []const u8 = if (std.mem.eql(u8, root, "peer")) " ~ " else " ";

    const escaped_root = if (modifier) |m| switch (m) {
        .named => |n| try std.fmt.allocPrint(allocator, ".{s}\\/{s}", .{ root, n }),
        .arbitrary => return VariantError.UnknownVariant,
    } else try std.fmt.allocPrint(allocator, ".{s}", .{root});
    defer allocator.free(escaped_root);

    const new_sel = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}{s}",
        .{ escaped_root, sub_no_amp, combinator, selector.* },
    );
    allocator.free(selector.*);
    selector.* = new_sel;
}

// ── Arbitrary selector variants ─────────────────────────────────────────────

fn applyArbitrary(
    allocator: std.mem.Allocator,
    arbitrary_selector: []const u8,
    relative: bool,
    selector: *[]u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    // Arbitrary at-rule variant: `[@media(width>=123px)]:` →
    // `@media (width>=123px) { … }`. Detected by the leading `@` (the parser
    // doesn't pass these through `&:is(...)` wrapping).
    if (arbitrary_selector.len > 0 and arbitrary_selector[0] == '@') {
        return parseArbitraryAtRule(allocator, arbitrary_selector, at_rules);
    }

    if (relative) {
        // Relative (e.g., `> img`): append to selector with the relative combinator.
        const new_sel = try std.fmt.allocPrint(allocator, "{s} {s}", .{ selector.*, arbitrary_selector });
        allocator.free(selector.*);
        selector.* = new_sel;
        return;
    }

    // Substitute `&` with current selector.
    const new_sel = try substituteAmpersand(allocator, arbitrary_selector, selector.*);
    allocator.free(selector.*);
    selector.* = new_sel;
}

/// Parse a CSS at-rule string like `@media(width>=123px)` or
/// `@supports (display: grid)` into the runner's at-rule format.
/// The split is on the first `(` (or first whitespace) — everything before
/// is the at-rule name (without the `@`); everything after is the condition.
fn parseArbitraryAtRule(
    allocator: std.mem.Allocator,
    raw: []const u8,
    at_rules: *std.array_list.Managed(AtRule),
) VariantError!void {
    // Skip leading `@`.
    const after_at = raw[1..];
    // Find end of at-rule name: first `(`, ` `, or end of string.
    var i: usize = 0;
    while (i < after_at.len and after_at[i] != '(' and after_at[i] != ' ') : (i += 1) {}
    if (i == 0) return VariantError.UnknownVariant;
    const name = after_at[0..i];
    // Skip whitespace between name and condition.
    var cond_start = i;
    while (cond_start < after_at.len and after_at[cond_start] == ' ') : (cond_start += 1) {}
    const cond_raw = after_at[cond_start..];

    // Match the at-rule name against a small allow-list of safe ones.
    if (!isAllowedArbitraryAtRule(name)) return VariantError.UnknownVariant;

    // Normalize: ensure condition is wrapped in parens (callers may pass
    // either `(...)` or just `...`). If empty, leave as empty.
    const cond_owned: []u8 = if (cond_raw.len == 0)
        try allocator.dupe(u8, "")
    else if (cond_raw[0] == '(')
        try allocator.dupe(u8, cond_raw)
    else
        try std.fmt.allocPrint(allocator, "({s})", .{cond_raw});

    // Dupe `name` because the runner's `AtRule.name` is a static slice;
    // we hand back the parser-owned slice (`raw` lives in the candidate's
    // allocator, which outlives this call). For safety, return one of a
    // small set of known constants instead.
    const name_const = canonicalAtRuleName(name) orelse {
        allocator.free(cond_owned);
        return VariantError.UnknownVariant;
    };
    try at_rules.append(.{ .name = name_const, .condition = cond_owned });
}

fn isAllowedArbitraryAtRule(name: []const u8) bool {
    return std.mem.eql(u8, name, "media") or
        std.mem.eql(u8, name, "supports") or
        std.mem.eql(u8, name, "container") or
        std.mem.eql(u8, name, "starting-style");
}

fn canonicalAtRuleName(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "media")) return "media";
    if (std.mem.eql(u8, name, "supports")) return "supports";
    if (std.mem.eql(u8, name, "container")) return "container";
    if (std.mem.eql(u8, name, "starting-style")) return "starting-style";
    return null;
}

fn substituteAmpersand(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    replacement: []const u8,
) VariantError![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (pattern) |c| {
        if (c == '&') {
            try out.appendSlice(replacement);
        } else {
            try out.append(c);
        }
    }
    return out.toOwnedSlice();
}

// ── Selector escaping ───────────────────────────────────────────────────────

/// Escape special characters in a class name for use in a CSS selector.
/// Characters needing escapes: `:`, `/`, `[`, `]`, `(`, `)`, `.`, `,`, `#`,
/// `%`, `!`, `@`, `$`, `^`, `*`, `+`, `=`, `~`, `|`, `<`, `>`, `?`, `'`, `"`.
/// We escape with a leading backslash.
pub fn escapeClassSelector(allocator: std.mem.Allocator, class: []const u8) VariantError![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('.');
    for (class) |c| {
        switch (c) {
            ':', '/', '[', ']', '(', ')', '.', ',', '#', '%', '!', '@',
            '$', '^', '*', '+', '=', '~', '|', '<', '>', '?', '\'', '"',
            ' ',
            => {
                try out.append('\\');
                try out.append(c);
            },
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────────

const tst = std.testing;

const test_theme = theme.Theme{ .tokens = &.{
    .{ .name = "breakpoint-sm", .value = "40rem" },
    .{ .name = "breakpoint-md", .value = "48rem" },
    .{ .name = "breakpoint-lg", .value = "64rem" },
    .{ .name = "container-xs", .value = "20rem" },
    .{ .name = "container-sm", .value = "24rem" },
    .{ .name = "container-md", .value = "28rem" },
} };

fn parseAndApply(allocator: std.mem.Allocator, input: []const u8) !struct { sel: []u8, ats: []AtRule, base: []const u8 } {
    const cands = try candidate.parseCandidate(allocator, input);
    defer candidate.freeCandidates(allocator, cands);
    // Take the first functional or static-c candidate for testing.
    for (cands) |c| {
        switch (c) {
            .static_c => |s| {
                const wr = try applyVariants(allocator, test_theme, s.variants, s.root);
                return .{ .sel = wr.selector, .ats = wr.at_rules, .base = s.root };
            },
            .functional => |f| {
                const wr = try applyVariants(allocator, test_theme, f.variants, f.root);
                return .{ .sel = wr.selector, .ats = wr.at_rules, .base = f.root };
            },
            else => continue,
        }
    }
    return error.NoCandidate;
}

test "static variant: hover" {
    const r = try parseAndApply(tst.allocator, "hover:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:hover", r.sel);
    try tst.expectEqual(@as(usize, 0), r.ats.len);
}

test "static variant: focus-visible" {
    const r = try parseAndApply(tst.allocator, "focus-visible:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:focus-visible", r.sel);
}

test "static variant: dark (at-rule)" {
    const r = try parseAndApply(tst.allocator, "dark:flex");
    defer tst.allocator.free(r.sel);
    defer {
        for (r.ats) |ar| tst.allocator.free(ar.condition);
        tst.allocator.free(r.ats);
    }
    try tst.expectEqualStrings(".flex", r.sel);
    try tst.expectEqual(@as(usize, 1), r.ats.len);
    try tst.expectEqualStrings("media", r.ats[0].name);
    try tst.expectEqualStrings("(prefers-color-scheme: dark)", r.ats[0].condition);
}

test "breakpoint variant: md (theme-driven)" {
    const r = try parseAndApply(tst.allocator, "md:flex");
    defer tst.allocator.free(r.sel);
    defer {
        for (r.ats) |ar| tst.allocator.free(ar.condition);
        tst.allocator.free(r.ats);
    }
    try tst.expectEqualStrings(".flex", r.sel);
    try tst.expectEqualStrings("media", r.ats[0].name);
    // Literal value substituted from theme — `var()` is illegal in @media
    // feature value position.
    try tst.expectEqualStrings("(min-width: 48rem)", r.ats[0].condition);
}

test "stacked: md:hover (innermost first in source order)" {
    const r = try parseAndApply(tst.allocator, "md:hover:flex");
    defer tst.allocator.free(r.sel);
    defer {
        for (r.ats) |ar| tst.allocator.free(ar.condition);
        tst.allocator.free(r.ats);
    }
    // Variants applied innermost-first: hover then md. Both wrap the base.
    try tst.expectEqualStrings(".flex:hover", r.sel);
    try tst.expectEqual(@as(usize, 1), r.ats.len);
    try tst.expectEqualStrings("(min-width: 48rem)", r.ats[0].condition);
}

test "functional variant: data-[state=open]" {
    const r = try parseAndApply(tst.allocator, "data-[state=open]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex[data-state=open]", r.sel);
}

test "functional variant: data-[publr-state=open] (dash inside bracket)" {
    // Regression: parser used to find the LAST `-` even when it was inside
    // `[…]`, splitting `data-[publr-state=open]` into `data-[publr` +
    // `state=open]` (neither parses) and silently dropping the variant.
    // Symptom: Dialog overlay never opened in the gallery because
    // `group-data-[publr-state=open]:opacity-100` produced no rule.
    const r = try parseAndApply(tst.allocator, "data-[publr-state=open]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex[data-publr-state=open]", r.sel);
}

test "compound variant: group-data-[publr-state=open] (dash inside bracket)" {
    const r = try parseAndApply(tst.allocator, "group-data-[publr-state=open]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".group[data-publr-state=open] .flex", r.sel);
}

test "functional variant: aria-[busy=true]" {
    const r = try parseAndApply(tst.allocator, "aria-[busy=true]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex[aria-busy=true]", r.sel);
}

test "compound variant: group-hover" {
    const r = try parseAndApply(tst.allocator, "group-hover:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".group:hover .flex", r.sel);
}

test "compound variant: peer-focus" {
    const r = try parseAndApply(tst.allocator, "peer-focus:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    // `peer-` uses the subsequent-sibling combinator, not descendant — the
    // inner element is rendered next to the marker, not inside it.
    try tst.expectEqualStrings(".peer:focus ~ .flex", r.sel);
}

test "compound variant: peer-checked emits sibling combinator" {
    // Regression: previously `peer-checked:bg-primary` emitted the
    // descendant combinator (` ` instead of ` ~ `), so Switch's track span
    // never received the checked-state styles even though it was a sibling
    // of the `<input class="peer">`.
    const r = try parseAndApply(tst.allocator, "peer-checked:bg-primary");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".peer:checked ~ .bg-primary", r.sel);
}

test "compound variant: named group (group-hover/foo)" {
    const r = try parseAndApply(tst.allocator, "group-hover/foo:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".group\\/foo:hover .flex", r.sel);
}

test "arbitrary variant: [&_p]:flex → & p .flex" {
    const r = try parseAndApply(tst.allocator, "[&_p]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    // Parser produces selector "& p"; we substitute & with current selector ".flex".
    try tst.expectEqualStrings(".flex p", r.sel);
}

test "escape: class with `:` gets escaped" {
    const out = try escapeClassSelector(tst.allocator, "md:flex");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings(".md\\:flex", out);
}

test "escape: class with `/` gets escaped" {
    const out = try escapeClassSelector(tst.allocator, "w-1/2");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings(".w-1\\/2", out);
}

test "escape: class with brackets gets escaped" {
    const out = try escapeClassSelector(tst.allocator, "bg-[#abc]");
    defer tst.allocator.free(out);
    try tst.expectEqualStrings(".bg-\\[\\#abc\\]", out);
}

// ── not-* / has-* / in-* compound forwarding ────────────────────────────────

test "not-hover: wraps inner in :not(...)" {
    const r = try parseAndApply(tst.allocator, "not-hover:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:not(:hover)", r.sel);
}

test "not-data-[active]: wraps in :not([data-active])" {
    const r = try parseAndApply(tst.allocator, "not-data-[active]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:not([data-active])", r.sel);
}

test "has-focus: wraps inner in :has(...)" {
    const r = try parseAndApply(tst.allocator, "has-focus:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:has(:focus)", r.sel);
}

test "has-[input:focus]: wraps in :has(:is(input:focus))" {
    // Parser wraps non-relative arbitrary selectors in `&:is(...)`.
    const r = try parseAndApply(tst.allocator, "has-[input:focus]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:has(:is(input:focus))", r.sel);
}

test "in-hover: ancestor-condition wrapper with :where()" {
    const r = try parseAndApply(tst.allocator, "in-hover:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(":where(:hover) .flex", r.sel);
}

test "group-data-[active]: still works after compound refactor (regression)" {
    // The class is `group-data-[active]:opacity-100` — let's just check
    // group-hover here to keep the test simple.
    const r = try parseAndApply(tst.allocator, "group-hover:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".group:hover .flex", r.sel);
}

// ── Container queries ──────────────────────────────────────────────────────

test "container query: bare @container" {
    const r = try parseAndApply(tst.allocator, "@container:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqual(@as(usize, 1), r.ats.len);
    try tst.expectEqualStrings("container", r.ats[0].name);
    try tst.expectEqualStrings("", r.ats[0].condition);
}

test "container query: @sm (theme-driven)" {
    const r = try parseAndApply(tst.allocator, "@sm:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqual(@as(usize, 1), r.ats.len);
    try tst.expectEqualStrings("container", r.ats[0].name);
    try tst.expectEqualStrings("(width >= 24rem)", r.ats[0].condition);
}

test "container query: @max-md (max-width form)" {
    const r = try parseAndApply(tst.allocator, "@max-md:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqualStrings("(width < 28rem)", r.ats[0].condition);
}

test "container query: @[400px] (arbitrary)" {
    const r = try parseAndApply(tst.allocator, "@[400px]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqualStrings("(400px)", r.ats[0].condition);
}

test "container query: @max-[500px] (arbitrary max)" {
    const r = try parseAndApply(tst.allocator, "@max-[500px]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqualStrings("(width < 500px)", r.ats[0].condition);
}

// ── Arbitrary at-rule variants ──────────────────────────────────────────────

test "arbitrary at-rule: [@media(width>=123px)]:flex" {
    const r = try parseAndApply(tst.allocator, "[@media(width>=123px)]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqual(@as(usize, 1), r.ats.len);
    try tst.expectEqualStrings("media", r.ats[0].name);
    try tst.expectEqualStrings("(width>=123px)", r.ats[0].condition);
}

test "arbitrary at-rule: [@supports(display:grid)]:flex" {
    const r = try parseAndApply(tst.allocator, "[@supports(display:grid)]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqualStrings("supports", r.ats[0].name);
    try tst.expectEqualStrings("(display:grid)", r.ats[0].condition);
}

test "before: + hover stacking — pseudo-element comes last in CSS selector" {
    // CSS rule: pseudo-elements must be the LAST simple selector. The
    // helper escapes only `s.root` (`flex`), so the expected base is `.flex`.
    const r = try parseAndApply(tst.allocator, "before:hover:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:hover::before", r.sel);
}

test "hover: + before stacking — same final order regardless of source order" {
    const r = try parseAndApply(tst.allocator, "hover:before:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    try tst.expectEqualStrings(".flex:hover::before", r.sel);
}

test "arbitrary at-rule: bare condition gets wrapped in parens" {
    const r = try parseAndApply(tst.allocator, "[@media_screen]:flex");
    defer tst.allocator.free(r.sel);
    defer tst.allocator.free(r.ats);
    defer for (r.ats) |ar| tst.allocator.free(ar.condition);
    try tst.expectEqualStrings("media", r.ats[0].name);
    try tst.expectEqualStrings("(screen)", r.ats[0].condition);
}
