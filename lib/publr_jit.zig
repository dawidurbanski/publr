// SPDX-License-Identifier: Apache-2.0
// Publr JIT Amalgamation — generated from jit/src/*.zig
// Do not edit directly. Regenerate: ./scripts/amalgamate-jit.sh
// The third-party compatibility preflight is distributed separately.

const amalgam = @This();

pub const candidate_mod = struct {
/// Class candidate parser.
///
/// Configuration-free: produces all possible structural interpretations of an
/// input class string. The consumer (utility and variant tables) disambiguates
/// them by checking which root is registered.
///
/// Coverage in this version:
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

    // Parse variants in reverse so the innermost variant is stored first.
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
        var data_type_slice: ?[]const u8 = null;
        var value_str: []const u8 = decoded;
        var th_idx: usize = 0;
        while (th_idx < decoded.len) : (th_idx += 1) {
            const c = decoded[th_idx];
            if (c == ':') {
                data_type_slice = decoded[0..th_idx];
                value_str = decoded[th_idx + 1 ..];
                break;
            }
            // Typehint chars: lowercase or `-`.
            if (c == '-' or (c >= 'a' and c <= 'z')) continue;
            break;
        }

        const data_type = if (data_type_slice) |dt| try allocator.dupe(u8, dt) else null;
        errdefer if (data_type) |dt| allocator.free(dt);
        const owned_value = try allocator.dupe(u8, value_str);
        errdefer allocator.free(owned_value);
        allocator.free(decoded);

        try results.append(.{ .functional = .{
            .root = root,
            .value = .{ .arbitrary = .{ .data_type = data_type, .value = owned_value } },
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
        var data_type_slice: ?[]const u8 = null;
        var var_name: []const u8 = inner;
        if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
            data_type_slice = inner[0..colon];
            var_name = inner[colon + 1 ..];
        }
        // Var name must start with `--`.
        if (var_name.len < 2 or var_name[0] != '-' or var_name[1] != '-') return results.toOwnedSlice();
        if (!isValidArbitrary(var_name)) return results.toOwnedSlice();

        // Wrap in `var(...)` to form the arbitrary CSS value.
        const wrapped = try std.fmt.allocPrint(allocator, "var({s})", .{var_name});
        errdefer allocator.free(wrapped);
        const data_type = if (data_type_slice) |dt| try allocator.dupe(u8, dt) else null;
        errdefer if (data_type) |dt| allocator.free(dt);
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
            // Store `${value}/${modifierSegment}` in the fraction field.
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
        // Reject `[@media(...){&:hover}]` (combined at-rules + selector).
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

    // For compound variants (group-, peer-, etc.), split on
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
    // binary `+` and `-` operators. Class values may contain `calc(50%-4rem)`;
    // canonicalize it by inserting spaces. The sign of a unary `-` (e.g.
    // `-4rem` at the start of an arg)
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
        .arbitrary => |a| {
            if (a.data_type) |data_type| allocator.free(data_type);
            allocator.free(a.value);
        },
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

};

pub const theme_mod = struct {
/// Theme — Publr JIT's comptime theme model.
///
/// Decision (locked 2026-05-02): theme is comptime-only. `theme.zon` imports
/// at comptime, with no runtime override layer.
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

};

pub const utilities_mod = struct {
/// Utility resolver — turns parsed `Candidate`s into CSS declarations.
///
/// Architecture: a comptime-known set of "kinds" (static utilities, functional
/// utilities) implemented as a switch over the candidate's `root`. Theme tokens
/// are looked up at runtime against the merged comptime theme.
///
/// Memory model: caller provides an allocator. `resolveCandidate` returns an
/// owned `ResolvedUtility` (or null). Caller must call `freeResolvedUtility`.
///
/// This module owns:
///   - The utility-kind dispatch (static + functional).
///   - Theme-token lookup helpers.
///   - Declaration emission for each kind.
///
/// This module DOES NOT own:
///   - Variant wrapping (task-06's variants.zig).
///   - Sort order (task-07's compile.zig).
///   - The full CSS serializer.
const std = @import("std");
const candidate = amalgam.candidate_mod;
const theme = amalgam.theme_mod;

const Candidate = candidate.Candidate;
const Theme = theme.Theme;

pub const Declaration = struct {
    property: []const u8,
    value: []const u8,
};

pub const ResolvedUtility = struct {
    /// CSS declarations the utility emits, in the order they should appear in
    /// the output rule.
    declarations: []Declaration,
    /// Set when the candidate carried `!important` syntax (`underline!`,
    /// `!underline`, `[color:red]!`). `compile.zig:emitClassRule` emits
    /// `!important` after each value when this is set.
    important: bool = false,
    /// Optional CSS selector suffix the utility wants appended to its class
    /// selector. Used by selector-modifying utilities like `space-x-N` which
    /// need to emit `.space-x-4 > :not(:last-child) { margin-right: ... }`.
    /// When non-null, `compile.zig` appends ` <suffix>` to the wrapped
    /// selector before emitting the declaration block.
    selector_suffix: ?[]u8 = null,
};

pub const ResolveError = error{OutOfMemory};

/// Free the declarations array. Each declaration's strings may or may not be
/// owned (some come from theme/candidate slices, some are allocPrint'd). For
/// simplicity, callers should treat the slices as borrowed for now — handlers
/// that allocate their own strings flag this in comments.
///
/// Phase-1 simplification: most declarations use string-literal property names
/// (which are static, never freed) and theme-token-string values (also static
/// after comptime). Numeric values built via allocPrint are the heap part.
/// We track those by always going through `allocPrint` for value strings, so
/// freeing the value of every declaration is safe.
///
/// If a declaration value points into the input candidate (e.g., arbitrary
/// values copied verbatim), we duplicate it through the allocator first.
/// This means: every declaration value in a returned ResolvedUtility is
/// heap-owned by the allocator passed to resolveCandidate.
pub fn freeResolvedUtility(allocator: std.mem.Allocator, r: ResolvedUtility) void {
    for (r.declarations) |d| allocator.free(d.value);
    allocator.free(r.declarations);
    if (r.selector_suffix) |s| allocator.free(s);
}

/// Resolve a parsed Candidate against the merged Theme.
/// Returns null if the candidate doesn't match any known utility kind.
pub fn resolveCandidate(
    allocator: std.mem.Allocator,
    t: Theme,
    cand: Candidate,
) ResolveError!?ResolvedUtility {
    var maybe = switch (cand) {
        .static_c => |s| try resolveStatic(allocator, t, s.root),
        .functional => |f| try resolveFunctional(allocator, t, f),
        .arbitrary => |a| try resolveArbitraryProperty(allocator, a.property, a.value, a.modifier),
    };
    if (maybe) |*r| {
        r.important = switch (cand) {
            .static_c => |s| s.important,
            .functional => |f| f.important,
            .arbitrary => |a| a.important,
        };
    }
    return maybe;
}

// ── Static utilities ────────────────────────────────────────────────────────

/// Static utility table: name → declarations (raw, unallocated).
/// At resolve time we copy values into allocator-owned strings.
const StaticEntry = struct {
    name: []const u8,
    decls: []const Declaration,
};

const STATIC_UTILITIES = [_]StaticEntry{
    // ── Display ─────────────────────────────────────────────────────────────
    .{ .name = "block", .decls = &.{.{ .property = "display", .value = "block" }} },
    .{ .name = "inline", .decls = &.{.{ .property = "display", .value = "inline" }} },
    .{ .name = "inline-block", .decls = &.{.{ .property = "display", .value = "inline-block" }} },
    .{ .name = "flex", .decls = &.{.{ .property = "display", .value = "flex" }} },
    .{ .name = "inline-flex", .decls = &.{.{ .property = "display", .value = "inline-flex" }} },
    .{ .name = "grid", .decls = &.{.{ .property = "display", .value = "grid" }} },
    .{ .name = "inline-grid", .decls = &.{.{ .property = "display", .value = "inline-grid" }} },
    .{ .name = "hidden", .decls = &.{.{ .property = "display", .value = "none" }} },
    .{ .name = "table", .decls = &.{.{ .property = "display", .value = "table" }} },
    .{ .name = "inline-table", .decls = &.{.{ .property = "display", .value = "inline-table" }} },
    .{ .name = "table-caption", .decls = &.{.{ .property = "display", .value = "table-caption" }} },
    .{ .name = "table-cell", .decls = &.{.{ .property = "display", .value = "table-cell" }} },
    .{ .name = "table-column", .decls = &.{.{ .property = "display", .value = "table-column" }} },
    .{ .name = "table-column-group", .decls = &.{.{ .property = "display", .value = "table-column-group" }} },
    .{ .name = "table-footer-group", .decls = &.{.{ .property = "display", .value = "table-footer-group" }} },
    .{ .name = "table-header-group", .decls = &.{.{ .property = "display", .value = "table-header-group" }} },
    .{ .name = "table-row-group", .decls = &.{.{ .property = "display", .value = "table-row-group" }} },
    .{ .name = "table-row", .decls = &.{.{ .property = "display", .value = "table-row" }} },
    .{ .name = "flow-root", .decls = &.{.{ .property = "display", .value = "flow-root" }} },
    .{ .name = "contents", .decls = &.{.{ .property = "display", .value = "contents" }} },
    .{ .name = "list-item", .decls = &.{.{ .property = "display", .value = "list-item" }} },

    // ── Field-sizing ────────────────────────────────────────────────────────
    .{ .name = "field-sizing-content", .decls = &.{.{ .property = "field-sizing", .value = "content" }} },
    .{ .name = "field-sizing-fixed", .decls = &.{.{ .property = "field-sizing", .value = "fixed" }} },

    // ── Visibility ──────────────────────────────────────────────────────────
    .{ .name = "visible", .decls = &.{.{ .property = "visibility", .value = "visible" }} },
    .{ .name = "invisible", .decls = &.{.{ .property = "visibility", .value = "hidden" }} },
    .{ .name = "collapse", .decls = &.{.{ .property = "visibility", .value = "collapse" }} },

    // ── Box sizing ──────────────────────────────────────────────────────────
    .{ .name = "box-border", .decls = &.{.{ .property = "box-sizing", .value = "border-box" }} },
    .{ .name = "box-content", .decls = &.{.{ .property = "box-sizing", .value = "content-box" }} },

    // ── Box decoration break ────────────────────────────────────────────────
    .{ .name = "box-decoration-slice", .decls = &.{
        .{ .property = "-webkit-box-decoration-break", .value = "slice" },
        .{ .property = "box-decoration-break", .value = "slice" },
    } },
    .{ .name = "box-decoration-clone", .decls = &.{
        .{ .property = "-webkit-box-decoration-break", .value = "clone" },
        .{ .property = "box-decoration-break", .value = "clone" },
    } },

    // ── Isolation ───────────────────────────────────────────────────────────
    .{ .name = "isolation-auto", .decls = &.{.{ .property = "isolation", .value = "auto" }} },

    // ── Float ───────────────────────────────────────────────────────────────
    .{ .name = "float-start", .decls = &.{.{ .property = "float", .value = "inline-start" }} },
    .{ .name = "float-end", .decls = &.{.{ .property = "float", .value = "inline-end" }} },
    .{ .name = "float-right", .decls = &.{.{ .property = "float", .value = "right" }} },
    .{ .name = "float-left", .decls = &.{.{ .property = "float", .value = "left" }} },
    .{ .name = "float-none", .decls = &.{.{ .property = "float", .value = "none" }} },

    // ── Clear ───────────────────────────────────────────────────────────────
    .{ .name = "clear-start", .decls = &.{.{ .property = "clear", .value = "inline-start" }} },
    .{ .name = "clear-end", .decls = &.{.{ .property = "clear", .value = "inline-end" }} },
    .{ .name = "clear-right", .decls = &.{.{ .property = "clear", .value = "right" }} },
    .{ .name = "clear-left", .decls = &.{.{ .property = "clear", .value = "left" }} },
    .{ .name = "clear-both", .decls = &.{.{ .property = "clear", .value = "both" }} },
    .{ .name = "clear-none", .decls = &.{.{ .property = "clear", .value = "none" }} },

    // ── Position ────────────────────────────────────────────────────────────
    .{ .name = "static", .decls = &.{.{ .property = "position", .value = "static" }} },
    .{ .name = "relative", .decls = &.{.{ .property = "position", .value = "relative" }} },
    .{ .name = "absolute", .decls = &.{.{ .property = "position", .value = "absolute" }} },
    .{ .name = "fixed", .decls = &.{.{ .property = "position", .value = "fixed" }} },
    .{ .name = "sticky", .decls = &.{.{ .property = "position", .value = "sticky" }} },

    // ── Flex direction ──────────────────────────────────────────────────────
    .{ .name = "flex-row", .decls = &.{.{ .property = "flex-direction", .value = "row" }} },
    .{ .name = "flex-row-reverse", .decls = &.{.{ .property = "flex-direction", .value = "row-reverse" }} },
    .{ .name = "flex-col", .decls = &.{.{ .property = "flex-direction", .value = "column" }} },
    .{ .name = "flex-col-reverse", .decls = &.{.{ .property = "flex-direction", .value = "column-reverse" }} },
    .{ .name = "flex-wrap", .decls = &.{.{ .property = "flex-wrap", .value = "wrap" }} },
    .{ .name = "flex-nowrap", .decls = &.{.{ .property = "flex-wrap", .value = "nowrap" }} },
    .{ .name = "flex-wrap-reverse", .decls = &.{.{ .property = "flex-wrap", .value = "wrap-reverse" }} },

    // ── place-content / place-items / place-self ────────────────────────────
    .{ .name = "place-content-center", .decls = &.{.{ .property = "place-content", .value = "center" }} },
    .{ .name = "place-content-start", .decls = &.{.{ .property = "place-content", .value = "start" }} },
    .{ .name = "place-content-end", .decls = &.{.{ .property = "place-content", .value = "end" }} },
    .{ .name = "place-content-center-safe", .decls = &.{.{ .property = "place-content", .value = "safe center" }} },
    .{ .name = "place-content-end-safe", .decls = &.{.{ .property = "place-content", .value = "safe end" }} },
    .{ .name = "place-content-between", .decls = &.{.{ .property = "place-content", .value = "space-between" }} },
    .{ .name = "place-content-around", .decls = &.{.{ .property = "place-content", .value = "space-around" }} },
    .{ .name = "place-content-evenly", .decls = &.{.{ .property = "place-content", .value = "space-evenly" }} },
    .{ .name = "place-content-baseline", .decls = &.{.{ .property = "place-content", .value = "baseline" }} },
    .{ .name = "place-content-stretch", .decls = &.{.{ .property = "place-content", .value = "stretch" }} },

    .{ .name = "place-items-center", .decls = &.{.{ .property = "place-items", .value = "center" }} },
    .{ .name = "place-items-start", .decls = &.{.{ .property = "place-items", .value = "start" }} },
    .{ .name = "place-items-end", .decls = &.{.{ .property = "place-items", .value = "end" }} },
    .{ .name = "place-items-center-safe", .decls = &.{.{ .property = "place-items", .value = "safe center" }} },
    .{ .name = "place-items-end-safe", .decls = &.{.{ .property = "place-items", .value = "safe end" }} },
    .{ .name = "place-items-baseline", .decls = &.{.{ .property = "place-items", .value = "baseline" }} },
    .{ .name = "place-items-stretch", .decls = &.{.{ .property = "place-items", .value = "stretch" }} },

    .{ .name = "place-self-auto", .decls = &.{.{ .property = "place-self", .value = "auto" }} },
    .{ .name = "place-self-start", .decls = &.{.{ .property = "place-self", .value = "start" }} },
    .{ .name = "place-self-end", .decls = &.{.{ .property = "place-self", .value = "end" }} },
    .{ .name = "place-self-center", .decls = &.{.{ .property = "place-self", .value = "center" }} },
    .{ .name = "place-self-end-safe", .decls = &.{.{ .property = "place-self", .value = "safe end" }} },
    .{ .name = "place-self-center-safe", .decls = &.{.{ .property = "place-self", .value = "safe center" }} },
    .{ .name = "place-self-stretch", .decls = &.{.{ .property = "place-self", .value = "stretch" }} },

    // ── align-content (`content-*`) ─────────────────────────────────────────
    .{ .name = "content-normal", .decls = &.{.{ .property = "align-content", .value = "normal" }} },
    .{ .name = "content-center", .decls = &.{.{ .property = "align-content", .value = "center" }} },
    .{ .name = "content-start", .decls = &.{.{ .property = "align-content", .value = "flex-start" }} },
    .{ .name = "content-end", .decls = &.{.{ .property = "align-content", .value = "flex-end" }} },
    .{ .name = "content-center-safe", .decls = &.{.{ .property = "align-content", .value = "safe center" }} },
    .{ .name = "content-end-safe", .decls = &.{.{ .property = "align-content", .value = "safe flex-end" }} },
    .{ .name = "content-between", .decls = &.{.{ .property = "align-content", .value = "space-between" }} },
    .{ .name = "content-around", .decls = &.{.{ .property = "align-content", .value = "space-around" }} },
    .{ .name = "content-evenly", .decls = &.{.{ .property = "align-content", .value = "space-evenly" }} },
    .{ .name = "content-baseline", .decls = &.{.{ .property = "align-content", .value = "baseline" }} },
    .{ .name = "content-stretch", .decls = &.{.{ .property = "align-content", .value = "stretch" }} },

    // ── justify-items ───────────────────────────────────────────────────────
    .{ .name = "justify-items-normal", .decls = &.{.{ .property = "justify-items", .value = "normal" }} },
    .{ .name = "justify-items-center", .decls = &.{.{ .property = "justify-items", .value = "center" }} },
    .{ .name = "justify-items-start", .decls = &.{.{ .property = "justify-items", .value = "start" }} },
    .{ .name = "justify-items-end", .decls = &.{.{ .property = "justify-items", .value = "end" }} },
    .{ .name = "justify-items-center-safe", .decls = &.{.{ .property = "justify-items", .value = "safe center" }} },
    .{ .name = "justify-items-end-safe", .decls = &.{.{ .property = "justify-items", .value = "safe end" }} },
    .{ .name = "justify-items-stretch", .decls = &.{.{ .property = "justify-items", .value = "stretch" }} },

    // ── justify-self ────────────────────────────────────────────────────────
    .{ .name = "justify-self-auto", .decls = &.{.{ .property = "justify-self", .value = "auto" }} },
    .{ .name = "justify-self-start", .decls = &.{.{ .property = "justify-self", .value = "start" }} },
    .{ .name = "justify-self-end", .decls = &.{.{ .property = "justify-self", .value = "end" }} },
    .{ .name = "justify-self-center", .decls = &.{.{ .property = "justify-self", .value = "center" }} },
    .{ .name = "justify-self-end-safe", .decls = &.{.{ .property = "justify-self", .value = "safe end" }} },
    .{ .name = "justify-self-center-safe", .decls = &.{.{ .property = "justify-self", .value = "safe center" }} },
    .{ .name = "justify-self-stretch", .decls = &.{.{ .property = "justify-self", .value = "stretch" }} },

    // ── grid-flow ───────────────────────────────────────────────────────────
    .{ .name = "grid-flow-row", .decls = &.{.{ .property = "grid-auto-flow", .value = "row" }} },
    .{ .name = "grid-flow-col", .decls = &.{.{ .property = "grid-auto-flow", .value = "column" }} },
    .{ .name = "grid-flow-dense", .decls = &.{.{ .property = "grid-auto-flow", .value = "dense" }} },
    .{ .name = "grid-flow-row-dense", .decls = &.{.{ .property = "grid-auto-flow", .value = "row dense" }} },
    .{ .name = "grid-flow-col-dense", .decls = &.{.{ .property = "grid-auto-flow", .value = "column dense" }} },

    // ── Justify / Align ─────────────────────────────────────────────────────
    .{ .name = "justify-normal", .decls = &.{.{ .property = "justify-content", .value = "normal" }} },
    .{ .name = "justify-start", .decls = &.{.{ .property = "justify-content", .value = "flex-start" }} },
    .{ .name = "justify-center", .decls = &.{.{ .property = "justify-content", .value = "center" }} },
    .{ .name = "justify-between", .decls = &.{.{ .property = "justify-content", .value = "space-between" }} },
    .{ .name = "justify-end", .decls = &.{.{ .property = "justify-content", .value = "flex-end" }} },
    .{ .name = "justify-around", .decls = &.{.{ .property = "justify-content", .value = "space-around" }} },
    .{ .name = "justify-evenly", .decls = &.{.{ .property = "justify-content", .value = "space-evenly" }} },
    .{ .name = "justify-center-safe", .decls = &.{.{ .property = "justify-content", .value = "safe center" }} },
    .{ .name = "justify-end-safe", .decls = &.{.{ .property = "justify-content", .value = "safe flex-end" }} },
    .{ .name = "justify-baseline", .decls = &.{.{ .property = "justify-content", .value = "baseline" }} },
    .{ .name = "justify-stretch", .decls = &.{.{ .property = "justify-content", .value = "stretch" }} },

    .{ .name = "items-start", .decls = &.{.{ .property = "align-items", .value = "flex-start" }} },
    .{ .name = "items-center", .decls = &.{.{ .property = "align-items", .value = "center" }} },
    .{ .name = "items-end", .decls = &.{.{ .property = "align-items", .value = "flex-end" }} },
    .{ .name = "items-baseline", .decls = &.{.{ .property = "align-items", .value = "baseline" }} },
    .{ .name = "items-baseline-last", .decls = &.{.{ .property = "align-items", .value = "last baseline" }} },
    .{ .name = "items-stretch", .decls = &.{.{ .property = "align-items", .value = "stretch" }} },
    .{ .name = "items-center-safe", .decls = &.{.{ .property = "align-items", .value = "safe center" }} },
    .{ .name = "items-end-safe", .decls = &.{.{ .property = "align-items", .value = "safe flex-end" }} },

    .{ .name = "self-auto", .decls = &.{.{ .property = "align-self", .value = "auto" }} },
    .{ .name = "self-start", .decls = &.{.{ .property = "align-self", .value = "flex-start" }} },
    .{ .name = "self-end", .decls = &.{.{ .property = "align-self", .value = "flex-end" }} },
    .{ .name = "self-center", .decls = &.{.{ .property = "align-self", .value = "center" }} },
    .{ .name = "self-end-safe", .decls = &.{.{ .property = "align-self", .value = "safe flex-end" }} },
    .{ .name = "self-center-safe", .decls = &.{.{ .property = "align-self", .value = "safe center" }} },
    .{ .name = "self-stretch", .decls = &.{.{ .property = "align-self", .value = "stretch" }} },
    .{ .name = "self-baseline", .decls = &.{.{ .property = "align-self", .value = "baseline" }} },
    .{ .name = "self-baseline-last", .decls = &.{.{ .property = "align-self", .value = "last baseline" }} },

    // ── Text wrap (gap kind #14 from validation C) ──────────────────────────
    .{ .name = "text-balance", .decls = &.{.{ .property = "text-wrap", .value = "balance" }} },
    .{ .name = "text-pretty", .decls = &.{.{ .property = "text-wrap", .value = "pretty" }} },
    .{ .name = "text-wrap", .decls = &.{.{ .property = "text-wrap", .value = "wrap" }} },
    .{ .name = "text-nowrap", .decls = &.{.{ .property = "text-wrap", .value = "nowrap" }} },

    // ── Text overflow ───────────────────────────────────────────────────────
    .{ .name = "text-clip", .decls = &.{.{ .property = "text-overflow", .value = "clip" }} },
    .{ .name = "text-ellipsis", .decls = &.{.{ .property = "text-overflow", .value = "ellipsis" }} },

    // ── Truncate (3-property shortcut) ──────────────────────────────────────
    .{ .name = "truncate", .decls = &.{
        .{ .property = "overflow", .value = "hidden" },
        .{ .property = "text-overflow", .value = "ellipsis" },
        .{ .property = "white-space", .value = "nowrap" },
    } },

    // ── Text alignment ──────────────────────────────────────────────────────
    .{ .name = "text-left", .decls = &.{.{ .property = "text-align", .value = "left" }} },
    .{ .name = "text-center", .decls = &.{.{ .property = "text-align", .value = "center" }} },
    .{ .name = "text-right", .decls = &.{.{ .property = "text-align", .value = "right" }} },
    .{ .name = "text-justify", .decls = &.{.{ .property = "text-align", .value = "justify" }} },
    .{ .name = "text-start", .decls = &.{.{ .property = "text-align", .value = "start" }} },
    .{ .name = "text-end", .decls = &.{.{ .property = "text-align", .value = "end" }} },

    // ── Vertical-align (`align-*`) ──────────────────────────────────────────
    .{ .name = "align-baseline", .decls = &.{.{ .property = "vertical-align", .value = "baseline" }} },
    .{ .name = "align-top", .decls = &.{.{ .property = "vertical-align", .value = "top" }} },
    .{ .name = "align-middle", .decls = &.{.{ .property = "vertical-align", .value = "middle" }} },
    .{ .name = "align-bottom", .decls = &.{.{ .property = "vertical-align", .value = "bottom" }} },
    .{ .name = "align-text-top", .decls = &.{.{ .property = "vertical-align", .value = "text-top" }} },
    .{ .name = "align-text-bottom", .decls = &.{.{ .property = "vertical-align", .value = "text-bottom" }} },
    .{ .name = "align-sub", .decls = &.{.{ .property = "vertical-align", .value = "sub" }} },
    .{ .name = "align-super", .decls = &.{.{ .property = "vertical-align", .value = "super" }} },

    // ── Decoration style + thickness statics ────────────────────────────────
    .{ .name = "decoration-solid", .decls = &.{.{ .property = "text-decoration-style", .value = "solid" }} },
    .{ .name = "decoration-double", .decls = &.{.{ .property = "text-decoration-style", .value = "double" }} },
    .{ .name = "decoration-dotted", .decls = &.{.{ .property = "text-decoration-style", .value = "dotted" }} },
    .{ .name = "decoration-dashed", .decls = &.{.{ .property = "text-decoration-style", .value = "dashed" }} },
    .{ .name = "decoration-wavy", .decls = &.{.{ .property = "text-decoration-style", .value = "wavy" }} },
    .{ .name = "decoration-auto", .decls = &.{.{ .property = "text-decoration-thickness", .value = "auto" }} },
    .{ .name = "decoration-from-font", .decls = &.{.{ .property = "text-decoration-thickness", .value = "from-font" }} },

    // ── Hyphens ─────────────────────────────────────────────────────────────
    .{ .name = "hyphens-none", .decls = &.{
        .{ .property = "-webkit-hyphens", .value = "none" },
        .{ .property = "hyphens", .value = "none" },
    } },
    .{ .name = "hyphens-manual", .decls = &.{
        .{ .property = "-webkit-hyphens", .value = "manual" },
        .{ .property = "hyphens", .value = "manual" },
    } },
    .{ .name = "hyphens-auto", .decls = &.{
        .{ .property = "-webkit-hyphens", .value = "auto" },
        .{ .property = "hyphens", .value = "auto" },
    } },

    // ── White-space ─────────────────────────────────────────────────────────
    .{ .name = "whitespace-normal", .decls = &.{.{ .property = "white-space", .value = "normal" }} },
    .{ .name = "whitespace-nowrap", .decls = &.{.{ .property = "white-space", .value = "nowrap" }} },
    .{ .name = "whitespace-pre", .decls = &.{.{ .property = "white-space", .value = "pre" }} },
    .{ .name = "whitespace-pre-line", .decls = &.{.{ .property = "white-space", .value = "pre-line" }} },
    .{ .name = "whitespace-pre-wrap", .decls = &.{.{ .property = "white-space", .value = "pre-wrap" }} },
    .{ .name = "whitespace-break-spaces", .decls = &.{.{ .property = "white-space", .value = "break-spaces" }} },

    // ── Word break / overflow wrap ──────────────────────────────────────────
    .{ .name = "break-normal", .decls = &.{
        .{ .property = "overflow-wrap", .value = "normal" },
        .{ .property = "word-break", .value = "normal" },
    } },
    .{ .name = "break-all", .decls = &.{.{ .property = "word-break", .value = "break-all" }} },
    .{ .name = "break-keep", .decls = &.{.{ .property = "word-break", .value = "keep-all" }} },
    .{ .name = "wrap-anywhere", .decls = &.{.{ .property = "overflow-wrap", .value = "anywhere" }} },
    .{ .name = "wrap-break-word", .decls = &.{.{ .property = "overflow-wrap", .value = "break-word" }} },
    .{ .name = "wrap-normal", .decls = &.{.{ .property = "overflow-wrap", .value = "normal" }} },

    // ── List-style-position ─────────────────────────────────────────────────
    .{ .name = "list-inside", .decls = &.{.{ .property = "list-style-position", .value = "inside" }} },
    .{ .name = "list-outside", .decls = &.{.{ .property = "list-style-position", .value = "outside" }} },
    .{ .name = "list-none", .decls = &.{.{ .property = "list-style-type", .value = "none" }} },
    .{ .name = "list-disc", .decls = &.{.{ .property = "list-style-type", .value = "disc" }} },
    .{ .name = "list-decimal", .decls = &.{.{ .property = "list-style-type", .value = "decimal" }} },
    .{ .name = "list-image-none", .decls = &.{.{ .property = "list-style-image", .value = "none" }} },

    // ── Font-variant-numeric ────────────────────────────────────────────────
    // The class contract composes via `--tw-numeric-*` vars; we emit each utility
    // directly (last-write-wins). For most use cases this is identical.
    .{ .name = "normal-nums", .decls = &.{.{ .property = "font-variant-numeric", .value = "normal" }} },
    .{ .name = "ordinal", .decls = &.{.{ .property = "font-variant-numeric", .value = "ordinal" }} },
    .{ .name = "slashed-zero", .decls = &.{.{ .property = "font-variant-numeric", .value = "slashed-zero" }} },
    .{ .name = "lining-nums", .decls = &.{.{ .property = "font-variant-numeric", .value = "lining-nums" }} },
    .{ .name = "oldstyle-nums", .decls = &.{.{ .property = "font-variant-numeric", .value = "oldstyle-nums" }} },
    .{ .name = "proportional-nums", .decls = &.{.{ .property = "font-variant-numeric", .value = "proportional-nums" }} },
    .{ .name = "tabular-nums", .decls = &.{.{ .property = "font-variant-numeric", .value = "tabular-nums" }} },
    .{ .name = "diagonal-fractions", .decls = &.{.{ .property = "font-variant-numeric", .value = "diagonal-fractions" }} },
    .{ .name = "stacked-fractions", .decls = &.{.{ .property = "font-variant-numeric", .value = "stacked-fractions" }} },

    // ── Filter / backdrop-filter resets ─────────────────────────────────────
    .{ .name = "filter-none", .decls = &.{.{ .property = "filter", .value = "none" }} },
    .{ .name = "backdrop-filter-none", .decls = &.{.{ .property = "backdrop-filter", .value = "none" }} },

    // ── Filter bare-form defaults (100%) ───────────────────────────────────
    .{ .name = "grayscale", .decls = &.{.{ .property = "filter", .value = "grayscale(100%)" }} },
    .{ .name = "invert", .decls = &.{.{ .property = "filter", .value = "invert(100%)" }} },
    .{ .name = "sepia", .decls = &.{.{ .property = "filter", .value = "sepia(100%)" }} },
    .{ .name = "backdrop-grayscale", .decls = &.{.{ .property = "backdrop-filter", .value = "grayscale(100%)" }} },
    .{ .name = "backdrop-invert", .decls = &.{.{ .property = "backdrop-filter", .value = "invert(100%)" }} },
    .{ .name = "backdrop-sepia", .decls = &.{.{ .property = "backdrop-filter", .value = "sepia(100%)" }} },
    .{ .name = "blur", .decls = &.{.{ .property = "filter", .value = "blur(8px)" }} },
    .{ .name = "backdrop-blur", .decls = &.{.{ .property = "backdrop-filter", .value = "blur(8px)" }} },

    // ── Content (pseudo-element content property) ───────────────────────────
    .{ .name = "content-none", .decls = &.{
        .{ .property = "--tw-content", .value = "none" },
        .{ .property = "content", .value = "none" },
    } },

    // ── Grid auto cols / auto rows statics ─────────────────────────────────
    .{ .name = "auto-cols-auto", .decls = &.{.{ .property = "grid-auto-columns", .value = "auto" }} },
    .{ .name = "auto-cols-min", .decls = &.{.{ .property = "grid-auto-columns", .value = "min-content" }} },
    .{ .name = "auto-cols-max", .decls = &.{.{ .property = "grid-auto-columns", .value = "max-content" }} },
    .{ .name = "auto-cols-fr", .decls = &.{.{ .property = "grid-auto-columns", .value = "minmax(0, 1fr)" }} },
    .{ .name = "auto-rows-auto", .decls = &.{.{ .property = "grid-auto-rows", .value = "auto" }} },
    .{ .name = "auto-rows-min", .decls = &.{.{ .property = "grid-auto-rows", .value = "min-content" }} },
    .{ .name = "auto-rows-max", .decls = &.{.{ .property = "grid-auto-rows", .value = "max-content" }} },
    .{ .name = "auto-rows-fr", .decls = &.{.{ .property = "grid-auto-rows", .value = "minmax(0, 1fr)" }} },

    // ── Underline-offset auto ──────────────────────────────────────────────
    .{ .name = "underline-offset-auto", .decls = &.{.{ .property = "text-underline-offset", .value = "auto" }} },

    // ── Line-clamp none ────────────────────────────────────────────────────
    .{ .name = "line-clamp-none", .decls = &.{
        .{ .property = "overflow", .value = "visible" },
        .{ .property = "display", .value = "block" },
        .{ .property = "-webkit-box-orient", .value = "horizontal" },
        .{ .property = "-webkit-line-clamp", .value = "unset" },
    } },

    // ── Text decoration ─────────────────────────────────────────────────────
    .{ .name = "underline", .decls = &.{.{ .property = "text-decoration-line", .value = "underline" }} },
    .{ .name = "overline", .decls = &.{.{ .property = "text-decoration-line", .value = "overline" }} },
    .{ .name = "line-through", .decls = &.{.{ .property = "text-decoration-line", .value = "line-through" }} },
    .{ .name = "no-underline", .decls = &.{.{ .property = "text-decoration-line", .value = "none" }} },

    // ── Text transform ──────────────────────────────────────────────────────
    .{ .name = "uppercase", .decls = &.{.{ .property = "text-transform", .value = "uppercase" }} },
    .{ .name = "lowercase", .decls = &.{.{ .property = "text-transform", .value = "lowercase" }} },
    .{ .name = "capitalize", .decls = &.{.{ .property = "text-transform", .value = "capitalize" }} },
    .{ .name = "normal-case", .decls = &.{.{ .property = "text-transform", .value = "none" }} },

    // ── Font style ──────────────────────────────────────────────────────────
    .{ .name = "italic", .decls = &.{.{ .property = "font-style", .value = "italic" }} },
    .{ .name = "not-italic", .decls = &.{.{ .property = "font-style", .value = "normal" }} },

    // ── Font weight (full supported scale) ─────────────────────────────────
    .{ .name = "font-thin", .decls = &.{.{ .property = "font-weight", .value = "100" }} },
    .{ .name = "font-extralight", .decls = &.{.{ .property = "font-weight", .value = "200" }} },
    .{ .name = "font-light", .decls = &.{.{ .property = "font-weight", .value = "300" }} },
    .{ .name = "font-normal", .decls = &.{.{ .property = "font-weight", .value = "400" }} },
    .{ .name = "font-medium", .decls = &.{.{ .property = "font-weight", .value = "500" }} },
    .{ .name = "font-semibold", .decls = &.{.{ .property = "font-weight", .value = "600" }} },
    .{ .name = "font-bold", .decls = &.{.{ .property = "font-weight", .value = "700" }} },
    .{ .name = "font-extrabold", .decls = &.{.{ .property = "font-weight", .value = "800" }} },
    .{ .name = "font-black", .decls = &.{.{ .property = "font-weight", .value = "900" }} },

    // ── Flex shorthand ──────────────────────────────────────────────────────
    .{ .name = "flex-auto", .decls = &.{.{ .property = "flex", .value = "auto" }} },
    .{ .name = "flex-initial", .decls = &.{.{ .property = "flex", .value = "0 auto" }} },
    .{ .name = "flex-none", .decls = &.{.{ .property = "flex", .value = "none" }} },
    .{ .name = "flex-1", .decls = &.{.{ .property = "flex", .value = "1 1 0%" }} },

    // ── Flex shrink / grow ─────────────────────────────────────────────────
    .{ .name = "shrink", .decls = &.{.{ .property = "flex-shrink", .value = "1" }} },
    .{ .name = "shrink-0", .decls = &.{.{ .property = "flex-shrink", .value = "0" }} },
    .{ .name = "grow", .decls = &.{.{ .property = "flex-grow", .value = "1" }} },
    .{ .name = "grow-0", .decls = &.{.{ .property = "flex-grow", .value = "0" }} },

    // ── Flex basis statics ─────────────────────────────────────────────────
    .{ .name = "basis-auto", .decls = &.{.{ .property = "flex-basis", .value = "auto" }} },
    .{ .name = "basis-full", .decls = &.{.{ .property = "flex-basis", .value = "100%" }} },

    // ── Screen-reader only (3-decl shortcut, multi-property) ────────────────
    .{ .name = "sr-only", .decls = &.{
        .{ .property = "position", .value = "absolute" },
        .{ .property = "width", .value = "1px" },
        .{ .property = "height", .value = "1px" },
        .{ .property = "padding", .value = "0" },
        .{ .property = "margin", .value = "-1px" },
        .{ .property = "overflow", .value = "hidden" },
        .{ .property = "clip", .value = "rect(0, 0, 0, 0)" },
        .{ .property = "white-space", .value = "nowrap" },
        .{ .property = "border-width", .value = "0" },
    } },
    .{ .name = "not-sr-only", .decls = &.{
        .{ .property = "position", .value = "static" },
        .{ .property = "width", .value = "auto" },
        .{ .property = "height", .value = "auto" },
        .{ .property = "padding", .value = "0" },
        .{ .property = "margin", .value = "0" },
        .{ .property = "overflow", .value = "visible" },
        .{ .property = "clip", .value = "auto" },
        .{ .property = "white-space", .value = "normal" },
    } },

    // ── Ring width: bare `ring` defaults to 3px ────────────────────────────
    .{ .name = "ring", .decls = &.{
        .{ .property = "--tw-ring-shadow", .value = "var(--tw-ring-inset, ) 0 0 0 calc(3px + var(--tw-ring-offset-width, 0px)) var(--tw-ring-color, currentColor)" },
        .{ .property = "box-shadow", .value = "var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow), var(--tw-shadow, 0 0 #0000)" },
    } },

    // ── Font smoothing ──────────────────────────────────────────────────────
    .{ .name = "antialiased", .decls = &.{
        .{ .property = "-webkit-font-smoothing", .value = "antialiased" },
        .{ .property = "-moz-osx-font-smoothing", .value = "grayscale" },
    } },
    .{ .name = "subpixel-antialiased", .decls = &.{
        .{ .property = "-webkit-font-smoothing", .value = "auto" },
        .{ .property = "-moz-osx-font-smoothing", .value = "auto" },
    } },

    // ── Overflow (full set) ─────────────────────────────────────────────────
    .{ .name = "overflow-auto", .decls = &.{.{ .property = "overflow", .value = "auto" }} },
    .{ .name = "overflow-hidden", .decls = &.{.{ .property = "overflow", .value = "hidden" }} },
    .{ .name = "overflow-clip", .decls = &.{.{ .property = "overflow", .value = "clip" }} },
    .{ .name = "overflow-visible", .decls = &.{.{ .property = "overflow", .value = "visible" }} },
    .{ .name = "overflow-scroll", .decls = &.{.{ .property = "overflow", .value = "scroll" }} },
    .{ .name = "overflow-x-auto", .decls = &.{.{ .property = "overflow-x", .value = "auto" }} },
    .{ .name = "overflow-x-hidden", .decls = &.{.{ .property = "overflow-x", .value = "hidden" }} },
    .{ .name = "overflow-x-clip", .decls = &.{.{ .property = "overflow-x", .value = "clip" }} },
    .{ .name = "overflow-x-visible", .decls = &.{.{ .property = "overflow-x", .value = "visible" }} },
    .{ .name = "overflow-x-scroll", .decls = &.{.{ .property = "overflow-x", .value = "scroll" }} },
    .{ .name = "overflow-y-auto", .decls = &.{.{ .property = "overflow-y", .value = "auto" }} },
    .{ .name = "overflow-y-hidden", .decls = &.{.{ .property = "overflow-y", .value = "hidden" }} },
    .{ .name = "overflow-y-clip", .decls = &.{.{ .property = "overflow-y", .value = "clip" }} },
    .{ .name = "overflow-y-visible", .decls = &.{.{ .property = "overflow-y", .value = "visible" }} },
    .{ .name = "overflow-y-scroll", .decls = &.{.{ .property = "overflow-y", .value = "scroll" }} },

    // ── Marker classes (no output; used by other variants like peer-*) ──────
    .{ .name = "peer", .decls = &.{} },
    .{ .name = "group", .decls = &.{} },

    // ── Mask family (statics) ───────────────────────────────────────────────
    .{ .name = "mask-none", .decls = &.{.{ .property = "mask-image", .value = "none" }} },
    .{ .name = "mask-add", .decls = &.{.{ .property = "mask-composite", .value = "add" }} },
    .{ .name = "mask-subtract", .decls = &.{.{ .property = "mask-composite", .value = "subtract" }} },
    .{ .name = "mask-intersect", .decls = &.{.{ .property = "mask-composite", .value = "intersect" }} },
    .{ .name = "mask-exclude", .decls = &.{.{ .property = "mask-composite", .value = "exclude" }} },
    .{ .name = "mask-alpha", .decls = &.{.{ .property = "mask-mode", .value = "alpha" }} },
    .{ .name = "mask-luminance", .decls = &.{.{ .property = "mask-mode", .value = "luminance" }} },
    .{ .name = "mask-match", .decls = &.{.{ .property = "mask-mode", .value = "match-source" }} },
    .{ .name = "mask-type-alpha", .decls = &.{.{ .property = "mask-type", .value = "alpha" }} },
    .{ .name = "mask-type-luminance", .decls = &.{.{ .property = "mask-type", .value = "luminance" }} },
    .{ .name = "mask-auto", .decls = &.{.{ .property = "mask-size", .value = "auto" }} },
    .{ .name = "mask-cover", .decls = &.{.{ .property = "mask-size", .value = "cover" }} },
    .{ .name = "mask-contain", .decls = &.{.{ .property = "mask-size", .value = "contain" }} },
    .{ .name = "mask-top", .decls = &.{.{ .property = "mask-position", .value = "top" }} },
    .{ .name = "mask-top-left", .decls = &.{.{ .property = "mask-position", .value = "left top" }} },
    .{ .name = "mask-top-right", .decls = &.{.{ .property = "mask-position", .value = "right top" }} },
    .{ .name = "mask-bottom", .decls = &.{.{ .property = "mask-position", .value = "bottom" }} },
    .{ .name = "mask-bottom-left", .decls = &.{.{ .property = "mask-position", .value = "left bottom" }} },
    .{ .name = "mask-bottom-right", .decls = &.{.{ .property = "mask-position", .value = "right bottom" }} },
    .{ .name = "mask-left", .decls = &.{.{ .property = "mask-position", .value = "left" }} },
    .{ .name = "mask-right", .decls = &.{.{ .property = "mask-position", .value = "right" }} },
    .{ .name = "mask-center", .decls = &.{.{ .property = "mask-position", .value = "center" }} },
    .{ .name = "mask-repeat", .decls = &.{.{ .property = "mask-repeat", .value = "repeat" }} },
    .{ .name = "mask-no-repeat", .decls = &.{.{ .property = "mask-repeat", .value = "no-repeat" }} },
    .{ .name = "mask-repeat-x", .decls = &.{.{ .property = "mask-repeat", .value = "repeat-x" }} },
    .{ .name = "mask-repeat-y", .decls = &.{.{ .property = "mask-repeat", .value = "repeat-y" }} },
    .{ .name = "mask-repeat-round", .decls = &.{.{ .property = "mask-repeat", .value = "round" }} },
    .{ .name = "mask-repeat-space", .decls = &.{.{ .property = "mask-repeat", .value = "space" }} },
    .{ .name = "mask-clip-border", .decls = &.{.{ .property = "mask-clip", .value = "border-box" }} },
    .{ .name = "mask-clip-padding", .decls = &.{.{ .property = "mask-clip", .value = "padding-box" }} },
    .{ .name = "mask-clip-content", .decls = &.{.{ .property = "mask-clip", .value = "content-box" }} },
    .{ .name = "mask-clip-fill", .decls = &.{.{ .property = "mask-clip", .value = "fill-box" }} },
    .{ .name = "mask-clip-stroke", .decls = &.{.{ .property = "mask-clip", .value = "stroke-box" }} },
    .{ .name = "mask-clip-view", .decls = &.{.{ .property = "mask-clip", .value = "view-box" }} },
    .{ .name = "mask-no-clip", .decls = &.{.{ .property = "mask-clip", .value = "no-clip" }} },
    .{ .name = "mask-origin-border", .decls = &.{.{ .property = "mask-origin", .value = "border-box" }} },
    .{ .name = "mask-origin-padding", .decls = &.{.{ .property = "mask-origin", .value = "padding-box" }} },
    .{ .name = "mask-origin-content", .decls = &.{.{ .property = "mask-origin", .value = "content-box" }} },
    .{ .name = "mask-origin-fill", .decls = &.{.{ .property = "mask-origin", .value = "fill-box" }} },
    .{ .name = "mask-origin-stroke", .decls = &.{.{ .property = "mask-origin", .value = "stroke-box" }} },
    .{ .name = "mask-origin-view", .decls = &.{.{ .property = "mask-origin", .value = "view-box" }} },
    .{ .name = "mask-circle", .decls = &.{.{ .property = "--tw-mask-radial-shape", .value = "circle" }} },
    .{ .name = "mask-ellipse", .decls = &.{.{ .property = "--tw-mask-radial-shape", .value = "ellipse" }} },
    .{ .name = "mask-radial-closest-side", .decls = &.{.{ .property = "--tw-mask-radial-size", .value = "closest-side" }} },
    .{ .name = "mask-radial-farthest-side", .decls = &.{.{ .property = "--tw-mask-radial-size", .value = "farthest-side" }} },
    .{ .name = "mask-radial-closest-corner", .decls = &.{.{ .property = "--tw-mask-radial-size", .value = "closest-corner" }} },
    .{ .name = "mask-radial-farthest-corner", .decls = &.{.{ .property = "--tw-mask-radial-size", .value = "farthest-corner" }} },
    .{ .name = "mask-radial-at-top", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "top" }} },
    .{ .name = "mask-radial-at-top-left", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "top left" }} },
    .{ .name = "mask-radial-at-top-right", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "top right" }} },
    .{ .name = "mask-radial-at-bottom", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "bottom" }} },
    .{ .name = "mask-radial-at-bottom-left", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "bottom left" }} },
    .{ .name = "mask-radial-at-bottom-right", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "bottom right" }} },
    .{ .name = "mask-radial-at-left", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "left" }} },
    .{ .name = "mask-radial-at-right", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "right" }} },
    .{ .name = "mask-radial-at-center", .decls = &.{.{ .property = "--tw-mask-radial-position", .value = "center" }} },

    // ── Space-reverse markers — flag classes referenced by `space-x-N` etc.
    //    in the v4-with-CSS-variables emission. We don't emit the variable
    //    chain (simpler `> :not(:last-child)` form is used), but the markers
    //    still need to be recognised so they don't fall through as unknown.
    .{ .name = "space-x-reverse", .decls = &.{} },
    .{ .name = "space-y-reverse", .decls = &.{} },

    // ── Background size ─────────────────────────────────────────────────────
    .{ .name = "bg-auto", .decls = &.{.{ .property = "background-size", .value = "auto" }} },
    .{ .name = "bg-cover", .decls = &.{.{ .property = "background-size", .value = "cover" }} },
    .{ .name = "bg-contain", .decls = &.{.{ .property = "background-size", .value = "contain" }} },

    // ── Background attachment ───────────────────────────────────────────────
    .{ .name = "bg-fixed", .decls = &.{.{ .property = "background-attachment", .value = "fixed" }} },
    .{ .name = "bg-local", .decls = &.{.{ .property = "background-attachment", .value = "local" }} },
    .{ .name = "bg-scroll", .decls = &.{.{ .property = "background-attachment", .value = "scroll" }} },

    // ── Background position ─────────────────────────────────────────────────
    .{ .name = "bg-top", .decls = &.{.{ .property = "background-position", .value = "top" }} },
    .{ .name = "bg-top-left", .decls = &.{.{ .property = "background-position", .value = "left top" }} },
    .{ .name = "bg-top-right", .decls = &.{.{ .property = "background-position", .value = "right top" }} },
    .{ .name = "bg-bottom", .decls = &.{.{ .property = "background-position", .value = "bottom" }} },
    .{ .name = "bg-bottom-left", .decls = &.{.{ .property = "background-position", .value = "left bottom" }} },
    .{ .name = "bg-bottom-right", .decls = &.{.{ .property = "background-position", .value = "right bottom" }} },
    .{ .name = "bg-left", .decls = &.{.{ .property = "background-position", .value = "left" }} },
    .{ .name = "bg-right", .decls = &.{.{ .property = "background-position", .value = "right" }} },
    .{ .name = "bg-center", .decls = &.{.{ .property = "background-position", .value = "center" }} },

    // ── Background repeat ───────────────────────────────────────────────────
    .{ .name = "bg-repeat", .decls = &.{.{ .property = "background-repeat", .value = "repeat" }} },
    .{ .name = "bg-no-repeat", .decls = &.{.{ .property = "background-repeat", .value = "no-repeat" }} },
    .{ .name = "bg-repeat-x", .decls = &.{.{ .property = "background-repeat", .value = "repeat-x" }} },
    .{ .name = "bg-repeat-y", .decls = &.{.{ .property = "background-repeat", .value = "repeat-y" }} },
    .{ .name = "bg-repeat-round", .decls = &.{.{ .property = "background-repeat", .value = "round" }} },
    .{ .name = "bg-repeat-space", .decls = &.{.{ .property = "background-repeat", .value = "space" }} },

    // ── Background image: none ──────────────────────────────────────────────
    .{ .name = "bg-none", .decls = &.{.{ .property = "background-image", .value = "none" }} },

    // ── Background clip ─────────────────────────────────────────────────────
    .{ .name = "bg-clip-text", .decls = &.{.{ .property = "background-clip", .value = "text" }} },
    .{ .name = "bg-clip-border", .decls = &.{.{ .property = "background-clip", .value = "border-box" }} },
    .{ .name = "bg-clip-padding", .decls = &.{.{ .property = "background-clip", .value = "padding-box" }} },
    .{ .name = "bg-clip-content", .decls = &.{.{ .property = "background-clip", .value = "content-box" }} },

    // ── Background origin ───────────────────────────────────────────────────
    .{ .name = "bg-origin-border", .decls = &.{.{ .property = "background-origin", .value = "border-box" }} },
    .{ .name = "bg-origin-padding", .decls = &.{.{ .property = "background-origin", .value = "padding-box" }} },
    .{ .name = "bg-origin-content", .decls = &.{.{ .property = "background-origin", .value = "content-box" }} },

    // ── Background blend mode ───────────────────────────────────────────────
    .{ .name = "bg-blend-normal", .decls = &.{.{ .property = "background-blend-mode", .value = "normal" }} },
    .{ .name = "bg-blend-multiply", .decls = &.{.{ .property = "background-blend-mode", .value = "multiply" }} },
    .{ .name = "bg-blend-screen", .decls = &.{.{ .property = "background-blend-mode", .value = "screen" }} },
    .{ .name = "bg-blend-overlay", .decls = &.{.{ .property = "background-blend-mode", .value = "overlay" }} },
    .{ .name = "bg-blend-darken", .decls = &.{.{ .property = "background-blend-mode", .value = "darken" }} },
    .{ .name = "bg-blend-lighten", .decls = &.{.{ .property = "background-blend-mode", .value = "lighten" }} },
    .{ .name = "bg-blend-color-dodge", .decls = &.{.{ .property = "background-blend-mode", .value = "color-dodge" }} },
    .{ .name = "bg-blend-color-burn", .decls = &.{.{ .property = "background-blend-mode", .value = "color-burn" }} },
    .{ .name = "bg-blend-hard-light", .decls = &.{.{ .property = "background-blend-mode", .value = "hard-light" }} },
    .{ .name = "bg-blend-soft-light", .decls = &.{.{ .property = "background-blend-mode", .value = "soft-light" }} },
    .{ .name = "bg-blend-difference", .decls = &.{.{ .property = "background-blend-mode", .value = "difference" }} },
    .{ .name = "bg-blend-exclusion", .decls = &.{.{ .property = "background-blend-mode", .value = "exclusion" }} },
    .{ .name = "bg-blend-hue", .decls = &.{.{ .property = "background-blend-mode", .value = "hue" }} },
    .{ .name = "bg-blend-saturation", .decls = &.{.{ .property = "background-blend-mode", .value = "saturation" }} },
    .{ .name = "bg-blend-color", .decls = &.{.{ .property = "background-blend-mode", .value = "color" }} },
    .{ .name = "bg-blend-luminosity", .decls = &.{.{ .property = "background-blend-mode", .value = "luminosity" }} },

    // ── Mix blend mode ──────────────────────────────────────────────────────
    .{ .name = "mix-blend-normal", .decls = &.{.{ .property = "mix-blend-mode", .value = "normal" }} },
    .{ .name = "mix-blend-multiply", .decls = &.{.{ .property = "mix-blend-mode", .value = "multiply" }} },
    .{ .name = "mix-blend-screen", .decls = &.{.{ .property = "mix-blend-mode", .value = "screen" }} },
    .{ .name = "mix-blend-overlay", .decls = &.{.{ .property = "mix-blend-mode", .value = "overlay" }} },
    .{ .name = "mix-blend-darken", .decls = &.{.{ .property = "mix-blend-mode", .value = "darken" }} },
    .{ .name = "mix-blend-lighten", .decls = &.{.{ .property = "mix-blend-mode", .value = "lighten" }} },
    .{ .name = "mix-blend-color-dodge", .decls = &.{.{ .property = "mix-blend-mode", .value = "color-dodge" }} },
    .{ .name = "mix-blend-color-burn", .decls = &.{.{ .property = "mix-blend-mode", .value = "color-burn" }} },
    .{ .name = "mix-blend-hard-light", .decls = &.{.{ .property = "mix-blend-mode", .value = "hard-light" }} },
    .{ .name = "mix-blend-soft-light", .decls = &.{.{ .property = "mix-blend-mode", .value = "soft-light" }} },
    .{ .name = "mix-blend-difference", .decls = &.{.{ .property = "mix-blend-mode", .value = "difference" }} },
    .{ .name = "mix-blend-exclusion", .decls = &.{.{ .property = "mix-blend-mode", .value = "exclusion" }} },
    .{ .name = "mix-blend-hue", .decls = &.{.{ .property = "mix-blend-mode", .value = "hue" }} },
    .{ .name = "mix-blend-saturation", .decls = &.{.{ .property = "mix-blend-mode", .value = "saturation" }} },
    .{ .name = "mix-blend-color", .decls = &.{.{ .property = "mix-blend-mode", .value = "color" }} },
    .{ .name = "mix-blend-luminosity", .decls = &.{.{ .property = "mix-blend-mode", .value = "luminosity" }} },
    .{ .name = "mix-blend-plus-darker", .decls = &.{.{ .property = "mix-blend-mode", .value = "plus-darker" }} },
    .{ .name = "mix-blend-plus-lighter", .decls = &.{.{ .property = "mix-blend-mode", .value = "plus-lighter" }} },

    // ── Gradient via-none ───────────────────────────────────────────────────
    .{ .name = "via-none", .decls = &.{.{ .property = "--tw-gradient-via-stops", .value = "initial" }} },

    // ── Gradient base shapes (no value / no angle) ──────────────────────────
    .{ .name = "bg-radial", .decls = &.{
        .{ .property = "--tw-gradient-position", .value = "in oklab" },
        .{ .property = "background-image", .value = "radial-gradient(var(--tw-gradient-stops, var(--tw-gradient-stops-fallback)))" },
    } },
    .{ .name = "bg-conic", .decls = &.{
        .{ .property = "--tw-gradient-position", .value = "in oklab" },
        .{ .property = "background-image", .value = "conic-gradient(var(--tw-gradient-stops, var(--tw-gradient-stops-fallback)))" },
    } },

    // ── Border width — bare forms (functional `border-N` handled separately) ─
    .{ .name = "border", .decls = &.{
        .{ .property = "border-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-width", .value = "1px" },
    } },
    .{ .name = "border-t", .decls = &.{
        .{ .property = "border-top-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-top-width", .value = "1px" },
    } },
    .{ .name = "border-r", .decls = &.{
        .{ .property = "border-right-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-right-width", .value = "1px" },
    } },
    .{ .name = "border-b", .decls = &.{
        .{ .property = "border-bottom-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-bottom-width", .value = "1px" },
    } },
    .{ .name = "border-l", .decls = &.{
        .{ .property = "border-left-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-left-width", .value = "1px" },
    } },
    .{ .name = "border-x", .decls = &.{
        .{ .property = "border-inline-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-inline-width", .value = "1px" },
    } },
    .{ .name = "border-y", .decls = &.{
        .{ .property = "border-block-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-block-width", .value = "1px" },
    } },
    .{ .name = "border-s", .decls = &.{
        .{ .property = "border-inline-start-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-inline-start-width", .value = "1px" },
    } },
    .{ .name = "border-e", .decls = &.{
        .{ .property = "border-inline-end-style", .value = "var(--tw-border-style, solid)" },
        .{ .property = "border-inline-end-width", .value = "1px" },
    } },

    // ── Border style ────────────────────────────────────────────────────────
    .{ .name = "border-solid", .decls = &.{
        .{ .property = "--tw-border-style", .value = "solid" },
        .{ .property = "border-style", .value = "solid" },
    } },
    .{ .name = "border-dashed", .decls = &.{
        .{ .property = "--tw-border-style", .value = "dashed" },
        .{ .property = "border-style", .value = "dashed" },
    } },
    .{ .name = "border-dotted", .decls = &.{
        .{ .property = "--tw-border-style", .value = "dotted" },
        .{ .property = "border-style", .value = "dotted" },
    } },
    .{ .name = "border-double", .decls = &.{
        .{ .property = "--tw-border-style", .value = "double" },
        .{ .property = "border-style", .value = "double" },
    } },
    .{ .name = "border-hidden", .decls = &.{
        .{ .property = "--tw-border-style", .value = "hidden" },
        .{ .property = "border-style", .value = "hidden" },
    } },
    .{ .name = "border-none", .decls = &.{
        .{ .property = "--tw-border-style", .value = "none" },
        .{ .property = "border-style", .value = "none" },
    } },

    // ── Border radius — bare + extremes (theme-driven scale handled below) ──
    .{ .name = "rounded", .decls = &.{.{ .property = "border-radius", .value = "var(--radius)" }} },
    .{ .name = "rounded-none", .decls = &.{.{ .property = "border-radius", .value = "0" }} },
    .{ .name = "rounded-full", .decls = &.{.{ .property = "border-radius", .value = "calc(infinity * 1px)" }} },

    // ── Misc ────────────────────────────────────────────────────────────────
    // ── Cursor (full supported set) ─────────────────────────────────────────
    .{ .name = "cursor-auto", .decls = &.{.{ .property = "cursor", .value = "auto" }} },
    .{ .name = "cursor-default", .decls = &.{.{ .property = "cursor", .value = "default" }} },
    .{ .name = "cursor-pointer", .decls = &.{.{ .property = "cursor", .value = "pointer" }} },
    .{ .name = "cursor-wait", .decls = &.{.{ .property = "cursor", .value = "wait" }} },
    .{ .name = "cursor-text", .decls = &.{.{ .property = "cursor", .value = "text" }} },
    .{ .name = "cursor-move", .decls = &.{.{ .property = "cursor", .value = "move" }} },
    .{ .name = "cursor-help", .decls = &.{.{ .property = "cursor", .value = "help" }} },
    .{ .name = "cursor-not-allowed", .decls = &.{.{ .property = "cursor", .value = "not-allowed" }} },
    .{ .name = "cursor-none", .decls = &.{.{ .property = "cursor", .value = "none" }} },
    .{ .name = "cursor-context-menu", .decls = &.{.{ .property = "cursor", .value = "context-menu" }} },
    .{ .name = "cursor-progress", .decls = &.{.{ .property = "cursor", .value = "progress" }} },
    .{ .name = "cursor-cell", .decls = &.{.{ .property = "cursor", .value = "cell" }} },
    .{ .name = "cursor-crosshair", .decls = &.{.{ .property = "cursor", .value = "crosshair" }} },
    .{ .name = "cursor-vertical-text", .decls = &.{.{ .property = "cursor", .value = "vertical-text" }} },
    .{ .name = "cursor-alias", .decls = &.{.{ .property = "cursor", .value = "alias" }} },
    .{ .name = "cursor-copy", .decls = &.{.{ .property = "cursor", .value = "copy" }} },
    .{ .name = "cursor-no-drop", .decls = &.{.{ .property = "cursor", .value = "no-drop" }} },
    .{ .name = "cursor-grab", .decls = &.{.{ .property = "cursor", .value = "grab" }} },
    .{ .name = "cursor-grabbing", .decls = &.{.{ .property = "cursor", .value = "grabbing" }} },
    .{ .name = "cursor-all-scroll", .decls = &.{.{ .property = "cursor", .value = "all-scroll" }} },
    .{ .name = "cursor-col-resize", .decls = &.{.{ .property = "cursor", .value = "col-resize" }} },
    .{ .name = "cursor-row-resize", .decls = &.{.{ .property = "cursor", .value = "row-resize" }} },
    .{ .name = "cursor-n-resize", .decls = &.{.{ .property = "cursor", .value = "n-resize" }} },
    .{ .name = "cursor-e-resize", .decls = &.{.{ .property = "cursor", .value = "e-resize" }} },
    .{ .name = "cursor-s-resize", .decls = &.{.{ .property = "cursor", .value = "s-resize" }} },
    .{ .name = "cursor-w-resize", .decls = &.{.{ .property = "cursor", .value = "w-resize" }} },
    .{ .name = "cursor-ne-resize", .decls = &.{.{ .property = "cursor", .value = "ne-resize" }} },
    .{ .name = "cursor-nw-resize", .decls = &.{.{ .property = "cursor", .value = "nw-resize" }} },
    .{ .name = "cursor-se-resize", .decls = &.{.{ .property = "cursor", .value = "se-resize" }} },
    .{ .name = "cursor-sw-resize", .decls = &.{.{ .property = "cursor", .value = "sw-resize" }} },
    .{ .name = "cursor-ew-resize", .decls = &.{.{ .property = "cursor", .value = "ew-resize" }} },
    .{ .name = "cursor-ns-resize", .decls = &.{.{ .property = "cursor", .value = "ns-resize" }} },
    .{ .name = "cursor-nesw-resize", .decls = &.{.{ .property = "cursor", .value = "nesw-resize" }} },
    .{ .name = "cursor-nwse-resize", .decls = &.{.{ .property = "cursor", .value = "nwse-resize" }} },
    .{ .name = "cursor-zoom-in", .decls = &.{.{ .property = "cursor", .value = "zoom-in" }} },
    .{ .name = "cursor-zoom-out", .decls = &.{.{ .property = "cursor", .value = "zoom-out" }} },

    // ── User-select ─────────────────────────────────────────────────────────
    .{ .name = "select-none", .decls = &.{.{ .property = "user-select", .value = "none" }} },
    .{ .name = "select-text", .decls = &.{.{ .property = "user-select", .value = "text" }} },
    .{ .name = "select-all", .decls = &.{.{ .property = "user-select", .value = "all" }} },
    .{ .name = "select-auto", .decls = &.{.{ .property = "user-select", .value = "auto" }} },

    // ── Object-fit ──────────────────────────────────────────────────────────
    .{ .name = "object-contain", .decls = &.{.{ .property = "object-fit", .value = "contain" }} },
    .{ .name = "object-cover", .decls = &.{.{ .property = "object-fit", .value = "cover" }} },
    .{ .name = "object-fill", .decls = &.{.{ .property = "object-fit", .value = "fill" }} },
    .{ .name = "object-none", .decls = &.{.{ .property = "object-fit", .value = "none" }} },
    .{ .name = "object-scale-down", .decls = &.{.{ .property = "object-fit", .value = "scale-down" }} },

    // ── Object-position ─────────────────────────────────────────────────────
    .{ .name = "object-top", .decls = &.{.{ .property = "object-position", .value = "top" }} },
    .{ .name = "object-right", .decls = &.{.{ .property = "object-position", .value = "right" }} },
    .{ .name = "object-bottom", .decls = &.{.{ .property = "object-position", .value = "bottom" }} },
    .{ .name = "object-left", .decls = &.{.{ .property = "object-position", .value = "left" }} },
    .{ .name = "object-center", .decls = &.{.{ .property = "object-position", .value = "center" }} },
    .{ .name = "object-top-right", .decls = &.{.{ .property = "object-position", .value = "top right" }} },
    .{ .name = "object-top-left", .decls = &.{.{ .property = "object-position", .value = "top left" }} },
    .{ .name = "object-bottom-right", .decls = &.{.{ .property = "object-position", .value = "bottom right" }} },
    .{ .name = "object-bottom-left", .decls = &.{.{ .property = "object-position", .value = "bottom left" }} },

    // ── Pointer-events ──────────────────────────────────────────────────────
    .{ .name = "pointer-events-auto", .decls = &.{.{ .property = "pointer-events", .value = "auto" }} },
    .{ .name = "pointer-events-none", .decls = &.{.{ .property = "pointer-events", .value = "none" }} },

    // ── Resize ──────────────────────────────────────────────────────────────
    .{ .name = "resize", .decls = &.{.{ .property = "resize", .value = "both" }} },
    .{ .name = "resize-x", .decls = &.{.{ .property = "resize", .value = "horizontal" }} },
    .{ .name = "resize-y", .decls = &.{.{ .property = "resize", .value = "vertical" }} },
    .{ .name = "resize-none", .decls = &.{.{ .property = "resize", .value = "none" }} },

    // ── Touch action ────────────────────────────────────────────────────────
    .{ .name = "touch-auto", .decls = &.{.{ .property = "touch-action", .value = "auto" }} },
    .{ .name = "touch-none", .decls = &.{.{ .property = "touch-action", .value = "none" }} },
    .{ .name = "touch-manipulation", .decls = &.{.{ .property = "touch-action", .value = "manipulation" }} },
    .{ .name = "touch-pan-x", .decls = &.{.{ .property = "touch-action", .value = "pan-x" }} },
    .{ .name = "touch-pan-left", .decls = &.{.{ .property = "touch-action", .value = "pan-left" }} },
    .{ .name = "touch-pan-right", .decls = &.{.{ .property = "touch-action", .value = "pan-right" }} },
    .{ .name = "touch-pan-y", .decls = &.{.{ .property = "touch-action", .value = "pan-y" }} },
    .{ .name = "touch-pan-up", .decls = &.{.{ .property = "touch-action", .value = "pan-up" }} },
    .{ .name = "touch-pan-down", .decls = &.{.{ .property = "touch-action", .value = "pan-down" }} },
    .{ .name = "touch-pinch-zoom", .decls = &.{.{ .property = "touch-action", .value = "pinch-zoom" }} },

    // ── Scroll behavior + scroll-snap-* ─────────────────────────────────────
    .{ .name = "scroll-auto", .decls = &.{.{ .property = "scroll-behavior", .value = "auto" }} },
    .{ .name = "scroll-smooth", .decls = &.{.{ .property = "scroll-behavior", .value = "smooth" }} },
    .{ .name = "snap-none", .decls = &.{.{ .property = "scroll-snap-type", .value = "none" }} },
    .{ .name = "snap-x", .decls = &.{.{ .property = "scroll-snap-type", .value = "x var(--tw-scroll-snap-strictness, proximity)" }} },
    .{ .name = "snap-y", .decls = &.{.{ .property = "scroll-snap-type", .value = "y var(--tw-scroll-snap-strictness, proximity)" }} },
    .{ .name = "snap-both", .decls = &.{.{ .property = "scroll-snap-type", .value = "both var(--tw-scroll-snap-strictness, proximity)" }} },
    .{ .name = "snap-mandatory", .decls = &.{.{ .property = "--tw-scroll-snap-strictness", .value = "mandatory" }} },
    .{ .name = "snap-proximity", .decls = &.{.{ .property = "--tw-scroll-snap-strictness", .value = "proximity" }} },
    .{ .name = "snap-align-none", .decls = &.{.{ .property = "scroll-snap-align", .value = "none" }} },
    .{ .name = "snap-start", .decls = &.{.{ .property = "scroll-snap-align", .value = "start" }} },
    .{ .name = "snap-end", .decls = &.{.{ .property = "scroll-snap-align", .value = "end" }} },
    .{ .name = "snap-center", .decls = &.{.{ .property = "scroll-snap-align", .value = "center" }} },
    .{ .name = "snap-normal", .decls = &.{.{ .property = "scroll-snap-stop", .value = "normal" }} },
    .{ .name = "snap-always", .decls = &.{.{ .property = "scroll-snap-stop", .value = "always" }} },

    // ── Will-change ─────────────────────────────────────────────────────────
    .{ .name = "will-change-auto", .decls = &.{.{ .property = "will-change", .value = "auto" }} },
    .{ .name = "will-change-scroll", .decls = &.{.{ .property = "will-change", .value = "scroll-position" }} },
    .{ .name = "will-change-contents", .decls = &.{.{ .property = "will-change", .value = "contents" }} },
    .{ .name = "will-change-transform", .decls = &.{.{ .property = "will-change", .value = "transform" }} },

    // ── Forced colors / contain ─────────────────────────────────────────────
    .{ .name = "forced-color-adjust-none", .decls = &.{.{ .property = "forced-color-adjust", .value = "none" }} },
    .{ .name = "forced-color-adjust-auto", .decls = &.{.{ .property = "forced-color-adjust", .value = "auto" }} },
    .{ .name = "contain-none", .decls = &.{.{ .property = "contain", .value = "none" }} },
    .{ .name = "contain-content", .decls = &.{.{ .property = "contain", .value = "content" }} },
    .{ .name = "contain-strict", .decls = &.{.{ .property = "contain", .value = "strict" }} },
    .{ .name = "contain-size", .decls = &.{.{ .property = "contain", .value = "size" }} },
    .{ .name = "contain-inline-size", .decls = &.{.{ .property = "contain", .value = "inline-size" }} },
    .{ .name = "contain-layout", .decls = &.{.{ .property = "contain", .value = "layout" }} },
    .{ .name = "contain-paint", .decls = &.{.{ .property = "contain", .value = "paint" }} },
    .{ .name = "contain-style", .decls = &.{.{ .property = "contain", .value = "style" }} },

    // ── Overscroll ──────────────────────────────────────────────────────────
    .{ .name = "overscroll-auto", .decls = &.{.{ .property = "overscroll-behavior", .value = "auto" }} },
    .{ .name = "overscroll-contain", .decls = &.{.{ .property = "overscroll-behavior", .value = "contain" }} },
    .{ .name = "overscroll-none", .decls = &.{.{ .property = "overscroll-behavior", .value = "none" }} },
    .{ .name = "overscroll-x-auto", .decls = &.{.{ .property = "overscroll-behavior-x", .value = "auto" }} },
    .{ .name = "overscroll-x-contain", .decls = &.{.{ .property = "overscroll-behavior-x", .value = "contain" }} },
    .{ .name = "overscroll-x-none", .decls = &.{.{ .property = "overscroll-behavior-x", .value = "none" }} },
    .{ .name = "overscroll-y-auto", .decls = &.{.{ .property = "overscroll-behavior-y", .value = "auto" }} },
    .{ .name = "overscroll-y-contain", .decls = &.{.{ .property = "overscroll-behavior-y", .value = "contain" }} },
    .{ .name = "overscroll-y-none", .decls = &.{.{ .property = "overscroll-behavior-y", .value = "none" }} },

    // ── Break before/inside/after ───────────────────────────────────────────
    .{ .name = "break-before-auto", .decls = &.{.{ .property = "break-before", .value = "auto" }} },
    .{ .name = "break-before-avoid", .decls = &.{.{ .property = "break-before", .value = "avoid" }} },
    .{ .name = "break-before-all", .decls = &.{.{ .property = "break-before", .value = "all" }} },
    .{ .name = "break-before-avoid-page", .decls = &.{.{ .property = "break-before", .value = "avoid-page" }} },
    .{ .name = "break-before-page", .decls = &.{.{ .property = "break-before", .value = "page" }} },
    .{ .name = "break-before-left", .decls = &.{.{ .property = "break-before", .value = "left" }} },
    .{ .name = "break-before-right", .decls = &.{.{ .property = "break-before", .value = "right" }} },
    .{ .name = "break-before-column", .decls = &.{.{ .property = "break-before", .value = "column" }} },
    .{ .name = "break-inside-auto", .decls = &.{.{ .property = "break-inside", .value = "auto" }} },
    .{ .name = "break-inside-avoid", .decls = &.{.{ .property = "break-inside", .value = "avoid" }} },
    .{ .name = "break-inside-avoid-page", .decls = &.{.{ .property = "break-inside", .value = "avoid-page" }} },
    .{ .name = "break-inside-avoid-column", .decls = &.{.{ .property = "break-inside", .value = "avoid-column" }} },
    .{ .name = "break-after-auto", .decls = &.{.{ .property = "break-after", .value = "auto" }} },
    .{ .name = "break-after-avoid", .decls = &.{.{ .property = "break-after", .value = "avoid" }} },
    .{ .name = "break-after-all", .decls = &.{.{ .property = "break-after", .value = "all" }} },
    .{ .name = "break-after-avoid-page", .decls = &.{.{ .property = "break-after", .value = "avoid-page" }} },
    .{ .name = "break-after-page", .decls = &.{.{ .property = "break-after", .value = "page" }} },
    .{ .name = "break-after-left", .decls = &.{.{ .property = "break-after", .value = "left" }} },
    .{ .name = "break-after-right", .decls = &.{.{ .property = "break-after", .value = "right" }} },
    .{ .name = "break-after-column", .decls = &.{.{ .property = "break-after", .value = "column" }} },

    // ── Transition (bare + property variants + none) ────────────────────────
    .{ .name = "transition", .decls = &.{
        .{ .property = "transition-property", .value = "color, background-color, border-color, outline-color, text-decoration-color, fill, stroke, --tw-gradient-from, --tw-gradient-via, --tw-gradient-to, opacity, box-shadow, transform, translate, scale, rotate, filter, backdrop-filter" },
        .{ .property = "transition-timing-function", .value = "var(--default-transition-timing-function, ease)" },
        .{ .property = "transition-duration", .value = "var(--default-transition-duration, 150ms)" },
    } },
    .{ .name = "transition-all", .decls = &.{
        .{ .property = "transition-property", .value = "all" },
        .{ .property = "transition-timing-function", .value = "var(--default-transition-timing-function, ease)" },
        .{ .property = "transition-duration", .value = "var(--default-transition-duration, 150ms)" },
    } },
    .{ .name = "transition-colors", .decls = &.{
        .{ .property = "transition-property", .value = "color, background-color, border-color, outline-color, text-decoration-color, fill, stroke, --tw-gradient-from, --tw-gradient-via, --tw-gradient-to" },
        .{ .property = "transition-timing-function", .value = "var(--default-transition-timing-function, ease)" },
        .{ .property = "transition-duration", .value = "var(--default-transition-duration, 150ms)" },
    } },
    .{ .name = "transition-opacity", .decls = &.{
        .{ .property = "transition-property", .value = "opacity" },
        .{ .property = "transition-timing-function", .value = "var(--default-transition-timing-function, ease)" },
        .{ .property = "transition-duration", .value = "var(--default-transition-duration, 150ms)" },
    } },
    .{ .name = "transition-shadow", .decls = &.{
        .{ .property = "transition-property", .value = "box-shadow" },
        .{ .property = "transition-timing-function", .value = "var(--default-transition-timing-function, ease)" },
        .{ .property = "transition-duration", .value = "var(--default-transition-duration, 150ms)" },
    } },
    .{ .name = "transition-transform", .decls = &.{
        .{ .property = "transition-property", .value = "transform, translate, scale, rotate" },
        .{ .property = "transition-timing-function", .value = "var(--default-transition-timing-function, ease)" },
        .{ .property = "transition-duration", .value = "var(--default-transition-duration, 150ms)" },
    } },
    .{ .name = "transition-none", .decls = &.{.{ .property = "transition-property", .value = "none" }} },
    .{ .name = "transition-discrete", .decls = &.{.{ .property = "transition-behavior", .value = "allow-discrete" }} },
    .{ .name = "transition-normal", .decls = &.{.{ .property = "transition-behavior", .value = "normal" }} },
    .{ .name = "duration-initial", .decls = &.{.{ .property = "transition-duration", .value = "initial" }} },

    // ── Easing presets ──────────────────────────────────────────────────────
    .{ .name = "ease-linear", .decls = &.{.{ .property = "transition-timing-function", .value = "linear" }} },
    .{ .name = "ease-in", .decls = &.{.{ .property = "transition-timing-function", .value = "var(--ease-in, cubic-bezier(0.4, 0, 1, 1))" }} },
    .{ .name = "ease-out", .decls = &.{.{ .property = "transition-timing-function", .value = "var(--ease-out, cubic-bezier(0, 0, 0.2, 1))" }} },
    .{ .name = "ease-in-out", .decls = &.{.{ .property = "transition-timing-function", .value = "var(--ease-in-out, cubic-bezier(0.4, 0, 0.2, 1))" }} },
    .{ .name = "ease-initial", .decls = &.{.{ .property = "transition-timing-function", .value = "initial" }} },

    // ── Shadow base statics ─────────────────────────────────────────────────
    // Bare `shadow` defaults to the theme's `--shadow-DEFAULT` (or `--shadow`).
    // The functional `shadow-{key}` and `shadow-{color}` paths handle the rest.
    .{ .name = "shadow", .decls = &.{
        .{ .property = "--tw-shadow", .value = "var(--shadow, 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1))" },
        .{ .property = "box-shadow", .value = "var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow)" },
    } },
    .{ .name = "shadow-none", .decls = &.{
        .{ .property = "--tw-shadow", .value = "0 0 #0000" },
        .{ .property = "box-shadow", .value = "var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow)" },
    } },
    .{ .name = "shadow-initial", .decls = &.{.{ .property = "--tw-shadow-color", .value = "initial" }} },
    .{ .name = "shadow-inherit", .decls = &.{.{ .property = "--tw-shadow", .value = "inherit" }} },
    .{ .name = "inset-shadow-initial", .decls = &.{.{ .property = "--tw-inset-shadow-color", .value = "initial" }} },
    .{ .name = "drop-shadow-none", .decls = &.{.{ .property = "filter", .value = "drop-shadow(0 0 #0000)" }} },
    .{ .name = "text-shadow-initial", .decls = &.{.{ .property = "--tw-text-shadow-color", .value = "initial" }} },

    // ── Outline base statics ────────────────────────────────────────────────
    .{ .name = "outline", .decls = &.{
        .{ .property = "outline-style", .value = "solid" },
        .{ .property = "outline-width", .value = "1px" },
    } },
    .{ .name = "outline-none", .decls = &.{
        .{ .property = "outline-style", .value = "none" },
    } },
    .{ .name = "outline-hidden", .decls = &.{
        .{ .property = "outline", .value = "2px solid transparent" },
        .{ .property = "outline-offset", .value = "2px" },
    } },
    .{ .name = "outline-dashed", .decls = &.{.{ .property = "outline-style", .value = "dashed" }} },
    .{ .name = "outline-dotted", .decls = &.{.{ .property = "outline-style", .value = "dotted" }} },
    .{ .name = "outline-double", .decls = &.{.{ .property = "outline-style", .value = "double" }} },
    .{ .name = "isolate", .decls = &.{.{ .property = "isolation", .value = "isolate" }} },
    .{ .name = "ring-inset", .decls = &.{.{ .property = "--tw-ring-inset", .value = "inset" }} },

    // ── Sizing shortcuts ────────────────────────────────────────────────────
    .{ .name = "size-full", .decls = &.{
        .{ .property = "width", .value = "100%" },
        .{ .property = "height", .value = "100%" },
    } },
    .{ .name = "w-full", .decls = &.{.{ .property = "width", .value = "100%" }} },
    .{ .name = "h-full", .decls = &.{.{ .property = "height", .value = "100%" }} },

    // ── Width/height: viewport-units variants (property-dependent values) ──
    .{ .name = "w-screen", .decls = &.{.{ .property = "width", .value = "100vw" }} },
    .{ .name = "h-screen", .decls = &.{.{ .property = "height", .value = "100vh" }} },
    .{ .name = "min-w-screen", .decls = &.{.{ .property = "min-width", .value = "100vw" }} },
    .{ .name = "min-h-screen", .decls = &.{.{ .property = "min-height", .value = "100vh" }} },
    .{ .name = "max-w-screen", .decls = &.{.{ .property = "max-width", .value = "100vw" }} },
    .{ .name = "max-h-screen", .decls = &.{.{ .property = "max-height", .value = "100vh" }} },
    .{ .name = "h-svh", .decls = &.{.{ .property = "height", .value = "100svh" }} },
    .{ .name = "h-lvh", .decls = &.{.{ .property = "height", .value = "100lvh" }} },
    .{ .name = "h-dvh", .decls = &.{.{ .property = "height", .value = "100dvh" }} },

    // ── Logical inline-size / block-size statics ───────────────────────────
    .{ .name = "inline-screen", .decls = &.{.{ .property = "inline-size", .value = "100vw" }} },
    .{ .name = "min-inline-screen", .decls = &.{.{ .property = "min-inline-size", .value = "100vw" }} },
    .{ .name = "max-inline-screen", .decls = &.{.{ .property = "max-inline-size", .value = "100vw" }} },
    .{ .name = "block-screen", .decls = &.{.{ .property = "block-size", .value = "100vh" }} },
    .{ .name = "min-block-screen", .decls = &.{.{ .property = "min-block-size", .value = "100vh" }} },
    .{ .name = "max-block-screen", .decls = &.{.{ .property = "max-block-size", .value = "100vh" }} },
    .{ .name = "inline-svw", .decls = &.{.{ .property = "inline-size", .value = "100svw" }} },
    .{ .name = "inline-lvw", .decls = &.{.{ .property = "inline-size", .value = "100lvw" }} },
    .{ .name = "inline-dvw", .decls = &.{.{ .property = "inline-size", .value = "100dvw" }} },
    .{ .name = "min-inline-svw", .decls = &.{.{ .property = "min-inline-size", .value = "100svw" }} },
    .{ .name = "min-inline-lvw", .decls = &.{.{ .property = "min-inline-size", .value = "100lvw" }} },
    .{ .name = "min-inline-dvw", .decls = &.{.{ .property = "min-inline-size", .value = "100dvw" }} },
    .{ .name = "max-inline-svw", .decls = &.{.{ .property = "max-inline-size", .value = "100svw" }} },
    .{ .name = "max-inline-lvw", .decls = &.{.{ .property = "max-inline-size", .value = "100lvw" }} },
    .{ .name = "max-inline-dvw", .decls = &.{.{ .property = "max-inline-size", .value = "100dvw" }} },
    .{ .name = "block-svh", .decls = &.{.{ .property = "block-size", .value = "100svh" }} },
    .{ .name = "block-lvh", .decls = &.{.{ .property = "block-size", .value = "100lvh" }} },
    .{ .name = "block-dvh", .decls = &.{.{ .property = "block-size", .value = "100dvh" }} },
    .{ .name = "min-block-svh", .decls = &.{.{ .property = "min-block-size", .value = "100svh" }} },
    .{ .name = "min-block-lvh", .decls = &.{.{ .property = "min-block-size", .value = "100lvh" }} },
    .{ .name = "min-block-dvh", .decls = &.{.{ .property = "min-block-size", .value = "100dvh" }} },
    .{ .name = "max-block-svh", .decls = &.{.{ .property = "max-block-size", .value = "100svh" }} },
    .{ .name = "max-block-lvh", .decls = &.{.{ .property = "max-block-size", .value = "100lvh" }} },
    .{ .name = "max-block-dvh", .decls = &.{.{ .property = "max-block-size", .value = "100dvh" }} },
    .{ .name = "block-lh", .decls = &.{.{ .property = "block-size", .value = "1lh" }} },
    .{ .name = "min-block-lh", .decls = &.{.{ .property = "min-block-size", .value = "1lh" }} },
    .{ .name = "max-block-lh", .decls = &.{.{ .property = "max-block-size", .value = "1lh" }} },

    // ── Order shortcuts ─────────────────────────────────────────────────────
    .{ .name = "order-first", .decls = &.{.{ .property = "order", .value = "-9999" }} },
    .{ .name = "order-last", .decls = &.{.{ .property = "order", .value = "9999" }} },
    .{ .name = "order-none", .decls = &.{.{ .property = "order", .value = "0" }} },

    // ── GPU compositing hint ────────────────────────────────────────────────
    .{ .name = "transform-gpu", .decls = &.{.{ .property = "transform", .value = "translateZ(0)" }} },
    .{ .name = "transform-none", .decls = &.{.{ .property = "transform", .value = "none" }} },
    .{ .name = "transform-cpu", .decls = &.{.{ .property = "transform", .value = "var(--tw-rotate-x,) var(--tw-rotate-y,) var(--tw-rotate-z,) var(--tw-skew-x,) var(--tw-skew-y,)" }} },

    // ── Transform style + box ───────────────────────────────────────────────
    .{ .name = "transform-flat", .decls = &.{.{ .property = "transform-style", .value = "flat" }} },
    .{ .name = "transform-3d", .decls = &.{.{ .property = "transform-style", .value = "preserve-3d" }} },
    .{ .name = "transform-content", .decls = &.{.{ .property = "transform-box", .value = "content-box" }} },
    .{ .name = "transform-border", .decls = &.{.{ .property = "transform-box", .value = "border-box" }} },
    .{ .name = "transform-fill", .decls = &.{.{ .property = "transform-box", .value = "fill-box" }} },
    .{ .name = "transform-stroke", .decls = &.{.{ .property = "transform-box", .value = "stroke-box" }} },
    .{ .name = "transform-view", .decls = &.{.{ .property = "transform-box", .value = "view-box" }} },

    // ── Transform 3D + per-axis statics ─────────────────────────────────────
    .{ .name = "translate-none", .decls = &.{.{ .property = "translate", .value = "none" }} },
    .{ .name = "translate-3d", .decls = &.{.{ .property = "translate", .value = "var(--tw-translate-x, 0) var(--tw-translate-y, 0) var(--tw-translate-z, 0)" }} },
    .{ .name = "scale-none", .decls = &.{.{ .property = "scale", .value = "none" }} },
    .{ .name = "scale-3d", .decls = &.{.{ .property = "scale", .value = "var(--tw-scale-x) var(--tw-scale-y) var(--tw-scale-z)" }} },
    .{ .name = "rotate-none", .decls = &.{.{ .property = "rotate", .value = "none" }} },

    // ── Backface visibility ─────────────────────────────────────────────────
    .{ .name = "backface-visible", .decls = &.{.{ .property = "backface-visibility", .value = "visible" }} },
    .{ .name = "backface-hidden", .decls = &.{.{ .property = "backface-visibility", .value = "hidden" }} },

    // ── Aspect ratio shortcuts ──────────────────────────────────────────────
    .{ .name = "aspect-square", .decls = &.{.{ .property = "aspect-ratio", .value = "1 / 1" }} },
    .{ .name = "aspect-video", .decls = &.{.{ .property = "aspect-ratio", .value = "16 / 9" }} },
    .{ .name = "aspect-auto", .decls = &.{.{ .property = "aspect-ratio", .value = "auto" }} },

    // ── Tables ──────────────────────────────────────────────────────────────
    .{ .name = "table-auto", .decls = &.{.{ .property = "table-layout", .value = "auto" }} },
    .{ .name = "table-fixed", .decls = &.{.{ .property = "table-layout", .value = "fixed" }} },
    .{ .name = "caption-top", .decls = &.{.{ .property = "caption-side", .value = "top" }} },
    .{ .name = "caption-bottom", .decls = &.{.{ .property = "caption-side", .value = "bottom" }} },
    .{ .name = "border-collapse", .decls = &.{.{ .property = "border-collapse", .value = "collapse" }} },
    .{ .name = "border-separate", .decls = &.{.{ .property = "border-collapse", .value = "separate" }} },

    // ── Forms ───────────────────────────────────────────────────────────────
    .{ .name = "appearance-none", .decls = &.{.{ .property = "appearance", .value = "none" }} },
    .{ .name = "appearance-auto", .decls = &.{.{ .property = "appearance", .value = "auto" }} },
    .{ .name = "scheme-normal", .decls = &.{.{ .property = "color-scheme", .value = "normal" }} },
    .{ .name = "scheme-dark", .decls = &.{.{ .property = "color-scheme", .value = "dark" }} },
    .{ .name = "scheme-light", .decls = &.{.{ .property = "color-scheme", .value = "light" }} },
    .{ .name = "scheme-light-dark", .decls = &.{.{ .property = "color-scheme", .value = "light dark" }} },
    .{ .name = "scheme-only-dark", .decls = &.{.{ .property = "color-scheme", .value = "only dark" }} },
    .{ .name = "scheme-only-light", .decls = &.{.{ .property = "color-scheme", .value = "only light" }} },

    // ── Color extras ────────────────────────────────────────────────────────
    .{ .name = "accent-auto", .decls = &.{.{ .property = "accent-color", .value = "auto" }} },
    .{ .name = "fill-none", .decls = &.{.{ .property = "fill", .value = "none" }} },
    .{ .name = "stroke-none", .decls = &.{.{ .property = "stroke", .value = "none" }} },

    // ── Sizing — line-height units ──────────────────────────────────────────
    .{ .name = "h-lh", .decls = &.{.{ .property = "height", .value = "1lh" }} },
    .{ .name = "min-h-lh", .decls = &.{.{ .property = "min-height", .value = "1lh" }} },
    .{ .name = "max-h-lh", .decls = &.{.{ .property = "max-height", .value = "1lh" }} },

    // ── Grid column shortcuts ───────────────────────────────────────────────
    .{ .name = "col-auto", .decls = &.{.{ .property = "grid-column", .value = "auto" }} },
    .{ .name = "col-span-full", .decls = &.{.{ .property = "grid-column", .value = "1 / -1" }} },
    .{ .name = "col-start-auto", .decls = &.{.{ .property = "grid-column-start", .value = "auto" }} },
    .{ .name = "col-end-auto", .decls = &.{.{ .property = "grid-column-end", .value = "auto" }} },

    // ── Grid row shortcuts ──────────────────────────────────────────────────
    .{ .name = "row-auto", .decls = &.{.{ .property = "grid-row", .value = "auto" }} },
    .{ .name = "row-span-full", .decls = &.{.{ .property = "grid-row", .value = "1 / -1" }} },
    .{ .name = "row-start-auto", .decls = &.{.{ .property = "grid-row-start", .value = "auto" }} },
    .{ .name = "row-end-auto", .decls = &.{.{ .property = "grid-row-end", .value = "auto" }} },

    // ── Tracking (letter-spacing) presets ──────────────────────────────────
    .{ .name = "tracking-tight", .decls = &.{.{ .property = "letter-spacing", .value = "-0.025em" }} },
    .{ .name = "tracking-tighter", .decls = &.{.{ .property = "letter-spacing", .value = "-0.05em" }} },
    .{ .name = "tracking-normal", .decls = &.{.{ .property = "letter-spacing", .value = "0em" }} },
    .{ .name = "tracking-wide", .decls = &.{.{ .property = "letter-spacing", .value = "0.025em" }} },
    .{ .name = "tracking-wider", .decls = &.{.{ .property = "letter-spacing", .value = "0.05em" }} },
};

