/// Tailwind class candidate parser.
///
/// Ported from upstream tailwindcss/packages/tailwindcss/src/candidate.ts
/// (~1100 lines TS → ~600 lines Zig). Configuration-free: produces all
/// possible structural interpretations of an input class string. The consumer
/// (utility/variant tables, task-05/06) disambiguates by checking which root
/// is registered.
///
/// Coverage in this version (Phase 1 of jit-tailwind-engine epic):
///   - Static utilities (flex, block, etc.)
///   - Functional utilities (bg-red-500, w-1/2)
///   - Arbitrary values (bg-[#abc], w-[calc(100%-1rem)])
///   - Parens-arbitrary values (bg-(--my-var), bg-(color:--my-var))
///   - Arbitrary properties ([color:red])
///   - Modifiers (named: /50, arbitrary: /[0.9], parens: /(--my-var))
///   - Important markers (trailing `!`, leading `!` legacy syntax)
///   - Static variants (hover:, focus:)
///   - Functional variants (md:, data-[state=open]:, aria-[busy=true]:)
///   - Compound variants (group-hover:, peer-focus:, named: group/foo:hover:)
///   - Arbitrary variants ([selector]:, [&_p]:, [@media...]:)
///   - Stacked variants (md:hover:focus:)
///
/// Deferred to follow-up:
///   - Container queries (@container, @sm: inside container contexts)
///   - not-*, has-*, in-* compound forwarding
///   - Some niche edge cases around relative selectors
///
/// Memory model: parser takes an allocator; returns an array of Candidates.
/// Slices inside the candidates point into the input string OR the allocator's
/// memory. Caller frees by passing the same allocator to `freeCandidates`.

const std = @import("std");

// ── Types ───────────────────────────────────────────────────────────────────

pub const ArbitraryUtilityValue = struct {
    /// Type hint, e.g. `color` in `bg-[color:var(--my-color)]`.
    data_type: ?[]const u8,
    value: []const u8,
};

pub const NamedUtilityValue = struct {
    value: []const u8,
    /// For fractions like `w-1/2`, this stores `1/2`. Otherwise null.
    fraction: ?[]const u8,
};

pub const UtilityValueKind = enum { named, arbitrary };

pub const UtilityValue = union(UtilityValueKind) {
    named: NamedUtilityValue,
    arbitrary: ArbitraryUtilityValue,
};

pub const ModifierKind = enum { named, arbitrary };

pub const Modifier = union(ModifierKind) {
    /// `bg-red-500/50` — `value` is `"50"`.
    named: []const u8,
    /// `bg-red-500/[50%]` or `bg-red-500/(--var)` — `value` is `"50%"` or `"var(--var)"`.
    arbitrary: []const u8,
};

pub const VariantKind = enum { static_v, functional, compound, arbitrary };

/// Variant tags.
/// `static_v` instead of `static` to avoid the Zig keyword.
pub const Variant = union(VariantKind) {
    static_v: struct { root: []const u8 },
    functional: struct {
        root: []const u8,
        value: ?VariantValue,
        modifier: ?Modifier,
    },
    compound: struct {
        root: []const u8,
        /// Named-group variant suffix. `group/foo:hover` → modifier = "foo" (named).
        modifier: ?Modifier,
        variant: *Variant,
    },
    arbitrary: struct {
        selector: []const u8,
        relative: bool,
    },
};

pub const VariantValueKind = enum { named, arbitrary };

pub const VariantValue = union(VariantValueKind) {
    named: []const u8,
    arbitrary: []const u8,
};

pub const CandidateKind = enum { static_c, functional, arbitrary };

pub const Candidate = union(CandidateKind) {
    static_c: struct {
        root: []const u8,
        variants: []const Variant,
        important: bool,
        raw: []const u8,
    },
    functional: struct {
        root: []const u8,
        value: ?UtilityValue,
        modifier: ?Modifier,
        variants: []const Variant,
        important: bool,
        raw: []const u8,
    },
    arbitrary: struct {
        property: []const u8,
        value: []const u8,
        modifier: ?Modifier,
        variants: []const Variant,
        important: bool,
        raw: []const u8,
    },
};

// ── Public entry point ──────────────────────────────────────────────────────

pub const ParseError = error{OutOfMemory};

