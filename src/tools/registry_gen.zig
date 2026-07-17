//! View registry codegen for the HMR fast path.
//!
//! Walks `.zsx` source files in one or more input directories, runs each
//! through `zsx.parseAll` to get its `Manifest` list, and emits a single
//! `registry.zig` listing one `Entry` per `pub fn` in the source tree.
//!
//! Each entry packs:
//!   * `name`              — `"<dir-rel-path>:<FnName>"` (matches the key
//!                           the HMR `captureProps` call writes to disk).
//!   * `source_path`       — the `.zsx` file path (build-root relative).
//!   * `manifest`          — pointer to the baked `<Fn>_manifest` constant
//!                           in the generated `.zig` view module.
//!   * `setL`              — pointer to the file-scoped `setL` so the swap
//!                           loop can replace the literal table without
//!                           recompiling.
//!   * `render_from_zon`   — type-erased per-fn trampoline that ZON-parses
//!                           a serialized prop blob, then calls the view
//!                           with concrete props (or returns an error for
//!                           the slow-path-only views below).
//!
//! ## Writer type choice
//!
//! ZSX views are emitted as `pub fn Foo(writer: anytype, props: anytype) !void`,
//! which means each instantiation has a distinct concrete fn type. To store
//! the trampolines in a homogeneous slice, every trampoline takes a concrete
//! `*std.ArrayList(u8)` (the same buffer `cms/src/tpl.zig::render` writes
//! into) — `anytype` cannot appear in a runtime fn-pointer signature.
//! Picked `*ArrayList(u8)` rather than `*std.Io.Writer`/interface erasure
//! because the swap-loop already renders into an in-memory buffer before
//! broadcasting; no need to abstract over destinations.
//!
//! ## Slow-path-only views
//!
//! A trampoline can only re-render from a ZON blob if it can name a concrete
//! props type at compile time. Two situations rule that out:
//!   1. The signature is `props: anytype` with no nearby `withDefaults`
//!      hint (no module-level prop struct to reference).
//!   2. The signature's struct literal references identifiers that aren't
//!      `pub` in the view module (so the trampoline, which lives in a
//!      separate module, can't see them).
//! Both cases get a placeholder trampoline that returns
//! `error.PropTypeUnresolvable`. Task-06's swap loop will fall through to
//! the rebuild path for these views.
//!
//! ## CLI shape
//!
//! ```
//! registry_gen <output_registry_path> <label>=<input_dir> [<label2>=<input_dir2> ...]
//! ```
//!
//! `label` is the Zig import name the trampolines use to reach view
//! decls — e.g. `views=src/views` makes trampolines write
//! `views.admin.dashboard.Dashboard(...)`. Plugin labels can be added
//! later by extending the build wiring; v1 only feeds core views.

const std = @import("std");
const zsx = @import("zsx");

const Allocator = std.mem.Allocator;

/// One pub fn surfaced from a `.zsx` file. Driven into the emitted entries
/// slice in deterministic order (sorted by name).
const Entry = struct {
    /// `<dir-rel-path>:<FnName>` — the swap-loop lookup key.
    name: []u8,
    /// `.zsx` path, build-root-relative — for debug logging and source-path
    /// matching when the watcher emits an event.
    source_path: []u8,
    /// Zig import-path dot expression rooted at the input dir's label,
    /// e.g. `views.admin.dashboard` — used to qualify the `<Fn>_manifest`
    /// reference and the trampoline's view call.
    import_path: []u8,
    /// The pub fn name (e.g. "Dashboard").
    fn_name: []u8,
    /// `name` field rewritten as a Zig-safe identifier — used for the
    /// trampoline fn name to avoid collisions across files.
    trampoline_id: []u8,
    /// Resolution of the function's first parameter type:
    ///   * `.concrete` — a Zig type expression usable inside the trampoline
    ///     (e.g. `views.admin.dashboard.Props` or an inline `struct { ... }`
    ///     whose identifier tokens were qualified successfully).
    ///   * `.slow_path` — couldn't resolve the type; emit a stub
    ///     trampoline that returns `error.PropTypeUnresolvable`.
    props_kind: PropsKind,
    /// True if the fn is `pub fn` in the source (registry only includes pubs).
    is_pub: bool,
};

