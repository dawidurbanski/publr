/// Resolver — converts class candidates to CSS rules.
///
/// Resolution paths (tried in order):
///   1. Static utilities:    "flex", "block" → fixed CSS
///   2. Border shorthands:   "border", "border-b" → fixed CSS
///   3. Arbitrary value:     "w-[380px]" → property-from-prefix, value-from-brackets
///   4. Spacing/sizing:      "gap-1.5", "p-4", "h-12" → Tailwind 4 numeric scale × 0.25rem
///   5. max-w/max-h:         "max-w-md" → Tailwind max-w/max-h scale
///   6. Grid columns:        "grid-cols-4" → grid-template-columns: repeat(N, ...)
///   7. Space y/x:           "space-y-2" → margin-top on adjacent siblings (special selector)
///   8. Token functional:    "bg-primary", "text-muted-foreground", "font-bold", "rounded-md"
///   9. Color w/ opacity:    "bg-muted/40" → color-mix(...)
///  10. Text size combo:     "text-sm" → font-size + line-height
///
/// Variants (prefix:base):  hover:, focus:, focus-visible:, active:, disabled:, first:, last:.

const std = @import("std");
const tokens = @import("tokens.zig");

pub const CssRule = struct {
    selector: []const u8,
    property: []const u8,
    value: []const u8,
};

/// Static utilities — classes that map directly to fixed CSS (no value parsing)
const static_utilities = .{
    // Display
    .{ "flex", "display", "flex" },
    .{ "block", "display", "block" },
    .{ "inline-flex", "display", "inline-flex" },
    .{ "inline-block", "display", "inline-block" },
    .{ "hidden", "display", "none" },
    .{ "grid", "display", "grid" },

    // Flex direction
    .{ "flex-row", "flex-direction", "row" },
    .{ "flex-col", "flex-direction", "column" },

    // Flex sizing
    .{ "flex-1", "flex", "1 1 0%" },
    .{ "flex-auto", "flex", "1 1 auto" },
    .{ "flex-none", "flex", "none" },
    .{ "shrink-0", "flex-shrink", "0" },
    .{ "grow", "flex-grow", "1" },
    .{ "grow-0", "flex-grow", "0" },

    // Wrap
    .{ "flex-wrap", "flex-wrap", "wrap" },
    .{ "flex-nowrap", "flex-wrap", "nowrap" },

    // Alignment
    .{ "items-start", "align-items", "flex-start" },
    .{ "items-center", "align-items", "center" },
    .{ "items-end", "align-items", "flex-end" },
    .{ "items-stretch", "align-items", "stretch" },
    .{ "items-baseline", "align-items", "baseline" },

    // Justify
    .{ "justify-start", "justify-content", "flex-start" },
    .{ "justify-center", "justify-content", "center" },
    .{ "justify-end", "justify-content", "flex-end" },
    .{ "justify-between", "justify-content", "space-between" },
    .{ "justify-around", "justify-content", "space-around" },

    // Overflow
    .{ "overflow-hidden", "overflow", "hidden" },
    .{ "overflow-auto", "overflow", "auto" },
    .{ "overflow-y-auto", "overflow-y", "auto" },
    .{ "overflow-x-auto", "overflow-x", "auto" },

    // Position
    .{ "relative", "position", "relative" },
    .{ "absolute", "position", "absolute" },
    .{ "fixed", "position", "fixed" },
    .{ "sticky", "position", "sticky" },

    // Sizing — common percentages / viewport
    .{ "w-full", "width", "100%" },
    .{ "w-screen", "width", "100vw" },
    .{ "w-auto", "width", "auto" },
    .{ "h-full", "height", "100%" },
    .{ "h-screen", "height", "100vh" },
    .{ "h-auto", "height", "auto" },
    .{ "min-w-full", "min-width", "100%" },
    .{ "min-h-screen", "min-height", "100vh" },

    // Spacing shortcuts
    .{ "mt-auto", "margin-top", "auto" },
    .{ "ml-auto", "margin-left", "auto" },
    .{ "mr-auto", "margin-right", "auto" },
    .{ "mx-auto", "margin-inline", "auto" },

    // Text
    .{ "text-left", "text-align", "left" },
    .{ "text-center", "text-align", "center" },
    .{ "text-right", "text-align", "right" },

    // Misc
    .{ "resize-y", "resize", "vertical" },
    .{ "cursor-pointer", "cursor", "pointer" },
    .{ "cursor-default", "cursor", "default" },
    .{ "cursor-not-allowed", "cursor", "not-allowed" },
    .{ "cursor-text", "cursor", "text" },
    .{ "cursor-wait", "cursor", "wait" },
    .{ "cursor-help", "cursor", "help" },
    .{ "select-none", "user-select", "none" },
    .{ "select-text", "user-select", "text" },
    .{ "select-all", "user-select", "all" },

    // Object fit / position
    .{ "object-cover", "object-fit", "cover" },
    .{ "object-contain", "object-fit", "contain" },
    .{ "object-fill", "object-fit", "fill" },
    .{ "object-none", "object-fit", "none" },
    .{ "object-scale-down", "object-fit", "scale-down" },

    // Text utilities
    .{ "truncate", "_truncate", "" },
    .{ "uppercase", "text-transform", "uppercase" },
    .{ "lowercase", "text-transform", "lowercase" },
    .{ "capitalize", "text-transform", "capitalize" },
    .{ "italic", "font-style", "italic" },
    .{ "underline", "text-decoration-line", "underline" },
    .{ "line-through", "text-decoration-line", "line-through" },
    .{ "no-underline", "text-decoration-line", "none" },
    .{ "tracking-tighter", "letter-spacing", "-0.05em" },
    .{ "tracking-tight", "letter-spacing", "-0.025em" },
    .{ "tracking-normal", "letter-spacing", "0em" },
    .{ "tracking-wide", "letter-spacing", "0.025em" },
    .{ "tracking-wider", "letter-spacing", "0.05em" },
    .{ "tracking-widest", "letter-spacing", "0.1em" },

    // Whitespace / wrap
    .{ "whitespace-nowrap", "white-space", "nowrap" },
    .{ "whitespace-normal", "white-space", "normal" },
    .{ "whitespace-pre", "white-space", "pre" },
    .{ "whitespace-pre-wrap", "white-space", "pre-wrap" },
    .{ "break-all", "word-break", "break-all" },
    .{ "break-words", "overflow-wrap", "break-word" },

    // Sr-only — visually hidden but accessible
    .{ "sr-only", "_sr-only", "" },
    .{ "not-sr-only", "_not-sr-only", "" },

    // Bare rounded → default radius (Tailwind 4 default = lg)
    .{ "rounded", "border-radius", "var(--radius)" },

    // Caption side
    .{ "caption-top", "caption-side", "top" },
    .{ "caption-bottom", "caption-side", "bottom" },

    // Animate spin (keyframes emitted in main.zig base_css)
    .{ "animate-spin", "animation", "publr-spin 1s linear infinite" },

    // Line height
    .{ "leading-none", "line-height", "1" },
    .{ "leading-tight", "line-height", "1.25" },
    .{ "leading-snug", "line-height", "1.375" },
    .{ "leading-normal", "line-height", "1.5" },
    .{ "leading-relaxed", "line-height", "1.625" },
    .{ "leading-loose", "line-height", "2" },

    // Self alignment
    .{ "self-auto", "align-self", "auto" },
    .{ "self-start", "align-self", "flex-start" },
    .{ "self-end", "align-self", "flex-end" },
    .{ "self-center", "align-self", "center" },
    .{ "self-stretch", "align-self", "stretch" },

    // Transitions
    .{ "transition", "transition-property", "color, background-color, border-color, fill, stroke, opacity, box-shadow, transform" },
    .{ "transition-all", "transition-property", "all" },
    .{ "transition-colors", "transition-property", "color, background-color, border-color" },
    .{ "transition-opacity", "transition-property", "opacity" },
    .{ "transition-transform", "transition-property", "transform" },
    .{ "transition-shadow", "transition-property", "box-shadow" },
    .{ "transition-none", "transition-property", "none" },

    // Outline
    .{ "outline-none", "outline", "2px solid transparent" },
    .{ "outline-hidden", "outline", "2px solid transparent" },

    // Z-index named
    .{ "z-auto", "z-index", "auto" },

    // Inset shorthand
    .{ "inset-0", "inset", "0" },

    // Pointer events
    .{ "pointer-events-auto", "pointer-events", "auto" },
    .{ "pointer-events-none", "pointer-events", "none" },
};