/// Parse a class string into all possible structural interpretations.
/// Returns an empty slice if the input is structurally invalid.
/// Caller owns the returned slice; the allocator is also used for nested
/// allocations (variants, etc.).
pub fn parseCandidate(allocator: std.mem.Allocator, input: []const u8) ParseError![]Candidate {
    var results = std.array_list.Managed(Candidate).init(allocator);
    errdefer results.deinit();

    if (input.len == 0) return results.toOwnedSlice();

    // Split on `:` outside brackets to separate stacked variants from base.
    var raw_variants = try segmentColon(allocator, input);
    defer allocator.free(raw_variants);

    if (raw_variants.len == 0) return results.toOwnedSlice();

    var base = raw_variants[raw_variants.len - 1];
    const variant_strs = raw_variants[0 .. raw_variants.len - 1];

    // Parse variants in reverse (innermost first per upstream's convention).
    var parsed_variants = std.array_list.Managed(Variant).init(allocator);
    errdefer parsed_variants.deinit();

    var i = variant_strs.len;
    while (i > 0) {
        i -= 1;
        const v = parseVariant(allocator, variant_strs[i]) catch return ParseError.OutOfMemory;
        if (v == null) return results.toOwnedSlice(); // unparseable variant → no candidates
        try parsed_variants.append(v.?);
    }
    // `variants_master` is a single owned copy; we deep-clone it for each yielded
    // candidate so freeCandidates can free per-candidate without double-freeing.
    const variants_master = try parsed_variants.toOwnedSlice();
    defer {
        for (variants_master) |v| freeVariant(allocator, v);
        allocator.free(variants_master);
    }

    // Important detection: trailing `!` (preferred), or legacy leading `!`.
    var important = false;
    if (base.len > 0 and base[base.len - 1] == '!') {
        important = true;
        base = base[0 .. base.len - 1];
    } else if (base.len > 0 and base[0] == '!') {
        important = true;
        base = base[1..];
    }

    if (base.len == 0) return results.toOwnedSlice();

    // Try a pure static interpretation first (e.g. `flex` could be a static utility).
    // Skip if the base contains `[`, `(`, or `/` — those signal arbitrary / parens /
    // modifier forms which can never be a static utility name on their own.
    if (std.mem.indexOfScalar(u8, base, '[') == null and
        std.mem.indexOfScalar(u8, base, '(') == null and
        std.mem.indexOfScalar(u8, base, '/') == null)
    {
        try results.append(.{ .static_c = .{
            .root = base,
            .variants = try cloneVariants(allocator, variants_master),
            .important = important,
            .raw = input,
        } });
    }

    // Modifier slash split (top-level only, outside brackets/parens).
    var base_no_mod = base;
    var modifier_str: ?[]const u8 = null;
    {
        const slash_parts = try segmentByte(allocator, base, '/');
        defer allocator.free(slash_parts);
        // 0 or 1 segments: no modifier. Exactly 2 parts: name/modifier. >2 parts: invalid.
        if (slash_parts.len == 2) {
            base_no_mod = slash_parts[0];
            modifier_str = slash_parts[1];
        } else if (slash_parts.len > 2) {
            return results.toOwnedSlice();
        }
    }

    // Parse modifier if present. `parsed_modifier_master` is the single owned copy;
    // each yield clones it so freeCandidates can free per-candidate.
    var parsed_modifier_master: ?Modifier = null;
    defer if (parsed_modifier_master) |m| freeModifier(allocator, m);
    if (modifier_str) |m| {
        parsed_modifier_master = try parseModifier(allocator, m);
        if (parsed_modifier_master == null) return results.toOwnedSlice(); // empty/invalid
    }

    // Arbitrary properties: `[color:red]` or `[--var:1px]`.
    if (base_no_mod.len >= 2 and base_no_mod[0] == '[' and base_no_mod[base_no_mod.len - 1] == ']') {
        const inner = base_no_mod[1 .. base_no_mod.len - 1];
        // Property must start with a-z or `-` (vendor prefix).
        if (inner.len == 0) return results.toOwnedSlice();
        const c0 = inner[0];
        if (!(c0 == '-' or (c0 >= 'a' and c0 <= 'z'))) return results.toOwnedSlice();
        const colon_idx = std.mem.indexOfScalar(u8, inner, ':') orelse return results.toOwnedSlice();
        if (colon_idx == 0 or colon_idx == inner.len - 1) return results.toOwnedSlice();
        const property = inner[0..colon_idx];
        const value_raw = inner[colon_idx + 1 ..];
        const value = try decodeArbitrary(allocator, value_raw);
        if (!isValidArbitrary(value)) {
            allocator.free(value);
            return results.toOwnedSlice();
        }
        try results.append(.{ .arbitrary = .{
            .property = property,
            .value = value,
            .modifier = if (parsed_modifier_master) |m| try cloneModifier(allocator, m) else null,
            .variants = try cloneVariants(allocator, variants_master),
            .important = important,
            .raw = input,
        } });
        return results.toOwnedSlice();
    }

    // Functional with `[...]` arbitrary value.
    if (base_no_mod.len > 0 and base_no_mod[base_no_mod.len - 1] == ']') {
        const idx = std.mem.indexOf(u8, base_no_mod, "-[") orelse return results.toOwnedSlice();
        const root = base_no_mod[0..idx];
        const arbitrary_raw = base_no_mod[idx + 2 .. base_no_mod.len - 1];
        const decoded = try decodeArbitrary(allocator, arbitrary_raw);
        if (!isValidArbitrary(decoded)) {
            allocator.free(decoded);
            return results.toOwnedSlice();
        }
        if (decoded.len == 0 or std.mem.trim(u8, decoded, " \t\n\r").len == 0) {
            allocator.free(decoded);
            return results.toOwnedSlice();
        }

        // Extract a typehint if present: `bg-[color:var(--x)]` → typehint=`color`.
        var data_type: ?[]const u8 = null;
        var value_str: []const u8 = decoded;
        var th_idx: usize = 0;
        while (th_idx < decoded.len) : (th_idx += 1) {
            const c = decoded[th_idx];
            if (c == ':') {
                data_type = decoded[0..th_idx];
                value_str = decoded[th_idx + 1 ..];
                break;
            }
            // Typehint chars: lowercase or `-`.
            if (c == '-' or (c >= 'a' and c <= 'z')) continue;
            break;
        }

        try results.append(.{ .functional = .{
            .root = root,
            .value = .{ .arbitrary = .{ .data_type = data_type, .value = value_str } },
            .modifier = if (parsed_modifier_master) |m| try cloneModifier(allocator, m) else null,
            .variants = try cloneVariants(allocator, variants_master),
            .important = important,
            .raw = input,
        } });
        return results.toOwnedSlice();
    }

    // Functional with `(--var)` parens-arbitrary value.
    if (base_no_mod.len > 0 and base_no_mod[base_no_mod.len - 1] == ')') {
        const idx = std.mem.indexOf(u8, base_no_mod, "-(") orelse return results.toOwnedSlice();
        const root = base_no_mod[0..idx];
        const inner = base_no_mod[idx + 2 .. base_no_mod.len - 1];
        // Optional typehint via `:` separator inside the parens.
        var data_type: ?[]const u8 = null;
        var var_name: []const u8 = inner;
        if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
            data_type = inner[0..colon];
            var_name = inner[colon + 1 ..];
        }
        // Var name must start with `--`.
        if (var_name.len < 2 or var_name[0] != '-' or var_name[1] != '-') return results.toOwnedSlice();
        if (!isValidArbitrary(var_name)) return results.toOwnedSlice();

        // Wrap in `var(...)` to form the arbitrary CSS value.
        const wrapped = try std.fmt.allocPrint(allocator, "var({s})", .{var_name});
        try results.append(.{ .functional = .{
            .root = root,
            .value = .{ .arbitrary = .{ .data_type = data_type, .value = wrapped } },
            .modifier = if (parsed_modifier_master) |m| try cloneModifier(allocator, m) else null,
            .variants = try cloneVariants(allocator, variants_master),
            .important = important,
            .raw = input,
        } });
        return results.toOwnedSlice();
    }

    // Functional with named value. Yield all possible (root, value) splits at
    // hyphen positions, right-to-left. Plus the no-value form (full base = root).
    // Consumer disambiguates via utility table presence.
    {
        var idx = std.mem.lastIndexOfScalar(u8, base_no_mod, '-');
        while (idx != null and idx.? > 0) {
            const root = base_no_mod[0..idx.?];
            const value_part = base_no_mod[idx.? + 1 ..];
            if (value_part.len == 0) break; // `bg-` is invalid

            if (!isValidNamedValue(value_part)) {
                idx = std.mem.lastIndexOfScalar(u8, base_no_mod[0..idx.?], '-');
                continue;
            }

            // Compute fraction string if a modifier exists alongside (e.g. `w-1/2`):
            // upstream stores `${value}/${modifierSegment}` in the fraction field.
            // We don't have access to modifier_str directly here unless we capture it.
            const fraction: ?[]const u8 = blk: {
                if (modifier_str == null) break :blk null;
                if (parsed_modifier_master != null and parsed_modifier_master.? == .arbitrary) break :blk null;
                break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ value_part, modifier_str.? });
            };

            try results.append(.{ .functional = .{
                .root = root,
                .value = .{ .named = .{ .value = value_part, .fraction = fraction } },
                .modifier = if (parsed_modifier_master) |m| try cloneModifier(allocator, m) else null,
                .variants = try cloneVariants(allocator, variants_master),
                .important = important,
                .raw = input,
            } });

            idx = std.mem.lastIndexOfScalar(u8, base_no_mod[0..idx.?], '-');
        }
    }

    return results.toOwnedSlice();
}