const PropsKind = union(enum) {
    /// Trampoline-callable: ZON-parses to this type, then dispatches.
    concrete: []u8,
    /// Documented reason for not having a callable trampoline. Always
    /// owned (allocated via `alloc.dupe`/`allocPrint`) so `freeEntry` can
    /// free it uniformly.
    slow_path: []u8,
};

/// Resolved per-file context: which `pub const`s (types) are accessible
/// from outside the view module — used when qualifying identifier tokens
/// inside an inline struct sig.
const ModuleScope = struct {
    /// Sorted list of identifier names that are `pub const`/`pub fn` decls
    /// at the file's top level (i.e. visible via `<view_import>.<Name>`).
    pub_decls: std.StringHashMap(void),

    fn deinit(self: *ModuleScope, alloc: Allocator) void {
        var it = self.pub_decls.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        self.pub_decls.deinit();
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) {
        std.debug.print(
            "usage: registry_gen <output_path> <label>=<input_dir> [<label2>=<input_dir2> ...]\n",
            .{},
        );
        std.process.exit(2);
    }

    const output_path = args[1];

    var entries: std.ArrayListUnmanaged(Entry) = .{};
    defer {
        for (entries.items) |*e| freeEntry(alloc, e);
        entries.deinit(alloc);
    }

    // Track every input label so the emitted file can `@import` each one.
    var labels: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (labels.items) |l| alloc.free(l);
        labels.deinit(alloc);
    }

    for (args[2..]) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
            std.debug.print("invalid input spec '{s}', expected '<label>=<dir>'\n", .{spec});
            std.process.exit(2);
        };
        const label = spec[0..eq];
        const dir_path = spec[eq + 1 ..];

        try labels.append(alloc, try alloc.dupe(u8, label));
        try walkDir(alloc, label, dir_path, &entries);
    }

    // Sort entries by name for deterministic output (eases code review and
    // diffing across builds).
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    try emit(alloc, output_path, labels.items, entries.items);
}

fn freeEntry(alloc: Allocator, e: *Entry) void {
    alloc.free(e.name);
    alloc.free(e.source_path);
    alloc.free(e.import_path);
    alloc.free(e.fn_name);
    alloc.free(e.trampoline_id);
    switch (e.props_kind) {
        .concrete => |s| alloc.free(s),
        .slow_path => |s| alloc.free(s),
    }
}

fn walkDir(
    alloc: Allocator,
    label: []const u8,
    dir_path: []const u8,
    entries: *std.ArrayListUnmanaged(Entry),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("registry_gen: cannot open '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return err;
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zsx")) continue;

        const rel_path = try alloc.dupe(u8, entry.path);
        defer alloc.free(rel_path);

        try processFile(alloc, label, dir_path, rel_path, entries);
    }
}

