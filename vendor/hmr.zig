// Runtime support for hot-swappable component-call attrs.
//
// The transpiler lifts every literal attribute at a component invocation
// (`label="Primary"`, `hierarchy=.primary`, `size=.md`, `disabled={true}`)
// into a per-file `A` table: `pub var A: []const []const hmr.Attr`. The
// generated call site then becomes:
//
//     var __p: ButtonProps = .{};
//     hmr.applyAttrs(ButtonProps, &__p, A[3]);
//     try Button(writer, __p);
//
// On every save of a file that owns an A table, the HMR comparator parses
// the fresh source, identifies which literal-attr values changed (without
// any structural shape difference), allocates a new A slice, and calls
// `setA(new)`. No `zig build`, no exec — instant prop swap.
//
// Expression attrs (`label={someVar}`, `class={x ++ y}`) and `bool_present`
// shorthand (`<X disabled />`) are NOT lifted: their values reference
// local scope or are intentionally untyped. Those still trigger the
// slow path when they change.
const std = @import("std");
const mem = std.mem;

pub const Attr = struct {
    name: []const u8,
    /// Raw source text of the attr value as it appeared in the .zsx file.
    /// String attrs: the content between the quotes (`Primary`). Enum-tag
    /// attrs: includes the leading dot (`.primary`). Bool / int: the
    /// literal source (`true`, `42`).
    value: []const u8,
};

/// Baked descriptor for one runtime A-table slot, emitted by the
/// transpiler alongside `initial_A`. Lets the dev loop rebuild the A
/// table from freshly-parsed manifest nodes with the EXACT slot layout
/// the emitter used — without re-deriving the build-time lift-eligibility
/// rules (which depend on `has_props` / no-default-field scans the runtime
/// can't see). Without this, a runtime guess at "which components got
/// lifted" diverges from the baked layout and `applyAttrs` reads the wrong
/// slot. See `buildFreshA` in cms/src/hmr_loop.zig.
pub const LiftSite = struct {
    /// 0-based index of this component among ALL `.component` nodes in the
    /// file's manifest, in flat (pre-order) source order. The dev loop
    /// collects fresh component nodes in the same order and indexes with
    /// this to find the component whose attr values feed this slot.
    comp_index: u32,
    /// The attr names lifted into this slot (defaulted + literal/const-expr
    /// fields). The dev loop pulls each name's current value from the fresh
    /// component to rebuild `A[slot]`.
    attr_names: []const []const u8,
};

/// Apply a slice of runtime attrs onto a defaults-initialised props struct.
/// For each field in T, if `attrs` contains an entry with that name, parse
/// it according to the field's type. Fields without a corresponding entry
/// keep their default. Unknown attrs in `attrs` are ignored.
///
/// NEVER panics. A malformed attr value (e.g. user is mid-typing
/// `hierarchy=.prima` before completing `.primary`) logs a warning and
/// the field keeps its default. The dev server's error-overlay code
/// surfaces these visually to the user; the render keeps working with
/// "wrong-but-safe" values until the next valid save.
pub fn applyAttrs(comptime T: type, dst: *T, attrs: []const Attr) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        // Skip fields whose type we can't parse from a string (e.g. a
        // `[]const Item` slice or a nested struct). Such fields are only
        // ever passed as expressions at the call site, so they never land
        // in the A table anyway — and instantiating tryParseAttr for them
        // would be a comptime error. This keeps lift universal: a component
        // can have arbitrary Props fields; only the string/enum/bool/number
        // ones are swappable.
        if (comptime !isParseableFieldType(f.type)) continue;
        for (attrs) |a| {
            if (mem.eql(u8, a.name, f.name)) {
                if (tryParseAttr(f.type, a.value, f.name)) |v| {
                    @field(dst.*, f.name) = v;
                } // else: keep struct default, warning already logged
                break;
            }
        }
    }
}

/// Collect A-table attrs whose name is NOT a declared field of `T` — i.e.
/// forwarded directives/attributes the component doesn't model (data-p-*,
/// role, …). Returns them as a ` name="value"` run ready to splice into a
/// tag, or "" when there are none. page_allocator-backed (lives for the
/// render frame, like the transpiler's concatRt).
pub fn forwardedAttrs(comptime T: type, attrs: []const Attr) []const u8 {
    const alloc = std.heap.page_allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    attr_loop: for (attrs) |a| {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (mem.eql(u8, a.name, f.name)) continue :attr_loop;
        }
        out.appendSlice(alloc, " ") catch return "";
        out.appendSlice(alloc, a.name) catch return "";
        out.appendSlice(alloc, "=\"") catch return "";
        out.appendSlice(alloc, a.value) catch return "";
        out.appendSlice(alloc, "\"") catch return "";
    }
    return out.items;
}

/// Render a lifted component, splicing `fwd` (forwarded attrs from
/// `forwardedAttrs`) onto its ROOT element. This is how directives a component
/// doesn't declare survive HMR's concrete-props lift: `applyAttrs` can't place
/// them on the props, so we inject them straight onto the rendered root — the
/// same idea as the `data-component` root splice. Fast path: no forwarded
/// attrs → render directly (no buffering).
pub fn renderForwarding(comptime render_fn: anytype, writer: anytype, props: anytype, fwd: []const u8) !void {
    if (fwd.len == 0) return render_fn(writer, props);
    const alloc = std.heap.page_allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try render_fn(buf.writer(alloc), props);
    try spliceAttrsIntoRoot(writer, buf.items, fwd);
}