// ── Variant parsing ─────────────────────────────────────────────────────────

/// Like `std.mem.lastIndexOfScalar(u8, s, '-')` but ignores dashes that sit
/// inside `[…]` or `(…)` so e.g. `data-[publr-state=open]` splits between
/// `data` and the bracketed value, not at the `-` inside `publr-state`.
fn lastIndexOfDashOutsideBrackets(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        const c = s[i];
        switch (c) {
            ']', ')' => depth += 1,
            '[', '(' => depth -= 1,
            '-' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

pub fn parseVariant(allocator: std.mem.Allocator, input: []const u8) ParseError!?Variant {
    if (input.len == 0) return null;

    // Arbitrary variants: `[selector]`, `[&:hover]`, `[@media (...)]`.
    if (input[0] == '[' and input[input.len - 1] == ']') {
        // Upstream rejects `[@media(...){&:hover}]` (combined at-rules + selector).
        if (input.len > 1 and input[1] == '@' and std.mem.indexOfScalar(u8, input, '&') != null) return null;
        const inner = input[1 .. input.len - 1];
        const decoded = try decodeArbitrary(allocator, inner);
        if (!isValidArbitrary(decoded) or decoded.len == 0 or std.mem.trim(u8, decoded, " \t\n\r").len == 0) {
            allocator.free(decoded);
            return null;
        }
        const relative = decoded.len > 0 and (decoded[0] == '>' or decoded[0] == '+' or decoded[0] == '~');
        var selector: []const u8 = decoded;
        // If not a relative selector and not an at-rule, wrap in `&:is(…)` for the `&` requirement.
        if (!relative and decoded.len > 0 and decoded[0] != '@' and std.mem.indexOfScalar(u8, decoded, '&') == null) {
            const wrapped = try std.fmt.allocPrint(allocator, "&:is({s})", .{decoded});
            allocator.free(decoded);
            selector = wrapped;
        }
        return .{ .arbitrary = .{ .selector = selector, .relative = relative } };
    }

    // Static, functional, compound — split on `/` for modifier.
    const slash_parts = try segmentByte(allocator, input, '/');
    defer allocator.free(slash_parts);
    if (slash_parts.len > 2) return null;
    const without_modifier = if (slash_parts.len == 0) input else slash_parts[0];
    const modifier_str = if (slash_parts.len == 2) slash_parts[1] else null;

    const parsed_modifier: ?Modifier = if (modifier_str) |m| try parseModifier(allocator, m) else null;
    if (modifier_str != null and parsed_modifier == null) return null;

    // For compound variants (group-, peer-, etc.), the upstream parser splits on
    // the first `-` to find the compound root, then recursively parses the rest.
    // We try a few well-known compound roots.
    const compound_roots = [_][]const u8{ "group", "peer", "in", "has", "not", "supports" };
    for (compound_roots) |cr| {
        if (std.mem.startsWith(u8, without_modifier, cr) and
            without_modifier.len > cr.len and
            without_modifier[cr.len] == '-')
        {
            const sub = without_modifier[cr.len + 1 ..];
            const sub_parsed = try parseVariant(allocator, sub);
            if (sub_parsed == null) return null;
            const heap_sub = try allocator.create(Variant);
            heap_sub.* = sub_parsed.?;
            return .{ .compound = .{
                .root = cr,
                .modifier = parsed_modifier,
                .variant = heap_sub,
            } };
        }
    }

    // Otherwise: static or functional variant.
    // For Phase 1 we yield just the most-specific match: full `without_modifier`
    // as static, plus the rightmost dash split as functional. Consumer (variant
    // table, task-06) determines which is real.
    //
    // Use a bracket-aware lastIndexOf — a plain `lastIndexOfScalar` would find
    // the `-` *inside* `[publr-state=open]` and break `data-[publr-state=open]`
    // into `data-[publr` + `state=open]`, neither of which parses. Symptom:
    // `group-data-[publr-state=open]:opacity-100` silently drops out of the
    // JIT manifest and Dialog's overlay never opens.
    if (lastIndexOfDashOutsideBrackets(without_modifier)) |dash_idx| {
        if (dash_idx > 0 and dash_idx < without_modifier.len - 1) {
            const root = without_modifier[0..dash_idx];
            const value_str = without_modifier[dash_idx + 1 ..];
            // Functional value can be arbitrary `[...]`, parens `(...)`, or named.
            var v_value: ?VariantValue = null;
            if (value_str.len >= 2 and value_str[0] == '[' and value_str[value_str.len - 1] == ']') {
                const inner = value_str[1 .. value_str.len - 1];
                const decoded = try decodeArbitrary(allocator, inner);
                if (!isValidArbitrary(decoded) or decoded.len == 0 or std.mem.trim(u8, decoded, " \t\n\r").len == 0) {
                    allocator.free(decoded);
                    return null;
                }
                v_value = .{ .arbitrary = decoded };
            } else if (value_str.len >= 2 and value_str[0] == '(' and value_str[value_str.len - 1] == ')') {
                const inner = value_str[1 .. value_str.len - 1];
                if (inner.len < 2 or inner[0] != '-' or inner[1] != '-') return null;
                const wrapped = try std.fmt.allocPrint(allocator, "var({s})", .{inner});
                v_value = .{ .arbitrary = wrapped };
            } else if (isValidNamedValue(value_str)) {
                v_value = .{ .named = value_str };
            } else {
                return null;
            }
            return .{ .functional = .{
                .root = root,
                .value = v_value,
                .modifier = parsed_modifier,
            } };
        }
    }

    // Pure static variant (no value, no dash split).
    if (parsed_modifier != null) return null; // static variants don't take modifiers
    return .{ .static_v = .{ .root = without_modifier } };
}

// ── Modifier parsing ────────────────────────────────────────────────────────

pub fn parseModifier(allocator: std.mem.Allocator, input: []const u8) ParseError!?Modifier {
    if (input.len == 0) return null;
    // Arbitrary `[...]`
    if (input[0] == '[' and input[input.len - 1] == ']') {
        const inner = input[1 .. input.len - 1];
        const decoded = try decodeArbitrary(allocator, inner);
        if (!isValidArbitrary(decoded) or decoded.len == 0 or std.mem.trim(u8, decoded, " \t\n\r").len == 0) {
            allocator.free(decoded);
            return null;
        }
        return .{ .arbitrary = decoded };
    }
    // Parens `(--var)`
    if (input[0] == '(' and input[input.len - 1] == ')') {
        const inner = input[1 .. input.len - 1];
        if (inner.len < 2 or inner[0] != '-' or inner[1] != '-') return null;
        if (!isValidArbitrary(inner)) return null;
        const wrapped = try std.fmt.allocPrint(allocator, "var({s})", .{inner});
        return .{ .arbitrary = wrapped };
    }
    // Named
    if (!isValidNamedValue(input)) return null;
    return .{ .named = input };
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Split a string on `:` at top level (not inside `[]` or `()`).
/// Returns owned slice of subslices.
fn segmentColon(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    return segmentByte(allocator, input, ':');
}

fn segmentByte(allocator: std.mem.Allocator, input: []const u8, delim: u8) ![][]const u8 {
    var parts = std.array_list.Managed([]const u8).init(allocator);
    errdefer parts.deinit();

    var depth_sq: u32 = 0;
    var depth_pa: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (c) {
            '[' => depth_sq += 1,
            ']' => if (depth_sq > 0) {
                depth_sq -= 1;
            },
            '(' => depth_pa += 1,
            ')' => if (depth_pa > 0) {
                depth_pa -= 1;
            },
            else => {},
        }
        if (c == delim and depth_sq == 0 and depth_pa == 0) {
            try parts.append(input[start..i]);
            start = i + 1;
        }
    }
    if (start <= input.len) try parts.append(input[start..]);
    return parts.toOwnedSlice();
}

/// Decode an arbitrary value: replace `_` with ` ` (unless escaped as `\_`).
/// Caller owns the returned slice.
fn decodeArbitrary(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '\\' and i + 1 < input.len and input[i + 1] == '_') {
            try out.append('_');
            i += 1;
            continue;
        }
        if (c == '_') {
            try out.append(' ');
            continue;
        }
        try out.append(c);
    }
    const decoded = try out.toOwnedSlice();
    defer allocator.free(decoded);
    // CSS `calc()`, `min()`, `max()`, `clamp()` require whitespace around the
    // binary `+` and `-` operators. Tailwind users often write `calc(50%-4rem)`
    // expecting it to work — upstream canonicalizes by inserting spaces. We do
    // the same. The sign of a unary `-` (e.g. `-4rem` at the start of an arg)
    // stays untouched: a `-` is only treated as binary when the preceding
    // non-space char is a digit, `%`, `)`, or letter.
    return try canonicalizeCalcOps(allocator, decoded);
}