/// Maps a root prefix (e.g. `p`, `mx`, `gap-x`, `min-w`) to one or more CSS
/// longhand properties. Used by the spacing dispatch in `resolveFunctional`
/// to handle padding, margin, gap, width/height variants, and the inset
/// sides — all of which share the same numeric-spacing-scale resolution.
const SpacingDispatchEntry = struct {
    root: []const u8,
    props: []const []const u8,
};

const SPACING_DISPATCH = [_]SpacingDispatchEntry{
    // ── Padding ─────────────────────────────────────────────────────────────
    .{ .root = "p", .props = &.{"padding"} },
    .{ .root = "pt", .props = &.{"padding-top"} },
    .{ .root = "pr", .props = &.{"padding-right"} },
    .{ .root = "pb", .props = &.{"padding-bottom"} },
    .{ .root = "pl", .props = &.{"padding-left"} },
    .{ .root = "px", .props = &.{ "padding-left", "padding-right" } },
    .{ .root = "py", .props = &.{ "padding-top", "padding-bottom" } },
    .{ .root = "ps", .props = &.{"padding-inline-start"} },
    .{ .root = "pe", .props = &.{"padding-inline-end"} },
    .{ .root = "pbs", .props = &.{"padding-block-start"} },
    .{ .root = "pbe", .props = &.{"padding-block-end"} },
    // ── Margin ──────────────────────────────────────────────────────────────
    .{ .root = "m", .props = &.{"margin"} },
    .{ .root = "mt", .props = &.{"margin-top"} },
    .{ .root = "mr", .props = &.{"margin-right"} },
    .{ .root = "mb", .props = &.{"margin-bottom"} },
    .{ .root = "ml", .props = &.{"margin-left"} },
    .{ .root = "mx", .props = &.{ "margin-left", "margin-right" } },
    .{ .root = "my", .props = &.{ "margin-top", "margin-bottom" } },
    .{ .root = "ms", .props = &.{"margin-inline-start"} },
    .{ .root = "me", .props = &.{"margin-inline-end"} },
    .{ .root = "mbs", .props = &.{"margin-block-start"} },
    .{ .root = "mbe", .props = &.{"margin-block-end"} },
    // ── Gap ─────────────────────────────────────────────────────────────────
    .{ .root = "gap", .props = &.{"gap"} },
    .{ .root = "gap-x", .props = &.{"column-gap"} },
    .{ .root = "gap-y", .props = &.{"row-gap"} },
    // ── Width / height ──────────────────────────────────────────────────────
    .{ .root = "w", .props = &.{"width"} },
    .{ .root = "h", .props = &.{"height"} },
    .{ .root = "min-w", .props = &.{"min-width"} },
    .{ .root = "min-h", .props = &.{"min-height"} },
    .{ .root = "max-w", .props = &.{"max-width"} },
    .{ .root = "max-h", .props = &.{"max-height"} },
    // ── Flex basis (spacing scale + container namespace) ───────────────────
    .{ .root = "basis", .props = &.{"flex-basis"} },
    // ── Logical inline-size / block-size ───────────────────────────────────
    .{ .root = "inline", .props = &.{"inline-size"} },
    .{ .root = "block", .props = &.{"block-size"} },
    .{ .root = "min-inline", .props = &.{"min-inline-size"} },
    .{ .root = "min-block", .props = &.{"min-block-size"} },
    .{ .root = "max-inline", .props = &.{"max-inline-size"} },
    .{ .root = "max-block", .props = &.{"max-block-size"} },
    // ── Inset sides (`top`/`right`/`bottom`/`left` as standalone roots) ────
    .{ .root = "top", .props = &.{"top"} },
    .{ .root = "right", .props = &.{"right"} },
    .{ .root = "bottom", .props = &.{"bottom"} },
    .{ .root = "left", .props = &.{"left"} },
    .{ .root = "start", .props = &.{"inset-inline-start"} },
    .{ .root = "end", .props = &.{"inset-inline-end"} },
    .{ .root = "inset-s", .props = &.{"inset-inline-start"} },
    .{ .root = "inset-e", .props = &.{"inset-inline-end"} },
    .{ .root = "inset-bs", .props = &.{"inset-block-start"} },
    .{ .root = "inset-be", .props = &.{"inset-block-end"} },
    // (translate-x/y/z handled by resolveTranslateAxis below — sets the
    //  per-axis var AND the composed `translate:` declaration.)
    // ── Scroll padding / margin (mirror padding/margin) ─────────────────────
    .{ .root = "scroll-p", .props = &.{"scroll-padding"} },
    .{ .root = "scroll-pt", .props = &.{"scroll-padding-top"} },
    .{ .root = "scroll-pr", .props = &.{"scroll-padding-right"} },
    .{ .root = "scroll-pb", .props = &.{"scroll-padding-bottom"} },
    .{ .root = "scroll-pl", .props = &.{"scroll-padding-left"} },
    .{ .root = "scroll-px", .props = &.{ "scroll-padding-left", "scroll-padding-right" } },
    .{ .root = "scroll-py", .props = &.{ "scroll-padding-top", "scroll-padding-bottom" } },
    .{ .root = "scroll-m", .props = &.{"scroll-margin"} },
    .{ .root = "scroll-mt", .props = &.{"scroll-margin-top"} },
    .{ .root = "scroll-mr", .props = &.{"scroll-margin-right"} },
    .{ .root = "scroll-mb", .props = &.{"scroll-margin-bottom"} },
    .{ .root = "scroll-ml", .props = &.{"scroll-margin-left"} },
    .{ .root = "scroll-mx", .props = &.{ "scroll-margin-left", "scroll-margin-right" } },
    .{ .root = "scroll-my", .props = &.{ "scroll-margin-top", "scroll-margin-bottom" } },
    .{ .root = "scroll-ms", .props = &.{"scroll-margin-inline-start"} },
    .{ .root = "scroll-me", .props = &.{"scroll-margin-inline-end"} },
    .{ .root = "scroll-mbs", .props = &.{"scroll-margin-block-start"} },
    .{ .root = "scroll-mbe", .props = &.{"scroll-margin-block-end"} },
    .{ .root = "scroll-ps", .props = &.{"scroll-padding-inline-start"} },
    .{ .root = "scroll-pe", .props = &.{"scroll-padding-inline-end"} },
    .{ .root = "scroll-pbs", .props = &.{"scroll-padding-block-start"} },
    .{ .root = "scroll-pbe", .props = &.{"scroll-padding-block-end"} },
};

