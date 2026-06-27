//! ZSX transpilation pipeline + theme JIT CSS compiler.
//!
//! Three sub-pipelines:
//!   1. `src/views/*.zsx` → transpiled .zig (for admin UI)
//!   2. `themes/<name>/*.publr` → synthetic .zsx → transpiled .zig (for theme)
//!   3. JIT compiler runs over each class manifest and emits utility CSS
//!      embedded into the binary as /static/publr.css and /theme.css.
//!
//! All build-time tools (`zsx_transpile`, `zsx_format`, `publr_preprocess`,
//! `jit`) live here too because their lifetime is tied to this pipeline.

const std = @import("std");
const helpers = @import("helpers.zig");

pub const Deps = struct {
    project_dir: ?[]const u8,
    theme_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// `-Dminify=true|false`. null = follow `optimize` (Debug unminified,
    /// otherwise minified).
    minify_css: ?bool,
    /// `-Dhmr=true`. When true, every zsx_transpile invocation in this
    /// pipeline gets `--hmr --hmr-capture-props` prepended to its argv so
    /// the generated views carry the manifest_nodes scaffolding and emit
    /// `captureProps` calls at the top of each component body.
    hmr: bool = false,
};

pub const Result = struct {
    zsx: *std.Build.Module,
    /// Used by `publr_template` tests.
    publr_template_module: *std.Build.Module,
    transpile_zsx_cmd: *std.Build.Step.Run,
    transpile_theme_cmd: *std.Build.Step.Run,
    /// The compiled ZSX transpiler exe — surfaced so plugins can spawn
    /// their own transpile runs over `plugins/<name>/views/`.
    zsx_transpiler: *std.Build.Step.Compile,
    /// Output of ZSX views transpile — referenced for class-manifest reads.
    gen_views: std.Build.LazyPath,
    /// Output of theme .publr → .zsx → transpile — referenced by tests/REST.
    gen_theme: std.Build.LazyPath,
    /// Captured stdout of the admin JIT compiler.
    jit_css_output: std.Build.LazyPath,
    /// Captured stdout of the theme JIT compiler.
    theme_jit_css_output: std.Build.LazyPath,
    /// Resolved minify gate (option override > optimize-mode default).
    should_minify: bool,
    /// Build options module surfaced as `build_options` to the runtime so the
    /// --watch rebuild loop propagates the minify flag.
    build_opts: *std.Build.Step.Options,
};