/// Functional utilities — prefix → CSS property mapping for token-based classes.
/// Numeric scales (spacing, sizing) are handled by dedicated paths below.
const functional_utilities = .{
    // Colors
    .{ "bg", "background-color", tokens.colors },
    .{ "text", "_color", tokens.colors }, // text-{color} → color: ...

    // Typography
    .{ "font", "font-weight", tokens.font_weight },
    .{ "rounded", "border-radius", tokens.radius },
};

/// Arbitrary value property mapping: prefix → CSS property
const arbitrary_properties = .{
    .{ "w", "width" },
    .{ "h", "height" },
    .{ "min-w", "min-width" },
    .{ "min-h", "min-height" },
    .{ "max-w", "max-width" },
    .{ "max-h", "max-height" },
    .{ "p", "padding" },
    .{ "px", "_multi" },
    .{ "py", "_multi" },
    .{ "pt", "padding-top" },
    .{ "pb", "padding-bottom" },
    .{ "pl", "padding-left" },
    .{ "pr", "padding-right" },
    .{ "m", "margin" },
    .{ "mx", "_multi" },
    .{ "my", "_multi" },
    .{ "mt", "margin-top" },
    .{ "mb", "margin-bottom" },
    .{ "ml", "margin-left" },
    .{ "mr", "margin-right" },
    .{ "top", "top" },
    .{ "right", "right" },
    .{ "bottom", "bottom" },
    .{ "left", "left" },
    .{ "gap", "gap" },
    .{ "text", "font-size" },
    .{ "rounded", "border-radius" },
    .{ "grid-cols", "grid-template-columns" },
};

/// Spacing-prefix → CSS property mapping for the numeric scale (Tailwind 4: 1 unit = 0.25rem).
/// A `_multi` value triggers a multi-property emit (e.g. `px-4` writes both `padding-left` and `padding-right`).
const spacing_prefixes = .{
    .{ "gap", "gap" },
    .{ "gap-x", "column-gap" },
    .{ "gap-y", "row-gap" },
    .{ "p", "padding" },
    .{ "px", "_multi" },
    .{ "py", "_multi" },
    .{ "pt", "padding-top" },
    .{ "pb", "padding-bottom" },
    .{ "pl", "padding-left" },
    .{ "pr", "padding-right" },
    .{ "m", "margin" },
    .{ "mx", "_multi" },
    .{ "my", "_multi" },
    .{ "mt", "margin-top" },
    .{ "mb", "margin-bottom" },
    .{ "ml", "margin-left" },
    .{ "mr", "margin-right" },
    .{ "w", "width" },
    .{ "h", "height" },
    .{ "min-w", "min-width" },
    .{ "min-h", "min-height" },
    .{ "max-h", "max-height" },
    .{ "top", "top" },
    .{ "right", "right" },
    .{ "bottom", "bottom" },
    .{ "left", "left" },
};