fn resolveStatic(
    allocator: std.mem.Allocator,
    t: Theme,
    name: []const u8,
) ResolveError!?ResolvedUtility {
    _ = t;
    inline for (STATIC_UTILITIES) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            return try cloneDecls(allocator, entry.decls);
        }
    }
    return null;
}

fn cloneDecls(
    allocator: std.mem.Allocator,
    decls: []const Declaration,
) ResolveError!ResolvedUtility {
    const out = try allocator.alloc(Declaration, decls.len);
    errdefer allocator.free(out);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) allocator.free(out[j].value);
    }
    while (i < decls.len) : (i += 1) {
        const dup = try allocator.dupe(u8, decls[i].value);
        out[i] = .{ .property = decls[i].property, .value = dup };
    }
    return .{ .declarations = out };
}

// ── Functional utilities ────────────────────────────────────────────────────

fn resolveFunctional(
    allocator: std.mem.Allocator,
    t: Theme,
    f: anytype, // candidate.Candidate.functional payload
) ResolveError!?ResolvedUtility {
    const root = f.root;

    // Negative-prefix detection: roots like `-z` are forms of `z`.
    // We probe the root for a leading `-` and dispatch on the un-prefixed root.
    var unsigned_root = root;
    var negative = false;
    if (root.len > 0 and root[0] == '-') {
        unsigned_root = root[1..];
        negative = true;
    }

    // ── size-N (gap kind #8) — width + height from spacing scale ───────────
    if (std.mem.eql(u8, root, "size") and !negative) {
        return try resolveSpacingPair(allocator, t, f.value, &.{ "width", "height" });
    }

    // ── col-span-N (gap kind #11) — grid-column ────────────────────────────
    if (std.mem.eql(u8, root, "col-span") and !negative) {
        return try resolveSpanLonghand(allocator, f.value, "grid-column");
    }
    // ── row-span-N — grid-row counterpart ──────────────────────────────────
    if (std.mem.eql(u8, root, "row-span") and !negative) {
        return try resolveSpanLonghand(allocator, f.value, "grid-row");
    }

    // ── grid-cols-{N | subgrid} — extends gap kind #12 ────────────────────
    if (std.mem.eql(u8, root, "grid-cols") and !negative) {
        return try resolveGridTrack(allocator, f.value, "grid-template-columns");
    }
    // ── grid-rows-{N | subgrid} — counterpart ──────────────────────────────
    if (std.mem.eql(u8, root, "grid-rows") and !negative) {
        return try resolveGridTrack(allocator, f.value, "grid-template-rows");
    }

    // ── inset-N (gap kind #10) — routes through the generalized spacing
    //    dispatch so `inset-auto`, `inset-[10px]`, etc. all work uniformly.
    if (std.mem.eql(u8, unsigned_root, "inset")) {
        return try resolveSpacingPairSigned(allocator, t, f.value, f.modifier, &.{"inset"}, negative);
    }

    // ── space-x-N / space-y-N — child spacing via selector-modifying rule ──
    // Emits `.space-x-N > :not(:last-child) { margin-right: ... }` (or
    // `margin-bottom` for y). Uses ResolvedUtility.selector_suffix.
    if (std.mem.eql(u8, unsigned_root, "space-x")) {
        return try resolveSpaceAxis(allocator, t, f.value, "margin-right", negative);
    }
    if (std.mem.eql(u8, unsigned_root, "space-y")) {
        return try resolveSpaceAxis(allocator, t, f.value, "margin-bottom", negative);
    }

    // ── divide-x-N / divide-y-N — between-children border via selector mod ─
    // Emits `.divide-x-N > :not(:last-child) { border-right-width: Npx }`.
    // Default (just `divide-x`) is 1px. The same dispatch handles
    // `divide-{color}` by falling through to the color path below.
    if (std.mem.eql(u8, root, "divide-x") and !negative) {
        if (try resolveDivideAxis(allocator, f.value, "border-right-width")) |r| return r;
    }
    if (std.mem.eql(u8, root, "divide-y") and !negative) {
        if (try resolveDivideAxis(allocator, f.value, "border-bottom-width")) |r| return r;
    }
    // The parser splits `divide-y` (no width value) as functional
    // root=`divide` value=`y`. Catch that bare form before the color path
    // claims it. Same for `divide-x`.
    if (std.mem.eql(u8, root, "divide") and !negative and f.value != null and f.value.? == .named) {
        if (std.mem.eql(u8, f.value.?.named.value, "y")) {
            return try resolveDivideAxis(allocator, null, "border-bottom-width");
        }
        if (std.mem.eql(u8, f.value.?.named.value, "x")) {
            return try resolveDivideAxis(allocator, null, "border-right-width");
        }
    }
    // divide-{color} → sets border-color on the between-child rule.
    if (std.mem.eql(u8, root, "divide") and !negative) {
        if (try resolveDivideColor(allocator, t, f.value, f.modifier)) |r| return r;
    }

    // ── opacity-N (functional) ─────────────────────────────────────────────
    if (std.mem.eql(u8, root, "opacity") and !negative) {
        if (try resolveOpacity(allocator, f.value)) |r| return r;
    }

    // ── ring-N width (functional) ──────────────────────────────────────────
    if (std.mem.eql(u8, root, "ring") and !negative) {
        if (try resolveRingWidth(allocator, f.value)) |r| return r;
    }

    // ── Spacing dispatch (padding, margin, gap, width/height, inset sides) ─
    // Generic comptime table: map a root → one or more longhand properties.
    // Negative roots (e.g. `-m-4`, `-mx-2`, `-top-1`) work via the `negative`
    // flag detected at the top of this function. The modifier gets passed
    // through so fractional forms like `w-1/2` resolve to a percentage.
    inline for (SPACING_DISPATCH) |entry| {
        if (std.mem.eql(u8, unsigned_root, entry.root)) {
            return try resolveSpacingPairSigned(allocator, t, f.value, f.modifier, entry.props, negative);
        }
    }

    // ── z-N / -z-N (gap kind #1 covers negative case) ──────────────────────
    if (std.mem.eql(u8, unsigned_root, "z")) {
        return try resolveZIndex(allocator, f.value, negative);
    }

    // ── font-{family} (gap kind #9) — theme font lookup ────────────────────
    if (std.mem.eql(u8, root, "font") and !negative) {
        return try resolveFontFamily(allocator, t, f.value);
    }

    // ── text-{size} — theme text-size lookup. Falls through if the value
    //    isn't a `--text-*` token, leaving text-color cases to the color
    //    handler below (or, for other names, the legacy resolver).
    //    Modifier (`/N`) overrides line-height: `text-2xl/8` → font-size from
    //    --text-2xl, line-height = calc(var(--spacing) * 8).
    if (std.mem.eql(u8, root, "text") and !negative) {
        if (try resolveTextSize(allocator, t, f.value, f.modifier)) |r| return r;
    }

    // ── order-N / -order-N (CSS `order` longhand) ──────────────────────────
    if (std.mem.eql(u8, unsigned_root, "order")) {
        return try resolveIntegerLonghand(allocator, f.value, "order", negative);
    }

    // ── col-start-N, col-end-N ─────────────────────────────────────────────
    if (std.mem.eql(u8, root, "col-start") and !negative) {
        return try resolveIntegerLonghand(allocator, f.value, "grid-column-start", false);
    }
    if (std.mem.eql(u8, root, "col-end") and !negative) {
        return try resolveIntegerLonghand(allocator, f.value, "grid-column-end", false);
    }
    if (std.mem.eql(u8, root, "row-start") and !negative) {
        return try resolveIntegerLonghand(allocator, f.value, "grid-row-start", false);
    }
    if (std.mem.eql(u8, root, "row-end") and !negative) {
        return try resolveIntegerLonghand(allocator, f.value, "grid-row-end", false);
    }

    // ── Filter family: brightness, contrast, hue-rotate, saturate, sepia,
    //    grayscale, invert. Each emits filter:<fn>(<v>). Multiple filters
    //    on the same element overwrite — use the composed chain (Phase C1)
    //    when needed. Default values (no value) for grayscale/invert/sepia
    //    are 100%; brightness/contrast/saturate require an explicit N.
    if (std.mem.eql(u8, root, "brightness") and !negative) {
        if (try resolveFilterFn(allocator, t, f.value, "brightness", "%", null)) |r| return r;
    }
    if (std.mem.eql(u8, root, "contrast") and !negative) {
        if (try resolveFilterFn(allocator, t, f.value, "contrast", "%", null)) |r| return r;
    }
    if (std.mem.eql(u8, root, "saturate") and !negative) {
        if (try resolveFilterFn(allocator, t, f.value, "saturate", "%", null)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "hue-rotate")) {
        if (try resolveFilterFnSigned(allocator, t, f.value, "hue-rotate", "deg", null, negative)) |r| return r;
    }
    if (std.mem.eql(u8, root, "grayscale") and !negative) {
        if (try resolveFilterFn(allocator, t, f.value, "grayscale", "%", "100%")) |r| return r;
    }
    if (std.mem.eql(u8, root, "invert") and !negative) {
        if (try resolveFilterFn(allocator, t, f.value, "invert", "%", "100%")) |r| return r;
    }
    if (std.mem.eql(u8, root, "sepia") and !negative) {
        if (try resolveFilterFn(allocator, t, f.value, "sepia", "%", "100%")) |r| return r;
    }

    // ── Backdrop-filter family (mirror of filter; emit backdrop-filter) ────
    if (std.mem.eql(u8, root, "backdrop-brightness") and !negative) {
        if (try resolveBackdropFilterFn(allocator, t, f.value, "brightness", "%", null)) |r| return r;
    }
    if (std.mem.eql(u8, root, "backdrop-contrast") and !negative) {
        if (try resolveBackdropFilterFn(allocator, t, f.value, "contrast", "%", null)) |r| return r;
    }
    if (std.mem.eql(u8, root, "backdrop-saturate") and !negative) {
        if (try resolveBackdropFilterFn(allocator, t, f.value, "saturate", "%", null)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "backdrop-hue-rotate")) {
        if (try resolveBackdropFilterFnSigned(allocator, t, f.value, "hue-rotate", "deg", null, negative)) |r| return r;
    }
    if (std.mem.eql(u8, root, "backdrop-grayscale") and !negative) {
        if (try resolveBackdropFilterFn(allocator, t, f.value, "grayscale", "%", "100%")) |r| return r;
    }
    if (std.mem.eql(u8, root, "backdrop-invert") and !negative) {
        if (try resolveBackdropFilterFn(allocator, t, f.value, "invert", "%", "100%")) |r| return r;
    }
    if (std.mem.eql(u8, root, "backdrop-sepia") and !negative) {
        if (try resolveBackdropFilterFn(allocator, t, f.value, "sepia", "%", "100%")) |r| return r;
    }
    if (std.mem.eql(u8, root, "backdrop-opacity") and !negative) {
        if (try resolveBackdropFilterFn(allocator, t, f.value, "opacity", "%", null)) |r| return r;
    }

    // ── animate-{name|none|arbitrary} (theme `--animate-*`) ────────────────
    if (std.mem.eql(u8, root, "animate") and !negative) {
        if (try resolveAnimate(allocator, t, f.value)) |r| return r;
    }

    // ── backdrop-blur-{theme/none/arbitrary} ───────────────────────────────
    if (std.mem.eql(u8, root, "backdrop-blur") and !negative) {
        if (try resolveBackdropBlur(allocator, t, f.value)) |r| return r;
    }

    // ── drop-shadow-{theme/arbitrary} ──────────────────────────────────────
    if (std.mem.eql(u8, root, "drop-shadow") and !negative) {
        if (try resolveDropShadow(allocator, t, f.value)) |r| return r;
    }

    // ── ring-offset-N / ring-offset-{color} ────────────────────────────────
    if (std.mem.eql(u8, root, "ring-offset") and !negative) {
        if (try resolveRingOffset(allocator, t, f.value, f.modifier)) |r| return r;
    }

    // ── inset-ring-N / inset-ring-{color} ──────────────────────────────────
    if (std.mem.eql(u8, root, "inset-ring") and !negative) {
        if (try resolveInsetRing(allocator, t, f.value, f.modifier)) |r| return r;
    }

    // ── translate-N / translate-x-N / translate-y-N / translate-z-N ────────
    // Sets the per-axis `--tw-translate-{axis}` variable AND the composed
    // `translate:` declaration so x/y/z compose on the same element.
    if (std.mem.eql(u8, unsigned_root, "translate")) {
        if (try resolveTranslate(allocator, t, f.value, f.modifier, .both, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "translate-x")) {
        if (try resolveTranslate(allocator, t, f.value, f.modifier, .x, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "translate-y")) {
        if (try resolveTranslate(allocator, t, f.value, f.modifier, .y, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "translate-z")) {
        if (try resolveTranslate(allocator, t, f.value, f.modifier, .z, negative)) |r| return r;
    }

    // ── scale-N / scale-x-N / scale-y-N / scale-z-N ────────────────────────
    if (std.mem.eql(u8, unsigned_root, "scale")) {
        if (try resolveScale(allocator, t, f.value, .both, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "scale-x")) {
        if (try resolveScale(allocator, t, f.value, .x, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "scale-y")) {
        if (try resolveScale(allocator, t, f.value, .y, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "scale-z")) {
        if (try resolveScale(allocator, t, f.value, .z, negative)) |r| return r;
    }

    // ── rotate-N / -rotate-N (single property; no per-axis composition) ────
    if (std.mem.eql(u8, unsigned_root, "rotate")) {
        if (try resolveRotate(allocator, t, f.value, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "rotate-x")) {
        if (try resolveRotateAxis(allocator, t, f.value, .x, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "rotate-y")) {
        if (try resolveRotateAxis(allocator, t, f.value, .y, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "rotate-z")) {
        if (try resolveRotateAxis(allocator, t, f.value, .z, negative)) |r| return r;
    }

    // ── skew-N / skew-x-N / skew-y-N ───────────────────────────────────────
    if (std.mem.eql(u8, unsigned_root, "skew")) {
        if (try resolveSkew(allocator, t, f.value, .both, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "skew-x")) {
        if (try resolveSkew(allocator, t, f.value, .x, negative)) |r| return r;
    }
    if (std.mem.eql(u8, unsigned_root, "skew-y")) {
        if (try resolveSkew(allocator, t, f.value, .y, negative)) |r| return r;
    }

    // ── origin-{theme/named/arbitrary} (transform-origin) ──────────────────
    if (std.mem.eql(u8, root, "origin") and !negative) {
        if (try resolveTransformOrigin(allocator, t, f.value)) |r| return r;
    }
    if (std.mem.eql(u8, root, "perspective-origin") and !negative) {
        if (try resolveTransformOrigin(allocator, t, f.value)) |r| return r;
    }
    if (std.mem.eql(u8, root, "perspective") and !negative) {
        if (try resolvePerspective(allocator, t, f.value)) |r| return r;
    }

    // ── object-{theme/arbitrary} (object-position) ─────────────────────────
    if (std.mem.eql(u8, root, "object") and !negative) {
        if (try resolveArbitraryOrTheme(allocator, t, f.value, "object-position", "--object-position")) |r| return r;
    }
    // ── cursor-{theme/arbitrary} ──────────────────────────────────────────
    if (std.mem.eql(u8, root, "cursor") and !negative) {
        if (try resolveArbitraryOrTheme(allocator, t, f.value, "cursor", "--cursor")) |r| return r;
    }
    // ── will-change-{arbitrary} ────────────────────────────────────────────
    if (std.mem.eql(u8, root, "will-change") and !negative) {
        if (f.value) |v| switch (v) {
            .arbitrary => |a| return try resolveArbitraryProperty(allocator, "will-change", a.value, null),
            else => {},
        };
    }
    // ── contain-{arbitrary} ────────────────────────────────────────────────
    if (std.mem.eql(u8, root, "contain") and !negative) {
        if (f.value) |v| switch (v) {
            .arbitrary => |a| return try resolveArbitraryProperty(allocator, "contain", a.value, null),
            else => {},
        };
    }
    // ── border-spacing-{N/x/y} — composed via --tw-border-spacing-x/y ──────
    if (std.mem.eql(u8, root, "border-spacing") and !negative) {
        if (try resolveBorderSpacing(allocator, t, f.value, .both)) |r| return r;
    }
    if (std.mem.eql(u8, root, "border-spacing-x") and !negative) {
        if (try resolveBorderSpacing(allocator, t, f.value, .x)) |r| return r;
    }
    if (std.mem.eql(u8, root, "border-spacing-y") and !negative) {
        if (try resolveBorderSpacing(allocator, t, f.value, .y)) |r| return r;
    }

    // ── auto-cols-{auto/min/max/fr/arbitrary} ──────────────────────────────
    if (std.mem.eql(u8, root, "auto-cols") and !negative) {
        if (try resolveArbitraryOrTheme(allocator, t, f.value, "grid-auto-columns", "--grid-auto-columns")) |r| return r;
    }
    if (std.mem.eql(u8, root, "auto-rows") and !negative) {
        if (try resolveArbitraryOrTheme(allocator, t, f.value, "grid-auto-rows", "--grid-auto-rows")) |r| return r;
    }

    // ── columns-N (functional) ─────────────────────────────────────────────
    if (std.mem.eql(u8, root, "columns") and !negative) {
        if (try resolveColumns(allocator, t, f.value)) |r| return r;
    }

    // ── line-clamp-N / -[arb] ─────────────────────────────────────────────
    if (std.mem.eql(u8, root, "line-clamp") and !negative) {
        if (try resolveLineClamp(allocator, t, f.value)) |r| return r;
    }

    // ── indent-{spacing} (text-indent, supports negative) ──────────────────
    if (std.mem.eql(u8, unsigned_root, "indent")) {
        return try resolveSpacingPairSigned(allocator, t, f.value, f.modifier, &.{"text-indent"}, negative);
    }

    // ── tracking-N / -tracking-N (letter-spacing, supports negative) ───────
    if (std.mem.eql(u8, unsigned_root, "tracking")) {
        if (try resolveTracking(allocator, t, f.value, negative)) |r| return r;
    }

    // ── leading-N / leading-[arb] (line-height standalone) ─────────────────
    if (std.mem.eql(u8, root, "leading") and !negative) {
        if (try resolveLeading(allocator, t, f.value)) |r| return r;
    }

    // ── underline-offset-N / -underline-offset-N ──────────────────────────
    if (std.mem.eql(u8, unsigned_root, "underline-offset")) {
        if (try resolvePxLonghand(allocator, f.value, "text-underline-offset", negative)) |r| return r;
    }

    // ── decoration-{thickness} (numeric → Npx) ─────────────────────────────
    if (std.mem.eql(u8, root, "decoration") and !negative) {
        if (try resolveDecorationThickness(allocator, f.value)) |r| return r;
    }

    // ── list-{theme/arbitrary} ────────────────────────────────────────────
    if (std.mem.eql(u8, root, "list") and !negative) {
        if (try resolveArbitraryOrTheme(allocator, t, f.value, "list-style-type", "--list-style-type")) |r| return r;
    }
    if (std.mem.eql(u8, root, "list-image") and !negative) {
        if (try resolveArbitraryOrTheme(allocator, t, f.value, "list-style-image", "--list-style-image")) |r| return r;
    }

    // ── content-{theme/arbitrary} (sets --tw-content + content) ────────────
    if (std.mem.eql(u8, root, "content") and !negative) {
        if (try resolveContent(allocator, t, f.value)) |r| return r;
    }

    // ── flex-N / flex-W/H / flex-[arbitrary] (the `flex` shorthand) ────────
    if (std.mem.eql(u8, root, "flex") and !negative) {
        if (f.value) |v| {
            switch (v) {
                .arbitrary => |a| {
                    if (f.modifier == null) {
                        return try resolveArbitraryProperty(allocator, "flex", a.value, null);
                    }
                },
                .named => |n| {
                    if (n.fraction) |frac| {
                        const slash_idx = std.mem.indexOfScalar(u8, frac, '/') orelse return null;
                        const lhs = frac[0..slash_idx];
                        const rhs = frac[slash_idx + 1 ..];
                        if (!isInteger(lhs) or !isInteger(rhs)) return null;
                        const css_value = try std.fmt.allocPrint(allocator, "calc({s} * 100%)", .{frac});
                        errdefer allocator.free(css_value);
                        const decls = try allocator.alloc(Declaration, 1);
                        errdefer allocator.free(decls);
                        decls[0] = .{ .property = "flex", .value = css_value };
                        return .{ .declarations = decls };
                    }
                    if (isInteger(n.value) and f.modifier == null) {
                        const css_value = try allocator.dupe(u8, n.value);
                        errdefer allocator.free(css_value);
                        const decls = try allocator.alloc(Declaration, 1);
                        errdefer allocator.free(decls);
                        decls[0] = .{ .property = "flex", .value = css_value };
                        return .{ .declarations = decls };
                    }
                },
            }
        }
    }

    // ── shrink-N / grow-N (positive integer) ───────────────────────────────
    if (std.mem.eql(u8, root, "shrink") and !negative) {
        return try resolveIntegerLonghand(allocator, f.value, "flex-shrink", false);
    }
    if (std.mem.eql(u8, root, "grow") and !negative) {
        return try resolveIntegerLonghand(allocator, f.value, "flex-grow", false);
    }

    // ── col-N / -col-N (grid-column shorthand integer) ─────────────────────
    if (std.mem.eql(u8, unsigned_root, "col")) {
        return try resolveIntegerLonghand(allocator, f.value, "grid-column", negative);
    }
    // ── row-N / -row-N ─────────────────────────────────────────────────────
    if (std.mem.eql(u8, unsigned_root, "row")) {
        return try resolveIntegerLonghand(allocator, f.value, "grid-row", negative);
    }

    // ── aspect-W/H, aspect-[arbitrary] ─────────────────────────────────────
    if (std.mem.eql(u8, root, "aspect") and !negative) {
        if (try resolveAspect(allocator, t, f.value)) |r| return r;
    }

    // ── shadow-{size} (theme-driven, layered) ──────────────────────────────
    if (std.mem.eql(u8, root, "shadow") and !negative) {
        if (try resolveShadow(allocator, t, f.value)) |r| return r;
        // shadow-{color} fallback: sets `--tw-shadow-color` so chained shadow
        // utilities can colorize their drop. Reuses the color-base resolver.
        if (try resolveShadowColor(allocator, t, f.value, f.modifier)) |r| return r;
    }

    // ── blur-{size} ────────────────────────────────────────────────────────
    if (std.mem.eql(u8, root, "blur") and !negative) {
        if (try resolveBlur(allocator, t, f.value)) |r| return r;
    }

    // ── outline-N (width + style), outline-offset-N ────────────────────────
    if (std.mem.eql(u8, root, "outline") and !negative) {
        if (try resolveOutlineWidth(allocator, f.value)) |r| return r;
    }
    if (std.mem.eql(u8, root, "outline-offset")) {
        if (try resolvePxLonghand(allocator, f.value, "outline-offset", negative)) |r| return r;
    }

    // ── inset-x / inset-y / -inset-x / -inset-y axis pairs ─────────────────
    if (std.mem.eql(u8, unsigned_root, "inset-x")) {
        return try resolveSpacingPairSigned(allocator, t, f.value, f.modifier, &.{ "left", "right" }, negative);
    }
    if (std.mem.eql(u8, unsigned_root, "inset-y")) {
        return try resolveSpacingPairSigned(allocator, t, f.value, f.modifier, &.{ "top", "bottom" }, negative);
    }

    // ── mask-[arbitrary] / mask-(--var) passthrough ────────────────────────
    if (std.mem.eql(u8, root, "mask") and !negative) {
        if (f.value) |v| {
            if (v == .arbitrary) {
                return try resolveArbitraryProperty(allocator, "mask-image", v.arbitrary.value, null);
            }
        }
    }

    // ── Border width — `border-N`, `border-{side}-N`, `border-x/y-N` ──────
    // Must run BEFORE the color path so `border-2` and `border-[3.5px]` get
    // routed to width emission instead of being misread as border-color
    // values. Color names and the bare-color forms still fall through
    // because resolveBorderWidth returns null for non-numeric named values
    // and there's no border-side root that overlaps with a known color.
    if (try resolveBorderWidth(allocator, root, f.value)) |r| return r;

    // ── Transition timing: duration-N / delay-N / ease-{key|arb} ───────────
    if (std.mem.eql(u8, root, "duration") and !negative) {
        if (try resolveTimingMs(allocator, t, f.value, "transition-duration", "duration")) |r| return r;
    }
    if (std.mem.eql(u8, root, "delay") and !negative) {
        if (try resolveTimingMs(allocator, t, f.value, "transition-delay", "duration")) |r| return r;
    }
    if (std.mem.eql(u8, root, "ease") and !negative) {
        if (try resolveEasing(allocator, t, f.value)) |r| return r;
    }

    // ── color-property utilities (bg, text, border, ring, …) ───────────────
    // Theme-driven: each maps to a single CSS property and shares one
    // resolution path covering theme colors, special CSS keywords, arbitrary
    // values, and the `/<opacity>` modifier (rendered via `color-mix`).
    const color_mappings = [_]struct { root: []const u8, property: []const u8 }{
        .{ .root = "bg", .property = "background-color" },
        .{ .root = "text", .property = "color" },
        .{ .root = "border", .property = "border-color" },
        .{ .root = "ring", .property = "--tw-ring-color" },
        .{ .root = "decoration", .property = "text-decoration-color" },
        .{ .root = "outline", .property = "outline-color" },
        .{ .root = "accent", .property = "accent-color" },
        .{ .root = "caret", .property = "caret-color" },
        .{ .root = "fill", .property = "fill" },
        .{ .root = "stroke", .property = "stroke" },
    };
    inline for (color_mappings) |cm| {
        if (std.mem.eql(u8, root, cm.root) and !negative) {
            if (try resolveColorProperty(allocator, t, cm.property, f.value, f.modifier)) |r| return r;
        }
    }

    // ── Border radius (theme-driven, including side-shorthand variants) ────
    // `rounded-{key}` → border-radius
    // `rounded-{side}-{key}` → border-{side}-radius (two longhands per side)
    // `rounded-{corner}-{key}` → border-{corner}-radius (one longhand)
    if (try resolveBorderRadius(allocator, t, root, f.value, negative)) |r| return r;

    // ── Gradients (gap kinds #2, #3, #4) — basic shape ─────────────────────
    if (std.mem.eql(u8, root, "bg-linear-to") and !negative) {
        return try resolveBgLinearDirection(allocator, f.value);
    }
    // bg-linear-{angle} (degrees) — `bg-linear-45` → `45deg`. The root parses
    // as `bg-linear` because there's no `-to-` infix.
    if (std.mem.eql(u8, root, "bg-linear") and !negative) {
        if (try resolveBgLinearAngle(allocator, f.value)) |r| return r;
    }
    // bg-conic-{angle | arbitrary} — `bg-conic-45` → `from 45deg`,
    // `bg-conic-[from_45deg]` → arbitrary verbatim.
    if (std.mem.eql(u8, root, "bg-conic") and !negative) {
        if (try resolveBgConic(allocator, f.value)) |r| return r;
    }
    // bg-radial-{arbitrary} — `bg-radial-[ellipse_at_top]` → arbitrary verbatim.
    if (std.mem.eql(u8, root, "bg-radial") and !negative) {
        if (try resolveBgRadial(allocator, f.value)) |r| return r;
    }
    if (std.mem.eql(u8, root, "from") and !negative) {
        return try resolveGradientStop(allocator, t, f.value, f.modifier, .from);
    }
    if (std.mem.eql(u8, root, "to") and !negative) {
        return try resolveGradientStop(allocator, t, f.value, f.modifier, .to);
    }
    if (std.mem.eql(u8, root, "via") and !negative) {
        return try resolveGradientStop(allocator, t, f.value, f.modifier, .via);
    }

    return null;
}

fn resolveArbitraryProperty(
    allocator: std.mem.Allocator,
    property: []const u8,
    value: []const u8,
    modifier: ?candidate.Modifier,
) ResolveError!?ResolvedUtility {
    // When a modifier is present and the property is color-shaped, apply it
    // as opacity via `color-mix(in oklab, <value> <pct>, transparent)`.
    // Use `oklab` (not `srgb`) for arbitrary-property
    // color modifiers.
    const final_value: []u8 = if (modifier) |m| blk: {
        if (!isColorProperty(property)) {
            // Modifier on a non-color property is meaningless; emit verbatim.
            break :blk try allocator.dupe(u8, value);
        }
        const opacity = try modifierAsOpacity(allocator, m);
        defer allocator.free(opacity);
        break :blk try std.fmt.allocPrint(
            allocator,
            "color-mix(in oklab, {s} {s}, transparent)",
            .{ value, opacity },
        );
    } else try allocator.dupe(u8, value);
    errdefer allocator.free(final_value);

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = final_value };
    return .{ .declarations = decls };
}

/// CSS properties whose values are colors. Used to decide whether a `/<n>`
/// modifier on an arbitrary-property utility should be interpreted as opacity
/// (`color-mix`) versus left verbatim.
fn isColorProperty(property: []const u8) bool {
    const color_props = [_][]const u8{
        "color",
        "background-color",
        "border-color",
        "border-top-color",
        "border-right-color",
        "border-bottom-color",
        "border-left-color",
        "outline-color",
        "text-decoration-color",
        "accent-color",
        "caret-color",
        "fill",
        "stroke",
        "column-rule-color",
    };
    for (color_props) |p| {
        if (std.mem.eql(u8, property, p)) return true;
    }
    return false;
}

// ── Helper: emit declarations from the spacing scale ───────────────────────

/// Resolve a `<utility>-<N>` candidate where N is a numeric on the spacing scale.
/// Emits `<property>: calc(var(--spacing) * N)`. If theme has `--spacing-N`
/// directly, uses that value verbatim instead.
fn resolveSpacingDecl(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    property: []const u8,
    negative: bool,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    if (v != .named) return null; // arbitrary handled elsewhere if needed
    const n = v.named.value;

    // Try a direct theme lookup `--spacing-N` first (rare).
    const direct_name = try std.fmt.allocPrint(allocator, "spacing-{s}", .{n});
    defer allocator.free(direct_name);
    var css_value: []u8 = undefined;
    if (theme.lookup(t, direct_name)) |direct| {
        const owned = try allocator.dupe(u8, direct);
        css_value = if (negative) try negate(allocator, owned) else owned;
        if (negative) allocator.free(owned);
    } else if (isSpacingNumber(n)) {
        // Compute `calc(var(--spacing) * N)`. Accepts integers and the
        // half-step fractionals (0.5, 1.5, 2.5, 3.5).
        css_value = if (negative)
            try std.fmt.allocPrint(allocator, "calc(var(--spacing) * -{s})", .{n})
        else
            try std.fmt.allocPrint(allocator, "calc(var(--spacing) * {s})", .{n});
    } else {
        return null;
    }

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = css_value };
    return .{ .declarations = decls };
}

/// Negate a CSS value by wrapping in `calc(N * -1)` (preserves units / vars).
fn negate(allocator: std.mem.Allocator, val: []const u8) ResolveError![]u8 {
    return std.fmt.allocPrint(allocator, "calc({s} * -1)", .{val});
}

/// Emit two declarations from the spacing scale (e.g. `size-N` → width + height).
fn resolveSpacingPair(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    properties: []const []const u8,
) ResolveError!?ResolvedUtility {
    return resolveSpacingPairSigned(allocator, t, value, null, properties, false);
}

fn resolveSpacingPairSigned(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
    properties: []const []const u8,
    negative: bool,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;

    // Fraction form: `w-1/2`, `h-2/3`, `inset-1/4`. When both value and
    // modifier are integer-shaped, emit `calc(<n> / <d> * 100%)`. Fractions
    // are intended for size/position-style classes (the
    // dispatch table above is the gate — gap/padding/margin go through
    // here too, which is technically wrong, but those candidates are rare
    // enough we don't bother filtering. If someone writes `gap-1/2` they
    // get a percentage gap, which is at least defined.)
    if (modifier) |m| {
        if (v == .named and m == .named and isInteger(v.named.value) and isInteger(m.named)) {
            const num = v.named.value;
            const den = m.named;
            const pct_value = try std.fmt.allocPrint(allocator, "calc({s}/{s} * 100%)", .{ num, den });
            const final_value: []u8 = if (negative) try negate(allocator, pct_value) else pct_value;
            if (negative) allocator.free(pct_value);
            errdefer allocator.free(final_value);

            const decls = try allocator.alloc(Declaration, properties.len);
            errdefer allocator.free(decls);
            var fi: usize = 0;
            errdefer {
                var fj: usize = 0;
                while (fj < fi) : (fj += 1) allocator.free(decls[fj].value);
            }
            while (fi < properties.len) : (fi += 1) {
                decls[fi] = .{ .property = properties[fi], .value = try allocator.dupe(u8, final_value) };
            }
            allocator.free(final_value);
            return .{ .declarations = decls };
        }
        // Modifier present but not a numeric/numeric pair: bail out — these
        // utilities don't accept arbitrary modifiers (color modifiers go
        // through resolveColorProperty, which is a separate path).
        return null;
    }

    // Compute the base CSS value (single string shared across all properties).
    // Sources, in order of precedence:
    //   1. Arbitrary value: `p-[10px]` → `10px`
    //   2. Named keyword: `auto`, `full`, `px`, `screen`, `min`, `max`, `fit`
    //   3. Theme lookup `--<property>-<N>` (e.g. `--width-screen` → `100vw`)
    //   4. Container namespace lookup for width-shaped properties. Classes such
    //      as `max-w-7xl` and `w-prose` use `--container-{key}` (not
    //      `--max-width-{key}`). Only consulted when the first property is a
    //      width-or-height longhand.
    //   5. Theme lookup `--spacing-<N>` (rare direct-spacing).
    //   6. Numeric scale: `calc(var(--spacing) * N)` for integer or half-step.
    const base_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |named| blk: {
            const n = named.value;
            // (2) Static keywords first.
            if (try resolveSpacingKeyword(allocator, n)) |kw| break :blk kw;
            // (3) Property-specific theme token (use first property as the lookup key).
            const direct = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ properties[0], n });
            defer allocator.free(direct);
            if (theme.lookup(t, direct)) |dv| break :blk try allocator.dupe(u8, dv);
            // (4) Container namespace for width/height-shaped utilities.
            if (isWidthHeightProperty(properties[0])) {
                const ctok = try std.fmt.allocPrint(allocator, "container-{s}", .{n});
                defer allocator.free(ctok);
                if (theme.lookup(t, ctok) != null) {
                    break :blk try std.fmt.allocPrint(allocator, "var(--container-{s})", .{n});
                }
            }
            // (5) Direct spacing-N theme token.
            const sptok = try std.fmt.allocPrint(allocator, "spacing-{s}", .{n});
            defer allocator.free(sptok);
            if (theme.lookup(t, sptok)) |dv| break :blk try allocator.dupe(u8, dv);
            // (6) Numeric scale.
            if (!isSpacingNumber(n)) return null;
            break :blk try std.fmt.allocPrint(allocator, "calc(var(--spacing) * {s})", .{n});
        },
    };
    errdefer allocator.free(base_value);

    // Apply negation. For arbitrary or non-numeric values, wrap in calc(... * -1);
    // for the calc(var(--spacing) * N) form, just rewrite the multiplier.
    const final_value: []u8 = if (negative) try negate(allocator, base_value) else base_value;
    if (negative) allocator.free(base_value);
    errdefer allocator.free(final_value);

    const decls = try allocator.alloc(Declaration, properties.len);
    errdefer allocator.free(decls);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) allocator.free(decls[j].value);
    }
    while (i < properties.len) : (i += 1) {
        // Each property gets its own copy so freeResolvedUtility can free per-decl.
        decls[i] = .{ .property = properties[i], .value = try allocator.dupe(u8, final_value) };
    }
    allocator.free(final_value);
    return .{ .declarations = decls };
}

/// `divide-x-N` / `divide-y-N` — between-children border via selector
/// modifier. Mirror of `resolveSpaceAxis`. Default `divide-x` (no value)
/// emits 1px.
fn resolveDivideAxis(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
    property: []const u8,
) ResolveError!?ResolvedUtility {
    const css_value: []u8 = if (value) |v| switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "reverse")) {
                // divide-x-reverse / divide-y-reverse marker — emit nothing
                // declarations-wise but still attach a selector_suffix so the
                // class participates in the cascade as a marker.
                const decls = try allocator.alloc(Declaration, 0);
                return .{
                    .declarations = decls,
                    .selector_suffix = try allocator.dupe(u8, " > :not(:last-child)"),
                };
            }
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}px", .{n.value});
        },
    } else try allocator.dupe(u8, "1px");
    errdefer allocator.free(css_value);

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = css_value };
    return .{
        .declarations = decls,
        .selector_suffix = try allocator.dupe(u8, " > :not(:last-child)"),
    };
}