fn processFile(
    alloc: Allocator,
    label: []const u8,
    dir_path: []const u8,
    rel_path: []const u8,
    entries: *std.ArrayListUnmanaged(Entry),
) !void {
    const full_path = try std.fs.path.join(alloc, &.{ dir_path, rel_path });
    defer alloc.free(full_path);

    const source = std.fs.cwd().readFileAlloc(alloc, full_path, 8 * 1024 * 1024) catch |err| {
        std.debug.print("registry_gen: read '{s}' failed: {s}\n", .{ full_path, @errorName(err) });
        return err;
    };
    defer alloc.free(source);

    const manifests = zsx.parseAll(alloc, source) catch |err| {
        std.debug.print("registry_gen: parse '{s}' failed: {s}\n", .{ full_path, @errorName(err) });
        return err;
    };
    defer {
        for (manifests) |*m| m.deinit(alloc);
        alloc.free(manifests);
    }

    var scope = try collectModuleScope(alloc, source);
    defer scope.deinit(alloc);

    // dir-relative path without `.zsx` — used to form both the manifest
    // key and the dotted Zig import path.
    const stem_len = rel_path.len - ".zsx".len;
    const stem = rel_path[0..stem_len];

    var dir_rel_buf: std.ArrayListUnmanaged(u8) = .{};
    defer dir_rel_buf.deinit(alloc);
    try dir_rel_buf.appendSlice(alloc, stem);

    var import_path_buf: std.ArrayListUnmanaged(u8) = .{};
    defer import_path_buf.deinit(alloc);
    try import_path_buf.appendSlice(alloc, label);
    var seg_start: usize = 0;
    while (seg_start <= stem.len) {
        const slash = std.mem.indexOfScalarPos(u8, stem, seg_start, '/') orelse stem.len;
        try import_path_buf.append(alloc, '.');
        try appendPathSegment(alloc, &import_path_buf, stem[seg_start..slash]);
        if (slash == stem.len) break;
        seg_start = slash + 1;
    }

    // `pub fn` scan — registry only registers pub fns since private fns
    // aren't visible from outside the view module.
    var pub_fn_names = std.StringHashMap(void).init(alloc);
    defer {
        var it = pub_fn_names.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        pub_fn_names.deinit();
    }
    try collectPubFns(alloc, source, &pub_fn_names);

    for (manifests) |m| {
        if (m.name.len == 0) continue;
        const is_pub = pub_fn_names.contains(m.name);
        if (!is_pub) continue; // Skip private helpers — unreachable from outside.

        var entry: Entry = undefined;

        entry.name = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ stem, m.name });
        entry.source_path = try std.fs.path.join(alloc, &.{ dir_path, rel_path });
        entry.import_path = try alloc.dupe(u8, import_path_buf.items);
        entry.fn_name = try alloc.dupe(u8, m.name);
        entry.trampoline_id = try makeTrampolineId(alloc, label, stem, m.name);
        entry.is_pub = true;
        entry.props_kind = try resolvePropsKind(alloc, m.sig, entry.import_path, scope);

        try entries.append(alloc, entry);
    }
}

fn appendSanitizedIdent(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        try buf.append(alloc, if (ok) c else '_');
    }
}

/// Append a path segment to an emitted Zig dotted identifier. If the
/// segment collides with a Zig keyword (e.g. `error`, `fn`), wrap it in
/// the `@""` escape so it parses cleanly in the registry's import-path
/// expressions.
fn appendPathSegment(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    if (isZigKeyword(s)) {
        try buf.appendSlice(alloc, "@\"");
        try buf.appendSlice(alloc, s);
        try buf.append(alloc, '"');
    } else {
        try appendSanitizedIdent(alloc, buf, s);
    }
}

fn isZigKeyword(s: []const u8) bool {
    // Subset of Zig keywords that could appear as directory or file names.
    const kws: []const []const u8 = &.{
        "error", "if", "else", "for", "while", "switch", "fn",
        "const", "var", "pub",  "try", "catch", "defer",  "errdefer",
        "and",   "or", "not",   "struct",     "enum",    "union",
        "test",  "comptime",   "inline",     "noinline", "extern",
        "export","return",     "break",      "continue", "async",
        "await", "resume",     "suspend",    "anytype",  "type",
        "void",  "noreturn",   "bool",       "null",     "undefined",
        "true",  "false",      "unreachable","threadlocal",
    };
    for (kws) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}

fn makeTrampolineId(alloc: Allocator, label: []const u8, stem: []const u8, fn_name: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "render__");
    try appendSanitizedIdent(alloc, &buf, label);
    try buf.append(alloc, '_');
    for (stem) |c| {
        if (c == '/') {
            try buf.append(alloc, '_');
        } else {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
            try buf.append(alloc, if (ok) c else '_');
        }
    }
    try buf.append(alloc, '_');
    try buf.appendSlice(alloc, fn_name);
    try buf.appendSlice(alloc, "__fromZon");
    return alloc.dupe(u8, buf.items);
}