/// Resolve a single class candidate to CSS rule(s).
/// Returns null if the candidate can't be resolved.
pub fn resolve(allocator: std.mem.Allocator, candidate: []const u8) !?std.ArrayListUnmanaged(u8) {
    @setEvalBranchQuota(20000);
    var css: std.ArrayListUnmanaged(u8) = .{};
    errdefer css.deinit(allocator);
    const w = css.writer(allocator);

    // Parse stacked variants + base, respecting brackets.
    const split = parseVariants(candidate);
    const variants = split.variants[0..split.count];
    const base = split.base;
    // Single-variant aliases for backward-compat with helpers that take ?[]const u8.
    const first_variant: ?[]const u8 = if (split.count > 0) split.variants[0] else null;

    // Special-case: space-y-N / space-x-N — non-standard selector, handle entirely here.
    if (trySpaceUtility(w, candidate, first_variant, base)) {
        return css;
    }

    // Special-case: divide-y / divide-x / divide-{color} — sibling border selector.
    if (tryDivideUtility(w, candidate, base)) {
        return css;
    }

    // Build selector — `.candidate` plus variant-derived pseudos / attribute selectors / parent contexts.
    try writeSelectorWithVariant(w, candidate, variants);

    try w.writeAll(" {\n");
    const declarations_start = css.items.len;

    // 1. Static utilities
    inline for (static_utilities) |entry| {
        if (std.mem.eql(u8, base, entry[0])) {
            // Multi-property pseudo-utilities (start with `_`)
            if (std.mem.eql(u8, entry[1], "_truncate")) {
                try w.writeAll("  overflow: hidden;\n  text-overflow: ellipsis;\n  white-space: nowrap;\n");
            } else if (std.mem.eql(u8, entry[1], "_sr-only")) {
                try w.writeAll("  position: absolute;\n  width: 1px;\n  height: 1px;\n  padding: 0;\n  margin: -1px;\n  overflow: hidden;\n  clip: rect(0, 0, 0, 0);\n  white-space: nowrap;\n  border-width: 0;\n");
            } else if (std.mem.eql(u8, entry[1], "_not-sr-only")) {
                try w.writeAll("  position: static;\n  width: auto;\n  height: auto;\n  padding: 0;\n  margin: 0;\n  overflow: visible;\n  clip: auto;\n  white-space: normal;\n");
            } else {
                try w.print("  {s}: {s};\n", .{ entry[1], entry[2] });
            }
            try w.writeAll("}\n");
            return css;
        }
    }

    // 2. Border shorthands
    if (std.mem.eql(u8, base, "border")) {
        try w.writeAll("  border-width: 1px;\n  border-color: var(--border);\n  border-style: solid;\n}\n");
        return css;
    }
    if (std.mem.eql(u8, base, "border-b")) {
        try w.writeAll("  border-bottom: 1px solid var(--border);\n}\n");
        return css;
    }
    if (std.mem.eql(u8, base, "border-t")) {
        try w.writeAll("  border-top: 1px solid var(--border);\n}\n");
        return css;
    }
    if (std.mem.eql(u8, base, "border-l")) {
        try w.writeAll("  border-left: 1px solid var(--border);\n}\n");
        return css;
    }
    if (std.mem.eql(u8, base, "border-r")) {
        try w.writeAll("  border-right: 1px solid var(--border);\n}\n");
        return css;
    }

    // 3. Arbitrary values
    if (try tryResolveArbitrary(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 4. Numeric spacing/sizing scale (including negative like -mr-1)
    if (try tryResolveSpacing(w, base)) {
        try w.writeAll("}\n");
        return css;
    }
    if (base.len > 1 and base[0] == '-') {
        if (try tryResolveNegativeSpacing(w, base[1..])) {
            try w.writeAll("}\n");
            return css;
        }
    }

    // 5. max-w / max-h named scale
    if (try tryResolveMaxSize(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6. grid-cols-N
    if (try tryResolveGridCols(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6a. ring-inset
    if (std.mem.eql(u8, base, "ring-inset")) {
        try w.writeAll("  --tw-ring-inset: inset;\n}\n");
        return css;
    }

    // 6b. shadow-{size}
    if (try tryResolveShadow(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6c. ring-{N} | ring (default 3px) | ring-offset-{N}
    if (try tryResolveRingWidth(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6d. ring-{color} | ring-offset-{color}
    if (try tryResolveRingColor(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6e. opacity-N
    if (try tryResolveOpacityN(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6f. z-N
    if (try tryResolveZIndex(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6g. duration-N
    if (try tryResolveDuration(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6h. inset-x-N / inset-y-N
    if (try tryResolveInsetAxis(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6i. border-{N} width or border-{side}-{N} | border-{color} | border-{side}-{color}
    if (try tryResolveBorder(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6j. translate-x/y-N (with negative + fractional)
    if (try tryResolveTranslate(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 6k. rotate-N (with negative)
    if (try tryResolveRotate(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 7. Color with opacity modifier (must precede plain functional)
    if (std.mem.indexOfScalar(u8, base, '/')) |slash| {
        if (try tryResolveColorWithOpacity(w, base[0..slash], base[slash + 1 ..])) {
            try w.writeAll("}\n");
            return css;
        }
    }

    // 8. Token-based functional (bg-, text- color, font-, rounded-)
    if (try tryResolveFunctional(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // 9. text-{size} combo
    if (try tryResolveTextSize(w, base)) {
        try w.writeAll("}\n");
        return css;
    }

    // No match
    if (css.items.len == declarations_start) {
        css.deinit(allocator);
        return null;
    }

    try w.writeAll("}\n");
    return css;
}

fn tryResolveArbitrary(w: anytype, base: []const u8) !bool {
    const bracket_start = std.mem.indexOfScalar(u8, base, '[') orelse return false;
    if (base[base.len - 1] != ']') return false;
    if (bracket_start == 0) return false;

    const prefix = base[0 .. bracket_start - 1]; // strip trailing dash
    const value = base[bracket_start + 1 .. base.len - 1];

    inline for (arbitrary_properties) |entry| {
        if (std.mem.eql(u8, prefix, entry[0])) {
            if (std.mem.eql(u8, entry[1], "_multi")) {
                if (std.mem.eql(u8, prefix, "px")) {
                    try w.print("  padding-left: {s};\n  padding-right: {s};\n", .{ value, value });
                } else if (std.mem.eql(u8, prefix, "py")) {
                    try w.print("  padding-top: {s};\n  padding-bottom: {s};\n", .{ value, value });
                } else if (std.mem.eql(u8, prefix, "mx")) {
                    try w.print("  margin-left: {s};\n  margin-right: {s};\n", .{ value, value });
                } else if (std.mem.eql(u8, prefix, "my")) {
                    try w.print("  margin-top: {s};\n  margin-bottom: {s};\n", .{ value, value });
                }
                return true;
            } else if (std.mem.eql(u8, entry[0], "grid-cols")) {
                // arbitrary grid-cols-[repeat(...)]
                try w.print("  grid-template-columns: {s};\n", .{value});
                return true;
            } else {
                try w.print("  {s}: {s};\n", .{ entry[1], value });
                return true;
            }
        }
    }
    return false;
}

/// Try matching the spacing scale prefixes (gap, p*, m*, w, h, min-*, top/right/etc).
/// Value is parsed as Tailwind 4 numeric: N → N*0.25rem. Special: "px" → "1px", "0" → "0".
fn tryResolveSpacing(w: anytype, base: []const u8) !bool {
    inline for (spacing_prefixes) |entry| {
        const prefix = entry[0];
        const property = entry[1];
        if (base.len > prefix.len + 1 and
            std.mem.startsWith(u8, base, prefix) and
            base[prefix.len] == '-')
        {
            const value_name = base[prefix.len + 1 ..];
            var value_buf: [32]u8 = undefined;
            if (formatSpacingValue(&value_buf, value_name)) |value| {
                if (std.mem.eql(u8, property, "_multi")) {
                    if (std.mem.eql(u8, prefix, "px")) {
                        try w.print("  padding-left: {s};\n  padding-right: {s};\n", .{ value, value });
                    } else if (std.mem.eql(u8, prefix, "py")) {
                        try w.print("  padding-top: {s};\n  padding-bottom: {s};\n", .{ value, value });
                    } else if (std.mem.eql(u8, prefix, "mx")) {
                        try w.print("  margin-left: {s};\n  margin-right: {s};\n", .{ value, value });
                    } else if (std.mem.eql(u8, prefix, "my")) {
                        try w.print("  margin-top: {s};\n  margin-bottom: {s};\n", .{ value, value });
                    }
                } else {
                    try w.print("  {s}: {s};\n", .{ property, value });
                }
                return true;
            }
        }
    }
    return false;
}

/// Format a Tailwind 4 spacing value name into rem (or 1px for "px", "0" for "0").
/// Also handles fractions like "1/2" → "50%", "2/5" → "40%".
/// Returns a slice of the provided buffer, or null if unparseable.
fn formatSpacingValue(buf: []u8, value_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value_name, "px")) {
        std.mem.copyForwards(u8, buf, "1px");
        return buf[0..3];
    }
    if (std.mem.eql(u8, value_name, "0")) {
        buf[0] = '0';
        return buf[0..1];
    }
    if (std.mem.eql(u8, value_name, "full")) {
        std.mem.copyForwards(u8, buf, "100%");
        return buf[0..4];
    }
    // Fraction: N/M → (N/M * 100)%
    if (std.mem.indexOfScalar(u8, value_name, '/')) |slash| {
        const num = std.fmt.parseFloat(f64, value_name[0..slash]) catch return null;
        const den = std.fmt.parseFloat(f64, value_name[slash + 1 ..]) catch return null;
        if (den == 0) return null;
        const pct = (num / den) * 100.0;
        return formatPercent(buf, pct);
    }
    const n = std.fmt.parseFloat(f64, value_name) catch return null;
    if (n < 0) return null;
    const rem = n * 0.25;
    return formatRem(buf, rem);
}

fn formatRem(buf: []u8, rem: f64) ?[]const u8 {
    var tmp: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&tmp, "{d:.4}", .{rem}) catch return null;
    var end = formatted.len;
    if (std.mem.indexOfScalar(u8, formatted, '.')) |_| {
        while (end > 0 and formatted[end - 1] == '0') : (end -= 1) {}
        if (end > 0 and formatted[end - 1] == '.') end -= 1;
    }
    if (end + 3 > buf.len) return null;
    std.mem.copyForwards(u8, buf, formatted[0..end]);
    std.mem.copyForwards(u8, buf[end..], "rem");
    return buf[0 .. end + 3];
}

fn formatPercent(buf: []u8, pct: f64) ?[]const u8 {
    var tmp: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&tmp, "{d:.4}", .{pct}) catch return null;
    var end = formatted.len;
    if (std.mem.indexOfScalar(u8, formatted, '.')) |_| {
        while (end > 0 and formatted[end - 1] == '0') : (end -= 1) {}
        if (end > 0 and formatted[end - 1] == '.') end -= 1;
    }
    if (end + 1 > buf.len) return null;
    std.mem.copyForwards(u8, buf, formatted[0..end]);
    buf[end] = '%';
    return buf[0 .. end + 1];
}

/// Negative spacing: -mr-1, -mt-2, etc. Negate the resolved value.
fn tryResolveNegativeSpacing(w: anytype, positive_base: []const u8) !bool {
    inline for (spacing_prefixes) |entry| {
        const prefix = entry[0];
        const property = entry[1];
        if (positive_base.len > prefix.len + 1 and
            std.mem.startsWith(u8, positive_base, prefix) and
            positive_base[prefix.len] == '-')
        {
            const value_name = positive_base[prefix.len + 1 ..];
            var value_buf: [32]u8 = undefined;
            if (formatSpacingValue(&value_buf, value_name)) |value| {
                if (std.mem.eql(u8, property, "_multi")) {
                    if (std.mem.eql(u8, prefix, "mx")) {
                        try w.print("  margin-left: -{s};\n  margin-right: -{s};\n", .{ value, value });
                    } else if (std.mem.eql(u8, prefix, "my")) {
                        try w.print("  margin-top: -{s};\n  margin-bottom: -{s};\n", .{ value, value });
                    }
                } else {
                    try w.print("  {s}: -{s};\n", .{ property, value });
                }
                return true;
            }
        }
    }
    return false;
}

/// max-w-{size} / max-h-{size} use Tailwind's max-width/max-height named scale.
fn tryResolveMaxSize(w: anytype, base: []const u8) !bool {
    const is_w = std.mem.startsWith(u8, base, "max-w-");
    const is_h = std.mem.startsWith(u8, base, "max-h-");
    if (!is_w and !is_h) return false;
    const property = if (is_w) "max-width" else "max-height";
    const value_name = base[6..];

    inline for (tokens.max_size) |entry| {
        if (std.mem.eql(u8, value_name, entry[0])) {
            try w.print("  {s}: {s};\n", .{ property, entry[1] });
            return true;
        }
    }
    return false;
}

/// grid-cols-N → grid-template-columns: repeat(N, minmax(0, 1fr));
fn tryResolveGridCols(w: anytype, base: []const u8) !bool {
    if (!std.mem.startsWith(u8, base, "grid-cols-")) return false;
    const n_str = base[10..];
    const n = std.fmt.parseInt(u32, n_str, 10) catch return false;
    if (n == 0 or n > 24) return false;
    try w.print("  grid-template-columns: repeat({d}, minmax(0, 1fr));\n", .{n});
    return true;
}

/// shadow-{size} → sets `--tw-shadow` and the layered `box-shadow` chain.
fn tryResolveShadow(w: anytype, base: []const u8) !bool {
    if (!std.mem.startsWith(u8, base, "shadow-")) {
        // Bare `shadow` not handled here (would conflict with shadow-{anything} parse).
        if (std.mem.eql(u8, base, "shadow")) {
            // Default shadow uses tokens.shadow's "sm" entry per Tailwind 4 default.
            try w.writeAll("  --tw-shadow: 0 1px 3px 0 oklch(0 0 0 / 0.06);\n");
            try writeBoxShadowChain(w);
            return true;
        }
        return false;
    }
    const size_name = base[7..];
    inline for (tokens.shadow) |entry| {
        if (std.mem.eql(u8, size_name, entry[0])) {
            try w.print("  --tw-shadow: {s};\n", .{entry[1]});
            try writeBoxShadowChain(w);
            return true;
        }
    }
    return false;
}

/// ring | ring-{N} | ring-offset-{N} — full Tailwind machinery via `--tw-ring-*` vars.
fn tryResolveRingWidth(w: anytype, base: []const u8) !bool {
    // ring-offset-{N}
    if (std.mem.startsWith(u8, base, "ring-offset-")) {
        const n_str = base[12..];
        // Skip if it's a color suffix not a number — let tryResolveRingColor handle it.
        const n = std.fmt.parseInt(u32, n_str, 10) catch return false;
        if (n > 99) return false;
        try w.print("  --tw-ring-offset-width: {d}px;\n", .{n});
        try w.writeAll("  --tw-ring-offset-shadow: var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color, #fff);\n");
        try writeBoxShadowChain(w);
        return true;
    }

    // ring-{N} or bare ring (default 3px)
    var n: u32 = 3;
    if (std.mem.eql(u8, base, "ring")) {
        // default
    } else if (std.mem.startsWith(u8, base, "ring-")) {
        const tail = base[5..];
        n = std.fmt.parseInt(u32, tail, 10) catch return false;
        if (n > 99) return false;
    } else {
        return false;
    }
    try w.print(
        "  --tw-ring-shadow: var(--tw-ring-inset) 0 0 0 calc({d}px + var(--tw-ring-offset-width, 0px)) var(--tw-ring-color, var(--ring));\n",
        .{n},
    );
    try w.writeAll("  --tw-ring-offset-shadow: var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width, 0px) var(--tw-ring-offset-color, #fff);\n");
    try writeBoxShadowChain(w);
    return true;
}

/// ring-{color} | ring-offset-{color} — sets the color CSS var only.
fn tryResolveRingColor(w: anytype, base: []const u8) !bool {
    if (std.mem.startsWith(u8, base, "ring-offset-")) {
        const color_name = base[12..];
        inline for (tokens.colors) |entry| {
            if (std.mem.eql(u8, color_name, entry[0])) {
                try w.print("  --tw-ring-offset-color: {s};\n", .{entry[1]});
                return true;
            }
        }
        return false;
    }
    if (std.mem.startsWith(u8, base, "ring-")) {
        const color_name = base[5..];
        inline for (tokens.colors) |entry| {
            if (std.mem.eql(u8, color_name, entry[0])) {
                try w.print("  --tw-ring-color: {s};\n", .{entry[1]});
                return true;
            }
        }
    }
    return false;
}

fn writeBoxShadowChain(w: anytype) !void {
    try w.writeAll("  box-shadow: var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow, 0 0 #0000);\n");
}

/// opacity-N → opacity: <decimal>. N comes from the opacity table (5%-step coverage).
fn tryResolveOpacityN(w: anytype, base: []const u8) !bool {
    if (!std.mem.startsWith(u8, base, "opacity-")) return false;
    const value_name = base[8..];
    inline for (tokens.opacity) |entry| {
        if (std.mem.eql(u8, value_name, entry[0])) {
            try w.print("  opacity: {s};\n", .{entry[1]});
            return true;
        }
    }
    return false;
}

/// z-N → z-index: N (Tailwind: 0, 10, 20, 30, 40, 50). Other integers also supported.
fn tryResolveZIndex(w: anytype, base: []const u8) !bool {
    if (!std.mem.startsWith(u8, base, "z-")) return false;
    const tail = base[2..];
    const n = std.fmt.parseInt(i32, tail, 10) catch return false;
    try w.print("  z-index: {d};\n", .{n});
    return true;
}

/// duration-N → transition-duration: Nms. Accepts any non-negative integer.
fn tryResolveDuration(w: anytype, base: []const u8) !bool {
    if (!std.mem.startsWith(u8, base, "duration-")) return false;
    const tail = base[9..];
    const n = std.fmt.parseInt(u32, tail, 10) catch return false;
    try w.print("  transition-duration: {d}ms;\n", .{n});
    return true;
}

/// inset-x-N → left + right; inset-y-N → top + bottom. Uses spacing scale.
fn tryResolveInsetAxis(w: anytype, base: []const u8) !bool {
    if (std.mem.startsWith(u8, base, "inset-x-")) {
        const value_name = base[8..];
        var buf: [32]u8 = undefined;
        if (formatSpacingValue(&buf, value_name)) |value| {
            try w.print("  left: {s};\n  right: {s};\n", .{ value, value });
            return true;
        }
    } else if (std.mem.startsWith(u8, base, "inset-y-")) {
        const value_name = base[8..];
        var buf: [32]u8 = undefined;
        if (formatSpacingValue(&buf, value_name)) |value| {
            try w.print("  top: {s};\n  bottom: {s};\n", .{ value, value });
            return true;
        }
    }
    return false;
}

/// border-N → border-width: Npx; border-{color} → border-color; border-{side}-{N|color} → border-side variants.
fn tryResolveBorder(w: anytype, base: []const u8) !bool {
    if (!std.mem.startsWith(u8, base, "border-")) return false;
    const tail = base[7..];

    // Side prefix (t/b/l/r/x/y) followed by `-`
    const Side = struct { name: []const u8, len: u32, props: []const []const u8 };
    const sides = [_]Side{
        .{ .name = "t-", .len = 2, .props = &.{"border-top"} },
        .{ .name = "b-", .len = 2, .props = &.{"border-bottom"} },
        .{ .name = "l-", .len = 2, .props = &.{"border-left"} },
        .{ .name = "r-", .len = 2, .props = &.{"border-right"} },
        .{ .name = "x-", .len = 2, .props = &.{ "border-left", "border-right" } },
        .{ .name = "y-", .len = 2, .props = &.{ "border-top", "border-bottom" } },
    };

    for (sides) |side| {
        if (std.mem.startsWith(u8, tail, side.name)) {
            const value_part = tail[side.len..];
            // Try numeric width
            if (std.fmt.parseInt(u32, value_part, 10)) |n| {
                for (side.props) |p| {
                    try w.print("  {s}-width: {d}px;\n", .{ p, n });
                }
                return true;
            } else |_| {}
            // Try color
            inline for (tokens.colors) |entry| {
                if (std.mem.eql(u8, value_part, entry[0])) {
                    for (side.props) |p| {
                        try w.print("  {s}-color: {s};\n", .{ p, entry[1] });
                    }
                    return true;
                }
            }
            return false;
        }
    }

    // No side: numeric width or color on whole border
    if (std.fmt.parseInt(u32, tail, 10)) |n| {
        try w.print("  border-width: {d}px;\n", .{n});
        return true;
    } else |_| {}

    inline for (tokens.colors) |entry| {
        if (std.mem.eql(u8, tail, entry[0])) {
            try w.print("  border-color: {s};\n", .{entry[1]});
            return true;
        }
    }
    return false;
}

/// translate-x-N | translate-y-N (with optional `-` prefix and `1/2`-style fractions).
fn tryResolveTranslate(w: anytype, raw_base: []const u8) !bool {
    var base = raw_base;
    var negative = false;
    if (base.len > 1 and base[0] == '-') {
        negative = true;
        base = base[1..];
    }
    const axis: u8 = if (std.mem.startsWith(u8, base, "translate-x-")) 'x'
        else if (std.mem.startsWith(u8, base, "translate-y-")) 'y'
        else return false;
    const value_name = base[12..];

    var value_buf: [32]u8 = undefined;
    var value: []const u8 = "";
    if (std.mem.indexOfScalar(u8, value_name, '/')) |slash| {
        // Fractional: 1/2 → 50%, 1/3 → 33.3333%, etc.
        const num = std.fmt.parseFloat(f64, value_name[0..slash]) catch return false;
        const den = std.fmt.parseFloat(f64, value_name[slash + 1 ..]) catch return false;
        if (den == 0) return false;
        const pct = (num / den) * 100.0;
        var tmp: [32]u8 = undefined;
        const fmt = std.fmt.bufPrint(&tmp, "{d:.4}", .{pct}) catch return false;
        var end = fmt.len;
        if (std.mem.indexOfScalar(u8, fmt, '.')) |_| {
            while (end > 0 and fmt[end - 1] == '0') : (end -= 1) {}
            if (end > 0 and fmt[end - 1] == '.') end -= 1;
        }
        if (end + 1 > value_buf.len) return false;
        std.mem.copyForwards(u8, value_buf[0..], fmt[0..end]);
        value_buf[end] = '%';
        value = value_buf[0 .. end + 1];
    } else if (formatSpacingValue(&value_buf, value_name)) |v| {
        value = v;
    } else {
        return false;
    }

    const sign: []const u8 = if (negative) "-" else "";
    if (axis == 'x') {
        try w.print("  transform: translateX({s}{s});\n", .{ sign, value });
    } else {
        try w.print("  transform: translateY({s}{s});\n", .{ sign, value });
    }
    return true;
}

/// rotate-N (with optional `-` prefix). Value in degrees.
fn tryResolveRotate(w: anytype, raw_base: []const u8) !bool {
    var base = raw_base;
    var negative = false;
    if (base.len > 1 and base[0] == '-') {
        negative = true;
        base = base[1..];
    }
    if (!std.mem.startsWith(u8, base, "rotate-")) return false;
    const tail = base[7..];
    const n = std.fmt.parseFloat(f64, tail) catch return false;
    const sign: []const u8 = if (negative) "-" else "";
    try w.print("  transform: rotate({s}{d}deg);\n", .{ sign, n });
    return true;
}

/// divide-y / divide-x — sets border between adjacent siblings.
/// divide-{color} — sets the border-color on those siblings.
fn tryDivideUtility(w: anytype, candidate: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, base, "divide-y")) {
        w.writeAll(".") catch return false;
        writeEscaped(w, candidate) catch return false;
        w.writeAll(" > :not([hidden]) ~ :not([hidden]) {\n  border-top-width: 1px;\n  border-style: solid;\n}\n") catch return false;
        return true;
    }
    if (std.mem.eql(u8, base, "divide-x")) {
        w.writeAll(".") catch return false;
        writeEscaped(w, candidate) catch return false;
        w.writeAll(" > :not([hidden]) ~ :not([hidden]) {\n  border-left-width: 1px;\n  border-style: solid;\n}\n") catch return false;
        return true;
    }
    // divide-{color}
    if (std.mem.startsWith(u8, base, "divide-")) {
        const color_name = base[7..];
        inline for (tokens.colors) |entry| {
            if (std.mem.eql(u8, color_name, entry[0])) {
                w.writeAll(".") catch return false;
                writeEscaped(w, candidate) catch return false;
                w.print(" > :not([hidden]) ~ :not([hidden]) {{\n  border-color: {s};\n}}\n", .{entry[1]}) catch return false;
                return true;
            }
        }
    }
    return false;
}

/// space-y-N / space-x-N — sets margin on adjacent siblings (selector includes child combinator).
/// Returns true if handled (writes the entire rule including selector).
fn trySpaceUtility(w: anytype, candidate: []const u8, variant: ?[]const u8, base: []const u8) bool {
    const is_y = std.mem.startsWith(u8, base, "space-y-");
    const is_x = std.mem.startsWith(u8, base, "space-x-");
    if (!is_y and !is_x) return false;
    const value_name = base[8..];
    var value_buf: [32]u8 = undefined;
    const value = formatSpacingValue(&value_buf, value_name) orelse return false;
    _ = variant; // Variants on space-y/x not yet supported; would need extra plumbing.

    w.writeAll(".") catch return false;
    writeEscaped(w, candidate) catch return false;
    w.writeAll(" > :not([hidden]) ~ :not([hidden]) {\n") catch return false;
    if (is_y) {
        w.print("  margin-top: {s};\n", .{value}) catch return false;
    } else {
        w.print("  margin-left: {s};\n", .{value}) catch return false;
    }
    w.writeAll("}\n") catch return false;
    return true;
}

fn tryResolveFunctional(w: anytype, base: []const u8) !bool {
    inline for (functional_utilities) |entry| {
        const prefix = entry[0];
        const property = entry[1];
        const scale = entry[2];

        if (base.len > prefix.len + 1 and
            std.mem.eql(u8, base[0..prefix.len], prefix) and
            base[prefix.len] == '-')
        {
            const value_name = base[prefix.len + 1 ..];

            inline for (scale) |token| {
                if (std.mem.eql(u8, value_name, token[0])) {
                    if (std.mem.eql(u8, property, "_color")) {
                        try w.print("  color: {s};\n", .{token[1]});
                    } else {
                        try w.print("  {s}: {s};\n", .{ property, token[1] });
                    }
                    return true;
                }
            }
        }
    }
    return false;
}

fn tryResolveTextSize(w: anytype, base: []const u8) !bool {
    if (!std.mem.startsWith(u8, base, "text-")) return false;
    const size_name = base[5..];

    inline for (tokens.font_size) |entry| {
        if (std.mem.eql(u8, size_name, entry[0])) {
            try w.print("  font-size: {s};\n", .{entry[1]});
            inline for (tokens.line_height_for_size) |lh| {
                if (std.mem.eql(u8, size_name, lh[0])) {
                    try w.print("  line-height: {s};\n", .{lh[1]});
                }
            }
            return true;
        }
    }
    return false;
}

fn tryResolveColorWithOpacity(w: anytype, color_part: []const u8, opacity_str: []const u8) !bool {
    var opacity_value: ?[]const u8 = null;
    inline for (tokens.opacity) |entry| {
        if (std.mem.eql(u8, opacity_str, entry[0])) {
            opacity_value = entry[1];
        }
    }
    if (opacity_value == null) return false;

    const Mapping = struct { prefix: []const u8, property: []const u8 };
    const mappings = [_]Mapping{
        .{ .prefix = "bg-", .property = "background-color" },
        .{ .prefix = "text-", .property = "color" },
        .{ .prefix = "border-", .property = "border-color" },
        .{ .prefix = "ring-", .property = "--tw-ring-color" },
    };

    for (mappings) |m| {
        if (std.mem.startsWith(u8, color_part, m.prefix)) {
            const color_name = color_part[m.prefix.len..];
            inline for (tokens.colors) |entry| {
                if (std.mem.eql(u8, color_name, entry[0])) {
                    try w.print("  {s}: color-mix(in oklch, {s} {s}%, transparent);\n", .{ m.property, entry[1], opacity_str });
                    return true;
                }
            }
            return false;
        }
    }
    return false;
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '[', ']', '(', ')', ',', ':', '/', '.', '=', '#', '%', '@', '!', '&', '?', '$' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => try w.writeByte(c),
        }
    }
}

/// Split a candidate into (variant, base) at the first colon outside square brackets.
/// `data-[publr-state=open]:bg-accent` → variant=`data-[publr-state=open]`, base=`bg-accent`.
/// Single-variant convenience — for stacked variants use `parseVariants`.
fn parseVariant(candidate: []const u8) struct { variant: ?[]const u8, base: []const u8 } {
    const i = findVariantSplit(candidate) orelse return .{ .variant = null, .base = candidate };
    return .{ .variant = candidate[0..i], .base = candidate[i + 1 ..] };
}

/// Find the index of the first colon outside square brackets, or null.
fn findVariantSplit(s: []const u8) ?usize {
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '[') {
            depth += 1;
        } else if (c == ']') {
            if (depth > 0) depth -= 1;
        } else if (c == ':' and depth == 0) {
            return i;
        }
    }
    return null;
}

const MAX_STACKED_VARIANTS = 8;

/// Parse all stacked variants and the base.
/// `disabled:hover:bg-foo` → variants = [disabled, hover], base = bg-foo.
/// `data-[k=v]:hover:foo` → variants = [data-[k=v], hover], base = foo.
fn parseVariants(candidate: []const u8) struct {
    variants: [MAX_STACKED_VARIANTS][]const u8,
    count: usize,
    base: []const u8,
} {
    var out: [MAX_STACKED_VARIANTS][]const u8 = undefined;
    var n: usize = 0;
    var rest = candidate;
    while (n < MAX_STACKED_VARIANTS) {
        const i = findVariantSplit(rest) orelse break;
        out[n] = rest[0..i];
        n += 1;
        rest = rest[i + 1 ..];
    }
    return .{ .variants = out, .count = n, .base = rest };
}

/// Build the selector for a candidate, supporting stacked variants.
/// Without variants: `.candidate`.
/// With variants: each one is applied as a suffix (`hover`, `data-[k=v]`, `placeholder`, etc.)
/// or as a parent-context prefix (`group-X` becomes `.group<X-suffix> .candidate`).
fn writeSelectorWithVariant(w: anytype, candidate: []const u8, variants: []const []const u8) !void {
    // First pass: pick out the (single) group-* parent context if present.
    var group_inner: ?[]const u8 = null;
    for (variants) |v| {
        if (std.mem.startsWith(u8, v, "group-")) {
            group_inner = v[6..];
            break;
        }
    }
    if (group_inner) |sub| {
        try w.writeAll(".group");
        try writeVariantSuffix(w, sub);
        try w.writeAll(" ");
    }

    try w.writeAll(".");
    try writeEscaped(w, candidate);

    // Apply non-group variants as selector suffixes (in declaration order).
    for (variants) |v| {
        if (std.mem.startsWith(u8, v, "group-")) continue;
        try writeVariantSuffix(w, v);
    }
}

/// Append the suffix that materializes a variant onto an already-written class selector.
/// For pseudo-classes: `:hover`. For data-attrs: `[data-k="v"]`. For pseudo-elements: `::placeholder`.
fn writeVariantSuffix(w: anytype, v: []const u8) !void {
    if (std.mem.eql(u8, v, "hover")) {
        try w.writeAll(":hover");
    } else if (std.mem.eql(u8, v, "focus")) {
        try w.writeAll(":focus");
    } else if (std.mem.eql(u8, v, "focus-visible")) {
        try w.writeAll(":focus-visible");
    } else if (std.mem.eql(u8, v, "active")) {
        try w.writeAll(":active");
    } else if (std.mem.eql(u8, v, "disabled")) {
        try w.writeAll(":disabled");
    } else if (std.mem.eql(u8, v, "first")) {
        try w.writeAll(":first-child");
    } else if (std.mem.eql(u8, v, "last")) {
        try w.writeAll(":last-child");
    } else if (std.mem.eql(u8, v, "placeholder")) {
        try w.writeAll("::placeholder");
    } else if (std.mem.startsWith(u8, v, "data-[") and v.len > 7 and v[v.len - 1] == ']') {
        const inside = v[6 .. v.len - 1];
        if (std.mem.indexOfScalar(u8, inside, '=')) |eq_pos| {
            try w.print("[data-{s}=\"{s}\"]", .{ inside[0..eq_pos], inside[eq_pos + 1 ..] });
        } else {
            try w.print("[data-{s}]", .{inside});
        }
    }
    // Unknown variants silently produce no suffix; the selector still matches the class itself.
}

// =============================================================================
// Tests
// =============================================================================

test "resolve static utility" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "flex")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".flex {\n  display: flex;\n}\n", css.items);
}

test "resolve numeric spacing — gap-1" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "gap-1")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".gap-1 {\n  gap: 0.25rem;\n}\n", css.items);
}

test "resolve numeric spacing — gap-1.5 (half-step)" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "gap-1.5")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".gap-1\\.5 {\n  gap: 0.375rem;\n}\n", css.items);
}

test "resolve numeric spacing — gap-4 (integer rem)" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "gap-4")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".gap-4 {\n  gap: 1rem;\n}\n", css.items);
}

test "resolve numeric spacing — p-px" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "p-px")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".p-px {\n  padding: 1px;\n}\n", css.items);
}

test "resolve numeric spacing — px-3 (multi)" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "px-3")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".px-3 {\n  padding-left: 0.75rem;\n  padding-right: 0.75rem;\n}\n", css.items);
}