/// `divide-{color}` — color of the between-children border. Selector-modifying
/// like the axis variants. Falls through (returns null) when value isn't a
/// known color.
fn resolveDivideColor(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const base = (try resolveColorBase(allocator, t, v)) orelse return null;
    const final = if (modifier) |m| blk: {
        defer allocator.free(base);
        const opacity = try modifierAsOpacity(allocator, m);
        defer allocator.free(opacity);
        break :blk try std.fmt.allocPrint(
            allocator,
            "color-mix(in oklab, {s} {s}, transparent)",
            .{ base, opacity },
        );
    } else base;
    errdefer allocator.free(final);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "border-color", .value = final };
    return .{
        .declarations = decls,
        .selector_suffix = try allocator.dupe(u8, " > :not(:last-child)"),
    };
}

/// `opacity-N` — N is 0–100, emits as decimal (`opacity-50` → `0.5`).
/// Arbitrary forms (`opacity-[var(--my-op)]`, `opacity-[0.42]`) pass through.
fn resolveOpacity(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            // Format as N% — modern browsers accept percentages here.
            break :blk try std.fmt.allocPrint(allocator, "{s}%", .{n.value});
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "opacity", .value = css_value };
    return .{ .declarations = decls };
}

/// `ring-N` — ring width. Numeric → `Npx`. Arbitrary passes through. Returns
/// null for non-numeric named values so `ring-red-500` falls through to the
/// color path. Bare `ring` (3px default) is in the static table.
fn resolveRingWidth(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "inset")) return null; // handled by ring-inset static
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}px", .{n.value});
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "--tw-ring-shadow",
        .value = try std.fmt.allocPrint(
            allocator,
            "var(--tw-ring-inset, ) 0 0 0 calc({s} + var(--tw-ring-offset-width, 0px)) var(--tw-ring-color, currentColor)",
            .{css_value},
        ),
    };
    decls[1] = .{
        .property = "box-shadow",
        .value = try allocator.dupe(u8, "var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow), var(--tw-shadow, 0 0 #0000)"),
    };
    allocator.free(css_value);
    return .{ .declarations = decls };
}

