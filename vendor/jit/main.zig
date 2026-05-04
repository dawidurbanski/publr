/// Publr JIT CSS Compiler CLI.
///
/// Reads a class manifest produced by the ZSX/.publr transpilers and emits
/// utility CSS to stdout via `jit.compile()`.
///
/// Theme model: the JIT is theme-agnostic. By default it uses the embedded
/// `default-theme.zon` (Tailwind v4.2.2 token set). Consumers pass their own
/// theme at the JIT's runtime — which is the consumer's BUILD time — via
/// `--theme=<path>`. The consumer's theme.zon may be a partial override; the
/// JIT merges it onto the default before resolving.
///
/// Class collection is the upstream transpilers' job — never a file scanner
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
///     Convert Tailwind @theme blocks to theme.zon (for migration).

const std = @import("std");
const theme_from_css = @import("theme_from_css.zig");
const jit = @import("jit.zig");
const default_theme: jit.Theme = @import("default-theme.zon");

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
    try stderr.interface.writeAll("    Convert Tailwind @theme blocks to theme.zon (for migration).\n");
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
