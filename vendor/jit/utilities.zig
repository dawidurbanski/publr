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
///   - The full Tailwind serializer (task-07).

const std = @import("std");
const candidate = @import("candidate.zig");
const theme = @import("theme.zig");

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
    // Upstream composes via `--tw-numeric-*` vars; we emit each utility
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

    // ── Font weight (full scale per Tailwind v4) ────────────────────────────
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

    // ── Ring width: bare `ring` defaults to 3px (Tailwind v4) ──────────────
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
    // ── Cursor (full set per Tailwind v4) ───────────────────────────────────
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
    // Default (just `divide-x`) is 1px per Tailwind v4. Same dispatch handles
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
    //    handler below (or, for non-Tailwind names, the legacy resolver).
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
    // Upstream Tailwind uses `oklab` (not `srgb`) for arbitrary-property
    // color modifiers — see `index.test.ts` fixtures around line 990.
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
        // Compute `calc(var(--spacing) * N)`. Accepts integers and Tailwind's
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
    // modifier are integer-shaped, emit `calc(<n> / <d> * 100%)`. Tailwind
    // v4 uses fractions only on size/position-style utilities (the
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
    //   4. Container namespace lookup for width-shaped properties — Tailwind
    //      v4 stores `max-w-7xl`, `w-prose`, etc. as `--container-{key}` (not
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
/// emits 1px per Tailwind v4.
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
            "color-mix(in srgb, {s} {s}, transparent)",
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
/// (`max-w-7xl`, `w-prose`, etc.) Tailwind v4 stores under `--container-*`.
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
    const v = value orelse return null;
    if (v != .named) return null;
    if (!isInteger(v.named.value)) return null;

    const decls = try allocator.alloc(Declaration, 1);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "z-index",
        .value = if (negative)
            try std.fmt.allocPrint(allocator, "-{s}", .{v.named.value})
        else
            try allocator.dupe(u8, v.named.value),
    };
    return .{ .declarations = decls };
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
        .arbitrary => |a| try allocator.dupe(u8, a.value),
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
    // whole property. Tailwind itself uses the same fallbacks.
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
            // Tailwind v4 keywords: center, top, top-right, right, bottom-right,
            // bottom, bottom-left, left, top-left.
            const allowed = [_][]const u8{
                "center",     "top",      "top-right", "right",   "bottom-right",
                "bottom",     "bottom-left", "left",   "top-left",
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
/// layered Tailwind v4 box-shadow composition so ring + inset + shadow can
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
/// arbitrary forms (`blur-[20px]`) pass through verbatim. The Tailwind v4
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
/// so a single class sets both font-size and line-height (matching upstream
/// Tailwind v4 behaviour).
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
    if (v != .named) return null;
    const size = v.named.value;

    const size_token = try std.fmt.allocPrint(allocator, "text-{s}", .{size});
    defer allocator.free(size_token);
    if (theme.lookup(t, size_token) == null) return null;

    // Resolve line-height. Modifier wins over the theme's default-LH for the
    // size (Tailwind v4 semantics). If neither is present, emit only font-size.
    const line_height: ?[]u8 = blk: {
        if (modifier) |m| {
            switch (m) {
                .named => |n| {
                    // Try `--leading-{n}` token first (Tailwind v4 named-leading scale).
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
        // No modifier — fall back to theme's default line-height for this size.
        const lh_token = try std.fmt.allocPrint(allocator, "text-{s}--line-height", .{size});
        defer allocator.free(lh_token);
        if (theme.lookup(t, lh_token) != null) {
            break :blk try std.fmt.allocPrint(allocator, "var(--text-{s}--line-height)", .{size});
        }
        break :blk null;
    };

    const decl_count: usize = if (line_height != null) 2 else 1;
    const decls = try allocator.alloc(Declaration, decl_count);
    errdefer allocator.free(decls);
    decls[0] = .{
        .property = "font-size",
        .value = try std.fmt.allocPrint(allocator, "var(--text-{s})", .{size}),
    };
    if (line_height) |lh| {
        decls[1] = .{ .property = "line-height", .value = lh };
    }
    return .{ .declarations = decls };
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
/// `color-mix(in srgb, <base> <pct>, transparent)`. Named `/50` becomes `50%`;
/// arbitrary `/[27%]` or `/(--my-opacity)` is passed through verbatim.
fn modifierAsOpacity(
    allocator: std.mem.Allocator,
    m: candidate.Modifier,
) ResolveError![]u8 {
    return switch (m) {
        .named => |n| try std.fmt.allocPrint(allocator, "{s}%", .{n}),
        .arbitrary => |a| try allocator.dupe(u8, a),
    };
}

/// Generic single-property color resolver. Output:
///   no modifier:   { property: <base> }
///   with modifier: { property: color-mix(in srgb, <base> <pct>, transparent) }
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
        break :blk try std.fmt.allocPrint(allocator, "color-mix(in srgb, {s} {s}, transparent)", .{ base, opacity });
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
/// Negative angles via `-bg-linear-45` aren't standard Tailwind syntax;
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
/// keywords like `bg-radial-circle` aren't standard Tailwind v4). The bare
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
        break :blk try std.fmt.allocPrint(allocator, "color-mix(in srgb, {s} {s}, transparent)", .{ base, opacity });
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
/// `theme_namespace` is `duration` for both — Tailwind v4 doesn't separately
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
            "color-mix(in srgb, {s} {s}, transparent)",
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
/// border-radius properties it sets. Tailwind v4 covers physical sides
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
/// single-decimal fractionals (`0.5`, `1.5`, `2.5`, `3.5` — Tailwind's
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

test "static: text-balance" {
    const r = (try parseAndResolve(tst.allocator, "text-balance")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("text-wrap", r.declarations[0].property);
    try tst.expectEqualStrings("balance", r.declarations[0].value);
}

test "static: text-clip / text-ellipsis" {
    const r1 = (try parseAndResolve(tst.allocator, "text-clip")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("text-overflow", r1.declarations[0].property);
    try tst.expectEqualStrings("clip", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "text-ellipsis")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("ellipsis", r2.declarations[0].value);
}

test "static: overflow-scroll + axis variants" {
    const r1 = (try parseAndResolve(tst.allocator, "overflow-scroll")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("overflow", r1.declarations[0].property);
    try tst.expectEqualStrings("scroll", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "overflow-x-hidden")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("overflow-x", r2.declarations[0].property);
    try tst.expectEqualStrings("hidden", r2.declarations[0].value);
    const r3 = (try parseAndResolve(tst.allocator, "overflow-y-auto")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("overflow-y", r3.declarations[0].property);
    try tst.expectEqualStrings("auto", r3.declarations[0].value);
}

test "static: truncate emits 3 declarations" {
    const r = (try parseAndResolve(tst.allocator, "truncate")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 3), r.declarations.len);
    try tst.expectEqualStrings("overflow", r.declarations[0].property);
    try tst.expectEqualStrings("hidden", r.declarations[0].value);
    try tst.expectEqualStrings("text-overflow", r.declarations[1].property);
    try tst.expectEqualStrings("ellipsis", r.declarations[1].value);
    try tst.expectEqualStrings("white-space", r.declarations[2].property);
    try tst.expectEqualStrings("nowrap", r.declarations[2].value);
}

test "static: peer / group resolve to empty decls (marker classes)" {
    const r1 = (try parseAndResolve(tst.allocator, "peer")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqual(@as(usize, 0), r1.declarations.len);
    const r2 = (try parseAndResolve(tst.allocator, "group")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqual(@as(usize, 0), r2.declarations.len);
}

test "important flag propagates from candidate (trailing form)" {
    // `underline!` — important after the root.
    const r = (try parseAndResolve(tst.allocator, "underline!")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expect(r.important);
}

test "important flag propagates from candidate (leading form)" {
    // `!underline` — legacy leading-bang form.
    const r = (try parseAndResolve(tst.allocator, "!underline")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expect(r.important);
}

test "important flag propagates on functional utilities" {
    const r = (try parseAndResolve(tst.allocator, "size-12!")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expect(r.important);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
}

test "important flag propagates on arbitrary properties" {
    const r = (try parseAndResolve(tst.allocator, "[color:red]!")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expect(r.important);
    try tst.expectEqualStrings("color", r.declarations[0].property);
    try tst.expectEqualStrings("red", r.declarations[0].value);
}

test "important flag absent when not marked" {
    const r = (try parseAndResolve(tst.allocator, "underline")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expect(!r.important);
}

// ── Border radius ────────────────────────────────────────────────────────────

test "rounded: bare → var(--radius)" {
    const r = (try parseAndResolve(tst.allocator, "rounded")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("border-radius", r.declarations[0].property);
    try tst.expectEqualStrings("var(--radius)", r.declarations[0].value);
}

test "rounded: -none → 0; -full → calc(infinity * 1px)" {
    const r1 = (try parseAndResolve(tst.allocator, "rounded-none")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("0", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "rounded-full")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("calc(infinity * 1px)", r2.declarations[0].value);
}

test "rounded: theme key (md, lg, 2xl)" {
    const r = (try parseAndResolve(tst.allocator, "rounded-md")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("border-radius", r.declarations[0].property);
    try tst.expectEqualStrings("var(--radius-md)", r.declarations[0].value);
}

test "rounded: arbitrary value" {
    const r = (try parseAndResolve(tst.allocator, "rounded-[7px]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("7px", r.declarations[0].value);
}

test "rounded: side variant (rounded-t-md sets two longhands)" {
    const r = (try parseAndResolve(tst.allocator, "rounded-t-md")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("border-top-left-radius", r.declarations[0].property);
    try tst.expectEqualStrings("var(--radius-md)", r.declarations[0].value);
    try tst.expectEqualStrings("border-top-right-radius", r.declarations[1].property);
    try tst.expectEqualStrings("var(--radius-md)", r.declarations[1].value);
}

test "rounded: corner variant (rounded-tl-lg sets one longhand)" {
    const r = (try parseAndResolve(tst.allocator, "rounded-tl-lg")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("border-top-left-radius", r.declarations[0].property);
    try tst.expectEqualStrings("var(--radius-lg)", r.declarations[0].value);
}

test "rounded: logical side (rounded-s-md → start-start + end-start)" {
    const r = (try parseAndResolve(tst.allocator, "rounded-s-md")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("border-start-start-radius", r.declarations[0].property);
    try tst.expectEqualStrings("border-end-start-radius", r.declarations[1].property);
}

test "rounded: side variant + none" {
    const r = (try parseAndResolve(tst.allocator, "rounded-b-none")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("0", r.declarations[0].value);
    try tst.expectEqualStrings("0", r.declarations[1].value);
}

test "rounded: unknown key returns null" {
    try tst.expect((try parseAndResolve(tst.allocator, "rounded-totally-invalid")) == null);
}

// ── Modifier on arbitrary properties ────────────────────────────────────────

test "arbitrary property + opacity modifier: [color:red]/50 → color-mix" {
    const r = (try parseAndResolve(tst.allocator, "[color:red]/50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("color", r.declarations[0].property);
    try tst.expectEqualStrings(
        "color-mix(in oklab, red 50%, transparent)",
        r.declarations[0].value,
    );
}

test "arbitrary property + arbitrary opacity: [color:red]/[var(--my-op)]" {
    const r = (try parseAndResolve(tst.allocator, "[color:red]/[var(--my-op)]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings(
        "color-mix(in oklab, red var(--my-op), transparent)",
        r.declarations[0].value,
    );
}

test "arbitrary color-property with var() value + opacity modifier" {
    const r = (try parseAndResolve(tst.allocator, "[color:var(--my-color)]/50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings(
        "color-mix(in oklab, var(--my-color) 50%, transparent)",
        r.declarations[0].value,
    );
}

test "arbitrary non-color property + modifier: modifier ignored, value verbatim" {
    // `[margin:10px]/50` — `/50` has no meaning on margin; emit `margin: 10px`.
    const r = (try parseAndResolve(tst.allocator, "[margin:10px]/50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("margin", r.declarations[0].property);
    try tst.expectEqualStrings("10px", r.declarations[0].value);
}

test "arbitrary property without modifier still works (regression check)" {
    const r = (try parseAndResolve(tst.allocator, "[--my-prop:42]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--my-prop", r.declarations[0].property);
    try tst.expectEqualStrings("42", r.declarations[0].value);
}

// ── Modifier on functional color: text-current/50 ───────────────────────────

test "color: text-current/50 → color-mix(currentColor)" {
    // The functional-color path through resolveColorProperty already handles
    // the `current` keyword and applies the modifier; verify it works.
    const r = (try parseAndResolve(tst.allocator, "text-current/50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("color", r.declarations[0].property);
    try tst.expectEqualStrings(
        "color-mix(in srgb, currentColor 50%, transparent)",
        r.declarations[0].value,
    );
}

test "color: text-transparent (no modifier emits literal)" {
    const r = (try parseAndResolve(tst.allocator, "text-transparent")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("transparent", r.declarations[0].value);
}

// ── Text size with line-height modifier ─────────────────────────────────────

test "text-{size}: emits font-size + theme default line-height" {
    const r = (try parseAndResolve(tst.allocator, "text-2xl")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("font-size", r.declarations[0].property);
    try tst.expectEqualStrings("var(--text-2xl)", r.declarations[0].value);
    try tst.expectEqualStrings("line-height", r.declarations[1].property);
    try tst.expectEqualStrings("var(--text-2xl--line-height)", r.declarations[1].value);
}

test "text-{size}/N: modifier overrides line-height with spacing calc" {
    // text-2xl/8 → font-size from --text-2xl, line-height = calc(var(--spacing) * 8)
    const r = (try parseAndResolve(tst.allocator, "text-2xl/8")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("var(--text-2xl)", r.declarations[0].value);
    try tst.expectEqualStrings("line-height", r.declarations[1].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 8)", r.declarations[1].value);
}

test "text-{size}/[arb]: arbitrary modifier emits verbatim" {
    const r = (try parseAndResolve(tst.allocator, "text-2xl/[1.5]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("1.5", r.declarations[1].value);
}

test "text-{size}/N with fractional spacing modifier" {
    const r = (try parseAndResolve(tst.allocator, "text-base/0.5")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("calc(var(--spacing) * 0.5)", r.declarations[1].value);
}

test "text-{size} without theme line-height: only font-size emitted" {
    // text-base in our test_theme has no --text-base--line-height token.
    const r = (try parseAndResolve(tst.allocator, "text-base")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("font-size", r.declarations[0].property);
}

// ── Gradient direction extras ───────────────────────────────────────────────

test "bg-linear-{angle}: numeric → <N>deg" {
    const r = (try parseAndResolve(tst.allocator, "bg-linear-45")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-gradient-position", r.declarations[0].property);
    try tst.expectEqualStrings("45deg", r.declarations[0].value);
    try tst.expectEqualStrings("background-image", r.declarations[1].property);
    try tst.expectEqualStrings("linear-gradient(var(--tw-gradient-stops, var(--tw-gradient-position), var(--tw-gradient-from, transparent), var(--tw-gradient-to, transparent)))", r.declarations[1].value);
}

test "bg-linear-[arbitrary]: passes value verbatim" {
    const r = (try parseAndResolve(tst.allocator, "bg-linear-[in_oklch_45deg]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("in oklch 45deg", r.declarations[0].value);
}

test "bg-conic: bare emits conic-gradient base" {
    const r = (try parseAndResolve(tst.allocator, "bg-conic")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-gradient-position", r.declarations[0].property);
    try tst.expect(std.mem.indexOf(u8, r.declarations[1].value, "conic-gradient") != null);
}

test "bg-conic-{angle}: emits 'from <N>deg in oklab'" {
    const r = (try parseAndResolve(tst.allocator, "bg-conic-90")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("from 90deg in oklab", r.declarations[0].value);
    try tst.expect(std.mem.indexOf(u8, r.declarations[1].value, "conic-gradient") != null);
}

test "bg-conic-[arbitrary]: passes verbatim" {
    const r = (try parseAndResolve(tst.allocator, "bg-conic-[from_180deg_at_25%_25%]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("from 180deg at 25% 25%", r.declarations[0].value);
}

test "bg-radial: bare emits radial-gradient base" {
    const r = (try parseAndResolve(tst.allocator, "bg-radial")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expect(std.mem.indexOf(u8, r.declarations[1].value, "radial-gradient") != null);
}

test "bg-radial-[arbitrary]: passes verbatim" {
    const r = (try parseAndResolve(tst.allocator, "bg-radial-[ellipse_at_top]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("ellipse at top", r.declarations[0].value);
    try tst.expect(std.mem.indexOf(u8, r.declarations[1].value, "radial-gradient") != null);
}

test "bg-radial-{named} (non-arbitrary) returns null" {
    // Tailwind v4 doesn't define `bg-radial-circle` etc.; only arbitrary.
    try tst.expect((try parseAndResolve(tst.allocator, "bg-radial-circle")) == null);
}

// ── Grid row utilities + arbitrary col-span ─────────────────────────────────

test "row-span-N → grid-row" {
    const r = (try parseAndResolve(tst.allocator, "row-span-3")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("grid-row", r.declarations[0].property);
    try tst.expectEqualStrings("span 3 / span 3", r.declarations[0].value);
}

test "col-span-[arbitrary]" {
    const r = (try parseAndResolve(tst.allocator, "col-span-[5]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("grid-column", r.declarations[0].property);
    try tst.expectEqualStrings("span 5 / span 5", r.declarations[0].value);
}

test "grid-rows-N → grid-template-rows repeat" {
    const r = (try parseAndResolve(tst.allocator, "grid-rows-4")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("grid-template-rows", r.declarations[0].property);
    try tst.expectEqualStrings("repeat(4, minmax(0, 1fr))", r.declarations[0].value);
}

test "grid-rows-subgrid → grid-template-rows: subgrid" {
    const r = (try parseAndResolve(tst.allocator, "grid-rows-subgrid")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("subgrid", r.declarations[0].value);
}

test "grid-cols-none → grid-template-columns: none" {
    const r = (try parseAndResolve(tst.allocator, "grid-cols-none")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("none", r.declarations[0].value);
}

test "row-auto / row-span-full statics" {
    const r1 = (try parseAndResolve(tst.allocator, "row-auto")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("grid-row", r1.declarations[0].property);
    try tst.expectEqualStrings("auto", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "row-span-full")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("1 / -1", r2.declarations[0].value);
}

// ── Spacing dispatch: padding / margin / gap / width / height ──────────────

test "padding: p-N → padding (single)" {
    const r = (try parseAndResolve(tst.allocator, "p-4")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("padding", r.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 4)", r.declarations[0].value);
}

test "padding: px-N expands to padding-left + padding-right" {
    const r = (try parseAndResolve(tst.allocator, "px-3")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("padding-left", r.declarations[0].property);
    try tst.expectEqualStrings("padding-right", r.declarations[1].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 3)", r.declarations[0].value);
    try tst.expectEqualStrings("calc(var(--spacing) * 3)", r.declarations[1].value);
}

test "padding: pt-N → padding-top only" {
    const r = (try parseAndResolve(tst.allocator, "pt-2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("padding-top", r.declarations[0].property);
}

test "padding: logical sides ps-/pe-" {
    const r1 = (try parseAndResolve(tst.allocator, "ps-2")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("padding-inline-start", r1.declarations[0].property);
    const r2 = (try parseAndResolve(tst.allocator, "pe-1.5")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("padding-inline-end", r2.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 1.5)", r2.declarations[0].value);
}

test "margin: m-N + negative -m-N + auto" {
    const r1 = (try parseAndResolve(tst.allocator, "m-4")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("margin", r1.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 4)", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "-m-4")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("calc(calc(var(--spacing) * 4) * -1)", r2.declarations[0].value);
    const r3 = (try parseAndResolve(tst.allocator, "m-auto")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("auto", r3.declarations[0].value);
}

test "margin: mx-auto sets both sides to auto" {
    const r = (try parseAndResolve(tst.allocator, "mx-auto")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("margin-left", r.declarations[0].property);
    try tst.expectEqualStrings("auto", r.declarations[0].value);
    try tst.expectEqualStrings("margin-right", r.declarations[1].property);
    try tst.expectEqualStrings("auto", r.declarations[1].value);
}

test "gap: gap-N + gap-x-N + gap-y-N" {
    const r1 = (try parseAndResolve(tst.allocator, "gap-4")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("gap", r1.declarations[0].property);
    const r2 = (try parseAndResolve(tst.allocator, "gap-x-2")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("column-gap", r2.declarations[0].property);
    const r3 = (try parseAndResolve(tst.allocator, "gap-y-0.5")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("row-gap", r3.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 0.5)", r3.declarations[0].value);
}

test "width: w-N, w-full (static), w-auto, w-px, w-screen (static)" {
    const r1 = (try parseAndResolve(tst.allocator, "w-32")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("width", r1.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 32)", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "w-auto")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("auto", r2.declarations[0].value);
    const r3 = (try parseAndResolve(tst.allocator, "w-px")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("1px", r3.declarations[0].value);
    const r4 = (try parseAndResolve(tst.allocator, "w-screen")).?;
    defer freeResolvedUtility(tst.allocator, r4);
    try tst.expectEqualStrings("100vw", r4.declarations[0].value);
}

test "spacing: arbitrary values [10px] / [var(--w)]" {
    const r1 = (try parseAndResolve(tst.allocator, "p-[10px]")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("10px", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "w-[var(--my-w)]")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("var(--my-w)", r2.declarations[0].value);
    // Negative arbitrary on margin.
    const r3 = (try parseAndResolve(tst.allocator, "-mt-[10px]")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("calc(10px * -1)", r3.declarations[0].value);
}

test "spacing: top/right/bottom/left as standalone roots" {
    const r1 = (try parseAndResolve(tst.allocator, "top-4")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("top", r1.declarations[0].property);
    const r2 = (try parseAndResolve(tst.allocator, "-bottom-2")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("bottom", r2.declarations[0].property);
    try tst.expectEqualStrings("calc(calc(var(--spacing) * 2) * -1)", r2.declarations[0].value);
}

test "spacing: width keywords (min/max/fit)" {
    const r1 = (try parseAndResolve(tst.allocator, "w-min")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("min-content", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "w-max")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("max-content", r2.declarations[0].value);
    const r3 = (try parseAndResolve(tst.allocator, "w-fit")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("fit-content", r3.declarations[0].value);
}

// ── Fractions (modifier-as-denominator) ─────────────────────────────────────

test "fraction: w-1/2 → calc(1/2 * 100%)" {
    const r = (try parseAndResolve(tst.allocator, "w-1/2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("width", r.declarations[0].property);
    try tst.expectEqualStrings("calc(1/2 * 100%)", r.declarations[0].value);
}

test "fraction: w-2/3 → calc(2/3 * 100%)" {
    const r = (try parseAndResolve(tst.allocator, "w-2/3")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("calc(2/3 * 100%)", r.declarations[0].value);
}

test "fraction: h-1/4 → calc(1/4 * 100%) on height" {
    const r = (try parseAndResolve(tst.allocator, "h-1/4")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("height", r.declarations[0].property);
    try tst.expectEqualStrings("calc(1/4 * 100%)", r.declarations[0].value);
}

test "fraction: inset-1/2 → calc(1/2 * 100%) on inset" {
    const r = (try parseAndResolve(tst.allocator, "inset-1/2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("inset", r.declarations[0].property);
    try tst.expectEqualStrings("calc(1/2 * 100%)", r.declarations[0].value);
}

test "fraction: -mt-1/2 negative fraction" {
    const r = (try parseAndResolve(tst.allocator, "-mt-1/2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("margin-top", r.declarations[0].property);
    try tst.expectEqualStrings("calc(calc(1/2 * 100%) * -1)", r.declarations[0].value);
}

test "fraction: w-3/4 (multi-digit numerator works)" {
    const r = (try parseAndResolve(tst.allocator, "w-11/12")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("calc(11/12 * 100%)", r.declarations[0].value);
}

// ── space-x-N / space-y-N — selector-modifying utility ──────────────────────

test "space-x-N emits margin-right with selector_suffix" {
    const r = (try parseAndResolve(tst.allocator, "space-x-4")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("margin-right", r.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 4)", r.declarations[0].value);
    try tst.expect(r.selector_suffix != null);
    try tst.expectEqualStrings(" > :not(:last-child)", r.selector_suffix.?);
}

test "space-y-N emits margin-bottom with selector_suffix" {
    const r = (try parseAndResolve(tst.allocator, "space-y-2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("margin-bottom", r.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 2)", r.declarations[0].value);
    try tst.expect(r.selector_suffix != null);
}

test "space-x-N: arbitrary value works" {
    const r = (try parseAndResolve(tst.allocator, "space-x-[10px]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("10px", r.declarations[0].value);
    try tst.expect(r.selector_suffix != null);
}

test "space-x-reverse: marker class (no decls)" {
    const r = (try parseAndResolve(tst.allocator, "space-x-reverse")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 0), r.declarations.len);
}

// ── Border width ────────────────────────────────────────────────────────────

test "border: bare → border-width: 1px + style" {
    const r = (try parseAndResolve(tst.allocator, "border")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("border-style", r.declarations[0].property);
    try tst.expectEqualStrings("border-width", r.declarations[1].property);
    try tst.expectEqualStrings("1px", r.declarations[1].value);
}

test "border-N: integer value → border-width: Npx" {
    const r = (try parseAndResolve(tst.allocator, "border-2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("border-width", r.declarations[0].property);
    try tst.expectEqualStrings("2px", r.declarations[0].value);
}

test "border-{side}-N: emits side-specific width" {
    const r1 = (try parseAndResolve(tst.allocator, "border-t-2")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("border-top-width", r1.declarations[0].property);
    try tst.expectEqualStrings("2px", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "border-l-4")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("border-left-width", r2.declarations[0].property);
}

test "border-x-N / border-y-N: axis pair" {
    const r1 = (try parseAndResolve(tst.allocator, "border-x-2")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqual(@as(usize, 2), r1.declarations.len);
    try tst.expectEqualStrings("border-left-width", r1.declarations[0].property);
    try tst.expectEqualStrings("border-right-width", r1.declarations[1].property);
    const r2 = (try parseAndResolve(tst.allocator, "border-y-1")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("border-top-width", r2.declarations[0].property);
    try tst.expectEqualStrings("border-bottom-width", r2.declarations[1].property);
}

test "border-{side}: bare side static" {
    const r = (try parseAndResolve(tst.allocator, "border-t")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("border-top-width", r.declarations[1].property);
    try tst.expectEqualStrings("1px", r.declarations[1].value);
}

test "border-[arbitrary]: arbitrary width" {
    const r = (try parseAndResolve(tst.allocator, "border-[3.5px]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("border-width", r.declarations[0].property);
    try tst.expectEqualStrings("3.5px", r.declarations[0].value);
}

test "border-{color}: color path still works (regression)" {
    // Color values shouldn't be caught by border-width — they fall through
    // to the color path which emits border-color.
    const r = (try parseAndResolve(tst.allocator, "border-red-500")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("border-color", r.declarations[0].property);
    try tst.expectEqualStrings("var(--color-red-500)", r.declarations[0].value);
}

// ── Transition / duration / delay / ease ────────────────────────────────────

test "static: transition (bare) emits property + duration + timing" {
    const r = (try parseAndResolve(tst.allocator, "transition")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 3), r.declarations.len);
    try tst.expectEqualStrings("transition-property", r.declarations[0].property);
    try tst.expect(std.mem.indexOf(u8, r.declarations[0].value, "color") != null);
    try tst.expectEqualStrings("transition-duration", r.declarations[2].property);
}

test "static: transition-{all,colors,opacity,shadow,transform,none}" {
    const r1 = (try parseAndResolve(tst.allocator, "transition-all")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("all", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "transition-opacity")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("opacity", r2.declarations[0].value);
    const r3 = (try parseAndResolve(tst.allocator, "transition-none")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqual(@as(usize, 1), r3.declarations.len);
    try tst.expectEqualStrings("none", r3.declarations[0].value);
}

test "duration-N → transition-duration: Nms" {
    const r = (try parseAndResolve(tst.allocator, "duration-300")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("transition-duration", r.declarations[0].property);
    try tst.expectEqualStrings("300ms", r.declarations[0].value);
}

test "delay-N → transition-delay: Nms" {
    const r = (try parseAndResolve(tst.allocator, "delay-150")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("transition-delay", r.declarations[0].property);
    try tst.expectEqualStrings("150ms", r.declarations[0].value);
}

test "duration-[arb] / delay-[arb] arbitrary values" {
    const r1 = (try parseAndResolve(tst.allocator, "duration-[2s]")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("2s", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "delay-[var(--my-delay)]")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("var(--my-delay)", r2.declarations[0].value);
}

test "static: ease-{linear,in,out,in-out,initial}" {
    const r1 = (try parseAndResolve(tst.allocator, "ease-linear")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("transition-timing-function", r1.declarations[0].property);
    try tst.expectEqualStrings("linear", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "ease-in-out")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expect(std.mem.indexOf(u8, r2.declarations[0].value, "cubic-bezier") != null);
}

test "ease-[arbitrary]" {
    const r = (try parseAndResolve(tst.allocator, "ease-[cubic-bezier(0.5,0,0.5,1)]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("cubic-bezier(0.5,0,0.5,1)", r.declarations[0].value);
}

// ── Shadow / outline base statics + cursor / select / object-fit ────────────

test "shadow-{color}: sets --tw-shadow-color" {
    const r = (try parseAndResolve(tst.allocator, "shadow-red-500")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-shadow-color", r.declarations[0].property);
    try tst.expectEqualStrings("var(--color-red-500)", r.declarations[0].value);
}

test "shadow-{color}/{opacity}: applies color-mix" {
    const r = (try parseAndResolve(tst.allocator, "shadow-red-500/50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings(
        "color-mix(in srgb, var(--color-red-500) 50%, transparent)",
        r.declarations[0].value,
    );
}

test "static: shadow (bare) + shadow-none" {
    const r1 = (try parseAndResolve(tst.allocator, "shadow")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqual(@as(usize, 2), r1.declarations.len);
    try tst.expectEqualStrings("--tw-shadow", r1.declarations[0].property);
    try tst.expectEqualStrings("box-shadow", r1.declarations[1].property);
    const r2 = (try parseAndResolve(tst.allocator, "shadow-none")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("0 0 #0000", r2.declarations[0].value);
}

test "static: outline (bare) + outline-none + outline-{style}" {
    const r1 = (try parseAndResolve(tst.allocator, "outline")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqual(@as(usize, 2), r1.declarations.len);
    try tst.expectEqualStrings("outline-style", r1.declarations[0].property);
    try tst.expectEqualStrings("outline-width", r1.declarations[1].property);
    const r2 = (try parseAndResolve(tst.allocator, "outline-none")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("none", r2.declarations[0].value);
    const r3 = (try parseAndResolve(tst.allocator, "outline-dashed")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("dashed", r3.declarations[0].value);
}

test "static: cursor variants (full set)" {
    for ([_][]const u8{
        "cursor-auto",       "cursor-default",   "cursor-pointer", "cursor-wait",
        "cursor-help",       "cursor-not-allowed", "cursor-grab",  "cursor-grabbing",
        "cursor-zoom-in",    "cursor-zoom-out",  "cursor-text",
    }) |c| {
        const r = (try parseAndResolve(tst.allocator, c)).?;
        defer freeResolvedUtility(tst.allocator, r);
        try tst.expectEqualStrings("cursor", r.declarations[0].property);
    }
}

test "static: select-{none,text,all,auto}" {
    for ([_][]const u8{ "select-none", "select-text", "select-all", "select-auto" }) |c| {
        const r = (try parseAndResolve(tst.allocator, c)).?;
        defer freeResolvedUtility(tst.allocator, r);
        try tst.expectEqualStrings("user-select", r.declarations[0].property);
    }
}

test "static: object-fit + object-position" {
    const r1 = (try parseAndResolve(tst.allocator, "object-cover")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("object-fit", r1.declarations[0].property);
    try tst.expectEqualStrings("cover", r1.declarations[0].value);
    const r2 = (try parseAndResolve(tst.allocator, "object-top-right")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("object-position", r2.declarations[0].property);
    try tst.expectEqualStrings("top right", r2.declarations[0].value);
}

test "static: pointer-events + resize" {
    const r1 = (try parseAndResolve(tst.allocator, "pointer-events-none")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("pointer-events", r1.declarations[0].property);
    const r2 = (try parseAndResolve(tst.allocator, "resize-y")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("vertical", r2.declarations[0].value);
}

test "border style statics (solid/dashed/dotted/double/none)" {
    const r1 = (try parseAndResolve(tst.allocator, "border-solid")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("solid", r1.declarations[1].value);
    const r2 = (try parseAndResolve(tst.allocator, "border-dashed")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("dashed", r2.declarations[1].value);
    const r3 = (try parseAndResolve(tst.allocator, "border-none")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqualStrings("none", r3.declarations[1].value);
}

test "static: antialiased emits two declarations" {
    const r = (try parseAndResolve(tst.allocator, "antialiased")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("-webkit-font-smoothing", r.declarations[0].property);
    try tst.expectEqualStrings("-moz-osx-font-smoothing", r.declarations[1].property);
}

test "functional: size-N emits width + height" {
    const r = (try parseAndResolve(tst.allocator, "size-12")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("width", r.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 12)", r.declarations[0].value);
    try tst.expectEqualStrings("height", r.declarations[1].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 12)", r.declarations[1].value);
}

test "functional: col-span-N" {
    const r = (try parseAndResolve(tst.allocator, "col-span-2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("grid-column", r.declarations[0].property);
    try tst.expectEqualStrings("span 2 / span 2", r.declarations[0].value);
}

test "functional: grid-cols-subgrid" {
    const r = (try parseAndResolve(tst.allocator, "grid-cols-subgrid")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("grid-template-columns", r.declarations[0].property);
    try tst.expectEqualStrings("subgrid", r.declarations[0].value);
}

test "functional: grid-cols-N" {
    const r = (try parseAndResolve(tst.allocator, "grid-cols-3")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("repeat(3, minmax(0, 1fr))", r.declarations[0].value);
}

test "functional: inset-N" {
    const r = (try parseAndResolve(tst.allocator, "inset-2")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("inset", r.declarations[0].property);
    try tst.expectEqualStrings("calc(var(--spacing) * 2)", r.declarations[0].value);
}

test "functional: fractional spacing (Tailwind half-step scale)" {
    // inset-0.5 → calc(var(--spacing) * 0.5)
    const r1 = (try parseAndResolve(tst.allocator, "inset-0.5")).?;
    defer freeResolvedUtility(tst.allocator, r1);
    try tst.expectEqualStrings("calc(var(--spacing) * 0.5)", r1.declarations[0].value);
    // inset-2.5
    const r2 = (try parseAndResolve(tst.allocator, "inset-2.5")).?;
    defer freeResolvedUtility(tst.allocator, r2);
    try tst.expectEqualStrings("calc(var(--spacing) * 2.5)", r2.declarations[0].value);
    // size-1.5 → both width + height with the fractional value
    const r3 = (try parseAndResolve(tst.allocator, "size-1.5")).?;
    defer freeResolvedUtility(tst.allocator, r3);
    try tst.expectEqual(@as(usize, 2), r3.declarations.len);
    try tst.expectEqualStrings("calc(var(--spacing) * 1.5)", r3.declarations[0].value);
    try tst.expectEqualStrings("calc(var(--spacing) * 1.5)", r3.declarations[1].value);
}

test "functional: malformed fractional spacing rejected" {
    // Leading dot, trailing dot, multi-dot, non-numeric all return null.
    try tst.expect((try parseAndResolve(tst.allocator, "inset-.5")) == null);
    try tst.expect((try parseAndResolve(tst.allocator, "inset-5.")) == null);
    try tst.expect((try parseAndResolve(tst.allocator, "inset-1.5.5")) == null);
}

test "isSpacingNumber covers integers and half-steps, rejects edges" {
    try tst.expect(isSpacingNumber("0"));
    try tst.expect(isSpacingNumber("12"));
    try tst.expect(isSpacingNumber("0.5"));
    try tst.expect(isSpacingNumber("1.5"));
    try tst.expect(isSpacingNumber("2.5"));
    try tst.expect(isSpacingNumber("100.25"));
    try tst.expect(!isSpacingNumber(""));
    try tst.expect(!isSpacingNumber("."));
    try tst.expect(!isSpacingNumber(".5"));
    try tst.expect(!isSpacingNumber("5."));
    try tst.expect(!isSpacingNumber("1.2.3"));
    try tst.expect(!isSpacingNumber("abc"));
    try tst.expect(!isSpacingNumber("1a"));
}

test "functional: -z-N (negative)" {
    const r = (try parseAndResolve(tst.allocator, "-z-10")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("z-index", r.declarations[0].property);
    try tst.expectEqualStrings("-10", r.declarations[0].value);
}

test "functional: z-N (positive)" {
    const r = (try parseAndResolve(tst.allocator, "z-50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("50", r.declarations[0].value);
}

test "functional: font-sans (theme lookup)" {
    const r = (try parseAndResolve(tst.allocator, "font-sans")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("font-family", r.declarations[0].property);
    try tst.expectEqualStrings("var(--font-sans)", r.declarations[0].value);
}

test "functional: font-{unknown} returns null" {
    const r = try parseAndResolve(tst.allocator, "font-unknown");
    try tst.expect(r == null);
}

test "functional: bg-linear-to-b" {
    const r = (try parseAndResolve(tst.allocator, "bg-linear-to-b")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 2), r.declarations.len);
    try tst.expectEqualStrings("--tw-gradient-position", r.declarations[0].property);
    try tst.expectEqualStrings("to bottom", r.declarations[0].value);
    try tst.expectEqualStrings("background-image", r.declarations[1].property);
    try tst.expectEqualStrings("linear-gradient(var(--tw-gradient-stops, var(--tw-gradient-position), var(--tw-gradient-from, transparent), var(--tw-gradient-to, transparent)))", r.declarations[1].value);
}

test "functional: from-{color} (theme lookup)" {
    const r = (try parseAndResolve(tst.allocator, "from-white")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-gradient-from", r.declarations[0].property);
    try tst.expectEqualStrings("var(--color-white)", r.declarations[0].value);
}

test "functional: to-{percent}" {
    const r = (try parseAndResolve(tst.allocator, "to-50%")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-gradient-to-position", r.declarations[0].property);
    try tst.expectEqualStrings("50%", r.declarations[0].value);
}

test "functional: from-[arbitrary]" {
    const r = (try parseAndResolve(tst.allocator, "from-[-25%]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-gradient-from", r.declarations[0].property);
    try tst.expectEqualStrings("-25%", r.declarations[0].value);
}

test "arbitrary property" {
    const r = (try parseAndResolve(tst.allocator, "[--my-prop:42]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--my-prop", r.declarations[0].property);
    try tst.expectEqualStrings("42", r.declarations[0].value);
}

test "unknown utility returns null" {
    const r = try parseAndResolve(tst.allocator, "totally-made-up");
    try tst.expect(r == null);
}

// ── Color utilities ────────────────────────────────────────────────────────

test "color: bg-{theme-color}" {
    const r = (try parseAndResolve(tst.allocator, "bg-red-500")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqual(@as(usize, 1), r.declarations.len);
    try tst.expectEqualStrings("background-color", r.declarations[0].property);
    try tst.expectEqualStrings("var(--color-red-500)", r.declarations[0].value);
}

test "color: bg-{color}/{opacity} → color-mix" {
    const r = (try parseAndResolve(tst.allocator, "bg-red-500/50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("background-color", r.declarations[0].property);
    try tst.expectEqualStrings(
        "color-mix(in srgb, var(--color-red-500) 50%, transparent)",
        r.declarations[0].value,
    );
}

test "color: text-{theme-color}" {
    const r = (try parseAndResolve(tst.allocator, "text-gray-800")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("color", r.declarations[0].property);
    try tst.expectEqualStrings("var(--color-gray-800)", r.declarations[0].value);
}

test "color: border-{color}/{opacity}" {
    const r = (try parseAndResolve(tst.allocator, "border-white/5")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("border-color", r.declarations[0].property);
    try tst.expectEqualStrings(
        "color-mix(in srgb, var(--color-white) 5%, transparent)",
        r.declarations[0].value,
    );
}

test "color: ring → --tw-ring-color" {
    const r = (try parseAndResolve(tst.allocator, "ring-red-500")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-ring-color", r.declarations[0].property);
    try tst.expectEqualStrings("var(--color-red-500)", r.declarations[0].value);
}

test "color: special keywords (transparent, current, inherit)" {
    {
        const r = (try parseAndResolve(tst.allocator, "bg-transparent")).?;
        defer freeResolvedUtility(tst.allocator, r);
        try tst.expectEqualStrings("transparent", r.declarations[0].value);
    }
    {
        const r = (try parseAndResolve(tst.allocator, "bg-current")).?;
        defer freeResolvedUtility(tst.allocator, r);
        try tst.expectEqualStrings("currentColor", r.declarations[0].value);
    }
    {
        const r = (try parseAndResolve(tst.allocator, "bg-inherit")).?;
        defer freeResolvedUtility(tst.allocator, r);
        try tst.expectEqualStrings("inherit", r.declarations[0].value);
    }
}

test "color: arbitrary [#abc]" {
    const r = (try parseAndResolve(tst.allocator, "bg-[#abc]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("background-color", r.declarations[0].property);
    try tst.expectEqualStrings("#abc", r.declarations[0].value);
}

test "color: parens-arbitrary (--my-var)" {
    const r = (try parseAndResolve(tst.allocator, "bg-(--my-var)")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("background-color", r.declarations[0].property);
    try tst.expectEqualStrings("var(--my-var)", r.declarations[0].value);
}

test "color: arbitrary opacity modifier" {
    const r = (try parseAndResolve(tst.allocator, "bg-red-500/[27%]")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings(
        "color-mix(in srgb, var(--color-red-500) 27%, transparent)",
        r.declarations[0].value,
    );
}

test "color: bg-{unknown} returns null (falls through)" {
    const r = try parseAndResolve(tst.allocator, "bg-totallyunknown");
    try tst.expect(r == null);
}

test "color: decoration / outline / accent / caret / fill / stroke" {
    const Cases = struct { input: []const u8, property: []const u8 };
    const cases = [_]Cases{
        .{ .input = "decoration-red-500", .property = "text-decoration-color" },
        .{ .input = "outline-red-500", .property = "outline-color" },
        .{ .input = "accent-red-500", .property = "accent-color" },
        .{ .input = "caret-red-500", .property = "caret-color" },
        .{ .input = "fill-red-500", .property = "fill" },
        .{ .input = "stroke-red-500", .property = "stroke" },
    };
    inline for (cases) |c| {
        const r = (try parseAndResolve(tst.allocator, c.input)).?;
        defer freeResolvedUtility(tst.allocator, r);
        try tst.expectEqualStrings(c.property, r.declarations[0].property);
        try tst.expectEqualStrings("var(--color-red-500)", r.declarations[0].value);
    }
}

test "gradient: from-{color}/{opacity}" {
    const r = (try parseAndResolve(tst.allocator, "from-red-500/50")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-gradient-from", r.declarations[0].property);
    try tst.expectEqualStrings(
        "color-mix(in srgb, var(--color-red-500) 50%, transparent)",
        r.declarations[0].value,
    );
}

test "gradient: to-transparent special keyword" {
    const r = (try parseAndResolve(tst.allocator, "to-transparent")).?;
    defer freeResolvedUtility(tst.allocator, r);
    try tst.expectEqualStrings("--tw-gradient-to", r.declarations[0].property);
    try tst.expectEqualStrings("transparent", r.declarations[0].value);
}