test "resolve numeric sizing — w-56" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "w-56")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".w-56 {\n  width: 14rem;\n}\n", css.items);
}

test "resolve numeric sizing — h-px" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "h-px")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".h-px {\n  height: 1px;\n}\n", css.items);
}

test "resolve max-w named scale" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "max-w-md")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".max-w-md {\n  max-width: 28rem;\n}\n", css.items);
}

test "resolve grid-cols-4" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "grid-cols-4")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".grid-cols-4 {\n  grid-template-columns: repeat(4, minmax(0, 1fr));\n}\n", css.items);
}

test "resolve space-y-2" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "space-y-2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".space-y-2 > :not([hidden]) ~ :not([hidden]) {\n  margin-top: 0.5rem;\n}\n", css.items);
}

test "resolve space-x-1.5" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "space-x-1.5")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".space-x-1\\.5 > :not([hidden]) ~ :not([hidden]) {\n  margin-left: 0.375rem;\n}\n", css.items);
}

test "resolve arbitrary value" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "w-[380px]")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".w-\\[380px\\] {\n  width: 380px;\n}\n", css.items);
}

test "resolve arbitrary grid-cols" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "grid-cols-[repeat(auto-fill,minmax(200px,1fr))]")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".grid-cols-\\[repeat\\(auto-fill\\,minmax\\(200px\\,1fr\\)\\)\\] {\n  grid-template-columns: repeat(auto-fill,minmax(200px,1fr));\n}\n", css.items);
}