/// Scan the raw `.zsx` source for top-level `pub const <Name>` and
/// `pub fn <Name>` decls. Only these are reachable from outside the
/// generated view module, so the trampoline can only qualify identifier
/// tokens that appear in this set.
fn collectModuleScope(alloc: Allocator, source: []const u8) !ModuleScope {
    var scope: ModuleScope = .{
        .pub_decls = std.StringHashMap(void).init(alloc),
    };

    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        // Only scan at column 0 so we ignore nested `pub` inside structs.
        if (i != 0 and source[i - 1] != '\n') {
            // Fast-forward to next newline.
            const nl = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
            i = nl;
            continue;
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        const line = source[i..line_end];
        const name = parsePubDeclName(line) orelse {
            i = line_end;
            continue;
        };
        if (!scope.pub_decls.contains(name)) {
            try scope.pub_decls.put(try alloc.dupe(u8, name), {});
        }
        i = line_end;
    }
    return scope;
}

fn parsePubDeclName(line: []const u8) ?[]const u8 {
    // The zsx emitter prepends `pub ` to EVERY top-level `const`/`var` it
    // passes through, so a source-level `const Foo`/`var Foo` is pub-visible
    // in the generated view module — we must treat it as such here, or the
    // render-from-zon trampoline (which lives in a separate module) wrongly
    // concludes the props type isn't reachable and falls back to slow-path.
    // Functions keep their source pub-ness (the emitter doesn't pub a bare
    // `fn`), so `fn` only counts when written `pub fn`.
    const has_pub = std.mem.startsWith(u8, line, "pub ");
    var rest: []const u8 = if (has_pub) line[4..] else line;
    if (std.mem.startsWith(u8, rest, "const ")) {
        rest = rest["const ".len..];
    } else if (std.mem.startsWith(u8, rest, "var ")) {
        rest = rest["var ".len..];
    } else if (has_pub and std.mem.startsWith(u8, rest, "fn ")) {
        rest = rest["fn ".len..];
    } else {
        return null;
    }
    var j: usize = 0;
    while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) : (j += 1) {}
    const start = j;
    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_')) : (j += 1) {}
    if (j == start) return null;
    return rest[start..j];
}

fn collectPubFns(alloc: Allocator, source: []const u8, out: *std.StringHashMap(void)) !void {
    var i: usize = 0;
    while (i < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        const line = source[i..line_end];
        // Only column-0 `pub fn `.
        if (std.mem.startsWith(u8, line, "pub fn ")) {
            const rest = line["pub fn ".len..];
            var j: usize = 0;
            while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_')) : (j += 1) {}
            if (j > 0) {
                const name = rest[0..j];
                if (!out.contains(name)) {
                    try out.put(try alloc.dupe(u8, name), {});
                }
            }
        }
        i = line_end + 1;
    }
}

/// Tokens that don't need qualification — Zig built-ins, std-namespace
/// references, common stdlib types, and structural punctuation.
///
/// `anytype` is intentionally NOT in the list: it's only valid as the
/// top-level form of a sig (handled earlier with a dedicated slow-path
/// branch) and inside a struct literal it makes the type non-instantiable
/// at runtime. Leaving it out means a `props: struct { x: anytype }` sig
/// falls through to the "unknown identifier" branch which correctly flags
/// it as slow-path-only.
fn isBuiltinIdent(s: []const u8) bool {
    const builtins: []const []const u8 = &.{
        "u8",   "u16",   "u32",   "u64",     "u128",   "usize",
        "i8",   "i16",   "i32",   "i64",     "i128",   "isize",
        "f16",  "f32",   "f64",   "f80",     "f128",   "bool",
        "void", "noreturn",       "type",
        "anyerror",                          "comptime_int",
        "comptime_float",                    "true",   "false",
        "null", "undefined",      "const",   "var",    "struct",
        "enum", "union",          "if",      "else",   "for",
        "while","return",         "fn",      "pub",    "error",
    };
    for (builtins) |b| if (std.mem.eql(u8, s, b)) return true;
    return false;
}