fn canonicalizeCalcOps(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    // Stack of "is this nested paren a math function?" booleans. Only inside
    // calc/min/max/clamp/mod/rem do we space out `+`/`-`. Inside `var(...)`,
    // `url(...)`, etc., a `-` is part of an identifier and must stay glued.
    var stack: std.array_list.Managed(bool) = .init(allocator);
    defer stack.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '(') {
            // Determine if this opening paren belongs to a math fn — look at
            // the trailing identifier in `out` (already-emitted chars).
            const is_math = endsWithMathFn(out.items);
            try stack.append(is_math);
            try out.append(c);
            continue;
        }
        if (c == ')') {
            if (stack.items.len > 0) _ = stack.pop();
            try out.append(c);
            continue;
        }

        const in_math = stack.items.len > 0 and stack.items[stack.items.len - 1];
        if (in_math and (c == '+' or c == '-')) {
            // Look at the previous non-space char to decide unary vs binary.
            var j: usize = out.items.len;
            while (j > 0 and out.items[j - 1] == ' ') : (j -= 1) {}
            if (j > 0) {
                const p = out.items[j - 1];
                const is_binary = (p >= '0' and p <= '9') or
                    (p >= 'a' and p <= 'z') or (p >= 'A' and p <= 'Z') or
                    p == '%' or p == ')';
                if (is_binary) {
                    if (out.items.len == 0 or out.items[out.items.len - 1] != ' ') {
                        try out.append(' ');
                    }
                    try out.append(c);
                    var k = i + 1;
                    while (k < input.len and input[k] == ' ') : (k += 1) {}
                    try out.append(' ');
                    i = k - 1;
                    continue;
                }
            }
        }
        try out.append(c);
    }
    return out.toOwnedSlice();
}