test "resolve color" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "bg-primary")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".bg-primary {\n  background-color: var(--primary);\n}\n", css.items);
}

test "resolve text color" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "text-muted-foreground")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".text-muted-foreground {\n  color: var(--muted-foreground);\n}\n", css.items);
}

test "resolve text size" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "text-sm")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".text-sm {\n  font-size: 0.875rem;\n  line-height: 1.25rem;\n}\n", css.items);
}

test "resolve hover variant" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "hover:bg-accent")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".hover\\:bg-accent:hover {\n  background-color: var(--accent);\n}\n", css.items);
}

test "resolve border shorthand" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "border-b")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".border-b {\n  border-bottom: 1px solid var(--border);\n}\n", css.items);
}

test "resolve unknown returns null" {
    const allocator = std.testing.allocator;
    const result = try resolve(allocator, "nonexistent-class");
    try std.testing.expect(result == null);
}

test "resolve font-bold" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "font-bold")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".font-bold {\n  font-weight: 700;\n}\n", css.items);
}

test "resolve font-normal" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "font-normal")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".font-normal {\n  font-weight: 400;\n}\n", css.items);
}

test "resolve shadow-md" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "shadow-md")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".shadow-md {\n  --tw-shadow: 0 2px 8px oklch(0 0 0 / 0.08);\n  box-shadow: var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow, 0 0 #0000);\n}\n",
        css.items,
    );
}