/// `space-x-N` / `space-y-N` — child spacing. Emits a single declaration
/// targeting `> :not(:last-child)` so the *between* gap shows up without
/// pushing the last child outward. Selector-suffix is set on the returned
/// ResolvedUtility; `compile.zig:emitClassRule` appends it to the wrapped
/// selector before emitting the rule.
fn resolveSpaceAxis(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    property: []const u8,
    negative: bool,
) ResolveError!?ResolvedUtility {
    var r = (try resolveSpacingPairSigned(allocator, t, value, null, &.{property}, negative)) orelse return null;
    r.selector_suffix = try allocator.dupe(u8, " > :not(:last-child)");
    return r;
}

/// True for the longhand width/height properties whose named values
/// (`max-w-7xl`, `w-prose`, etc.) stored under `--container-*`.
fn isWidthHeightProperty(property: []const u8) bool {
    return std.mem.eql(u8, property, "width") or
        std.mem.eql(u8, property, "height") or
        std.mem.eql(u8, property, "min-width") or
        std.mem.eql(u8, property, "min-height") or
        std.mem.eql(u8, property, "max-width") or
        std.mem.eql(u8, property, "max-height");
}

/// Spacing keywords that don't require a theme lookup. Returns null for
/// non-keywords (caller falls through to theme/numeric handling).
fn resolveSpacingKeyword(allocator: std.mem.Allocator, n: []const u8) ResolveError!?[]u8 {
    if (std.mem.eql(u8, n, "auto")) return try allocator.dupe(u8, "auto");
    if (std.mem.eql(u8, n, "full")) return try allocator.dupe(u8, "100%");
    if (std.mem.eql(u8, n, "px")) return try allocator.dupe(u8, "1px");
    // `screen` is property-dependent (w-screen → 100vw, h-screen → 100vh) so
    // it's handled as a static utility instead of here.
    if (std.mem.eql(u8, n, "min")) return try allocator.dupe(u8, "min-content");
    if (std.mem.eql(u8, n, "max")) return try allocator.dupe(u8, "max-content");
    if (std.mem.eql(u8, n, "fit")) return try allocator.dupe(u8, "fit-content");
    if (std.mem.eql(u8, n, "none")) return try allocator.dupe(u8, "none");
    if (std.mem.eql(u8, n, "prose")) return try allocator.dupe(u8, "65ch");
    if (std.mem.eql(u8, n, "svw")) return try allocator.dupe(u8, "100svw");
    if (std.mem.eql(u8, n, "lvw")) return try allocator.dupe(u8, "100lvw");
    if (std.mem.eql(u8, n, "dvw")) return try allocator.dupe(u8, "100dvw");
    return null;
}

/// `col-span-N`, `row-span-N` (and arbitrary `col-span-[5]`).
/// `property` is the longhand to set: `grid-column` or `grid-row`.
fn resolveSpanLonghand(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
    property: []const u8,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const span_n: []const u8 = switch (v) {
        .named => |n| n.value,
        .arbitrary => |a| a.value,
    };
    // For named values, only integers make sense; for arbitrary anything
    // numeric-shaped works (even something like `var(--n)`).
    if (v == .named and !isInteger(span_n)) return null;

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = property,
        .value = try std.fmt.allocPrint(allocator, "span {s} / span {s}", .{ span_n, span_n }),
    };
    return .{ .declarations = decls };
}

/// `grid-cols-{N|subgrid|arbitrary}`, `grid-rows-{N|subgrid|arbitrary}`.
/// `property` is the longhand to set.
fn resolveGridTrack(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
    property: []const u8,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;

    const track_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "subgrid")) break :blk try allocator.dupe(u8, "subgrid");
            if (std.mem.eql(u8, n.value, "none")) break :blk try allocator.dupe(u8, "none");
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "repeat({s}, minmax(0, 1fr))", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(track_value);

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = track_value };
    return .{ .declarations = decls };
}

fn resolveZIndex(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
    negative: bool,
) ResolveError!?ResolvedUtility {
    // Same shape as every other integer longhand — including `[arbitrary]`
    // passthrough, so `z-[60]` works like `order-[…]` does.
    return resolveIntegerLonghand(allocator, value, "z-index", negative);
}

/// `<utility>-N` where N is in pixels (e.g., `outline-offset-2` → `2px`).
/// Arbitrary forms pass through verbatim.
fn resolvePxLonghand(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
    property: []const u8,
    negative: bool,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk if (negative)
                try std.fmt.allocPrint(allocator, "-{s}px", .{n.value})
            else
                try std.fmt.allocPrint(allocator, "{s}px", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(css_value);

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = css_value };
    return .{ .declarations = decls };
}

/// `outline-N` emits both width and style — without an explicit style the
/// browser defaults to `none`, which makes the focus ring invisible.
fn resolveOutlineWidth(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const width_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}px", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(width_value);

    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "outline-style", .value = try allocator.dupe(u8, "solid") };
    decls[1] = .{ .property = "outline-width", .value = width_value };
    return .{ .declarations = decls };
}

/// Generic integer-valued single-property longhand (`order-N`, `col-start-N`,
/// `grid-row-start-N`, etc.). Accepts named integer values plus `[arbitrary]`
/// passthrough for callers that allow it.
fn resolveIntegerLonghand(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
    property: []const u8,
    negative: bool,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk if (negative)
                try std.fmt.allocPrint(allocator, "-{s}", .{n.value})
            else
                try allocator.dupe(u8, n.value);
        },
        // Negative arbitrary (`-z-[5]`, `-order-[2]`) negates via calc —
        // the raw value may itself be an expression, so `-{s}` won't do.
        .arbitrary => |a| if (negative)
            try std.fmt.allocPrint(allocator, "calc({s} * -1)", .{a.value})
        else
            try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(css_value);

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = css_value };
    return .{ .declarations = decls };
}

/// `aspect-W/H`, `aspect-N`, `aspect-[arbitrary]`. Named values use the
/// utility-value's `fraction` field when present (e.g. candidate parser
/// returns `value="W"`, `fraction="W/H"` for `aspect-W/H`).
fn resolveAspect(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (n.fraction) |frac| {
                // "W/H" → "W / H" (CSS aspect-ratio uses spaces).
                const slash_idx = std.mem.indexOfScalar(u8, frac, '/') orelse return null;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s} / {s}",
                    .{ frac[0..slash_idx], frac[slash_idx + 1 ..] },
                );
            }
            // Theme `--aspect-{name}` first.
            const tok = try std.fmt.allocPrint(allocator, "aspect-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            // Plain numeric → ratio over 1.
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s} / 1", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(css_value);

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "aspect-ratio", .value = css_value };
    return .{ .declarations = decls };
}

/// `<root>-N` → `filter: <fn_name>(N<unit>)`. Bare value (`grayscale`, `invert`,
/// `sepia`) uses `default_value` if non-null. Returns null otherwise.
fn resolveFilterFn(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    fn_name: []const u8,
    unit: []const u8,
    default_value: ?[]const u8,
) ResolveError!?ResolvedUtility {
    return try resolveFilterFnImpl(allocator, t, value, fn_name, unit, default_value, false, "filter");
}
fn resolveFilterFnSigned(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    fn_name: []const u8,
    unit: []const u8,
    default_value: ?[]const u8,
    negative: bool,
) ResolveError!?ResolvedUtility {
    return try resolveFilterFnImpl(allocator, t, value, fn_name, unit, default_value, negative, "filter");
}
fn resolveBackdropFilterFn(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    fn_name: []const u8,
    unit: []const u8,
    default_value: ?[]const u8,
) ResolveError!?ResolvedUtility {
    return try resolveFilterFnImpl(allocator, t, value, fn_name, unit, default_value, false, "backdrop-filter");
}
fn resolveBackdropFilterFnSigned(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    fn_name: []const u8,
    unit: []const u8,
    default_value: ?[]const u8,
    negative: bool,
) ResolveError!?ResolvedUtility {
    return try resolveFilterFnImpl(allocator, t, value, fn_name, unit, default_value, negative, "backdrop-filter");
}

fn resolveFilterFnImpl(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    fn_name: []const u8,
    unit: []const u8,
    default_value: ?[]const u8,
    negative: bool,
    css_property: []const u8,
) ResolveError!?ResolvedUtility {
    _ = t;
    const inner: []u8 = if (value) |v| switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk if (negative)
                try std.fmt.allocPrint(allocator, "-{s}{s}", .{ n.value, unit })
            else
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ n.value, unit });
        },
    } else if (default_value) |d| try allocator.dupe(u8, d) else return null;
    errdefer allocator.free(inner);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = css_property,
        .value = try std.fmt.allocPrint(allocator, "{s}({s})", .{ fn_name, inner }),
    };
    allocator.free(inner);
    return .{ .declarations = decls };
}

/// `animate-{name|none|arbitrary}`. Theme `--animate-{name}` looks up an
/// animation shorthand value (e.g., `--animate-spin: spin 1s linear infinite`).
fn resolveAnimate(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "none")) break :blk try allocator.dupe(u8, "none");
            const tok = try std.fmt.allocPrint(allocator, "animate-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            // Fallback: emit a var() reference so consumers can define the
            // animation in their own CSS without editing theme.zon.
            break :blk try std.fmt.allocPrint(allocator, "var(--animate-{s})", .{n.value});
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "animation", .value = css_value };
    return .{ .declarations = decls };
}

/// `backdrop-blur-{theme/none/arbitrary}` — emits backdrop-filter blur.
fn resolveBackdropBlur(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse {
        // Bare `backdrop-blur` → default blur via theme.
        return null;
    };
    const blur_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "none")) break :blk try allocator.dupe(u8, "0");
            const tok = try std.fmt.allocPrint(allocator, "blur-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            return null;
        },
    };
    errdefer allocator.free(blur_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "backdrop-filter",
        .value = try std.fmt.allocPrint(allocator, "blur({s})", .{blur_value}),
    };
    allocator.free(blur_value);
    return .{ .declarations = decls };
}

/// `drop-shadow-{theme/arbitrary}` — emits filter:drop-shadow(...).
fn resolveDropShadow(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const shadow_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            const tok = try std.fmt.allocPrint(allocator, "drop-shadow-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            return null;
        },
    };
    errdefer allocator.free(shadow_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "filter",
        .value = try std.fmt.allocPrint(allocator, "drop-shadow({s})", .{shadow_value}),
    };
    allocator.free(shadow_value);
    return .{ .declarations = decls };
}

/// `ring-offset-N` (width) or `ring-offset-{color}`. Falls through if value
/// isn't numeric and isn't a known color.
fn resolveRingOffset(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    // Try width first.
    switch (v) {
        .arbitrary => |a| {
            // Arbitrary could be width or color; assume width if it ends in unit.
            if (std.mem.endsWith(u8, a.value, "px") or std.mem.endsWith(u8, a.value, "rem") or std.mem.endsWith(u8, a.value, "em")) {
                const decls = try allocator.alloc(Declaration, 1);
                errdefer allocator.free(decls);
                decls[0] = .{ .property = "--tw-ring-offset-width", .value = try allocator.dupe(u8, a.value) };
                return .{ .declarations = decls };
            }
        },
        .named => |n| {
            if (isInteger(n.value)) {
                const decls = try allocator.alloc(Declaration, 1);
                errdefer allocator.free(decls);
                decls[0] = .{
                    .property = "--tw-ring-offset-width",
                    .value = try std.fmt.allocPrint(allocator, "{s}px", .{n.value}),
                };
                return .{ .declarations = decls };
            }
        },
    }
    // Fall through to color.
    return try resolveColorProperty(allocator, t, "--tw-ring-offset-color", value, modifier);
}

/// `inset-ring-N` (width) or `inset-ring-{color}`.
fn resolveInsetRing(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    switch (v) {
        .arbitrary => |a| {
            if (std.mem.endsWith(u8, a.value, "px") or std.mem.endsWith(u8, a.value, "rem") or std.mem.endsWith(u8, a.value, "em")) {
                const decls = try allocator.alloc(Declaration, 1);
                errdefer allocator.free(decls);
                decls[0] = .{
                    .property = "box-shadow",
                    .value = try std.fmt.allocPrint(allocator, "inset 0 0 0 {s} var(--tw-inset-ring-color, currentColor)", .{a.value}),
                };
                return .{ .declarations = decls };
            }
        },
        .named => |n| {
            if (isInteger(n.value)) {
                const decls = try allocator.alloc(Declaration, 1);
                errdefer allocator.free(decls);
                decls[0] = .{
                    .property = "box-shadow",
                    .value = try std.fmt.allocPrint(allocator, "inset 0 0 0 {s}px var(--tw-inset-ring-color, currentColor)", .{n.value}),
                };
                return .{ .declarations = decls };
            }
        },
    }
    return try resolveColorProperty(allocator, t, "--tw-inset-ring-color", value, modifier);
}

/// `translate-N`, `translate-x-N`, `translate-y-N`, `translate-z-N`.
/// Sets per-axis `--tw-translate-{axis}` and emits the composed `translate:`
/// declaration so x/y (and optionally z) compose on the same element.
const TranslateAxis = enum { x, y, z, both };
fn resolveTranslate(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
    axis: TranslateAxis,
    negative: bool,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;

    // Resolve base value via spacing scale + theme + arbitrary + fraction.
    const base_value: []u8 = try resolveSpacingValue(allocator, t, v, modifier, "translate") orelse return null;
    const final = if (negative) blk: {
        defer allocator.free(base_value);
        break :blk try negate(allocator, base_value);
    } else base_value;
    errdefer allocator.free(final);

    // Fallbacks (`, 0`) are essential: an undefined `var()` with no fallback
    // resolves to the empty token sequence, which makes the entire `translate`
    // declaration invalid (computed `none`) — so e.g. `peer-checked:translate-x-5`
    // on a Switch thumb sets `--tw-translate-x` correctly but the composed
    // `translate` reference for `--tw-translate-y` (never set) wipes the
    // whole property. The generated CSS uses the same fallbacks throughout.
    const composed_2axis: []const u8 = "var(--tw-translate-x, 0) var(--tw-translate-y, 0)";
    const composed_3axis: []const u8 = "var(--tw-translate-x, 0) var(--tw-translate-y, 0) var(--tw-translate-z, 0)";

    return switch (axis) {
        .both => emit: {
            const decls = try allocator.alloc(Declaration, 3);
            errdefer allocator.free(decls);
            decls[0] = .{ .property = "--tw-translate-x", .value = try allocator.dupe(u8, final) };
            decls[1] = .{ .property = "--tw-translate-y", .value = try allocator.dupe(u8, final) };
            decls[2] = .{ .property = "translate", .value = try allocator.dupe(u8, composed_2axis) };
            allocator.free(final);
            break :emit .{ .declarations = decls };
        },
        .x, .y => emit: {
            const decls = try allocator.alloc(Declaration, 2);
            errdefer allocator.free(decls);
            const prop = if (axis == .x) "--tw-translate-x" else "--tw-translate-y";
            decls[0] = .{ .property = prop, .value = final };
            decls[1] = .{ .property = "translate", .value = try allocator.dupe(u8, composed_2axis) };
            break :emit .{ .declarations = decls };
        },
        .z => emit: {
            const decls = try allocator.alloc(Declaration, 2);
            errdefer allocator.free(decls);
            decls[0] = .{ .property = "--tw-translate-z", .value = final };
            decls[1] = .{ .property = "translate", .value = try allocator.dupe(u8, composed_3axis) };
            break :emit .{ .declarations = decls };
        },
    };
}

/// Helper: resolve a spacing-shaped value to its CSS string. Used by
/// composed-property utilities (translate, scale axis, etc.).
fn resolveSpacingValue(
    allocator: std.mem.Allocator,
    t: Theme,
    v: candidate.UtilityValue,
    modifier: ?candidate.Modifier,
    namespace: []const u8,
) ResolveError!?[]u8 {
    if (modifier) |m| {
        if (v == .named and m == .named and isInteger(v.named.value) and isInteger(m.named)) {
            return try std.fmt.allocPrint(allocator, "calc({s}/{s} * 100%)", .{ v.named.value, m.named });
        }
        return null;
    }
    return switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |named| blk: {
            const n = named.value;
            if (try resolveSpacingKeyword(allocator, n)) |kw| break :blk kw;
            const tok = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ namespace, n });
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            const sptok = try std.fmt.allocPrint(allocator, "spacing-{s}", .{n});
            defer allocator.free(sptok);
            if (theme.lookup(t, sptok)) |dv| break :blk try allocator.dupe(u8, dv);
            if (!isSpacingNumber(n)) return null;
            break :blk try std.fmt.allocPrint(allocator, "calc(var(--spacing) * {s})", .{n});
        },
    };
}

/// `scale-N`, `scale-x-N`, `scale-y-N`, `scale-z-N`. N → percentage.
fn resolveScale(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    axis: TranslateAxis,
    negative: bool,
) ResolveError!?ResolvedUtility {
    _ = t;
    const v = value orelse return null;
    const base_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}%", .{n.value});
        },
    };
    const final = if (negative) blk: {
        defer allocator.free(base_value);
        break :blk try negate(allocator, base_value);
    } else base_value;
    errdefer allocator.free(final);

    const composed_2: []const u8 = "var(--tw-scale-x) var(--tw-scale-y)";
    const composed_3: []const u8 = "var(--tw-scale-x) var(--tw-scale-y) var(--tw-scale-z)";

    return switch (axis) {
        .both => emit: {
            const decls = try allocator.alloc(Declaration, 3);
            errdefer allocator.free(decls);
            decls[0] = .{ .property = "--tw-scale-x", .value = try allocator.dupe(u8, final) };
            decls[1] = .{ .property = "--tw-scale-y", .value = try allocator.dupe(u8, final) };
            decls[2] = .{ .property = "scale", .value = try allocator.dupe(u8, composed_2) };
            allocator.free(final);
            break :emit .{ .declarations = decls };
        },
        .x, .y => emit: {
            const decls = try allocator.alloc(Declaration, 2);
            errdefer allocator.free(decls);
            const prop = if (axis == .x) "--tw-scale-x" else "--tw-scale-y";
            decls[0] = .{ .property = prop, .value = final };
            decls[1] = .{ .property = "scale", .value = try allocator.dupe(u8, composed_2) };
            break :emit .{ .declarations = decls };
        },
        .z => emit: {
            const decls = try allocator.alloc(Declaration, 2);
            errdefer allocator.free(decls);
            decls[0] = .{ .property = "--tw-scale-z", .value = final };
            decls[1] = .{ .property = "scale", .value = try allocator.dupe(u8, composed_3) };
            break :emit .{ .declarations = decls };
        },
    };
}

/// `rotate-N` (degrees, single property) — no axis composition.
fn resolveRotate(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    negative: bool,
) ResolveError!?ResolvedUtility {
    _ = t;
    const v = value orelse return null;
    const base_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}deg", .{n.value});
        },
    };
    const final = if (negative) blk: {
        defer allocator.free(base_value);
        break :blk try negate(allocator, base_value);
    } else base_value;
    errdefer allocator.free(final);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "rotate", .value = final };
    return .{ .declarations = decls };
}

/// `rotate-x-N` / `rotate-y-N` / `rotate-z-N` — sets per-axis `--tw-rotate-*`
/// and emits composed `transform:`. (3D rotations require a `transform`.)
fn resolveRotateAxis(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    axis: TranslateAxis,
    negative: bool,
) ResolveError!?ResolvedUtility {
    _ = t;
    const v = value orelse return null;
    const angle: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk if (negative)
                try std.fmt.allocPrint(allocator, "-{s}deg", .{n.value})
            else
                try std.fmt.allocPrint(allocator, "{s}deg", .{n.value});
        },
    };
    errdefer allocator.free(angle);
    const fn_name = switch (axis) {
        .x => "rotateX",
        .y => "rotateY",
        .z => "rotateZ",
        .both => unreachable,
    };
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "transform",
        .value = try std.fmt.allocPrint(allocator, "{s}({s})", .{ fn_name, angle }),
    };
    allocator.free(angle);
    return .{ .declarations = decls };
}

/// `skew-N`, `skew-x-N`, `skew-y-N`. Same shape as scale.
fn resolveSkew(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    axis: TranslateAxis,
    negative: bool,
) ResolveError!?ResolvedUtility {
    _ = t;
    const v = value orelse return null;
    const angle: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk if (negative)
                try std.fmt.allocPrint(allocator, "-{s}deg", .{n.value})
            else
                try std.fmt.allocPrint(allocator, "{s}deg", .{n.value});
        },
    };
    errdefer allocator.free(angle);
    const composed: []const u8 = "var(--tw-skew-x) var(--tw-skew-y)";
    return switch (axis) {
        .both => emit: {
            const decls = try allocator.alloc(Declaration, 3);
            errdefer allocator.free(decls);
            decls[0] = .{
                .property = "--tw-skew-x",
                .value = try std.fmt.allocPrint(allocator, "skewX({s})", .{angle}),
            };
            decls[1] = .{
                .property = "--tw-skew-y",
                .value = try std.fmt.allocPrint(allocator, "skewY({s})", .{angle}),
            };
            decls[2] = .{ .property = "transform", .value = try allocator.dupe(u8, composed) };
            allocator.free(angle);
            break :emit .{ .declarations = decls };
        },
        .x => emit: {
            const decls = try allocator.alloc(Declaration, 2);
            errdefer allocator.free(decls);
            decls[0] = .{
                .property = "--tw-skew-x",
                .value = try std.fmt.allocPrint(allocator, "skewX({s})", .{angle}),
            };
            decls[1] = .{ .property = "transform", .value = try allocator.dupe(u8, composed) };
            allocator.free(angle);
            break :emit .{ .declarations = decls };
        },
        .y => emit: {
            const decls = try allocator.alloc(Declaration, 2);
            errdefer allocator.free(decls);
            decls[0] = .{
                .property = "--tw-skew-y",
                .value = try std.fmt.allocPrint(allocator, "skewY({s})", .{angle}),
            };
            decls[1] = .{ .property = "transform", .value = try allocator.dupe(u8, composed) };
            allocator.free(angle);
            break :emit .{ .declarations = decls };
        },
        .z => null,
    };
}