fn endsWithMathFn(buf: []const u8) bool {
    const fns = [_][]const u8{ "calc", "min", "max", "clamp", "mod", "rem", "round", "abs", "sign", "hypot" };
    for (fns) |f| {
        if (buf.len >= f.len) {
            const tail = buf[buf.len - f.len ..];
            if (std.mem.eql(u8, tail, f)) {
                // Make sure it's not a suffix of a longer ident (e.g. `mycalc`).
                if (buf.len == f.len) return true;
                const before = buf[buf.len - f.len - 1];
                const is_ident = (before >= 'a' and before <= 'z') or
                    (before >= 'A' and before <= 'Z') or
                    (before >= '0' and before <= '9') or before == '-' or before == '_';
                if (!is_ident) return true;
            }
        }
    }
    return false;
}

fn isValidArbitrary(input: []const u8) bool {
    // Reject `;` and `}` at the top level (outside parens/brackets).
    var depth_sq: u32 = 0;
    var depth_pa: u32 = 0;
    for (input) |c| {
        switch (c) {
            '[' => depth_sq += 1,
            ']' => if (depth_sq > 0) {
                depth_sq -= 1;
            },
            '(' => depth_pa += 1,
            ')' => if (depth_pa > 0) {
                depth_pa -= 1;
            },
            ';', '}' => if (depth_sq == 0 and depth_pa == 0) return false,
            else => {},
        }
    }
    return true;
}