test "resolve ring-2" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "ring-2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".ring-2 {\n  --tw-ring-shadow: var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width, 0px)) var(--tw-ring-color, var(--ring));\n  --tw-ring-offset-shadow: var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width, 0px) var(--tw-ring-offset-color, #fff);\n  box-shadow: var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow, 0 0 #0000);\n}\n",
        css.items,
    );
}

test "resolve ring-offset-2" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "ring-offset-2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".ring-offset-2 {\n  --tw-ring-offset-width: 2px;\n  --tw-ring-offset-shadow: var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color, #fff);\n  box-shadow: var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow, 0 0 #0000);\n}\n",
        css.items,
    );
}

test "resolve ring-color" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "ring-error")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".ring-error {\n  --tw-ring-color: var(--error);\n}\n", css.items);
}

test "resolve ring-inset" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "ring-inset")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".ring-inset {\n  --tw-ring-inset: inset;\n}\n", css.items);
}

test "resolve data-attr variant — eq form" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "data-[publr-state=open]:block")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".data-\\[publr-state\\=open\\]\\:block[data-publr-state=\"open\"] {\n  display: block;\n}\n",
        css.items,
    );
}

test "resolve data-attr variant — bare form" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "data-[checked]:bg-primary")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".data-\\[checked\\]\\:bg-primary[data-checked] {\n  background-color: var(--primary);\n}\n",
        css.items,
    );
}