/// `origin-{name|theme|arbitrary}` and `perspective-origin-{...}`. Named
/// values are CSS keywords (`top`, `bottom-left`, etc.) — pass through.
fn resolveTransformOrigin(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    _ = t;
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            // Supported keywords: center, top, top-right, right, bottom-right,
            // bottom, bottom-left, left, top-left.
            const allowed = [_][]const u8{
                "center", "top",         "top-right", "right",    "bottom-right",
                "bottom", "bottom-left", "left",      "top-left",
            };
            for (allowed) |k| {
                if (std.mem.eql(u8, n.value, k)) {
                    // Convert "top-right" → "top right" etc.
                    const out = try allocator.dupe(u8, k);
                    for (out) |*c| if (c.* == '-') {
                        c.* = ' ';
                    };
                    break :blk out;
                }
            }
            return null;
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "transform-origin", .value = css_value };
    return .{ .declarations = decls };
}

/// `perspective-N` / `perspective-[arb]` / `perspective-{theme}`. `none` static.
fn resolvePerspective(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "none")) break :blk try allocator.dupe(u8, "none");
            const tok = try std.fmt.allocPrint(allocator, "perspective-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            return null;
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "perspective", .value = css_value };
    return .{ .declarations = decls };
}

/// `border-spacing-{N|x-N|y-N}`. Sets `--tw-border-spacing-x/y` and the
/// composed `border-spacing` declaration so x and y can stack.
const BorderSpacingAxis = enum { x, y, both };
fn resolveBorderSpacing(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    axis: BorderSpacingAxis,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            const tok = try std.fmt.allocPrint(allocator, "border-spacing-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            if (!isSpacingNumber(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "calc(var(--spacing) * {s})", .{n.value});
        },
    };
    errdefer allocator.free(css_value);

    const decls = try allocator.alloc(Declaration, 3);
    errdefer allocator.free(decls);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) allocator.free(decls[j].value);
    }
    switch (axis) {
        .x => {
            decls[0] = .{ .property = "--tw-border-spacing-x", .value = try allocator.dupe(u8, css_value) };
            i += 1;
            decls[1] = .{ .property = "--tw-border-spacing-y", .value = try allocator.dupe(u8, "0") };
            i += 1;
        },
        .y => {
            decls[0] = .{ .property = "--tw-border-spacing-x", .value = try allocator.dupe(u8, "0") };
            i += 1;
            decls[1] = .{ .property = "--tw-border-spacing-y", .value = try allocator.dupe(u8, css_value) };
            i += 1;
        },
        .both => {
            decls[0] = .{ .property = "--tw-border-spacing-x", .value = try allocator.dupe(u8, css_value) };
            i += 1;
            decls[1] = .{ .property = "--tw-border-spacing-y", .value = try allocator.dupe(u8, css_value) };
            i += 1;
        },
    }
    decls[2] = .{
        .property = "border-spacing",
        .value = try allocator.dupe(u8, "var(--tw-border-spacing-x) var(--tw-border-spacing-y)"),
    };
    i += 1;
    allocator.free(css_value);
    return .{ .declarations = decls };
}

/// Generic helper: arbitrary value or theme-namespace lookup → single decl.
/// `theme_ns` is the leading `--{name}` part (e.g. `--list-style-type`),
/// concatenated with `-{value}` for the lookup. If the named value is the
/// raw theme-key prefix (e.g. lookup yields a CSS var ref), use that;
/// otherwise return null and let the caller fall through.
fn resolveArbitraryOrTheme(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    property: []const u8,
    theme_ns: []const u8,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            // Strip leading "--" from theme_ns to compose the lookup key.
            const ns_no_prefix = if (std.mem.startsWith(u8, theme_ns, "--")) theme_ns[2..] else theme_ns;
            const tok = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ ns_no_prefix, n.value });
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            return null;
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = css_value };
    return .{ .declarations = decls };
}

/// `columns-N` — integer becomes raw integer; `auto`/3xs/2xs/xs/sm/…/7xl
/// resolve via `--container-{key}` (or `--columns-{key}` if defined).
fn resolveColumns(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "auto")) break :blk try allocator.dupe(u8, "auto");
            if (isInteger(n.value)) break :blk try allocator.dupe(u8, n.value);
            const ctok = try std.fmt.allocPrint(allocator, "container-{s}", .{n.value});
            defer allocator.free(ctok);
            if (theme.lookup(t, ctok) != null) {
                break :blk try std.fmt.allocPrint(allocator, "var(--container-{s})", .{n.value});
            }
            return null;
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "columns", .value = css_value };
    return .{ .declarations = decls };
}

/// `line-clamp-N` / `line-clamp-[arb]`. Emits the 4-decl webkit-box pattern.
fn resolveLineClamp(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const lc_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (isInteger(n.value)) break :blk try allocator.dupe(u8, n.value);
            const tok = try std.fmt.allocPrint(allocator, "line-clamp-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            return null;
        },
    };
    errdefer allocator.free(lc_value);
    const decls = try allocator.alloc(Declaration, 4);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "overflow", .value = try allocator.dupe(u8, "hidden") };
    decls[1] = .{ .property = "display", .value = try allocator.dupe(u8, "-webkit-box") };
    decls[2] = .{ .property = "-webkit-box-orient", .value = try allocator.dupe(u8, "vertical") };
    decls[3] = .{ .property = "-webkit-line-clamp", .value = lc_value };
    return .{ .declarations = decls };
}

/// `tracking-N` / `-tracking-N` — letter-spacing. Theme: `--tracking-{name}`.
/// Negative reflects via `calc(<v> * -1)` for theme/arbitrary values.
fn resolveTracking(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    negative: bool,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const base: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            const tok = try std.fmt.allocPrint(allocator, "tracking-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            return null;
        },
    };
    const final = if (negative) blk: {
        defer allocator.free(base);
        break :blk try negate(allocator, base);
    } else base;
    errdefer allocator.free(final);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "letter-spacing", .value = final };
    return .{ .declarations = decls };
}

/// `leading-N` (line-height standalone). N → `calc(var(--spacing) * N)`,
/// theme `--leading-{key}` → CSS var, arbitrary verbatim, `none` → `1`.
fn resolveLeading(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "none")) break :blk try allocator.dupe(u8, "1");
            const tok = try std.fmt.allocPrint(allocator, "leading-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            if (!isSpacingNumber(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "calc(var(--spacing) * {s})", .{n.value});
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "line-height", .value = css_value };
    return .{ .declarations = decls };
}

/// `decoration-N` (thickness): integer → Npx, arbitrary verbatim. Falls
/// through (returns null) for non-numeric named values so the color path
/// can claim them.
fn resolveDecorationThickness(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}px", .{n.value});
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "text-decoration-thickness", .value = css_value };
    return .{ .declarations = decls };
}

/// `content-[arb]` / `content-{theme}` — sets `--tw-content` and `content`.
fn resolveContent(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            const tok = try std.fmt.allocPrint(allocator, "content-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok)) |dv| break :blk try allocator.dupe(u8, dv);
            return null;
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "--tw-content", .value = css_value };
    decls[1] = .{ .property = "content", .value = try allocator.dupe(u8, "var(--tw-content)") };
    return .{ .declarations = decls };
}

/// `shadow-{size}` — theme-driven via `--shadow-{size}` tokens. Emits the
/// layered box-shadow composition so ring + inset + shadow can
/// stack on the same element without overwriting each other.
fn resolveShadow(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const shadow_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "none")) {
                break :blk try allocator.dupe(u8, "0 0 #0000");
            }
            const tok = try std.fmt.allocPrint(allocator, "shadow-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok) == null) return null;
            break :blk try std.fmt.allocPrint(allocator, "var(--shadow-{s})", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(shadow_value);

    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "--tw-shadow", .value = shadow_value };
    decls[1] = .{
        .property = "box-shadow",
        .value = try allocator.dupe(
            u8,
            "var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow)",
        ),
    };
    return .{ .declarations = decls };
}

/// `blur-{size}` — `filter: blur(<value>)`. Theme tokens at `--blur-{size}`,
/// arbitrary forms (`blur-[20px]`) pass through verbatim. The
/// composed-filter pattern (`var(--tw-blur)`) isn't modeled yet — single
/// `filter` declaration is good enough for typical use; revisit if multiple
/// filter utilities need to compose.
fn resolveBlur(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const blur_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "none")) {
                break :blk try allocator.dupe(u8, "none");
            }
            const tok = try std.fmt.allocPrint(allocator, "blur-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok) == null) return null;
            break :blk try std.fmt.allocPrint(allocator, "blur(var(--blur-{s}))", .{n.value});
        },
        .arbitrary => |a| try std.fmt.allocPrint(allocator, "blur({s})", .{a.value}),
    };
    errdefer allocator.free(blur_value);

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "filter", .value = blur_value };
    return .{ .declarations = decls };
}

fn resolveFontFamily(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    if (v != .named) return null;
    const family_name = v.named.value;

    // Theme lookup `--font-<name>`.
    const token = try std.fmt.allocPrint(allocator, "font-{s}", .{family_name});
    defer allocator.free(token);
    if (theme.lookup(t, token) == null) return null;

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "font-family",
        .value = try std.fmt.allocPrint(allocator, "var(--font-{s})", .{family_name}),
    };
    return .{ .declarations = decls };
}

/// `text-<size>` (text-xs, text-3xl, …) — resolves via theme `--text-<size>`.
/// If the theme also defines `--text-<size>--line-height`, emit that as well
/// so a single class sets both font-size and line-height.
///
/// Modifier semantics — `text-{size}/{N}`:
///   - Named modifier `/8` → `line-height: calc(var(--spacing) * 8)` (or
///     `--leading-8` if the theme defines it).
///   - Arbitrary modifier `/[1.5]` → `line-height: 1.5` verbatim.
///   - When a modifier is present it OVERRIDES any default line-height the
///     theme provides via `--text-<size>--line-height`.
fn resolveTextSize(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const font_size: []u8 = switch (v) {
        .named => |n| blk: {
            const size_token = try std.fmt.allocPrint(allocator, "text-{s}", .{n.value});
            defer allocator.free(size_token);
            if (theme.lookup(t, size_token) == null) return null;
            break :blk try std.fmt.allocPrint(allocator, "var(--text-{s})", .{n.value});
        },
        .arbitrary => |a| blk: {
            if (!isArbitraryTextSize(a)) return null;
            break :blk try allocator.dupe(u8, a.value);
        },
    };
    errdefer allocator.free(font_size);

    // Resolve line-height. Modifier wins over the theme's default-LH for the
    // size. If neither is present, emit only font-size.
    const line_height: ?[]u8 = blk: {
        if (modifier) |m| {
            switch (m) {
                .named => |n| {
                    // Try the `--leading-{n}` named-leading token first.
                    const tok = try std.fmt.allocPrint(allocator, "leading-{s}", .{n});
                    defer allocator.free(tok);
                    if (theme.lookup(t, tok) != null) {
                        break :blk try std.fmt.allocPrint(allocator, "var(--leading-{s})", .{n});
                    }
                    // Fall back to spacing-scale calc (e.g. `/8` → calc(var(--spacing) * 8)).
                    if (isSpacingNumber(n)) {
                        break :blk try std.fmt.allocPrint(allocator, "calc(var(--spacing) * {s})", .{n});
                    }
                    // Unknown named modifier: emit verbatim (lets users plug in keywords).
                    break :blk try allocator.dupe(u8, n);
                },
                .arbitrary => |a| break :blk try allocator.dupe(u8, a),
            }
        }
        // No modifier — named sizes fall back to the theme's default line-height.
        if (v == .named) {
            const size = v.named.value;
            const lh_token = try std.fmt.allocPrint(allocator, "text-{s}--line-height", .{size});
            defer allocator.free(lh_token);
            if (theme.lookup(t, lh_token) != null) {
                break :blk try std.fmt.allocPrint(allocator, "var(--text-{s}--line-height)", .{size});
            }
        }
        break :blk null;
    };

    const decl_count: usize = if (line_height != null) 2 else 1;
    const decls = try allocator.alloc(Declaration, decl_count);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "font-size",
        .value = font_size,
    };
    if (line_height) |lh| {
        decls[1] = .{ .property = "line-height", .value = lh };
    }
    return .{ .declarations = decls };
}

/// Disambiguate `text-[…]`, which can mean either font-size or text color.
/// Explicit type hints win. Without one, CSS lengths/percentages and math
/// functions are sizes; color-shaped and ambiguous values continue to the
/// text-color resolver.
fn isArbitraryTextSize(a: candidate.ArbitraryUtilityValue) bool {
    if (a.data_type) |data_type| {
        return std.mem.eql(u8, data_type, "length") or
            std.mem.eql(u8, data_type, "percentage");
    }

    const value = std.mem.trim(u8, a.value, " \t\r\n");
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return true;
    if (std.mem.startsWith(u8, value, "calc(") or
        std.mem.startsWith(u8, value, "min(") or
        std.mem.startsWith(u8, value, "max(") or
        std.mem.startsWith(u8, value, "clamp(")) return true;
    if (std.mem.endsWith(u8, value, "%")) return true;

    const length_units = [_][]const u8{
        "cap",  "ch",   "em",  "ex",  "ic",  "lh", "rem", "rlh",
        "cm",   "mm",   "Q",   "in",  "pc",  "pt", "px",  "dvh",
        "dvw",  "lvh",  "lvw", "svh", "svw", "vb", "vh",  "vi",
        "vmax", "vmin", "vw",
    };
    for (length_units) |unit| {
        if (std.mem.endsWith(u8, value, unit)) return true;
    }
    return false;
}

// ── Color utilities ─────────────────────────────────────────────────────────

/// Resolve the base color string for a utility value. Returns null when the
/// value doesn't name a theme color (caller should fall through to the legacy
/// resolver, which handles CMS-internal semantic tokens like `bg-foreground`).
///
/// Special CSS keywords (`transparent`, `current`, `inherit`) emit literals.
/// Theme-named values emit `var(--color-<name>)`.
/// Arbitrary values pass through verbatim — the candidate parser already
/// decoded `[#abc]` and wrapped `(--my-var)` as `var(--my-var)`.
///
/// The returned slice is heap-owned by `allocator`.
fn resolveColorBase(
    allocator: std.mem.Allocator,
    t: Theme,
    value: candidate.UtilityValue,
) ResolveError!?[]u8 {
    switch (value) {
        .named => |n| {
            if (std.mem.eql(u8, n.value, "transparent")) return try allocator.dupe(u8, "transparent");
            if (std.mem.eql(u8, n.value, "current")) return try allocator.dupe(u8, "currentColor");
            if (std.mem.eql(u8, n.value, "inherit")) return try allocator.dupe(u8, "inherit");
            const tok = try std.fmt.allocPrint(allocator, "color-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok) == null) return null;
            return try std.fmt.allocPrint(allocator, "var(--color-{s})", .{n.value});
        },
        .arbitrary => |a| return try allocator.dupe(u8, a.value),
    }
}

/// Format an opacity modifier as the percentage string used inside
/// `color-mix(in oklab, <base> <pct>, transparent)`. Named `/50` becomes `50%`;
/// arbitrary `/[0.4]` is coerced to `40%` (matching the class contract's
/// `withAlpha`); arbitrary `/[27%]` or `/(--my-opacity)` is passed through
/// verbatim.
fn modifierAsOpacity(
    allocator: std.mem.Allocator,
    m: candidate.Modifier,
) ResolveError![]u8 {
    return switch (m) {
        .named => |n| try std.fmt.allocPrint(allocator, "{s}%", .{n}),
        .arbitrary => |a| {
            if (numberStringTimes100(allocator, a) catch null) |pct| {
                defer allocator.free(pct);
                return try std.fmt.allocPrint(allocator, "{s}%", .{pct});
            }
            return try allocator.dupe(u8, a);
        },
    };
}

/// If `s` is a plain decimal number (digits + at most one `.`), return its
/// value multiplied by 100 as a decimal string with no trailing zeros.
/// Returns null otherwise — used so non-numeric arbitraries like `27%` or
/// `var(--op)` fall through to verbatim emission.
///
/// `"0.4"` → `"40"`, `"0.04"` → `"4"`, `"0.123"` → `"12.3"`, `"1"` → `"100"`,
/// `".5"` → `"50"`. Implemented as decimal-point shifting so we don't pay
/// float-precision artifacts (e.g. `0.4 * 100 = 40.000000000000004`).
fn numberStringTimes100(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    if (s.len == 0) return null;
    var dot: ?usize = null;
    var has_digit = false;
    for (s, 0..) |c, idx| {
        switch (c) {
            '0'...'9' => has_digit = true,
            '.' => {
                if (dot != null) return null;
                dot = idx;
            },
            else => return null,
        }
    }
    if (!has_digit) return null;

    const int_part = if (dot) |p| s[0..p] else s;
    const frac_part = if (dot) |p| s[p + 1 ..] else "";

    // Strip leading zeros from int_part, keep one if all-zero.
    var lead: usize = 0;
    while (lead < int_part.len and int_part[lead] == '0') lead += 1;
    const int_clean = if (lead == int_part.len) "0" else int_part[lead..];

    // Concatenate digits, then place new decimal point at int_clean.len + 2.
    var digits = std.ArrayListUnmanaged(u8){};
    defer digits.deinit(allocator);
    try digits.appendSlice(allocator, int_clean);
    try digits.appendSlice(allocator, frac_part);
    const new_dot = int_clean.len + 2;
    while (digits.items.len < new_dot) try digits.append(allocator, '0');

    const int_out = digits.items[0..new_dot];
    const frac_out = digits.items[new_dot..];

    // Strip leading zeros from int_out (keep one if all-zero).
    var int_start: usize = 0;
    while (int_start + 1 < int_out.len and int_out[int_start] == '0') int_start += 1;
    const int_final = int_out[int_start..];

    // Strip trailing zeros from frac_out.
    var frac_end: usize = frac_out.len;
    while (frac_end > 0 and frac_out[frac_end - 1] == '0') frac_end -= 1;
    const frac_final = frac_out[0..frac_end];

    if (frac_final.len == 0) return try allocator.dupe(u8, int_final);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ int_final, frac_final });
}

/// Generic single-property color resolver. Output:
///   no modifier:   { property: <base> }
///   with modifier: { property: color-mix(in oklab, <base> <pct>, transparent) }
fn resolveColorProperty(
    allocator: std.mem.Allocator,
    t: Theme,
    property: []const u8,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const base = (try resolveColorBase(allocator, t, v)) orelse return null;

    const final = if (modifier) |m| blk: {
        defer allocator.free(base);
        const opacity = try modifierAsOpacity(allocator, m);
        defer allocator.free(opacity);
        break :blk try std.fmt.allocPrint(allocator, "color-mix(in oklab, {s} {s}, transparent)", .{ base, opacity });
    } else base;

    const decls = try allocator.alloc(Declaration, 1);
    errdefer {
        allocator.free(final);
        allocator.free(decls);
    }
    decls[0] = .{ .property = property, .value = final };
    return .{ .declarations = decls };
}

// ── Gradients (gap kinds #2, #3, #4) ────────────────────────────────────────

const GradientStop = enum { from, via, to };

/// `bg-linear-to-{dir}` → `background-image: linear-gradient(<dir>, ...)`.
/// Phase 1: emits a stub gradient using the `--tw-gradient-stops` custom property
/// (relies on `from-*`/`to-*` to populate the stops at runtime).
fn resolveBgLinearDirection(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    if (v != .named) return null;
    const dir = v.named.value;

    const css_dir: []const u8 = blk: {
        if (std.mem.eql(u8, dir, "t")) break :blk "to top";
        if (std.mem.eql(u8, dir, "tr")) break :blk "to top right";
        if (std.mem.eql(u8, dir, "r")) break :blk "to right";
        if (std.mem.eql(u8, dir, "br")) break :blk "to bottom right";
        if (std.mem.eql(u8, dir, "b")) break :blk "to bottom";
        if (std.mem.eql(u8, dir, "bl")) break :blk "to bottom left";
        if (std.mem.eql(u8, dir, "l")) break :blk "to left";
        if (std.mem.eql(u8, dir, "tl")) break :blk "to top left";
        // Numeric angle (e.g. bg-linear-115 — degrees from /site)
        if (isInteger(dir)) break :blk dir;
        return null;
    };

    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "--tw-gradient-position",
        .value = if (isInteger(dir))
            try std.fmt.allocPrint(allocator, "{s}deg", .{css_dir})
        else
            try allocator.dupe(u8, css_dir),
    };
    decls[1] = .{
        .property = "background-image",
        .value = try allocator.dupe(u8, "linear-gradient(var(--tw-gradient-stops, var(--tw-gradient-position), var(--tw-gradient-from, transparent), var(--tw-gradient-to, transparent)))"),
    };
    return .{ .declarations = decls };
}

/// `bg-linear-{angle}` (degrees) — e.g. `bg-linear-45`. The candidate parser
/// splits on `-` so the root becomes `bg-linear` and the value is the angle.
/// Negative angles via `-bg-linear-45` aren't supported class syntax;
/// negative is rejected at the dispatch site.
fn resolveBgLinearAngle(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const angle_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}deg", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(angle_value);

    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "--tw-gradient-position", .value = angle_value };
    decls[1] = .{
        .property = "background-image",
        .value = try allocator.dupe(u8, "linear-gradient(var(--tw-gradient-stops, var(--tw-gradient-position), var(--tw-gradient-from, transparent), var(--tw-gradient-to, transparent)))"),
    };
    return .{ .declarations = decls };
}

/// `bg-conic-{angle | arbitrary}` — emits a conic-gradient with a from-angle.
/// `bg-conic-45` → `from 45deg`. `bg-conic-[from_90deg_at_50%_50%]` → verbatim.
fn resolveBgConic(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const position: []u8 = switch (v) {
        .named => |n| blk: {
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "from {s}deg in oklab", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(position);

    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "--tw-gradient-position", .value = position };
    decls[1] = .{
        .property = "background-image",
        .value = try allocator.dupe(u8, "conic-gradient(var(--tw-gradient-stops, var(--tw-gradient-position), var(--tw-gradient-from, transparent), var(--tw-gradient-to, transparent)))"),
    };
    return .{ .declarations = decls };
}

/// `bg-radial-{arbitrary | --var}` — only arbitrary forms accepted (named
/// keywords like `bg-radial-circle` aren't supported). The bare
/// `bg-radial` is a static (no value).
fn resolveBgRadial(
    allocator: std.mem.Allocator,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    if (v != .arbitrary) return null;

    const decls = try allocator.alloc(Declaration, 2);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "--tw-gradient-position",
        .value = try allocator.dupe(u8, v.arbitrary.value),
    };
    decls[1] = .{
        .property = "background-image",
        .value = try allocator.dupe(u8, "radial-gradient(var(--tw-gradient-stops, var(--tw-gradient-position), var(--tw-gradient-from, transparent), var(--tw-gradient-to, transparent)))"),
    };
    return .{ .declarations = decls };
}

/// `from-<color>`, `to-<color>`, `via-<color>`, `from-<percent>`, `to-<percent>`, etc.
fn resolveGradientStop(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
    stop: GradientStop,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;

    // Percent-position form (named only): `to-50%`, `from-28%`. No modifier.
    if (v == .named) {
        const named = v.named.value;
        if (named.len > 0 and named[named.len - 1] == '%') {
            return try emitGradientStopPosition(allocator, stop, named);
        }
    }

    // Color form — share resolveColorBase so theme/special/arbitrary all work.
    const base = (try resolveColorBase(allocator, t, v)) orelse return null;

    // Optional opacity modifier wraps the color in color-mix.
    const final = if (modifier) |m| blk: {
        defer allocator.free(base);
        const opacity = try modifierAsOpacity(allocator, m);
        defer allocator.free(opacity);
        break :blk try std.fmt.allocPrint(allocator, "color-mix(in oklab, {s} {s}, transparent)", .{ base, opacity });
    } else base;

    return try emitGradientStopValueOwned(allocator, stop, final);
}

fn emitGradientStopValue(
    allocator: std.mem.Allocator,
    stop: GradientStop,
    val: []const u8,
) ResolveError!?ResolvedUtility {
    return emitGradientStopValueOwned(allocator, stop, try allocator.dupe(u8, val));
}

/// Takes ownership of `val` (already heap-allocated).
fn emitGradientStopValueOwned(
    allocator: std.mem.Allocator,
    stop: GradientStop,
    val: []u8,
) ResolveError!?ResolvedUtility {
    errdefer allocator.free(val);
    // `via-{color}` inserts itself into the gradient stops chain. Set both
    // `--tw-gradient-via` and `--tw-gradient-stops` so the linear/conic/radial
    // backgrounds (which read `var(--tw-gradient-stops, fallback)`) pick up
    // the via-color in the middle of the stop list. `from-`/`to-` only need
    // to set their own var; the bg-linear/conic/radial fallback chain
    // already references `--tw-gradient-from`/`-to` directly.
    if (stop == .via) {
        const decls = try allocator.alloc(Declaration, 2);
        errdefer allocator.free(decls);
        decls[0] = .{ .property = "--tw-gradient-via", .value = val };
        decls[1] = .{
            .property = "--tw-gradient-stops",
            .value = try allocator.dupe(u8, "var(--tw-gradient-position), var(--tw-gradient-from, transparent), var(--tw-gradient-via), var(--tw-gradient-to, transparent)"),
        };
        return .{ .declarations = decls };
    }
    const property: []const u8 = switch (stop) {
        .from => "--tw-gradient-from",
        .to => "--tw-gradient-to",
        else => unreachable,
    };
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = val };
    return .{ .declarations = decls };
}

fn emitGradientStopPosition(
    allocator: std.mem.Allocator,
    stop: GradientStop,
    pct: []const u8,
) ResolveError!?ResolvedUtility {
    const property: []const u8 = switch (stop) {
        .from => "--tw-gradient-from-position",
        .via => "--tw-gradient-via-position",
        .to => "--tw-gradient-to-position",
    };
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = try allocator.dupe(u8, pct) };
    return .{ .declarations = decls };
}

// ── Transition timing ───────────────────────────────────────────────────────

/// `duration-N` / `delay-N` — numeric values are milliseconds. Theme-keyed
/// (`duration-fast` etc.) tries `--<theme_namespace>-<key>` lookup.
/// `theme_namespace` is `duration` for both; the theme doesn't separately
/// namespace delays.
fn resolveTimingMs(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    property: []const u8,
    theme_namespace: []const u8,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "initial")) break :blk try allocator.dupe(u8, "initial");
            const tok = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ theme_namespace, n.value });
            defer allocator.free(tok);
            if (theme.lookup(t, tok) != null) {
                break :blk try std.fmt.allocPrint(allocator, "var(--{s}-{s})", .{ theme_namespace, n.value });
            }
            if (!isInteger(n.value)) return null;
            break :blk try std.fmt.allocPrint(allocator, "{s}ms", .{n.value});
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = property, .value = css_value };
    return .{ .declarations = decls };
}

/// `ease-{key|arb}` — sets `transition-timing-function`. Named keys for the
/// stock easings (`linear`, `in`, `out`, `in-out`, `initial`) are caught by
/// the static table; this handler covers theme-driven `ease-snappy` etc. and
/// arbitrary `ease-[cubic-bezier(...)]`.
fn resolveEasing(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const css_value: []u8 = switch (v) {
        .arbitrary => |a| try allocator.dupe(u8, a.value),
        .named => |n| blk: {
            const tok = try std.fmt.allocPrint(allocator, "ease-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok) == null) return null;
            break :blk try std.fmt.allocPrint(allocator, "var(--ease-{s})", .{n.value});
        },
    };
    errdefer allocator.free(css_value);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "transition-timing-function", .value = css_value };
    return .{ .declarations = decls };
}

/// `shadow-{color}` — sets `--tw-shadow-color` so a sibling `shadow-{size}`
/// utility can colorize its drop. Falls through (returns null) when the value
/// doesn't name a known theme color or special keyword.
fn resolveShadowColor(
    allocator: std.mem.Allocator,
    t: Theme,
    value: ?candidate.UtilityValue,
    modifier: ?candidate.Modifier,
) ResolveError!?ResolvedUtility {
    const v = value orelse return null;
    const base = (try resolveColorBase(allocator, t, v)) orelse return null;
    const final = if (modifier) |m| blk: {
        defer allocator.free(base);
        const opacity = try modifierAsOpacity(allocator, m);
        defer allocator.free(opacity);
        break :blk try std.fmt.allocPrint(
            allocator,
            "color-mix(in oklab, {s} {s}, transparent)",
            .{ base, opacity },
        );
    } else base;
    errdefer allocator.free(final);
    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{ .property = "--tw-shadow-color", .value = final };
    return .{ .declarations = decls };
}

// ── Border width ────────────────────────────────────────────────────────────

/// Map a `border-{root}` to the longhand `*-width` property names it sets.
/// Returns `null` for non-side roots (caller should treat as a non-border-
/// width root, e.g. a color form that should fall through).
fn borderWidthProperties(root: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, root, "border")) return &.{"border-width"};
    if (std.mem.eql(u8, root, "border-t")) return &.{"border-top-width"};
    if (std.mem.eql(u8, root, "border-r")) return &.{"border-right-width"};
    if (std.mem.eql(u8, root, "border-b")) return &.{"border-bottom-width"};
    if (std.mem.eql(u8, root, "border-l")) return &.{"border-left-width"};
    if (std.mem.eql(u8, root, "border-x")) return &.{ "border-left-width", "border-right-width" };
    if (std.mem.eql(u8, root, "border-y")) return &.{ "border-top-width", "border-bottom-width" };
    if (std.mem.eql(u8, root, "border-s")) return &.{"border-inline-start-width"};
    if (std.mem.eql(u8, root, "border-e")) return &.{"border-inline-end-width"};
    return null;
}

/// `border-N`, `border-{side}-N`, `border-x/y-N` — emits `border-*-width: Npx`.
/// Returns null when:
///   - The root isn't a border-width root (color/radius/style fall through).
///   - The value is missing (bare `border` is a static).
///   - The value isn't an integer or arbitrary (color names, `solid`, etc.).
fn resolveBorderWidth(
    allocator: std.mem.Allocator,
    root: []const u8,
    value: ?candidate.UtilityValue,
) ResolveError!?ResolvedUtility {
    const properties = borderWidthProperties(root) orelse return null;
    const v = value orelse return null;

    const css_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (!isInteger(n.value)) return null; // let color path handle named colors
            break :blk try std.fmt.allocPrint(allocator, "{s}px", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(css_value);

    const decls = try allocator.alloc(Declaration, properties.len);
    errdefer allocator.free(decls);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) allocator.free(decls[j].value);
    }
    while (i < properties.len) : (i += 1) {
        decls[i] = .{ .property = properties[i], .value = try allocator.dupe(u8, css_value) };
    }
    allocator.free(css_value);
    return .{ .declarations = decls };
}

// ── Border radius ───────────────────────────────────────────────────────────

/// Mapping from a `rounded-<side>` or `rounded-<corner>` root to the longhand
/// border-radius properties it sets. The class contract covers physical sides
/// (`t/r/b/l`), physical corners (`tl/tr/br/bl`), and logical (`s/e` and
/// `ss/se/es/ee`). Returns `null` if `root` isn't a recognised side/corner.
fn roundedSideProperties(root: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, root, "rounded-t")) return &.{ "border-top-left-radius", "border-top-right-radius" };
    if (std.mem.eql(u8, root, "rounded-r")) return &.{ "border-top-right-radius", "border-bottom-right-radius" };
    if (std.mem.eql(u8, root, "rounded-b")) return &.{ "border-bottom-right-radius", "border-bottom-left-radius" };
    if (std.mem.eql(u8, root, "rounded-l")) return &.{ "border-top-left-radius", "border-bottom-left-radius" };
    if (std.mem.eql(u8, root, "rounded-tl")) return &.{"border-top-left-radius"};
    if (std.mem.eql(u8, root, "rounded-tr")) return &.{"border-top-right-radius"};
    if (std.mem.eql(u8, root, "rounded-br")) return &.{"border-bottom-right-radius"};
    if (std.mem.eql(u8, root, "rounded-bl")) return &.{"border-bottom-left-radius"};
    // Logical (writing-mode aware).
    if (std.mem.eql(u8, root, "rounded-s")) return &.{ "border-start-start-radius", "border-end-start-radius" };
    if (std.mem.eql(u8, root, "rounded-e")) return &.{ "border-start-end-radius", "border-end-end-radius" };
    if (std.mem.eql(u8, root, "rounded-ss")) return &.{"border-start-start-radius"};
    if (std.mem.eql(u8, root, "rounded-se")) return &.{"border-start-end-radius"};
    if (std.mem.eql(u8, root, "rounded-es")) return &.{"border-end-start-radius"};
    if (std.mem.eql(u8, root, "rounded-ee")) return &.{"border-end-end-radius"};
    return null;
}