pub fn wire(b: *std.Build, deps: Deps) Result {
    // ZSX amalgamation — single vendor/zsx.zig for all build tools + runtime
    const zsx = b.createModule(.{
        .root_source_file = b.path("vendor/zsx.zig"),
    });

    // Thin entry points for build tools (generated at build time)
    const zsx_entries = b.addWriteFiles();
    const transpile_entry = zsx_entries.add("zsx_transpile_main.zig",
        \\const z = @import("zsx");
        \\pub fn main() !void { return z.transpile.main(); }
        \\
    );
    const format_entry = zsx_entries.add("zsx_format_main.zig",
        \\const z = @import("zsx");
        \\pub fn main() !void { return z.format.main(); }
        \\
    );

    const zsx_transpiler = b.addExecutable(.{
        .name = "zsx_transpile",
        .root_module = b.createModule(.{
            .root_source_file = transpile_entry,
            .target = b.graph.host,
            .imports = &.{.{ .name = "zsx", .module = zsx }},
        }),
    });

    // Run ZSX transpiler for views (cacheable: declared inputs + output directory)
    const transpile_zsx_cmd = b.addRunArtifact(zsx_transpiler);
    // Flags must precede positional <input_dir> <output_dir> args.
    if (deps.hmr) transpile_zsx_cmd.addArgs(&.{ "--hmr", "--hmr-capture-props", "--lift-attrs" });
    transpile_zsx_cmd.addDirectoryArg(b.path("src/views"));
    const gen_views = transpile_zsx_cmd.addOutputDirectoryArg("views");

    // Register .zsx files for content-based cache checking
    {
        var views_dir = b.build_root.handle.openDir("src/views", .{ .iterate = true }) catch
            @panic("cannot open src/views");
        defer views_dir.close();
        var walker = views_dir.walk(b.allocator) catch @panic("cannot walk src/views");
        defer walker.deinit();
        while (walker.next() catch @panic("walk error")) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zsx")) {
                transpile_zsx_cmd.addFileInput(b.path(b.pathJoin(&.{ "src/views", entry.path })));
            }
        }
    }

    // ZSX formatter + `zig build fmt`
    const zsx_formatter = b.addExecutable(.{
        .name = "zsx_format",
        .root_module = b.createModule(.{
            .root_source_file = format_entry,
            .target = b.graph.host,
            .imports = &.{.{ .name = "zsx", .module = zsx }},
        }),
    });
    const fmt_step = b.step("fmt", "Format ZSX files");
    const fmt_cmd = b.addRunArtifact(zsx_formatter);
    fmt_cmd.setCwd(b.path("."));
    fmt_cmd.addArgs(&.{"src/views"});
    fmt_step.dependOn(&fmt_cmd.step);

    // publr_template module (shared between preprocess tool and tests)
    const publr_template_module = b.createModule(.{
        .root_source_file = b.path("src/tools/publr_template.zig"),
        .imports = &.{.{ .name = "zsx", .module = zsx }},
    });

    // Build .publr preprocessor
    const publr_preprocess = b.addExecutable(.{
        .name = "publr_preprocess",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/publr_preprocess.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "publr_template", .module = publr_template_module }},
        }),
    });

    // Resolve theme directory (--project-dir for external builds, local otherwise)
    const theme_dir: std.Build.LazyPath = if (deps.project_dir) |pd|
        .{ .cwd_relative = b.pathJoin(&.{ pd, deps.theme_path }) }
    else
        b.path(deps.theme_path);

    // Step 1: Preprocess .publr → synthetic .zsx
    const preprocess_cmd = b.addRunArtifact(publr_preprocess);
    preprocess_cmd.addDirectoryArg(theme_dir);
    const theme_zsx = preprocess_cmd.addOutputDirectoryArg("theme_zsx");

    // Register .publr files for cache invalidation
    {
        const local_theme_dir = if (deps.project_dir) |_| null else b.build_root.handle.openDir(deps.theme_path, .{ .iterate = true }) catch null;
        if (local_theme_dir) |*dir| {
            var d = dir.*;
            defer d.close();
            var walker = d.walk(b.allocator) catch @panic("cannot walk theme dir");
            defer walker.deinit();
            while (walker.next() catch @panic("walk error")) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".publr")) {
                    preprocess_cmd.addFileInput(b.path(b.pathJoin(&.{ deps.theme_path, entry.path })));
                }
            }
        }
    }

    // Step 2: ZSX transpile synthetic .zsx → .zig
    const transpile_theme_cmd = b.addRunArtifact(zsx_transpiler);
    if (deps.hmr) transpile_theme_cmd.addArgs(&.{ "--hmr", "--hmr-capture-props", "--lift-attrs" });
    transpile_theme_cmd.addDirectoryArg(theme_zsx);
    const gen_theme = transpile_theme_cmd.addOutputDirectoryArg("theme");

    // JIT CSS compiler — reads class manifests produced by the transpilers
    // and emits utility CSS embedded as /static/publr.css.
    const jit_compiler = b.addExecutable(.{
        .name = "jit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vendor/jit/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "zsx", .module = zsx }},
        }),
    });

    const jit_cmd = b.addRunArtifact(jit_compiler);
    jit_cmd.setCwd(b.path("."));
    jit_cmd.addPrefixedFileArg("--theme=", b.path("vendor/jit/ds-tokens.zon"));

    const should_minify = deps.minify_css orelse (deps.optimize != .Debug);
    if (!should_minify) jit_cmd.addArg("--no-minify");

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "minify_css", should_minify);
    // CMS admin classes from .zsx
    jit_cmd.addFileArg(gen_views.path(b, "css_classes.txt"));
    // Pre-amalgamated publr_ui classes (invisible to local transpiler)
    jit_cmd.addFileArg(b.path("vendor/publr_ui.classes.txt"));
    jit_cmd.has_side_effects = true;
    jit_cmd.step.dependOn(&transpile_zsx_cmd.step);
    const jit_css_output = jit_cmd.captureStdOut();

    // Theme JIT: fed by the theme's class manifest from the .publr → ZSX
    // → transpile chain. Output served at /theme.css. We use `--prepend` so
    // the public stylesheet ships with preflight inline. theme.zon (if
    // present) overrides JIT default tokens at the consumer's build time.
    const theme_zon_rel = b.pathJoin(&.{ deps.theme_path, "theme.zon" });
    const has_theme_zon = blk: {
        if (deps.project_dir != null) break :blk false; // external builds skip
        b.build_root.handle.access(theme_zon_rel, .{}) catch break :blk false;
        break :blk true;
    };

    const theme_jit_cmd = b.addRunArtifact(jit_compiler);
    theme_jit_cmd.setCwd(b.path("."));
    theme_jit_cmd.addPrefixedFileArg("--theme=", b.path("vendor/jit/ds-tokens.zon"));
    if (!should_minify) theme_jit_cmd.addArg("--no-minify");
    if (has_theme_zon) {
        theme_jit_cmd.addPrefixedFileArg("--theme=", b.path(theme_zon_rel));
    }
    theme_jit_cmd.addArg("--prepend");
    theme_jit_cmd.addFileArg(b.path("vendor/jit/preflight.css"));
    theme_jit_cmd.addFileArg(gen_theme.path(b, "css_classes.txt"));
    theme_jit_cmd.has_side_effects = true;
    theme_jit_cmd.step.dependOn(&transpile_theme_cmd.step);
    const theme_jit_css_output = theme_jit_cmd.captureStdOut();

    return .{
        .zsx = zsx,
        .publr_template_module = publr_template_module,
        .transpile_zsx_cmd = transpile_zsx_cmd,
        .transpile_theme_cmd = transpile_theme_cmd,
        .zsx_transpiler = zsx_transpiler,
        .gen_views = gen_views,
        .gen_theme = gen_theme,
        .jit_css_output = jit_css_output,
        .theme_jit_css_output = theme_jit_css_output,
        .should_minify = should_minify,
        .build_opts = build_opts,
    };
}