test "resolve placeholder variant" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "placeholder:text-muted-foreground")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".placeholder\\:text-muted-foreground::placeholder {\n  color: var(--muted-foreground);\n}\n",
        css.items,
    );
}

test "resolve group-hover variant" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "group-hover:bg-accent")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".group:hover .group-hover\\:bg-accent {\n  background-color: var(--accent);\n}\n",
        css.items,
    );
}

test "resolve group-data variant" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "group-data-[publr-state=open]:block")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".group[data-publr-state=\"open\"] .group-data-\\[publr-state\\=open\\]\\:block {\n  display: block;\n}\n",
        css.items,
    );
}

test "resolve disabled variant on numeric spacing" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "disabled:gap-2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".disabled\\:gap-2:disabled {\n  gap: 0.5rem;\n}\n",
        css.items,
    );
}

test "resolve opacity-50" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "opacity-50")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".opacity-50 {\n  opacity: 0.5;\n}\n", css.items);
}

test "resolve z-50" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "z-50")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".z-50 {\n  z-index: 50;\n}\n", css.items);
}

test "resolve duration-200" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "duration-200")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".duration-200 {\n  transition-duration: 200ms;\n}\n", css.items);
}

test "resolve inset-0 (static)" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "inset-0")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".inset-0 {\n  inset: 0;\n}\n", css.items);
}