/// Resolve the props type from a manifest `sig`. The sig is the raw text
/// between `(` and `)` of the function signature — e.g.:
///   * `""`                           — prop-less (synthetic `_props`).
///   * `"props: anytype"`             — slow-path: type unknown.
///   * `"props: Props"`               — concrete: qualify with import path.
///   * `"props: struct { ... }"`      — concrete iff identifier tokens
///                                       inside the struct body resolve
///                                       against the module scope; slow
///                                       path otherwise.
fn resolvePropsKind(
    alloc: Allocator,
    sig: []const u8,
    import_path: []const u8,
    scope: ModuleScope,
) !PropsKind {
    const trimmed = std.mem.trim(u8, sig, " \t\n\r");
    if (trimmed.len == 0) {
        // Prop-less view — task-02 made these compile with `.{.{}}`,
        // so the trampoline parses an empty struct from ZON `.{}`.
        return .{ .concrete = try alloc.dupe(u8, "struct {}") };
    }

    // Take the first parameter only — strip everything from the first
    // top-level `,` onward (some sigs have helpers like a children:[]const u8
    // tail, but zsx only emits one parameter per public fn).
    const first_param = takeFirstParam(trimmed);

    // Skip the parameter name (e.g. "props", "_props") and the colon.
    const colon = std.mem.indexOfScalar(u8, first_param, ':') orelse {
        return .{ .slow_path = try alloc.dupe(u8, "no `:` in sig") };
    };
    const type_expr = std.mem.trim(u8, first_param[colon + 1 ..], " \t\n\r");

    if (std.mem.eql(u8, type_expr, "anytype")) {
        return .{ .slow_path = try alloc.dupe(u8, "anytype props cannot be hydrated from zon") };
    }

    // Case 1: bare identifier (e.g. `Props`, `MyProps`).
    if (isBareIdent(type_expr)) {
        if (scope.pub_decls.contains(type_expr)) {
            return .{ .concrete = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ import_path, type_expr }) };
        }
        return .{ .slow_path = try alloc.dupe(u8, "props type identifier not pub-visible in view module") };
    }

    // Case 2: inline struct literal — qualify identifier tokens against
    // the module scope.
    if (std.mem.startsWith(u8, type_expr, "struct")) {
        return try qualifyStructLiteral(alloc, type_expr, import_path, scope);
    }

    return .{ .slow_path = try alloc.dupe(u8, "unrecognized props type form") };
}

fn takeFirstParam(s: []const u8) []const u8 {
    var depth_paren: i32 = 0;
    var depth_brace: i32 = 0;
    var depth_brack: i32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '(' => depth_paren += 1,
            ')' => depth_paren -= 1,
            '{' => depth_brace += 1,
            '}' => depth_brace -= 1,
            '[' => depth_brack += 1,
            ']' => depth_brack -= 1,
            ',' => {
                if (depth_paren == 0 and depth_brace == 0 and depth_brack == 0) {
                    return std.mem.trim(u8, s[0..i], " \t\n\r");
                }
            },
            else => {},
        }
    }
    return std.mem.trim(u8, s, " \t\n\r");
}