/// Resolve a `rounded-{key}` or `rounded-{side}-{key}` candidate. The bare
/// `rounded`, `rounded-none`, `rounded-full` cases are static (handled by the
/// static table above). This handler covers:
///   - `rounded-{key}` → `border-radius: var(--radius-{key})` for theme keys
///   - `rounded-[<value>]` → `border-radius: <value>` (arbitrary)
///   - `rounded-{side}-{key}` and `rounded-{corner}-{key}` → corresponding
///     longhand(s) per `roundedSideProperties`.
///   - The same `none` / `full` keywords work in side form (`rounded-t-none`).
fn resolveBorderRadius(
    allocator: std.mem.Allocator,
    t: Theme,
    root: []const u8,
    value: ?candidate.UtilityValue,
    negative: bool,
) ResolveError!?ResolvedUtility {
    if (negative) return null;

    const properties: []const []const u8 = if (std.mem.eql(u8, root, "rounded"))
        &.{"border-radius"}
    else if (roundedSideProperties(root)) |sides|
        sides
    else
        return null;

    const v = value orelse return null;

    // Compute the CSS value (single string shared across all longhands).
    const css_value: []u8 = switch (v) {
        .named => |n| blk: {
            if (std.mem.eql(u8, n.value, "none")) break :blk try allocator.dupe(u8, "0");
            if (std.mem.eql(u8, n.value, "full")) break :blk try allocator.dupe(u8, "calc(infinity * 1px)");
            const tok = try std.fmt.allocPrint(allocator, "radius-{s}", .{n.value});
            defer allocator.free(tok);
            if (theme.lookup(t, tok) == null) return null;
            break :blk try std.fmt.allocPrint(allocator, "var(--radius-{s})", .{n.value});
        },
        .arbitrary => |a| try allocator.dupe(u8, a.value),
    };
    errdefer allocator.free(css_value);

    const decls = try allocator.alloc(Declaration, properties.len);
    errdefer allocator.free(decls);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) allocator.free(decls[j].value);
    }
    while (i < properties.len) : (i += 1) {
        // Each longhand owns its own copy so freeResolvedUtility can free them.
        decls[i] = .{ .property = properties[i], .value = try allocator.dupe(u8, css_value) };
    }
    allocator.free(css_value); // we duped per-longhand; release the shared copy
    return .{ .declarations = decls };
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn isInteger(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Numeric value on the spacing/scale grid. Accepts integers (`12`) and
/// single-decimal fractionals (`0.5`, `1.5`, `2.5`, `3.5` — the supported
/// half-step spacing scale). Rejects empty, leading dot, trailing dot,
/// multi-dot, or any non-digit characters.
fn isSpacingNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var saw_dot = false;
    var saw_digit_after_dot = false;
    var saw_digit_before_dot = false;
    for (s) |c| {
        if (c == '.') {
            if (saw_dot) return false; // only one dot
            if (!saw_digit_before_dot) return false; // ".5" not allowed
            saw_dot = true;
        } else if (c >= '0' and c <= '9') {
            if (saw_dot) saw_digit_after_dot = true else saw_digit_before_dot = true;
        } else {
            return false;
        }
    }
    if (saw_dot and !saw_digit_after_dot) return false; // "5." not allowed
    return saw_digit_before_dot;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const tst = std.testing;

const test_theme = theme.Theme{ .tokens = &.{
    .{ .name = "spacing", .value = "0.25rem" },
    .{ .name = "color-red-500", .value = "oklch(0.637 0.237 25.331)" },
    .{ .name = "color-gray-800", .value = "oklch(0.278 0.033 256.848)" },
    .{ .name = "color-white", .value = "#fff" },
    .{ .name = "font-sans", .value = "Switzer, system-ui, sans-serif" },
    .{ .name = "radius-md", .value = "0.375rem" },
    .{ .name = "radius-lg", .value = "0.5rem" },
    .{ .name = "text-2xl", .value = "1.5rem" },
    .{ .name = "text-2xl--line-height", .value = "calc(2 / 1.5)" },
    .{ .name = "text-base", .value = "1rem" },
} };

fn parseAndResolve(allocator: std.mem.Allocator, input: []const u8) !?ResolvedUtility {
    const cands = try candidate.parseCandidate(allocator, input);
    defer candidate.freeCandidates(allocator, cands);
    for (cands) |c| {
        if (try resolveCandidate(allocator, test_theme, c)) |r| return r;
    }
    return null;
}

// ── Border radius ────────────────────────────────────────────────────────────

// ── Modifier on arbitrary properties ────────────────────────────────────────

// ── Modifier on functional color: text-current/50 ───────────────────────────

// ── Text size with line-height modifier ─────────────────────────────────────

// ── Gradient direction extras ───────────────────────────────────────────────

// ── Grid row utilities + arbitrary col-span ─────────────────────────────────

// ── Spacing dispatch: padding / margin / gap / width / height ──────────────

// ── Fractions (modifier-as-denominator) ─────────────────────────────────────

// ── space-x-N / space-y-N — selector-modifying utility ──────────────────────

// ── Border width ────────────────────────────────────────────────────────────

// ── Transition / duration / delay / ease ────────────────────────────────────

// ── Shadow / outline base statics + cursor / select / object-fit ────────────

// ── Color utilities ────────────────────────────────────────────────────────

};

pub const variants_mod = struct {
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
const candidate = amalgam.candidate_mod;
const theme = amalgam.theme_mod;

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

// ── not-* / has-* / in-* compound forwarding ────────────────────────────────

// ── Container queries ──────────────────────────────────────────────────────

// ── Arbitrary at-rule variants ──────────────────────────────────────────────

};

pub const sort_mod = struct {
/// Deterministic class sorting.
///
/// Replaces the task-03 stub. Implements `sortClasses(allocator, input, theme_css)`
/// which the test runner calls per fixture.
///
/// Algorithm (Phase 1, faithful enough for the 10 sort fixtures):
///   1. Parse each class via candidate.zig.
///   2. Compute a sort key per class:
///      - Unknown or unparseable classes → null (sort to front,
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
const candidate = amalgam.candidate_mod;

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

/// Compute a sort key for a class name. Returns null for unknown or unparseable
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

    // Parser failed: not a recognized class.
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
            // Unknown utility → null sort key.
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
/// breakpoints if needed. Default breakpoints:
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
/// The bucket numbers implement the JIT's cascade order for known properties.
/// Extend them as class coverage grows.
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

    // ── Background (before padding/border) ──
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

};

pub const compile_mod = struct {
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
const candidate = amalgam.candidate_mod;
const theme = amalgam.theme_mod;
const utilities = amalgam.utilities_mod;
const variants = amalgam.variants_mod;
const sort = amalgam.sort_mod;

pub const CompileError = error{
    OutOfMemory,
    /// Raised when input contains a CSS directive Publr JIT does not
    /// support (`@apply`, `@import`, `@source`, `@utility`, `@variant`,
    /// `@custom-variant`). Callers that parse user CSS should pair this with
    /// `unsupportedFeatureMessage(directive)` for a migration-friendly
    /// diagnostic. `compile()` itself takes pre-tokenized class strings and
    /// has no path to raise it today; the variant exists so future user-CSS
    /// entry points (loaders, plugin hosts) error consistently. See
    UnsupportedFeature,
};

/// Migration message for an unsupported CSS directive. Returns a stable,
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

};

pub const theme_from_css_mod = struct {
/// theme-from-css — converts a CSS file's @theme blocks into
/// a Publr `theme.zon` override-only file.
///
/// Behaviors locked from validation B:
///   - Recognizes `@theme {}`, `@theme default {}`, `@theme inline {}`. Logs a
///     warning for non-bare modifier words and treats them the same.
///   - Skips nested `@keyframes` blocks inside `@theme` with a warning. Lifting
///     them as keyframe tokens is deferred (the flat Token schema doesn't
///     model keyframes natively yet).
///   - Multi-line CSS values (font stacks) are collapsed to single-line strings
///     by squashing whitespace runs to single spaces.
///
/// Output is deterministic: tokens emitted in source order, no trailing
/// whitespace, single trailing LF. Re-running on the same input is byte-stable.

const std = @import("std");

pub const ConvertOptions = struct {
    /// Optional warning sink. Receives one line per warning, no trailing LF.
    /// Caller can pass `&warnings_log.writer()` or null to suppress.
    warn: ?*std.io.Writer = null,
};

pub const ConvertError = error{
    UnclosedBlock,
    UnclosedComment,
    InvalidValue,
    OutOfMemory,
} || std.io.Writer.Error;

/// Convert a CSS source buffer into ZON bytes.
/// Caller owns the returned slice.
pub fn convert(
    allocator: std.mem.Allocator,
    css: []const u8,
    options: ConvertOptions,
) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll(".{\n    .tokens = .{\n");

    var i: usize = 0;
    var token_count: usize = 0;
    var skipped_keyframes: usize = 0;

    while (i < css.len) {
        const at_idx = std.mem.indexOfPos(u8, css, i, "@theme") orelse break;
        i = at_idx + "@theme".len;

        // Read optional modifier words (default / inline) until `{`.
        // Validation B: warn if a non-bare modifier appears so users know what
        // we treated it as.
        var modifier: []const u8 = "";
        while (i < css.len and (css[i] == ' ' or css[i] == '\t')) i += 1;
        if (i < css.len and css[i] != '{') {
            const start = i;
            while (i < css.len and css[i] != ' ' and css[i] != '\t' and css[i] != '{') i += 1;
            modifier = std.mem.trim(u8, css[start..i], " \t");
            while (i < css.len and (css[i] == ' ' or css[i] == '\t')) i += 1;
        }
        if (i >= css.len or css[i] != '{') continue; // malformed — skip
        i += 1; // past `{`

        if (modifier.len > 0 and options.warn != null) {
            try options.warn.?.print(
                "warning: @theme modifier '{s}' treated as bare @theme — Publr only supports the override-extend mode (see THEME.md)\n",
                .{modifier},
            );
        }

        // Parse declarations until matching `}`.
        var depth: u32 = 1;
        while (i < css.len and depth > 0) {
            // Skip whitespace.
            while (i < css.len and (css[i] == ' ' or css[i] == '\t' or css[i] == '\n' or css[i] == '\r')) i += 1;
            if (i >= css.len) break;

            if (css[i] == '}') {
                depth -= 1;
                i += 1;
                continue;
            }

            // Skip /* ... */ comments.
            if (i + 1 < css.len and css[i] == '/' and css[i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, css, i + 2, "*/") orelse return ConvertError.UnclosedComment;
                i = end + 2;
                continue;
            }

            // Skip nested at-rules (mainly @keyframes inside @theme).
            // Validation B finding: lift these as keyframe tokens later; for
            // now warn + skip the block.
            if (css[i] == '@') {
                const at_start = i;
                while (i < css.len and css[i] != '{') i += 1;
                if (i >= css.len) return ConvertError.UnclosedBlock;
                const at_name = std.mem.trim(u8, css[at_start..i], " \t\n\r");
                if (options.warn != null) {
                    try options.warn.?.print(
                        "warning: skipping nested at-rule inside @theme: {s} (keyframe-style theme tokens not yet supported by the converter)\n",
                        .{at_name},
                    );
                }
                skipped_keyframes += 1;

                // Walk balanced braces.
                i += 1;
                var nested: u32 = 1;
                while (i < css.len and nested > 0) {
                    if (css[i] == '{') nested += 1
                    else if (css[i] == '}') nested -= 1;
                    i += 1;
                }
                continue;
            }

            // Stray `{` — bump depth and continue (unusual but defensive).
            if (css[i] == '{') {
                depth += 1;
                i += 1;
                continue;
            }

            // Custom property `--name: value;`
            if (i + 1 >= css.len or css[i] != '-' or css[i + 1] != '-') {
                // Non-property content (e.g., regular CSS rule); skip to next `;` or `}`.
                while (i < css.len and css[i] != ';' and css[i] != '}') i += 1;
                if (i < css.len and css[i] == ';') i += 1;
                continue;
            }
            i += 2; // past `--`

            const name_start = i;
            while (i < css.len and css[i] != ':') i += 1;
            if (i >= css.len) return ConvertError.InvalidValue;
            const name = std.mem.trim(u8, css[name_start..i], " \t\n\r");
            i += 1; // past `:`

            // Read value until `;` outside parens / strings.
            const val_start = i;
            var paren_depth: u32 = 0;
            var in_single = false;
            var in_double = false;
            while (i < css.len) {
                const c = css[i];
                if (in_single) {
                    if (c == '\'') in_single = false;
                } else if (in_double) {
                    if (c == '"') in_double = false;
                } else if (c == '\'') {
                    in_single = true;
                } else if (c == '"') {
                    in_double = true;
                } else if (c == '(') {
                    paren_depth += 1;
                } else if (c == ')') {
                    if (paren_depth > 0) paren_depth -= 1;
                } else if (c == ';' and paren_depth == 0) {
                    break;
                }
                i += 1;
            }
            if (i >= css.len) return ConvertError.InvalidValue;
            const raw_value = std.mem.trim(u8, css[val_start..i], " \t\n\r");
            i += 1; // past `;`

            // Collapse whitespace runs (newlines + tabs) to single spaces. Lets
            // multi-line font stacks live as a single ZON string.
            const collapsed = try collapseWhitespace(allocator, raw_value);
            defer allocator.free(collapsed);

            // ZON string literals: escape `"` and `\`. Use the @"..." identifier
            // form is for field names, not values — values are plain strings.
            if (token_count > 0) try w.writeAll(",\n");
            try w.writeAll("        .{ .name = \"");
            try writeZonStringEscaped(w.any(), name);
            try w.writeAll("\", .value = \"");
            try writeZonStringEscaped(w.any(), collapsed);
            try w.writeAll("\" }");
            token_count += 1;
        }
    }

    if (token_count > 0) try w.writeAll(",\n");
    try w.writeAll("    },\n}\n");

    if (options.warn != null and skipped_keyframes > 0) {
        try options.warn.?.print(
            "info: skipped {d} nested at-rule(s) inside @theme; total tokens emitted: {d}\n",
            .{ skipped_keyframes, token_count },
        );
    }

    return out.toOwnedSlice();
}

/// Collapse runs of whitespace (space/tab/CR/LF) to a single ASCII space.
/// Caller owns the returned slice.
fn collapseWhitespace(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    var prev_ws = false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!prev_ws) try buf.append(' ');
            prev_ws = true;
        } else {
            try buf.append(c);
            prev_ws = false;
        }
    }
    // Trim trailing space if any.
    var out = try buf.toOwnedSlice();
    while (out.len > 0 and out[out.len - 1] == ' ') out = out[0 .. out.len - 1];
    return out;
}

/// Write a string with ZON-string-literal escaping: `\` and `"` get backslash-escaped.
/// Other chars pass through; we don't try to handle non-printable bytes since
/// CSS theme values shouldn't contain them.
fn writeZonStringEscaped(w: std.io.AnyWriter, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\', '"' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => try w.writeByte(c),
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

};