/// Scan `themes/<name>/public/` for static files and build a single Zig
/// module exposing them as a `[]const File` table. The JIT-emitted theme.css
/// is folded in as a synthetic entry (no on-disk path). Returns the module —
/// callers attach it to the target exe as `theme_static`.
pub fn staticAssetsModule(b: *std.Build, opts: struct {
    /// Relative path to `themes/<name>/public` (build-root-relative).
    theme_static_rel: []const u8,
    /// External-build project dir; when set, file scanning is skipped (the
    /// project dir resolves at runtime, not via @embedFile).
    project_dir: ?[]const u8,
    /// Captured stdout of the theme JIT compiler (replaces any disk theme.css).
    theme_jit_css_output: std.Build.LazyPath,
}) *std.Build.Module {
    var gen_src: std.ArrayListUnmanaged(u8) = .{};
    const w = gen_src.writer(b.allocator);

    w.writeAll(
        \\pub const File = struct {
        \\    path: []const u8,
        \\    data: []const u8,
        \\    content_type: []const u8,
        \\    disk_path: []const u8,
        \\};
        \\
        \\pub const files = [_]File{
        \\
    ) catch @panic("OOM");

    // Collect theme static files. `theme.css` is reserved for the JIT
    // pipeline — any disk copy is treated as a placeholder and ignored
    // here so the synthetic JIT-generated entry below wins.
    const local_static_dir = if (opts.project_dir) |_| null else b.build_root.handle.openDir(opts.theme_static_rel, .{ .iterate = true }) catch null;
    if (local_static_dir) |*sd| {
        var d = sd.*;
        defer d.close();
        var walker = d.walk(b.allocator) catch @panic("cannot walk theme static");
        defer walker.deinit();
        while (walker.next() catch @panic("walk error")) |entry| {
            if (entry.kind != .file) continue;
            const rel = entry.path;
            if (std.mem.eql(u8, rel, "theme.css")) continue;
            const import_name = helpers.sanitizeImportName(b.allocator, rel);
            const mime = helpers.getMimeForBuild(rel);
            const disk = b.pathJoin(&.{ opts.theme_static_rel, rel });
            w.print(
                \\    .{{ .path = "{s}", .data = @embedFile("{s}"), .content_type = "{s}", .disk_path = "{s}" }},
                \\
            , .{ rel, import_name, mime, disk }) catch @panic("OOM");
        }
    }

    // Synthetic entry: JIT-emitted theme.css, served at /theme.css.
    // disk_path is empty — there is no disk file to reload from in dev.
    w.writeAll(
        \\    .{ .path = "theme.css", .data = @embedFile("static_theme_jit_css"), .content_type = "text/css", .disk_path = "" },
        \\};
        \\
    ) catch @panic("OOM");

    const gen_files = b.addWriteFiles();
    const theme_static_src = gen_files.add("theme_static.zig", gen_src.items);
    const mod = b.createModule(.{ .root_source_file = theme_static_src });

    // Second pass: register an @embedFile target for each scanned file.
    if (opts.project_dir == null) {
        var sd2 = b.build_root.handle.openDir(opts.theme_static_rel, .{ .iterate = true }) catch @panic("cannot open theme static dir");
        defer sd2.close();
        var walker2 = sd2.walk(b.allocator) catch @panic("cannot walk theme static");
        defer walker2.deinit();
        while (walker2.next() catch @panic("walk error")) |entry2| {
            if (entry2.kind != .file) continue;
            if (std.mem.eql(u8, entry2.path, "theme.css")) continue;
            const import_name2 = helpers.sanitizeImportName(b.allocator, entry2.path);
            mod.addAnonymousImport(import_name2, .{
                .root_source_file = b.path(b.pathJoin(&.{ opts.theme_static_rel, entry2.path })),
            });
        }
    }
    mod.addAnonymousImport("static_theme_jit_css", .{
        .root_source_file = opts.theme_jit_css_output,
    });

    return mod;
}