test "resolve inset-y-2" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "inset-y-2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".inset-y-2 {\n  top: 0.5rem;\n  bottom: 0.5rem;\n}\n",
        css.items,
    );
}

test "resolve border-2 width" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "border-2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".border-2 {\n  border-width: 2px;\n}\n", css.items);
}

test "resolve border-input color" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "border-input")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".border-input {\n  border-color: var(--input);\n}\n", css.items);
}

test "resolve border-t-2 width" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "border-t-2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".border-t-2 {\n  border-top-width: 2px;\n}\n", css.items);
}

test "resolve translate-x-4" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "translate-x-4")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".translate-x-4 {\n  transform: translateX(1rem);\n}\n", css.items);
}

test "resolve translate-y-1/2 fractional" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "translate-y-1/2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".translate-y-1\\/2 {\n  transform: translateY(50%);\n}\n",
        css.items,
    );
}

test "resolve negative translate-y-1/2" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "-translate-y-1/2")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".-translate-y-1\\/2 {\n  transform: translateY(-50%);\n}\n",
        css.items,
    );
}

test "resolve rotate-45" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "rotate-45")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(".rotate-45 {\n  transform: rotate(45deg);\n}\n", css.items);
}

test "resolve outline-none (static)" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "outline-none")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".outline-none {\n  outline: 2px solid transparent;\n}\n",
        css.items,
    );
}

test "resolve transition-all (static)" {
    const allocator = std.testing.allocator;
    var css = (try resolve(allocator, "transition-all")).?;
    defer css.deinit(allocator);
    try std.testing.expectEqualStrings(
        ".transition-all {\n  transition-property: all;\n}\n",
        css.items,
    );
}