const embedded_default_theme: theme_mod.Theme =
.{
    .tokens = &.{
        .{ .name = "font-sans", .value = "ui-sans-serif, system-ui, sans-serif, 'Apple Color Emoji', 'Segoe UI Emoji', 'Segoe UI Symbol', 'Noto Color Emoji'" },
        .{ .name = "font-serif", .value = "ui-serif, Georgia, Cambria, 'Times New Roman', Times, serif" },
        .{ .name = "font-mono", .value = "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace" },
        .{ .name = "color-red-50", .value = "oklch(97.1% 0.013 17.38)" },
        .{ .name = "color-red-100", .value = "oklch(93.6% 0.032 17.717)" },
        .{ .name = "color-red-200", .value = "oklch(88.5% 0.062 18.334)" },
        .{ .name = "color-red-300", .value = "oklch(80.8% 0.114 19.571)" },
        .{ .name = "color-red-400", .value = "oklch(70.4% 0.191 22.216)" },
        .{ .name = "color-red-500", .value = "oklch(63.7% 0.237 25.331)" },
        .{ .name = "color-red-600", .value = "oklch(57.7% 0.245 27.325)" },
        .{ .name = "color-red-700", .value = "oklch(50.5% 0.213 27.518)" },
        .{ .name = "color-red-800", .value = "oklch(44.4% 0.177 26.899)" },
        .{ .name = "color-red-900", .value = "oklch(39.6% 0.141 25.723)" },
        .{ .name = "color-red-950", .value = "oklch(25.8% 0.092 26.042)" },
        .{ .name = "color-orange-50", .value = "oklch(98% 0.016 73.684)" },
        .{ .name = "color-orange-100", .value = "oklch(95.4% 0.038 75.164)" },
        .{ .name = "color-orange-200", .value = "oklch(90.1% 0.076 70.697)" },
        .{ .name = "color-orange-300", .value = "oklch(83.7% 0.128 66.29)" },
        .{ .name = "color-orange-400", .value = "oklch(75% 0.183 55.934)" },
        .{ .name = "color-orange-500", .value = "oklch(70.5% 0.213 47.604)" },
        .{ .name = "color-orange-600", .value = "oklch(64.6% 0.222 41.116)" },
        .{ .name = "color-orange-700", .value = "oklch(55.3% 0.195 38.402)" },
        .{ .name = "color-orange-800", .value = "oklch(47% 0.157 37.304)" },
        .{ .name = "color-orange-900", .value = "oklch(40.8% 0.123 38.172)" },
        .{ .name = "color-orange-950", .value = "oklch(26.6% 0.079 36.259)" },
        .{ .name = "color-amber-50", .value = "oklch(98.7% 0.022 95.277)" },
        .{ .name = "color-amber-100", .value = "oklch(96.2% 0.059 95.617)" },
        .{ .name = "color-amber-200", .value = "oklch(92.4% 0.12 95.746)" },
        .{ .name = "color-amber-300", .value = "oklch(87.9% 0.169 91.605)" },
        .{ .name = "color-amber-400", .value = "oklch(82.8% 0.189 84.429)" },
        .{ .name = "color-amber-500", .value = "oklch(76.9% 0.188 70.08)" },
        .{ .name = "color-amber-600", .value = "oklch(66.6% 0.179 58.318)" },
        .{ .name = "color-amber-700", .value = "oklch(55.5% 0.163 48.998)" },
        .{ .name = "color-amber-800", .value = "oklch(47.3% 0.137 46.201)" },
        .{ .name = "color-amber-900", .value = "oklch(41.4% 0.112 45.904)" },
        .{ .name = "color-amber-950", .value = "oklch(27.9% 0.077 45.635)" },
        .{ .name = "color-yellow-50", .value = "oklch(98.7% 0.026 102.212)" },
        .{ .name = "color-yellow-100", .value = "oklch(97.3% 0.071 103.193)" },
        .{ .name = "color-yellow-200", .value = "oklch(94.5% 0.129 101.54)" },
        .{ .name = "color-yellow-300", .value = "oklch(90.5% 0.182 98.111)" },
        .{ .name = "color-yellow-400", .value = "oklch(85.2% 0.199 91.936)" },
        .{ .name = "color-yellow-500", .value = "oklch(79.5% 0.184 86.047)" },
        .{ .name = "color-yellow-600", .value = "oklch(68.1% 0.162 75.834)" },
        .{ .name = "color-yellow-700", .value = "oklch(55.4% 0.135 66.442)" },
        .{ .name = "color-yellow-800", .value = "oklch(47.6% 0.114 61.907)" },
        .{ .name = "color-yellow-900", .value = "oklch(42.1% 0.095 57.708)" },
        .{ .name = "color-yellow-950", .value = "oklch(28.6% 0.066 53.813)" },
        .{ .name = "color-lime-50", .value = "oklch(98.6% 0.031 120.757)" },
        .{ .name = "color-lime-100", .value = "oklch(96.7% 0.067 122.328)" },
        .{ .name = "color-lime-200", .value = "oklch(93.8% 0.127 124.321)" },
        .{ .name = "color-lime-300", .value = "oklch(89.7% 0.196 126.665)" },
        .{ .name = "color-lime-400", .value = "oklch(84.1% 0.238 128.85)" },
        .{ .name = "color-lime-500", .value = "oklch(76.8% 0.233 130.85)" },
        .{ .name = "color-lime-600", .value = "oklch(64.8% 0.2 131.684)" },
        .{ .name = "color-lime-700", .value = "oklch(53.2% 0.157 131.589)" },
        .{ .name = "color-lime-800", .value = "oklch(45.3% 0.124 130.933)" },
        .{ .name = "color-lime-900", .value = "oklch(40.5% 0.101 131.063)" },
        .{ .name = "color-lime-950", .value = "oklch(27.4% 0.072 132.109)" },
        .{ .name = "color-green-50", .value = "oklch(98.2% 0.018 155.826)" },
        .{ .name = "color-green-100", .value = "oklch(96.2% 0.044 156.743)" },
        .{ .name = "color-green-200", .value = "oklch(92.5% 0.084 155.995)" },
        .{ .name = "color-green-300", .value = "oklch(87.1% 0.15 154.449)" },
        .{ .name = "color-green-400", .value = "oklch(79.2% 0.209 151.711)" },
        .{ .name = "color-green-500", .value = "oklch(72.3% 0.219 149.579)" },
        .{ .name = "color-green-600", .value = "oklch(62.7% 0.194 149.214)" },
        .{ .name = "color-green-700", .value = "oklch(52.7% 0.154 150.069)" },
        .{ .name = "color-green-800", .value = "oklch(44.8% 0.119 151.328)" },
        .{ .name = "color-green-900", .value = "oklch(39.3% 0.095 152.535)" },
        .{ .name = "color-green-950", .value = "oklch(26.6% 0.065 152.934)" },
        .{ .name = "color-emerald-50", .value = "oklch(97.9% 0.021 166.113)" },
        .{ .name = "color-emerald-100", .value = "oklch(95% 0.052 163.051)" },
        .{ .name = "color-emerald-200", .value = "oklch(90.5% 0.093 164.15)" },
        .{ .name = "color-emerald-300", .value = "oklch(84.5% 0.143 164.978)" },
        .{ .name = "color-emerald-400", .value = "oklch(76.5% 0.177 163.223)" },
        .{ .name = "color-emerald-500", .value = "oklch(69.6% 0.17 162.48)" },
        .{ .name = "color-emerald-600", .value = "oklch(59.6% 0.145 163.225)" },
        .{ .name = "color-emerald-700", .value = "oklch(50.8% 0.118 165.612)" },
        .{ .name = "color-emerald-800", .value = "oklch(43.2% 0.095 166.913)" },
        .{ .name = "color-emerald-900", .value = "oklch(37.8% 0.077 168.94)" },
        .{ .name = "color-emerald-950", .value = "oklch(26.2% 0.051 172.552)" },
        .{ .name = "color-teal-50", .value = "oklch(98.4% 0.014 180.72)" },
        .{ .name = "color-teal-100", .value = "oklch(95.3% 0.051 180.801)" },
        .{ .name = "color-teal-200", .value = "oklch(91% 0.096 180.426)" },
        .{ .name = "color-teal-300", .value = "oklch(85.5% 0.138 181.071)" },
        .{ .name = "color-teal-400", .value = "oklch(77.7% 0.152 181.912)" },
        .{ .name = "color-teal-500", .value = "oklch(70.4% 0.14 182.503)" },
        .{ .name = "color-teal-600", .value = "oklch(60% 0.118 184.704)" },
        .{ .name = "color-teal-700", .value = "oklch(51.1% 0.096 186.391)" },
        .{ .name = "color-teal-800", .value = "oklch(43.7% 0.078 188.216)" },
        .{ .name = "color-teal-900", .value = "oklch(38.6% 0.063 188.416)" },
        .{ .name = "color-teal-950", .value = "oklch(27.7% 0.046 192.524)" },
        .{ .name = "color-cyan-50", .value = "oklch(98.4% 0.019 200.873)" },
        .{ .name = "color-cyan-100", .value = "oklch(95.6% 0.045 203.388)" },
        .{ .name = "color-cyan-200", .value = "oklch(91.7% 0.08 205.041)" },
        .{ .name = "color-cyan-300", .value = "oklch(86.5% 0.127 207.078)" },
        .{ .name = "color-cyan-400", .value = "oklch(78.9% 0.154 211.53)" },
        .{ .name = "color-cyan-500", .value = "oklch(71.5% 0.143 215.221)" },
        .{ .name = "color-cyan-600", .value = "oklch(60.9% 0.126 221.723)" },
        .{ .name = "color-cyan-700", .value = "oklch(52% 0.105 223.128)" },
        .{ .name = "color-cyan-800", .value = "oklch(45% 0.085 224.283)" },
        .{ .name = "color-cyan-900", .value = "oklch(39.8% 0.07 227.392)" },
        .{ .name = "color-cyan-950", .value = "oklch(30.2% 0.056 229.695)" },
        .{ .name = "color-sky-50", .value = "oklch(97.7% 0.013 236.62)" },
        .{ .name = "color-sky-100", .value = "oklch(95.1% 0.026 236.824)" },
        .{ .name = "color-sky-200", .value = "oklch(90.1% 0.058 230.902)" },
        .{ .name = "color-sky-300", .value = "oklch(82.8% 0.111 230.318)" },
        .{ .name = "color-sky-400", .value = "oklch(74.6% 0.16 232.661)" },
        .{ .name = "color-sky-500", .value = "oklch(68.5% 0.169 237.323)" },
        .{ .name = "color-sky-600", .value = "oklch(58.8% 0.158 241.966)" },
        .{ .name = "color-sky-700", .value = "oklch(50% 0.134 242.749)" },
        .{ .name = "color-sky-800", .value = "oklch(44.3% 0.11 240.79)" },
        .{ .name = "color-sky-900", .value = "oklch(39.1% 0.09 240.876)" },
        .{ .name = "color-sky-950", .value = "oklch(29.3% 0.066 243.157)" },
        .{ .name = "color-blue-50", .value = "oklch(97% 0.014 254.604)" },
        .{ .name = "color-blue-100", .value = "oklch(93.2% 0.032 255.585)" },
        .{ .name = "color-blue-200", .value = "oklch(88.2% 0.059 254.128)" },
        .{ .name = "color-blue-300", .value = "oklch(80.9% 0.105 251.813)" },
        .{ .name = "color-blue-400", .value = "oklch(70.7% 0.165 254.624)" },
        .{ .name = "color-blue-500", .value = "oklch(62.3% 0.214 259.815)" },
        .{ .name = "color-blue-600", .value = "oklch(54.6% 0.245 262.881)" },
        .{ .name = "color-blue-700", .value = "oklch(48.8% 0.243 264.376)" },
        .{ .name = "color-blue-800", .value = "oklch(42.4% 0.199 265.638)" },
        .{ .name = "color-blue-900", .value = "oklch(37.9% 0.146 265.522)" },
        .{ .name = "color-blue-950", .value = "oklch(28.2% 0.091 267.935)" },
        .{ .name = "color-indigo-50", .value = "oklch(96.2% 0.018 272.314)" },
        .{ .name = "color-indigo-100", .value = "oklch(93% 0.034 272.788)" },
        .{ .name = "color-indigo-200", .value = "oklch(87% 0.065 274.039)" },
        .{ .name = "color-indigo-300", .value = "oklch(78.5% 0.115 274.713)" },
        .{ .name = "color-indigo-400", .value = "oklch(67.3% 0.182 276.935)" },
        .{ .name = "color-indigo-500", .value = "oklch(58.5% 0.233 277.117)" },
        .{ .name = "color-indigo-600", .value = "oklch(51.1% 0.262 276.966)" },
        .{ .name = "color-indigo-700", .value = "oklch(45.7% 0.24 277.023)" },
        .{ .name = "color-indigo-800", .value = "oklch(39.8% 0.195 277.366)" },
        .{ .name = "color-indigo-900", .value = "oklch(35.9% 0.144 278.697)" },
        .{ .name = "color-indigo-950", .value = "oklch(25.7% 0.09 281.288)" },
        .{ .name = "color-violet-50", .value = "oklch(96.9% 0.016 293.756)" },
        .{ .name = "color-violet-100", .value = "oklch(94.3% 0.029 294.588)" },
        .{ .name = "color-violet-200", .value = "oklch(89.4% 0.057 293.283)" },
        .{ .name = "color-violet-300", .value = "oklch(81.1% 0.111 293.571)" },
        .{ .name = "color-violet-400", .value = "oklch(70.2% 0.183 293.541)" },
        .{ .name = "color-violet-500", .value = "oklch(60.6% 0.25 292.717)" },
        .{ .name = "color-violet-600", .value = "oklch(54.1% 0.281 293.009)" },
        .{ .name = "color-violet-700", .value = "oklch(49.1% 0.27 292.581)" },
        .{ .name = "color-violet-800", .value = "oklch(43.2% 0.232 292.759)" },
        .{ .name = "color-violet-900", .value = "oklch(38% 0.189 293.745)" },
        .{ .name = "color-violet-950", .value = "oklch(28.3% 0.141 291.089)" },
        .{ .name = "color-purple-50", .value = "oklch(97.7% 0.014 308.299)" },
        .{ .name = "color-purple-100", .value = "oklch(94.6% 0.033 307.174)" },
        .{ .name = "color-purple-200", .value = "oklch(90.2% 0.063 306.703)" },
        .{ .name = "color-purple-300", .value = "oklch(82.7% 0.119 306.383)" },
        .{ .name = "color-purple-400", .value = "oklch(71.4% 0.203 305.504)" },
        .{ .name = "color-purple-500", .value = "oklch(62.7% 0.265 303.9)" },
        .{ .name = "color-purple-600", .value = "oklch(55.8% 0.288 302.321)" },
        .{ .name = "color-purple-700", .value = "oklch(49.6% 0.265 301.924)" },
        .{ .name = "color-purple-800", .value = "oklch(43.8% 0.218 303.724)" },
        .{ .name = "color-purple-900", .value = "oklch(38.1% 0.176 304.987)" },
        .{ .name = "color-purple-950", .value = "oklch(29.1% 0.149 302.717)" },
        .{ .name = "color-fuchsia-50", .value = "oklch(97.7% 0.017 320.058)" },
        .{ .name = "color-fuchsia-100", .value = "oklch(95.2% 0.037 318.852)" },
        .{ .name = "color-fuchsia-200", .value = "oklch(90.3% 0.076 319.62)" },
        .{ .name = "color-fuchsia-300", .value = "oklch(83.3% 0.145 321.434)" },
        .{ .name = "color-fuchsia-400", .value = "oklch(74% 0.238 322.16)" },
        .{ .name = "color-fuchsia-500", .value = "oklch(66.7% 0.295 322.15)" },
        .{ .name = "color-fuchsia-600", .value = "oklch(59.1% 0.293 322.896)" },
        .{ .name = "color-fuchsia-700", .value = "oklch(51.8% 0.253 323.949)" },
        .{ .name = "color-fuchsia-800", .value = "oklch(45.2% 0.211 324.591)" },
        .{ .name = "color-fuchsia-900", .value = "oklch(40.1% 0.17 325.612)" },
        .{ .name = "color-fuchsia-950", .value = "oklch(29.3% 0.136 325.661)" },
        .{ .name = "color-pink-50", .value = "oklch(97.1% 0.014 343.198)" },
        .{ .name = "color-pink-100", .value = "oklch(94.8% 0.028 342.258)" },
        .{ .name = "color-pink-200", .value = "oklch(89.9% 0.061 343.231)" },
        .{ .name = "color-pink-300", .value = "oklch(82.3% 0.12 346.018)" },
        .{ .name = "color-pink-400", .value = "oklch(71.8% 0.202 349.761)" },
        .{ .name = "color-pink-500", .value = "oklch(65.6% 0.241 354.308)" },
        .{ .name = "color-pink-600", .value = "oklch(59.2% 0.249 0.584)" },
        .{ .name = "color-pink-700", .value = "oklch(52.5% 0.223 3.958)" },
        .{ .name = "color-pink-800", .value = "oklch(45.9% 0.187 3.815)" },
        .{ .name = "color-pink-900", .value = "oklch(40.8% 0.153 2.432)" },
        .{ .name = "color-pink-950", .value = "oklch(28.4% 0.109 3.907)" },
        .{ .name = "color-rose-50", .value = "oklch(96.9% 0.015 12.422)" },
        .{ .name = "color-rose-100", .value = "oklch(94.1% 0.03 12.58)" },
        .{ .name = "color-rose-200", .value = "oklch(89.2% 0.058 10.001)" },
        .{ .name = "color-rose-300", .value = "oklch(81% 0.117 11.638)" },
        .{ .name = "color-rose-400", .value = "oklch(71.2% 0.194 13.428)" },
        .{ .name = "color-rose-500", .value = "oklch(64.5% 0.246 16.439)" },
        .{ .name = "color-rose-600", .value = "oklch(58.6% 0.253 17.585)" },
        .{ .name = "color-rose-700", .value = "oklch(51.4% 0.222 16.935)" },
        .{ .name = "color-rose-800", .value = "oklch(45.5% 0.188 13.697)" },
        .{ .name = "color-rose-900", .value = "oklch(41% 0.159 10.272)" },
        .{ .name = "color-rose-950", .value = "oklch(27.1% 0.105 12.094)" },
        .{ .name = "color-slate-50", .value = "oklch(98.4% 0.003 247.858)" },
        .{ .name = "color-slate-100", .value = "oklch(96.8% 0.007 247.896)" },
        .{ .name = "color-slate-200", .value = "oklch(92.9% 0.013 255.508)" },
        .{ .name = "color-slate-300", .value = "oklch(86.9% 0.022 252.894)" },
        .{ .name = "color-slate-400", .value = "oklch(70.4% 0.04 256.788)" },
        .{ .name = "color-slate-500", .value = "oklch(55.4% 0.046 257.417)" },
        .{ .name = "color-slate-600", .value = "oklch(44.6% 0.043 257.281)" },
        .{ .name = "color-slate-700", .value = "oklch(37.2% 0.044 257.287)" },
        .{ .name = "color-slate-800", .value = "oklch(27.9% 0.041 260.031)" },
        .{ .name = "color-slate-900", .value = "oklch(20.8% 0.042 265.755)" },
        .{ .name = "color-slate-950", .value = "oklch(12.9% 0.042 264.695)" },
        .{ .name = "color-gray-50", .value = "oklch(98.5% 0.002 247.839)" },
        .{ .name = "color-gray-100", .value = "oklch(96.7% 0.003 264.542)" },
        .{ .name = "color-gray-200", .value = "oklch(92.8% 0.006 264.531)" },
        .{ .name = "color-gray-300", .value = "oklch(87.2% 0.01 258.338)" },
        .{ .name = "color-gray-400", .value = "oklch(70.7% 0.022 261.325)" },
        .{ .name = "color-gray-500", .value = "oklch(55.1% 0.027 264.364)" },
        .{ .name = "color-gray-600", .value = "oklch(44.6% 0.03 256.802)" },
        .{ .name = "color-gray-700", .value = "oklch(37.3% 0.034 259.733)" },
        .{ .name = "color-gray-800", .value = "oklch(27.8% 0.033 256.848)" },
        .{ .name = "color-gray-900", .value = "oklch(21% 0.034 264.665)" },
        .{ .name = "color-gray-950", .value = "oklch(13% 0.028 261.692)" },
        .{ .name = "color-zinc-50", .value = "oklch(98.5% 0 0)" },
        .{ .name = "color-zinc-100", .value = "oklch(96.7% 0.001 286.375)" },
        .{ .name = "color-zinc-200", .value = "oklch(92% 0.004 286.32)" },
        .{ .name = "color-zinc-300", .value = "oklch(87.1% 0.006 286.286)" },
        .{ .name = "color-zinc-400", .value = "oklch(70.5% 0.015 286.067)" },
        .{ .name = "color-zinc-500", .value = "oklch(55.2% 0.016 285.938)" },
        .{ .name = "color-zinc-600", .value = "oklch(44.2% 0.017 285.786)" },
        .{ .name = "color-zinc-700", .value = "oklch(37% 0.013 285.805)" },
        .{ .name = "color-zinc-800", .value = "oklch(27.4% 0.006 286.033)" },
        .{ .name = "color-zinc-900", .value = "oklch(21% 0.006 285.885)" },
        .{ .name = "color-zinc-950", .value = "oklch(14.1% 0.005 285.823)" },
        .{ .name = "color-neutral-50", .value = "oklch(98.5% 0 0)" },
        .{ .name = "color-neutral-100", .value = "oklch(97% 0 0)" },
        .{ .name = "color-neutral-200", .value = "oklch(92.2% 0 0)" },
        .{ .name = "color-neutral-300", .value = "oklch(87% 0 0)" },
        .{ .name = "color-neutral-400", .value = "oklch(70.8% 0 0)" },
        .{ .name = "color-neutral-500", .value = "oklch(55.6% 0 0)" },
        .{ .name = "color-neutral-600", .value = "oklch(43.9% 0 0)" },
        .{ .name = "color-neutral-700", .value = "oklch(37.1% 0 0)" },
        .{ .name = "color-neutral-800", .value = "oklch(26.9% 0 0)" },
        .{ .name = "color-neutral-900", .value = "oklch(20.5% 0 0)" },
        .{ .name = "color-neutral-950", .value = "oklch(14.5% 0 0)" },
        .{ .name = "color-stone-50", .value = "oklch(98.5% 0.001 106.423)" },
        .{ .name = "color-stone-100", .value = "oklch(97% 0.001 106.424)" },
        .{ .name = "color-stone-200", .value = "oklch(92.3% 0.003 48.717)" },
        .{ .name = "color-stone-300", .value = "oklch(86.9% 0.005 56.366)" },
        .{ .name = "color-stone-400", .value = "oklch(70.9% 0.01 56.259)" },
        .{ .name = "color-stone-500", .value = "oklch(55.3% 0.013 58.071)" },
        .{ .name = "color-stone-600", .value = "oklch(44.4% 0.011 73.639)" },
        .{ .name = "color-stone-700", .value = "oklch(37.4% 0.01 67.558)" },
        .{ .name = "color-stone-800", .value = "oklch(26.8% 0.007 34.298)" },
        .{ .name = "color-stone-900", .value = "oklch(21.6% 0.006 56.043)" },
        .{ .name = "color-stone-950", .value = "oklch(14.7% 0.004 49.25)" },
        .{ .name = "color-mauve-50", .value = "oklch(98.5% 0 0)" },
        .{ .name = "color-mauve-100", .value = "oklch(96% 0.003 325.6)" },
        .{ .name = "color-mauve-200", .value = "oklch(92.2% 0.005 325.62)" },
        .{ .name = "color-mauve-300", .value = "oklch(86.5% 0.012 325.68)" },
        .{ .name = "color-mauve-400", .value = "oklch(71.1% 0.019 323.02)" },
        .{ .name = "color-mauve-500", .value = "oklch(54.2% 0.034 322.5)" },
        .{ .name = "color-mauve-600", .value = "oklch(43.5% 0.029 321.78)" },
        .{ .name = "color-mauve-700", .value = "oklch(36.4% 0.029 323.89)" },
        .{ .name = "color-mauve-800", .value = "oklch(26.3% 0.024 320.12)" },
        .{ .name = "color-mauve-900", .value = "oklch(21.2% 0.019 322.12)" },
        .{ .name = "color-mauve-950", .value = "oklch(14.5% 0.008 326)" },
        .{ .name = "color-olive-50", .value = "oklch(98.8% 0.003 106.5)" },
        .{ .name = "color-olive-100", .value = "oklch(96.6% 0.005 106.5)" },
        .{ .name = "color-olive-200", .value = "oklch(93% 0.007 106.5)" },
        .{ .name = "color-olive-300", .value = "oklch(88% 0.011 106.6)" },
        .{ .name = "color-olive-400", .value = "oklch(73.7% 0.021 106.9)" },
        .{ .name = "color-olive-500", .value = "oklch(58% 0.031 107.3)" },
        .{ .name = "color-olive-600", .value = "oklch(46.6% 0.025 107.3)" },
        .{ .name = "color-olive-700", .value = "oklch(39.4% 0.023 107.4)" },
        .{ .name = "color-olive-800", .value = "oklch(28.6% 0.016 107.4)" },
        .{ .name = "color-olive-900", .value = "oklch(22.8% 0.013 107.4)" },
        .{ .name = "color-olive-950", .value = "oklch(15.3% 0.006 107.1)" },
        .{ .name = "color-mist-50", .value = "oklch(98.7% 0.002 197.1)" },
        .{ .name = "color-mist-100", .value = "oklch(96.3% 0.002 197.1)" },
        .{ .name = "color-mist-200", .value = "oklch(92.5% 0.005 214.3)" },
        .{ .name = "color-mist-300", .value = "oklch(87.2% 0.007 219.6)" },
        .{ .name = "color-mist-400", .value = "oklch(72.3% 0.014 214.4)" },
        .{ .name = "color-mist-500", .value = "oklch(56% 0.021 213.5)" },
        .{ .name = "color-mist-600", .value = "oklch(45% 0.017 213.2)" },
        .{ .name = "color-mist-700", .value = "oklch(37.8% 0.015 216)" },
        .{ .name = "color-mist-800", .value = "oklch(27.5% 0.011 216.9)" },
        .{ .name = "color-mist-900", .value = "oklch(21.8% 0.008 223.9)" },
        .{ .name = "color-mist-950", .value = "oklch(14.8% 0.004 228.8)" },
        .{ .name = "color-taupe-50", .value = "oklch(98.6% 0.002 67.8)" },
        .{ .name = "color-taupe-100", .value = "oklch(96% 0.002 17.2)" },
        .{ .name = "color-taupe-200", .value = "oklch(92.2% 0.005 34.3)" },
        .{ .name = "color-taupe-300", .value = "oklch(86.8% 0.007 39.5)" },
        .{ .name = "color-taupe-400", .value = "oklch(71.4% 0.014 41.2)" },
        .{ .name = "color-taupe-500", .value = "oklch(54.7% 0.021 43.1)" },
        .{ .name = "color-taupe-600", .value = "oklch(43.8% 0.017 39.3)" },
        .{ .name = "color-taupe-700", .value = "oklch(36.7% 0.016 35.7)" },
        .{ .name = "color-taupe-800", .value = "oklch(26.8% 0.011 36.5)" },
        .{ .name = "color-taupe-900", .value = "oklch(21.4% 0.009 43.1)" },
        .{ .name = "color-taupe-950", .value = "oklch(14.7% 0.004 49.3)" },
        .{ .name = "color-black", .value = "#000" },
        .{ .name = "color-white", .value = "#fff" },
        .{ .name = "spacing", .value = "0.25rem" },
        .{ .name = "breakpoint-sm", .value = "40rem" },
        .{ .name = "breakpoint-md", .value = "48rem" },
        .{ .name = "breakpoint-lg", .value = "64rem" },
        .{ .name = "breakpoint-xl", .value = "80rem" },
        .{ .name = "breakpoint-2xl", .value = "96rem" },
        .{ .name = "container-3xs", .value = "16rem" },
        .{ .name = "container-2xs", .value = "18rem" },
        .{ .name = "container-xs", .value = "20rem" },
        .{ .name = "container-sm", .value = "24rem" },
        .{ .name = "container-md", .value = "28rem" },
        .{ .name = "container-lg", .value = "32rem" },
        .{ .name = "container-xl", .value = "36rem" },
        .{ .name = "container-2xl", .value = "42rem" },
        .{ .name = "container-3xl", .value = "48rem" },
        .{ .name = "container-4xl", .value = "56rem" },
        .{ .name = "container-5xl", .value = "64rem" },
        .{ .name = "container-6xl", .value = "72rem" },
        .{ .name = "container-7xl", .value = "80rem" },
        // Container helpers used by `max-w-screen-{key}` utilities — match
        // the breakpoint scale so consumers can clamp containers to the
        // viewport-step they design at.
        .{ .name = "container-screen-sm", .value = "40rem" },
        .{ .name = "container-screen-md", .value = "48rem" },
        .{ .name = "container-screen-lg", .value = "64rem" },
        .{ .name = "container-screen-xl", .value = "80rem" },
        .{ .name = "container-screen-2xl", .value = "96rem" },
        .{ .name = "text-xs", .value = "0.75rem" },
        .{ .name = "text-xs--line-height", .value = "calc(1 / 0.75)" },
        .{ .name = "text-sm", .value = "0.875rem" },
        .{ .name = "text-sm--line-height", .value = "calc(1.25 / 0.875)" },
        .{ .name = "text-base", .value = "1rem" },
        .{ .name = "text-base--line-height", .value = "calc(1.5 / 1)" },
        .{ .name = "text-lg", .value = "1.125rem" },
        .{ .name = "text-lg--line-height", .value = "calc(1.75 / 1.125)" },
        .{ .name = "text-xl", .value = "1.25rem" },
        .{ .name = "text-xl--line-height", .value = "calc(1.75 / 1.25)" },
        .{ .name = "text-2xl", .value = "1.5rem" },
        .{ .name = "text-2xl--line-height", .value = "calc(2 / 1.5)" },
        .{ .name = "text-3xl", .value = "1.875rem" },
        .{ .name = "text-3xl--line-height", .value = "calc(2.25 / 1.875)" },
        .{ .name = "text-4xl", .value = "2.25rem" },
        .{ .name = "text-4xl--line-height", .value = "calc(2.5 / 2.25)" },
        .{ .name = "text-5xl", .value = "3rem" },
        .{ .name = "text-5xl--line-height", .value = "1" },
        .{ .name = "text-6xl", .value = "3.75rem" },
        .{ .name = "text-6xl--line-height", .value = "1" },
        .{ .name = "text-7xl", .value = "4.5rem" },
        .{ .name = "text-7xl--line-height", .value = "1" },
        .{ .name = "text-8xl", .value = "6rem" },
        .{ .name = "text-8xl--line-height", .value = "1" },
        .{ .name = "text-9xl", .value = "8rem" },
        .{ .name = "text-9xl--line-height", .value = "1" },
        .{ .name = "font-weight-thin", .value = "100" },
        .{ .name = "font-weight-extralight", .value = "200" },
        .{ .name = "font-weight-light", .value = "300" },
        .{ .name = "font-weight-normal", .value = "400" },
        .{ .name = "font-weight-medium", .value = "500" },
        .{ .name = "font-weight-semibold", .value = "600" },
        .{ .name = "font-weight-bold", .value = "700" },
        .{ .name = "font-weight-extrabold", .value = "800" },
        .{ .name = "font-weight-black", .value = "900" },
        .{ .name = "tracking-tighter", .value = "-0.05em" },
        .{ .name = "tracking-tight", .value = "-0.025em" },
        .{ .name = "tracking-normal", .value = "0em" },
        .{ .name = "tracking-wide", .value = "0.025em" },
        .{ .name = "tracking-wider", .value = "0.05em" },
        .{ .name = "tracking-widest", .value = "0.1em" },
        .{ .name = "leading-tight", .value = "1.25" },
        .{ .name = "leading-snug", .value = "1.375" },
        .{ .name = "leading-normal", .value = "1.5" },
        .{ .name = "leading-relaxed", .value = "1.625" },
        .{ .name = "leading-loose", .value = "2" },
        .{ .name = "radius-xs", .value = "0.125rem" },
        .{ .name = "radius-sm", .value = "0.25rem" },
        .{ .name = "radius-md", .value = "0.375rem" },
        .{ .name = "radius-lg", .value = "0.5rem" },
        .{ .name = "radius-xl", .value = "0.75rem" },
        .{ .name = "radius-2xl", .value = "1rem" },
        .{ .name = "radius-3xl", .value = "1.5rem" },
        .{ .name = "radius-4xl", .value = "2rem" },
        .{ .name = "shadow-2xs", .value = "0 1px rgb(0 0 0 / 0.05)" },
        .{ .name = "shadow-xs", .value = "0 1px 2px 0 rgb(0 0 0 / 0.05)" },
        .{ .name = "shadow-sm", .value = "0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1)" },
        .{ .name = "shadow-md", .value = "0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1)" },
        .{ .name = "shadow-lg", .value = "0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1)" },
        .{ .name = "shadow-xl", .value = "0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1)" },
        .{ .name = "shadow-2xl", .value = "0 25px 50px -12px rgb(0 0 0 / 0.25)" },
        .{ .name = "inset-shadow-2xs", .value = "inset 0 1px rgb(0 0 0 / 0.05)" },
        .{ .name = "inset-shadow-xs", .value = "inset 0 1px 1px rgb(0 0 0 / 0.05)" },
        .{ .name = "inset-shadow-sm", .value = "inset 0 2px 4px rgb(0 0 0 / 0.05)" },
        .{ .name = "drop-shadow-xs", .value = "0 1px 1px rgb(0 0 0 / 0.05)" },
        .{ .name = "drop-shadow-sm", .value = "0 1px 2px rgb(0 0 0 / 0.15)" },
        .{ .name = "drop-shadow-md", .value = "0 3px 3px rgb(0 0 0 / 0.12)" },
        .{ .name = "drop-shadow-lg", .value = "0 4px 4px rgb(0 0 0 / 0.15)" },
        .{ .name = "drop-shadow-xl", .value = "0 9px 7px rgb(0 0 0 / 0.1)" },
        .{ .name = "drop-shadow-2xl", .value = "0 25px 25px rgb(0 0 0 / 0.15)" },
        .{ .name = "text-shadow-2xs", .value = "0px 1px 0px rgb(0 0 0 / 0.15)" },
        .{ .name = "text-shadow-xs", .value = "0px 1px 1px rgb(0 0 0 / 0.2)" },
        .{ .name = "text-shadow-sm", .value = "0px 1px 0px rgb(0 0 0 / 0.075), 0px 1px 1px rgb(0 0 0 / 0.075), 0px 2px 2px rgb(0 0 0 / 0.075)" },
        .{ .name = "text-shadow-md", .value = "0px 1px 1px rgb(0 0 0 / 0.1), 0px 1px 2px rgb(0 0 0 / 0.1), 0px 2px 4px rgb(0 0 0 / 0.1)" },
        .{ .name = "text-shadow-lg", .value = "0px 1px 2px rgb(0 0 0 / 0.1), 0px 3px 2px rgb(0 0 0 / 0.1), 0px 4px 8px rgb(0 0 0 / 0.1)" },
        .{ .name = "ease-in", .value = "cubic-bezier(0.4, 0, 1, 1)" },
        .{ .name = "ease-out", .value = "cubic-bezier(0, 0, 0.2, 1)" },
        .{ .name = "ease-in-out", .value = "cubic-bezier(0.4, 0, 0.2, 1)" },
        .{ .name = "animate-spin", .value = "spin 1s linear infinite" },
        .{ .name = "animate-ping", .value = "ping 1s cubic-bezier(0, 0, 0.2, 1) infinite" },
        .{ .name = "animate-pulse", .value = "pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite" },
        .{ .name = "animate-bounce", .value = "bounce 1s infinite" },
        .{ .name = "blur-xs", .value = "4px" },
        .{ .name = "blur-sm", .value = "8px" },
        .{ .name = "blur-md", .value = "12px" },
        .{ .name = "blur-lg", .value = "16px" },
        .{ .name = "blur-xl", .value = "24px" },
        .{ .name = "blur-2xl", .value = "40px" },
        .{ .name = "blur-3xl", .value = "64px" },
        .{ .name = "perspective-dramatic", .value = "100px" },
        .{ .name = "perspective-near", .value = "300px" },
        .{ .name = "perspective-normal", .value = "500px" },
        .{ .name = "perspective-midrange", .value = "800px" },
        .{ .name = "perspective-distant", .value = "1200px" },
        .{ .name = "aspect-video", .value = "16 / 9" },
        .{ .name = "default-transition-duration", .value = "150ms" },
        .{ .name = "default-transition-timing-function", .value = "cubic-bezier(0.4, 0, 0.2, 1)" },
        .{ .name = "default-font-family", .value = "--theme(--font-sans, initial)" },
        .{ .name = "default-font-feature-settings", .value = "--theme(--font-sans--font-feature-settings, initial)" },
        .{ .name = "default-font-variation-settings", .value = "--theme(--font-sans--font-variation-settings, initial)" },
        .{ .name = "default-mono-font-family", .value = "--theme(--font-mono, initial)" },
        .{ .name = "default-mono-font-feature-settings", .value = "--theme(--font-mono--font-feature-settings, initial)" },
        .{ .name = "default-mono-font-variation-settings", .value = "--theme(--font-mono--font-variation-settings, initial)" },
    },
};

pub const api = struct {
    pub const Theme = amalgam.theme_mod.Theme;
    pub const Token = amalgam.theme_mod.Token;
    pub const extendTheme = amalgam.theme_mod.extendTheme;
    pub const extendThemeRuntime = amalgam.theme_mod.extendThemeRuntime;
    pub const lookup = amalgam.theme_mod.lookup;
    pub const emitCssVariables = amalgam.theme_mod.emitCssVariables;
    pub const compile = amalgam.compile_mod.compile;
    pub const CompileError = amalgam.compile_mod.CompileError;
    pub const unsupportedFeatureMessage = amalgam.compile_mod.unsupportedFeatureMessage;
    pub const sortClasses = amalgam.sort_mod.sortClasses;
    pub const SortError = amalgam.sort_mod.SortError;
    pub const default_theme: Theme = amalgam.embedded_default_theme;
};

pub const cli = struct {
/// Publr JIT CSS Compiler CLI.
///
/// Reads a class manifest produced by the ZSX/.publr transpilers and emits
/// utility CSS to stdout via `jit.compile()`.
///
/// Theme model: the JIT is theme-agnostic. By default it uses the embedded
/// `default-theme.zon` token set. Consumers pass their own
/// theme at the JIT's runtime — which is the consumer's BUILD time — via
/// `--theme=<path>`. The consumer's theme.zon may be a partial override; the
/// JIT merges it onto the default before resolving.
///
/// Class collection is the transpilers' job — never a file scanner
/// here. See `memory/project_jit_input_scope.md`.
///
/// Preflight CSS (resets, `--tw-*` defaults, keyframes) lives in `preflight.css`
/// and is prepended by build pipelines, not by this CLI.
///
/// Usage:
///   jit [--theme=<theme.zon>] [--prepend=<preflight.css>] [--minify|--no-minify] <css_classes.txt>
///     Compile classes to CSS. Output is minified by default; pass `--no-minify`
///     for the readable indented form (typical for dev/debug builds).
///   jit theme-from-css <input.css>
///     Convert CSS @theme blocks to theme.zon.

const std = @import("std");
const theme_from_css = amalgam.theme_from_css_mod;
const jit = amalgam.api;
const default_theme: jit.Theme = amalgam.embedded_default_theme;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "theme-from-css")) {
        try runThemeFromCss(allocator, args);
        return;
    }

    // Parse flags. `compile-classes` is accepted as an alias for the default
    // mode (used by the visual-regression harness).
    var arg_index: usize = 1;
    if (std.mem.eql(u8, args[1], "compile-classes")) arg_index = 2;

    var prepend_path: ?[]const u8 = null;
    // CLI default: minify. Build pipelines that want readable output (e.g.
    // CMS Debug builds) pass `--no-minify` explicitly. Library callers of
    // `jit.compile()` get the unminified form by default — see Options in
    // compile.zig.
    var minify: bool = true;
    // `--theme=<path>` may be passed multiple times; each layer is merged on
    // top of the previous in argv order, so the rightmost flag wins. This
    // lets consumers stack a design-system token alias file underneath their
    // brand theme without having to flatten them externally.
    var theme_paths: std.array_list.Managed([]const u8) = .init(allocator);
    defer theme_paths.deinit();
    // Trailing positional args are class manifests. The build pipeline often
    // needs multiple — one for the consumer's own ZSX/.publr templates, plus
    // a vendored copy of `publr_ui.classes.txt` so design-system component
    // classes (baked into the amalgamated publr_ui.zig and invisible to the
    // consumer's transpiler) get rules generated in the JIT output. All
    // listed manifests are concatenated and de-duplicated before compile.
    var manifest_paths: std.array_list.Managed([]const u8) = .init(allocator);
    defer manifest_paths.deinit();
    while (arg_index < args.len) : (arg_index += 1) {
        const a = args[arg_index];
        if (std.mem.eql(u8, a, "--prepend")) {
            arg_index += 1;
            if (arg_index >= args.len) {
                try printUsage();
                std.process.exit(1);
            }
            prepend_path = args[arg_index];
        } else if (std.mem.startsWith(u8, a, "--prepend=")) {
            prepend_path = a["--prepend=".len..];
        } else if (std.mem.eql(u8, a, "--theme")) {
            arg_index += 1;
            if (arg_index >= args.len) {
                try printUsage();
                std.process.exit(1);
            }
            try theme_paths.append(args[arg_index]);
        } else if (std.mem.startsWith(u8, a, "--theme=")) {
            try theme_paths.append(a["--theme=".len..]);
        } else if (std.mem.eql(u8, a, "--minify")) {
            minify = true;
        } else if (std.mem.eql(u8, a, "--no-minify")) {
            minify = false;
        } else {
            try manifest_paths.append(a);
        }
    }
    if (manifest_paths.items.len == 0) {
        try printUsage();
        std.process.exit(1);
    }

    try runCompile(allocator, manifest_paths.items, prepend_path, theme_paths.items, minify);
}

fn printUsage() !void {
    var stderr_buf: [768]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    try stderr.interface.writeAll("Usage:\n");
    try stderr.interface.writeAll("  jit [--theme=<theme.zon>] [--prepend=<file.css>] [--minify|--no-minify] <css_classes.txt>\n");
    try stderr.interface.writeAll("    Compile classes to CSS. Manifest from ZSX/.publr transpiler.\n");
    try stderr.interface.writeAll("    --theme:     override the embedded default theme. The override\n");
    try stderr.interface.writeAll("                 is merged onto the default; partial themes are fine.\n");
    try stderr.interface.writeAll("    --prepend:   write the contents of <file.css> before the JIT output\n");
    try stderr.interface.writeAll("                 (typical use: prepend preflight.css).\n");
    try stderr.interface.writeAll("    --minify:    compact whitespace (default).\n");
    try stderr.interface.writeAll("    --no-minify: emit indented, readable CSS (dev/debug builds).\n");
    try stderr.interface.writeAll("  jit theme-from-css <input.css>\n");
    try stderr.interface.writeAll("    Convert CSS @theme blocks to theme.zon.\n");
    try stderr.interface.flush();
}

/// Read a class manifest, run through `jit.compile()`, write CSS to stdout.
/// If `theme_path` is provided, the file is parsed as ZON and merged onto the
/// embedded default theme. `extra_count > 0` triggers a one-release
/// transitional warning — the legacy CLI took `[scan_paths...]` after the
/// manifest, but file scanning is out of scope per the input-scope rule.
fn runCompile(
    allocator: std.mem.Allocator,
    manifest_paths: []const []const u8,
    prepend_path: ?[]const u8,
    theme_paths: []const []const u8,
    minify: bool,
) !void {
    // Read every manifest, tokenize whitespace-separated, dedupe across all of
    // them. Buffers stay alive until the end of the function because `classes`
    // holds borrowed slices into them.
    var manifest_buffers: std.array_list.Managed([]u8) = .init(allocator);
    defer {
        for (manifest_buffers.items) |b| allocator.free(b);
        manifest_buffers.deinit();
    }

    var classes: std.ArrayListUnmanaged([]const u8) = .{};
    defer classes.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (manifest_paths) |p| {
        const buf = try std.fs.cwd().readFileAlloc(allocator, p, 16 * 1024 * 1024);
        try manifest_buffers.append(buf);
        var it = std.mem.tokenizeAny(u8, buf, " \t\n\r");
        while (it.next()) |c| {
            if (c.len == 0) continue;
            const gop = try seen.getOrPut(c);
            if (gop.found_existing) continue;
            try classes.append(allocator, c);
        }
    }

    // Resolve the theme. Default is the embedded `default-theme.zon`. Each
    // `--theme=<path>` flag layers on top in argv order via
    // extendThemeRuntime, so the rightmost flag wins. Typical usage:
    //   --theme=ds-tokens.zon   (semantic alias palette — design system)
    //   --theme=brand.zon       (per-consumer brand overrides)
    var loaded_zons: std.array_list.Managed([:0]u8) = .init(allocator);
    defer {
        for (loaded_zons.items) |b| allocator.free(b);
        loaded_zons.deinit();
    }
    var loaded_themes: std.array_list.Managed(jit.Theme) = .init(allocator);
    defer {
        for (loaded_themes.items) |ut| std.zon.parse.free(allocator, ut);
        loaded_themes.deinit();
    }

    for (theme_paths) |p| {
        const bytes = try std.fs.cwd().readFileAllocOptions(
            allocator,
            p,
            4 * 1024 * 1024,
            null,
            std.mem.Alignment.@"1",
            0, // sentinel-terminated; std.zon.parse needs [:0]const u8
        );
        try loaded_zons.append(bytes);
        const t = try std.zon.parse.fromSlice(jit.Theme, allocator, bytes, null, .{});
        try loaded_themes.append(t);
    }

    // Chain merges: start from the embedded default, then layer each theme.
    // Each intermediate result is freed once it's been folded into the next.
    var merged_theme: jit.Theme = default_theme;
    var owns_merged = false;
    defer if (owns_merged) allocator.free(merged_theme.tokens);

    for (loaded_themes.items) |ut| {
        const next = try jit.extendThemeRuntime(allocator, merged_theme, ut);
        if (owns_merged) allocator.free(merged_theme.tokens);
        merged_theme = next;
        owns_merged = true;
    }

    const css = try jit.compile(allocator, merged_theme, classes.items, .{ .minify = minify });
    defer allocator.free(css);

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    if (prepend_path) |p| {
        const prepend = try std.fs.cwd().readFileAlloc(allocator, p, 4 * 1024 * 1024);
        defer allocator.free(prepend);
        try stdout.interface.writeAll(prepend);
        try stdout.interface.writeByte('\n');
    }
    try stdout.interface.writeAll(css);
    try stdout.interface.flush();
}

/// `jit theme-from-css <input.css>` — read CSS, emit theme.zon to stdout.
/// Warnings (unsupported `@theme` modifiers, skipped nested at-rules) go to stderr.
fn runThemeFromCss(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    if (args.len < 3) {
        var stderr_buf: [256]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&stderr_buf);
        try stderr.interface.writeAll("Usage: jit theme-from-css <input.css>\n");
        try stderr.interface.flush();
        std.process.exit(1);
    }

    const css = try std.fs.cwd().readFileAlloc(allocator, args[2], 4 * 1024 * 1024);
    defer allocator.free(css);

    var warn_buffer: [4096]u8 = undefined;
    var warn_iface = std.io.Writer.fixed(&warn_buffer);

    const zon = try theme_from_css.convert(allocator, css, .{ .warn = &warn_iface });
    defer allocator.free(zon);

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    try stdout.interface.writeAll(zon);
    try stdout.interface.flush();

    const warns = warn_iface.buffered();
    if (warns.len > 0) {
        var stderr_buf: [256]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&stderr_buf);
        try stderr.interface.writeAll(warns);
        try stderr.interface.flush();
    }
}
};

pub fn main() !void {
    return cli.main();
}