fn isBareIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// Walk the struct-literal text. For each identifier token that's not a
/// Zig keyword/primitive and not in the module's pub-decls set, declare
/// the sig unresolvable. Otherwise, emit the text verbatim with module
/// pub identifiers qualified to `<import_path>.<Ident>`.
fn qualifyStructLiteral(
    alloc: Allocator,
    expr: []const u8,
    import_path: []const u8,
    scope: ModuleScope,
) !PropsKind {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);

    var i: usize = 0;
    var prev_was_dot: bool = false;
    var in_field_pos: bool = true; // expecting a field name (identifier we should NOT qualify)
    var in_line_comment: bool = false;
    var brace_depth: i32 = 0;
    // The struct literal's outermost braces. Inside the body, identifiers
    // alternate roles: field name → colon → type expression → comma.
    // Track this state machine just well enough to know whether an
    // identifier is a field name (don't qualify) vs a type token (qualify).

    while (i < expr.len) {
        const c = expr[i];

        // Line comment: copy verbatim until newline.
        if (in_line_comment) {
            try out.append(alloc, c);
            if (c == '\n') in_line_comment = false;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < expr.len and expr[i + 1] == '/') {
            in_line_comment = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }

        if (c == '{') {
            brace_depth += 1;
            in_field_pos = brace_depth >= 1;
            try out.append(alloc, c);
            i += 1;
            prev_was_dot = false;
            continue;
        }
        if (c == '}') {
            brace_depth -= 1;
            try out.append(alloc, c);
            i += 1;
            prev_was_dot = false;
            continue;
        }
        if (c == ':') {
            in_field_pos = false; // next identifier is a type token.
            try out.append(alloc, c);
            i += 1;
            prev_was_dot = false;
            continue;
        }
        if (c == ',') {
            in_field_pos = brace_depth >= 1; // back to expecting a field name.
            try out.append(alloc, c);
            i += 1;
            prev_was_dot = false;
            continue;
        }
        if (c == '=') {
            // Default value — what follows isn't a type. Treat as type-ish
            // for safety (we don't qualify literals/exprs since they're
            // checked separately, but we keep in_field_pos = false so a
            // trailing identifier in `= MyEnum.foo` gets qualified iff
            // its leading ident is a pub decl).
            in_field_pos = false;
            try out.append(alloc, c);
            i += 1;
            prev_was_dot = false;
            continue;
        }

        if (c == '.') {
            // Dot prefix — next identifier is either an enum literal or
            // a field access; either way don't qualify.
            try out.append(alloc, c);
            i += 1;
            prev_was_dot = true;
            continue;
        }

        // String literal — copy until matching quote.
        if (c == '"') {
            const close = findClosingQuote(expr, i) orelse return .{ .slow_path = try alloc.dupe(u8, "unterminated string in props sig") };
            try out.appendSlice(alloc, expr[i .. close + 1]);
            i = close + 1;
            prev_was_dot = false;
            continue;
        }

        // Identifier token.
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var j: usize = i + 1;
            while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '_')) : (j += 1) {}
            const ident = expr[i..j];

            if (prev_was_dot or in_field_pos) {
                // Field access (`foo.bar`) or a struct field name — never qualify.
                try out.appendSlice(alloc, ident);
            } else if (isBuiltinIdent(ident)) {
                try out.appendSlice(alloc, ident);
            } else if (scope.pub_decls.contains(ident)) {
                try out.print(alloc, "{s}.{s}", .{ import_path, ident });
            } else {
                // Unknown identifier — can't safely emit a trampoline.
                return .{ .slow_path = try std.fmt.allocPrint(
                    alloc,
                    "props sig references identifier '{s}' that is not pub in the view module",
                    .{ident},
                ) };
            }

            i = j;
            prev_was_dot = false;
            continue;
        }

        try out.append(alloc, c);
        i += 1;
        prev_was_dot = false;
    }

    return .{ .concrete = try alloc.dupe(u8, out.items) };
}

fn findClosingQuote(s: []const u8, open: usize) ?usize {
    var i: usize = open + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return i;
    }
    return null;
}

// =============================================================================
// Code emission
// =============================================================================