fn isValidNamedValue(s: []const u8) bool {
    // /^[a-zA-Z0-9_.%-]+$/
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '.' or c == '%' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Deep-clone a single Variant. Allocates new heap memory for any inner
/// strings (arbitrary selectors, arbitrary values, modifier strings) and
/// for the inner Variant pointer of compound variants.
pub fn cloneVariant(allocator: std.mem.Allocator, v: Variant) ParseError!Variant {
    return switch (v) {
        .static_v => |s| .{ .static_v = .{ .root = s.root } },
        .functional => |f| blk: {
            var new_value: ?VariantValue = null;
            if (f.value) |val| switch (val) {
                .named => |n| new_value = .{ .named = n },
                .arbitrary => |a| {
                    const dup = try allocator.dupe(u8, a);
                    new_value = .{ .arbitrary = dup };
                },
            };
            const new_modifier: ?Modifier = if (f.modifier) |m| try cloneModifier(allocator, m) else null;
            break :blk .{ .functional = .{
                .root = f.root,
                .value = new_value,
                .modifier = new_modifier,
            } };
        },
        .compound => |c| blk: {
            const inner = try cloneVariant(allocator, c.variant.*);
            const heap_inner = try allocator.create(Variant);
            heap_inner.* = inner;
            const new_modifier: ?Modifier = if (c.modifier) |m| try cloneModifier(allocator, m) else null;
            break :blk .{ .compound = .{
                .root = c.root,
                .modifier = new_modifier,
                .variant = heap_inner,
            } };
        },
        .arbitrary => |a| blk: {
            const dup = try allocator.dupe(u8, a.selector);
            break :blk .{ .arbitrary = .{ .selector = dup, .relative = a.relative } };
        },
    };
}

fn cloneModifier(allocator: std.mem.Allocator, m: Modifier) ParseError!Modifier {
    return switch (m) {
        .named => |n| .{ .named = n },
        .arbitrary => |a| .{ .arbitrary = try allocator.dupe(u8, a) },
    };
}

/// Deep-clone a variants slice. Each candidate owns its own copy.
fn cloneVariants(allocator: std.mem.Allocator, variants: []const Variant) ParseError![]Variant {
    const out = try allocator.alloc(Variant, variants.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) freeVariant(allocator, out[j]);
        allocator.free(out);
    }
    while (i < variants.len) : (i += 1) {
        out[i] = try cloneVariant(allocator, variants[i]);
    }
    return out;
}

/// Free a Candidate slice and any heap-allocated content within.
/// Frees variants array, decoded arbitrary values, fractions, and recursively
/// frees compound variants' inner Variant pointers.
pub fn freeCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |c| {
        switch (c) {
            .static_c => |s| freeVariants(allocator, s.variants),
            .functional => |f| {
                freeVariants(allocator, f.variants);
                if (f.value) |v| freeUtilityValue(allocator, v);
                if (f.modifier) |m| freeModifier(allocator, m);
            },
            .arbitrary => |a| {
                freeVariants(allocator, a.variants);
                allocator.free(a.value);
                if (a.modifier) |m| freeModifier(allocator, m);
            },
        }
    }
    allocator.free(candidates);
}

fn freeVariants(allocator: std.mem.Allocator, variants: []const Variant) void {
    for (variants) |v| freeVariant(allocator, v);
    allocator.free(variants);
}

fn freeVariant(allocator: std.mem.Allocator, v: Variant) void {
    switch (v) {
        .static_v => {},
        .functional => |f| {
            if (f.value) |val| switch (val) {
                .named => {},
                .arbitrary => |s| allocator.free(s),
            };
            if (f.modifier) |m| freeModifier(allocator, m);
        },
        .compound => |c| {
            freeVariant(allocator, c.variant.*);
            allocator.destroy(c.variant);
            if (c.modifier) |m| freeModifier(allocator, m);
        },
        .arbitrary => |a| allocator.free(a.selector),
    }
}

fn freeUtilityValue(allocator: std.mem.Allocator, v: UtilityValue) void {
    switch (v) {
        .named => |n| {
            if (n.fraction) |f| allocator.free(f);
        },
        .arbitrary => |a| allocator.free(a.value),
    }
}

fn freeModifier(allocator: std.mem.Allocator, m: Modifier) void {
    switch (m) {
        .named => {},
        .arbitrary => |s| allocator.free(s),
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

fn expectStaticRoot(input: []const u8, expected_root: []const u8) !void {
    const cands = try parseCandidate(t.allocator, input);
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len > 0);
    // Find the static interpretation (parser yields static + functional splits).
    for (cands) |c| {
        if (c == .static_c) {
            try t.expectEqualStrings(expected_root, c.static_c.root);
            return;
        }
    }
    return error.NoStaticCandidate;
}

test "parseCandidate: simple static" {
    try expectStaticRoot("flex", "flex");
    try expectStaticRoot("block", "block");
    try expectStaticRoot("hidden", "hidden");
}

test "parseCandidate: functional named value" {
    const cands = try parseCandidate(t.allocator, "bg-red-500");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len >= 2); // static "bg-red-500" + functional splits
    // Find functional with root "bg" and value "red-500"
    var found = false;
    for (cands) |c| {
        if (c == .functional and std.mem.eql(u8, c.functional.root, "bg")) {
            try t.expectEqualStrings("red-500", c.functional.value.?.named.value);
            found = true;
        }
    }
    try t.expect(found);
}