fn isTagStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Insert `attrs` into the first opening tag of `html`, right before its
/// closing `>` (or `/>`). Writes `html` unchanged if no opening tag is found.
fn spliceAttrsIntoRoot(writer: anytype, html: []const u8, attrs: []const u8) !void {
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] == '<' and i + 1 < html.len and isTagStart(html[i + 1])) break;
    }
    if (i >= html.len) return writer.writeAll(html);
    var j = i + 1;
    var q: u8 = 0;
    while (j < html.len) : (j += 1) {
        const c = html[j];
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == '>') break;
    }
    if (j >= html.len) return writer.writeAll(html);
    const at = if (j > 0 and html[j - 1] == '/') j - 1 else j;
    try writer.writeAll(html[0..at]);
    try writer.writeAll(attrs);
    try writer.writeAll(html[at..]);
}

/// True iff `applyAttrs` can parse a value of type `T` from an attr string.
/// Mirrors `tryParseAttr`'s supported set; used to skip unparseable fields
/// at comptime instead of hitting `tryParseAttr`'s `@compileError`.
fn isParseableFieldType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        .@"enum", .bool, .int, .float => true,
        .optional => |o| isParseableFieldType(o.child),
        else => false,
    };
}

/// Build a concrete `T` from a call-site struct literal `raw`, taking each
/// of T's fields from `raw` when present and otherwise from the field's
/// default. Extra fields in `raw` (attrs the component doesn't declare —
/// `onclick` on a Button, `children` on a childless Badge) are IGNORED, so
/// the lifted call site stays as lenient as the component's own
/// `zsx.withDefaults`. Always returns `T` (so `&__p` type-matches
/// `applyAttrs(T, *T, …)`), unlike `withDefaults` which may return the raw
/// type. A field missing from `raw` with no default is a comptime error —
/// the same required-field check the non-lift call site has.
pub fn propsFrom(comptime T: type, raw: anytype) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (@hasField(@TypeOf(raw), f.name)) {
            @field(result, f.name) = @field(raw, f.name);
        } else if (comptime f.defaultValue()) |dv| {
            @field(result, f.name) = dv;
        }
        // else: no value in `raw` and no field default — leave undefined.
        // The companion applyAttrs fills lifted fields from the A table
        // (every literal/const-expr attr at the call site lands there). A
        // genuinely-missing required field would still be caught by the
        // production (non-lift) build's `withDefaults`, which hard-requires
        // it — so dev stays lenient without losing the prod safety check.
    }
    return result;
}

/// Soft-fail variant of parseAttr — returns `null` on bad input instead
/// of panicking. Callers that NEED the value (and accept the crash on
/// bad input) can still wrap with `orelse @panic(...)`, but applyAttrs
/// goes the keep-the-server-alive route.
pub fn tryParseAttr(comptime T: type, raw: []const u8, comptime field_name: []const u8) ?T {
    return switch (@typeInfo(T)) {
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk raw;
            @compileError("hmr.parseAttr: unsupported pointer type for field '" ++ field_name ++ "'");
        },
        .@"enum" => blk: {
            const name = if (raw.len > 0 and raw[0] == '.') raw[1..] else raw;
            const stripped = stripZigEscapeQuotes(name);
            const v = std.meta.stringToEnum(T, stripped) orelse {
                std.debug.print(
                    "[hmr] bad enum tag for {s}: '{s}' is not a member of {s} — keeping default\n",
                    .{ field_name, raw, @typeName(T) },
                );
                break :blk null;
            };
            break :blk v;
        },
        .bool => blk: {
            if (mem.eql(u8, raw, "true")) break :blk true;
            if (mem.eql(u8, raw, "false")) break :blk false;
            std.debug.print("[hmr] bad bool for {s}: '{s}' — keeping default\n", .{ field_name, raw });
            break :blk null;
        },
        .int => std.fmt.parseInt(T, raw, 10) catch {
            std.debug.print("[hmr] bad int for {s}: '{s}' — keeping default\n", .{ field_name, raw });
            return null;
        },
        .float => std.fmt.parseFloat(T, raw) catch {
            std.debug.print("[hmr] bad float for {s}: '{s}' — keeping default\n", .{ field_name, raw });
            return null;
        },
        .optional => |o| if (raw.len == 0) null else tryParseAttr(o.child, raw, field_name),
        else => @compileError("hmr.parseAttr: unsupported type for field '" ++ field_name ++ "'"),
    };
}

/// Hard-fail parser kept for tests / callers that want explicit crash.
/// Production code (the lift call sites) use applyAttrs / tryParseAttr.
pub fn parseAttr(comptime T: type, raw: []const u8, comptime field_name: []const u8) T {
    return tryParseAttr(T, raw, field_name) orelse @panic("hmr: bad attr — see log above");
}

fn stripZigEscapeQuotes(s: []const u8) []const u8 {
    if (s.len >= 4 and s[0] == '@' and s[1] == '"' and s[s.len - 1] == '"') return s[2 .. s.len - 1];
    return s;
}