fn emit(
    alloc: Allocator,
    output_path: []const u8,
    labels: []const []u8,
    entries: []const Entry,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll(
        \\// Generated by registry_gen — do not edit.
        \\//
        \\// Maps `view_name → (manifest, setL, render-from-zon)` so the HMR
        \\// swap loop can refresh a single view without restarting the
        \\// process. See src/tools/registry_gen.zig for the schema.
        \\
        \\const std = @import("std");
        \\const zsx = @import("zsx");
        \\
    );

    for (labels) |l| {
        try w.print("const {s} = @import(\"{s}\");\n", .{ l, l });
    }

    try w.writeAll(
        \\pub const Entry = struct {
        \\    /// `<dir-rel-path>:<FnName>` — matches the captureProps key.
        \\    name: []const u8,
        \\    /// `.zsx` path the view was generated from.
        \\    source_path: []const u8,
        \\    /// Pointer to the baked `<Fn>_manifest` const in the view module.
        \\    manifest: *const zsx.manifest_mod.Manifest,
        \\    /// The view file's file-wide `manifest_nodes` (every function in the
        \\    /// file, concatenated in source order). The HMR gate compares this so
        \\    /// a structural/attr change in a HELPER function the view renders
        \\    /// (e.g. `fn FilterBar` — not its own entry) still forces a rebuild.
        \\    file_manifest_nodes: []const zsx.manifest_mod.Node,
        \\    /// File-scoped `setL` — replaces the literal table.
        \\    setL: *const fn ([]const []const u8) void,
        \\    /// Trampoline: ZON-parses props, calls the view. Returns
        \\    /// `error.PropTypeUnresolvable` for slow-path-only views.
        \\    render_from_zon: *const fn (
        \\        out: *std.ArrayList(u8),
        \\        zon_bytes: []const u8,
        \\        alloc: std.mem.Allocator,
        \\    ) anyerror!void,
        \\};
        \\
        \\
    );

    // Emit one trampoline per entry.
    for (entries) |e| {
        try emitTrampoline(alloc, w, e);
    }

    // Emit the flat entries array.
    try w.writeAll("pub const entries: []const Entry = &.{\n");
    for (entries) |e| {
        try w.print(
            "    .{{ .name = \"{s}\", .source_path = ",
            .{e.name},
        );
        try writeZigStringLiteral(w, e.source_path);
        try w.print(
            ", .manifest = &{s}.{s}_manifest, .file_manifest_nodes = {s}.manifest_nodes, .setL = &{s}.setL, .render_from_zon = &{s} }},\n",
            .{ e.import_path, e.fn_name, e.import_path, e.import_path, e.trampoline_id },
        );
    }
    try w.writeAll("};\n");

    // Write atomically — the build step declares this path as an output
    // file and Zig's caching machinery wants a clean overwrite.
    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = buf.items });
}

fn emitTrampoline(_: Allocator, w: anytype, e: Entry) !void {
    switch (e.props_kind) {
        .slow_path => |reason| {
            try w.print(
                \\// {s}: slow-path-only — {s}.
                \\fn {s}(
                \\    out: *std.ArrayList(u8),
                \\    zon_bytes: []const u8,
                \\    alloc: std.mem.Allocator,
                \\) anyerror!void {{
                \\    _ = out;
                \\    _ = zon_bytes;
                \\    _ = alloc;
                \\    return error.PropTypeUnresolvable;
                \\}}
                \\
                \\
            , .{ e.name, reason, e.trampoline_id });
        },
        .concrete => |type_expr| {
            try w.print(
                \\fn {s}(
                \\    out: *std.ArrayList(u8),
                \\    zon_bytes: []const u8,
                \\    alloc: std.mem.Allocator,
                \\) anyerror!void {{
                \\    // std.zon.parse instantiates a deeply-recursive comptime
                \\    // generic per prop-struct field. The default quota (1000)
                \\    // trips on richer view-prop types (especially union/struct
                \\    // mixes used by admin views). 100k is plenty for the
                \\    // largest types we currently emit and keeps codegen
                \\    // tractable.
                \\    @setEvalBranchQuota(100_000);
                \\    var diag: std.zon.parse.Diagnostics = .{{}};
                \\    defer diag.deinit(alloc);
                \\    // Null-terminate for std.zon.parse.fromSlice (requires :0).
                \\    const zon_z = try alloc.dupeZ(u8, zon_bytes);
                \\    defer alloc.free(zon_z);
                \\    const props = std.zon.parse.fromSlice(
                \\        {s},
                \\        alloc,
                \\        zon_z,
                \\        &diag,
                \\        .{{}},
                \\    ) catch |err| {{
                \\        std.log.warn("[hmr] zon parse failed for {s}: {{s}}", .{{@errorName(err)}});
                \\        return err;
                \\    }};
                \\    defer std.zon.parse.free(alloc, props);
                \\    const writer = out.writer(alloc);
                \\    try {s}.{s}(writer, props);
                \\}}
                \\
                \\
            , .{
                e.trampoline_id,
                type_expr,
                e.name,
                e.import_path,
                e.fn_name,
            });
        },
    }
}

fn writeZigStringLiteral(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}