test "parseCandidate: functional with arbitrary value" {
    const cands = try parseCandidate(t.allocator, "bg-[#0088cc]");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len >= 1);
    const c = cands[0];
    try t.expect(c == .functional);
    try t.expectEqualStrings("bg", c.functional.root);
    try t.expect(c.functional.value.? == .arbitrary);
    try t.expectEqualStrings("#0088cc", c.functional.value.?.arbitrary.value);
}

test "parseCandidate: arbitrary value with calc" {
    const cands = try parseCandidate(t.allocator, "w-[calc(100%-1rem)]");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len >= 1);
    // Canonicalization inserts spaces around binary `-` per CSS calc() spec.
    try t.expectEqualStrings("calc(100% - 1rem)", cands[0].functional.value.?.arbitrary.value);
}

test "parseCandidate: arbitrary property" {
    const cands = try parseCandidate(t.allocator, "[color:red]");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len == 1);
    try t.expect(cands[0] == .arbitrary);
    try t.expectEqualStrings("color", cands[0].arbitrary.property);
    try t.expectEqualStrings("red", cands[0].arbitrary.value);
}

test "parseCandidate: parens-arbitrary with var" {
    const cands = try parseCandidate(t.allocator, "bg-(--my-color)");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len >= 1);
    try t.expectEqualStrings("bg", cands[0].functional.root);
    try t.expectEqualStrings("var(--my-color)", cands[0].functional.value.?.arbitrary.value);
}

test "parseCandidate: parens-arbitrary with typehint" {
    const cands = try parseCandidate(t.allocator, "bg-(color:--my-color)");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len >= 1);
    try t.expectEqualStrings("color", cands[0].functional.value.?.arbitrary.data_type.?);
    try t.expectEqualStrings("var(--my-color)", cands[0].functional.value.?.arbitrary.value);
}

test "parseCandidate: trailing important marker" {
    const cands = try parseCandidate(t.allocator, "mx-4!");
    defer freeCandidates(t.allocator, cands);
    var found = false;
    for (cands) |c| {
        if (c == .functional and std.mem.eql(u8, c.functional.root, "mx")) {
            try t.expect(c.functional.important);
            try t.expectEqualStrings("4", c.functional.value.?.named.value);
            found = true;
        }
    }
    try t.expect(found);
}

test "parseCandidate: leading important marker (legacy)" {
    const cands = try parseCandidate(t.allocator, "!mx-4");
    defer freeCandidates(t.allocator, cands);
    var found = false;
    for (cands) |c| {
        if (c == .functional and std.mem.eql(u8, c.functional.root, "mx")) {
            try t.expect(c.functional.important);
            found = true;
        }
    }
    try t.expect(found);
}

test "parseCandidate: named modifier" {
    const cands = try parseCandidate(t.allocator, "bg-red-500/50");
    defer freeCandidates(t.allocator, cands);
    var found = false;
    for (cands) |c| {
        if (c == .functional and std.mem.eql(u8, c.functional.root, "bg")) {
            try t.expectEqualStrings("50", c.functional.modifier.?.named);
            found = true;
        }
    }
    try t.expect(found);
}

test "parseCandidate: arbitrary modifier" {
    const cands = try parseCandidate(t.allocator, "text-6xl/[0.9]");
    defer freeCandidates(t.allocator, cands);
    var found = false;
    for (cands) |c| {
        if (c == .functional and c.functional.modifier != null) {
            try t.expect(c.functional.modifier.? == .arbitrary);
            try t.expectEqualStrings("0.9", c.functional.modifier.?.arbitrary);
            found = true;
        }
    }
    try t.expect(found);
}

test "parseCandidate: stacked variants" {
    const cands = try parseCandidate(t.allocator, "md:hover:bg-red-500");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len >= 1);
    // Static `md:hover:bg-red-500` is yielded too; find the functional bg.
    var found = false;
    for (cands) |c| {
        if (c == .functional and std.mem.eql(u8, c.functional.root, "bg")) {
            try t.expectEqual(@as(usize, 2), c.functional.variants.len);
            // Variants are stored innermost-first per upstream's convention.
            // First variant in the slice corresponds to `hover` (innermost).
            found = true;
        }
    }
    try t.expect(found);
}

test "parseVariant: static" {
    const v = try parseVariant(t.allocator, "hover");
    try t.expect(v != null);
    try t.expect(v.? == .static_v);
    try t.expectEqualStrings("hover", v.?.static_v.root);
}

test "parseVariant: functional with arbitrary value" {
    const v = try parseVariant(t.allocator, "data-[state=open]");
    try t.expect(v != null);
    defer freeVariant(t.allocator, v.?);
    try t.expect(v.? == .functional);
    try t.expectEqualStrings("data", v.?.functional.root);
    try t.expectEqualStrings("state=open", v.?.functional.value.?.arbitrary);
}

test "parseVariant: compound group-hover" {
    const v = try parseVariant(t.allocator, "group-hover");
    try t.expect(v != null);
    defer freeVariant(t.allocator, v.?);
    try t.expect(v.? == .compound);
    try t.expectEqualStrings("group", v.?.compound.root);
    try t.expect(v.?.compound.variant.* == .static_v);
    try t.expectEqualStrings("hover", v.?.compound.variant.static_v.root);
}

test "parseVariant: compound with named-group modifier" {
    const v = try parseVariant(t.allocator, "group-hover/foo");
    try t.expect(v != null);
    defer freeVariant(t.allocator, v.?);
    try t.expect(v.? == .compound);
    try t.expectEqualStrings("foo", v.?.compound.modifier.?.named);
}

test "parseVariant: arbitrary selector" {
    const v = try parseVariant(t.allocator, "[&_p]");
    try t.expect(v != null);
    defer freeVariant(t.allocator, v.?);
    try t.expect(v.? == .arbitrary);
    // `&` present, decoded space, no relative.
    try t.expectEqualStrings("& p", v.?.arbitrary.selector);
}

test "parseVariant: arbitrary selector wraps with &:is(...) when no & present" {
    const v = try parseVariant(t.allocator, "[p]");
    try t.expect(v != null);
    defer freeVariant(t.allocator, v.?);
    try t.expectEqualStrings("&:is(p)", v.?.arbitrary.selector);
}

test "parseModifier: named" {
    const m = try parseModifier(t.allocator, "50");
    try t.expect(m != null);
    try t.expectEqualStrings("50", m.?.named);
}

test "parseModifier: arbitrary" {
    const m = try parseModifier(t.allocator, "[0.9]");
    try t.expect(m != null);
    try t.expect(m.? == .arbitrary);
    try t.expectEqualStrings("0.9", m.?.arbitrary);
    if (m) |mm| freeModifier(t.allocator, mm);
}

test "parseModifier: parens-var" {
    const m = try parseModifier(t.allocator, "(--my-mod)");
    try t.expect(m != null);
    try t.expectEqualStrings("var(--my-mod)", m.?.arbitrary);
    if (m) |mm| freeModifier(t.allocator, mm);
}

test "parseCandidate: empty input" {
    const cands = try parseCandidate(t.allocator, "");
    defer freeCandidates(t.allocator, cands);
    try t.expectEqual(@as(usize, 0), cands.len);
}

test "parseCandidate: invalid double modifier" {
    const cands = try parseCandidate(t.allocator, "bg-red-500/50/50");
    defer freeCandidates(t.allocator, cands);
    try t.expectEqual(@as(usize, 0), cands.len);
}

test "parseCandidate: arbitrary property requires colon" {
    const cands = try parseCandidate(t.allocator, "[colored]");
    defer freeCandidates(t.allocator, cands);
    try t.expectEqual(@as(usize, 0), cands.len);
}

test "parseCandidate: data-variant with trailing arbitrary modifier" {
    const cands = try parseCandidate(t.allocator, "data-[state=open]:flex");
    defer freeCandidates(t.allocator, cands);
    var found = false;
    for (cands) |c| {
        if (c == .static_c and std.mem.eql(u8, c.static_c.root, "flex")) {
            try t.expectEqual(@as(usize, 1), c.static_c.variants.len);
            try t.expect(c.static_c.variants[0] == .functional);
            try t.expectEqualStrings("data", c.static_c.variants[0].functional.root);
            found = true;
        }
    }
    try t.expect(found);
}

test "parseCandidate: stacked group-data variant from /site" {
    // Real /site class string
    const cands = try parseCandidate(t.allocator, "group-data-dark:from-gray-800");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len > 0);
    // Should produce a functional `from` candidate with one variant.
    var found = false;
    for (cands) |c| {
        if (c == .functional and std.mem.eql(u8, c.functional.root, "from")) {
            try t.expectEqualStrings("gray-800", c.functional.value.?.named.value);
            try t.expectEqual(@as(usize, 1), c.functional.variants.len);
            try t.expect(c.functional.variants[0] == .compound);
            try t.expectEqualStrings("group", c.functional.variants[0].compound.root);
            found = true;
        }
    }
    try t.expect(found);
}

test "parseCandidate: arbitrary value with negative percent (from /site)" {
    const cands = try parseCandidate(t.allocator, "from-[-25%]");
    defer freeCandidates(t.allocator, cands);
    try t.expect(cands.len >= 1);
    try t.expectEqualStrings("from", cands[0].functional.root);
    try t.expectEqualStrings("-25%", cands[0].functional.value.?.arbitrary.value);
}

test "parseCandidate: text-size with line-height modifier" {
    const cands = try parseCandidate(t.allocator, "text-2xl/8");
    defer freeCandidates(t.allocator, cands);
    var found = false;
    for (cands) |c| {
        if (c == .functional and std.mem.eql(u8, c.functional.root, "text")) {
            try t.expectEqualStrings("2xl", c.functional.value.?.named.value);
            try t.expectEqualStrings("8", c.functional.modifier.?.named);
            found = true;
        }
    }
    try t.expect(found);
}
