//! Vendored C dependencies: SQLite (amalgamation), stb_image (stb_impl.c),
//! and libwebp (split amalgamation). Shared between the native exe library,
//! the WASM library, the test exe (direct compile), and the db_init tool.
//!
//! Native vs WASM differ only in SQLite flags (threading + load_extension).

const std = @import("std");

pub const Opts = struct {
    /// Build for WASM: single-threaded SQLite + no load_extension.
    wasm: bool = false,
    /// Extra C sources contributed by plugins. Compiled with their own
    /// flags into publr_vendors so the plugin's extension code shares
    /// the SQLite build.
    extra_c_sources: []const ExtraCSource = &.{},
    /// Extra include paths so plugin C sources can find their own
    /// headers (publr's vendor/ is already on the path).
    extra_include_paths: []const std.Build.LazyPath = &.{},
    /// Prebuilt static libraries (e.g. Rust-built cr-sqlite core) to
    /// link into publr_vendors. Resolved at the final link.
    static_libs: []const std.Build.LazyPath = &.{},
    /// Plugin-provided sqlite source directory (build-root-relative).
    /// When set, the build:
    ///   - uses `<dir>/sqlite3.c` instead of `vendor/sqlite3.c`
    ///   - adds `<dir>` to the include path FIRST so its `sqlite3.h` wins
    ///   - compiles every other `*.c` in `<dir>` with the override's flags
    /// Set by plugins whose manifest.zon declares `.sqlite_override_dir`
    /// (cr-sqlite, etc.). Only one plugin per build may override.
    sqlite_override_dir: ?[]const u8 = null,
    /// Extra C flags applied to override C sources (not the amalgamation
    /// — sqlite3.c always uses `sqliteFlags()`). Typically the override
    /// flags expected by the swapped sqlite extension (e.g. for cr-sqlite:
    /// `-DSQLITE_CORE -DSQLITE_OMIT_LOAD_EXTENSION -DHAVE_GETHOSTUUID=0`).
    sqlite_override_extra_cflags: []const []const u8 = &.{},
};

pub const ExtraCSource = struct {
    file: std.Build.LazyPath,
    flags: []const []const u8,
};

/// Attach libc + vendor/ include path + SQLite + stb_image + libwebp C
/// sources to any compile step (exe, lib, test). Plugin C sources are
/// compiled in here; plugin static libs (`opts.static_libs`) must be
/// attached separately to the final exe step (a static archive's contents
/// don't propagate when nested inside another archive — the symbols are
/// only pulled in at the final link).
pub fn addAll(b: *std.Build, compile: *std.Build.Step.Compile, opts: Opts) void {
    compile.linkLibC();
    // Override include path FIRST so the plugin's sqlite3.h is the one
    // every TU sees (the C glue is compiled against it). Default
    // vendor/ is added next so non-sqlite headers (stb, libwebp) still
    // resolve.
    if (opts.sqlite_override_dir) |dir| compile.addIncludePath(b.path(dir));
    compile.addIncludePath(b.path("vendor"));
    for (opts.extra_include_paths) |p| compile.addIncludePath(p);
    addSqlite(b, compile, opts);
    addImage(b, compile);
    addSqliteOverrideGlue(b, compile, opts);
    for (opts.extra_c_sources) |src| {
        compile.addCSourceFile(.{ .file = src.file, .flags = src.flags });
    }
}

/// Attach plugin-contributed static libs to a final exe / test target.
/// Call this on every step that links publr_vendors, since the symbols
/// from these libs are referenced by C sources inside publr_vendors.
pub fn linkStaticLibs(compile: *std.Build.Step.Compile, opts: Opts) void {
    for (opts.static_libs) |lib| compile.addObjectFile(lib);
}

/// Attach just SQLite (used by db_init, which doesn't need image processing).
/// Picks the plugin override's `sqlite3.c` when `opts.sqlite_override_dir`
/// is set; otherwise the vendored amalgamation. Flags come from
/// `sqliteFlags(opts.wasm)` in both cases — plugins must keep their swapped
/// sqlite3.c compatible with these flags.
pub fn addSqlite(b: *std.Build, compile: *std.Build.Step.Compile, opts: Opts) void {
    const sqlite_c_path = if (opts.sqlite_override_dir) |dir|
        b.fmt("{s}/sqlite3.c", .{dir})
    else
        "vendor/sqlite3.c";
    compile.addCSourceFile(.{
        .file = b.path(sqlite_c_path),
        .flags = sqliteFlags(opts.wasm),
    });
}

/// Compile every `*.c` in `opts.sqlite_override_dir` except `sqlite3.c`
/// (already handled by `addSqlite`). Plugin override dirs typically
/// contain glue C the plugin's static lib calls into — compiled with the
/// override's extra cflags so they match the plugin's expectations.
fn addSqliteOverrideGlue(b: *std.Build, compile: *std.Build.Step.Compile, opts: Opts) void {
    const dir = opts.sqlite_override_dir orelse return;
    var d = b.build_root.handle.openDir(dir, .{ .iterate = true }) catch return;
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        if (std.mem.eql(u8, entry.name, "sqlite3.c")) continue;
        compile.addCSourceFile(.{
            .file = b.path(b.fmt("{s}/{s}", .{ dir, entry.name })),
            .flags = opts.sqlite_override_extra_cflags,
        });
    }
}

/// Attach stb_image (stb_impl.c) + libwebp (split amalgamation, 124 parts).
pub fn addImage(b: *std.Build, compile: *std.Build.Step.Compile) void {
    // stb_image_resize2 does intentional misaligned uint64 stores in
    // stbir__pack_coefficients, which triggers UBSan in debug builds.
    compile.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{"-fno-sanitize=alignment"},
    });
    // libwebp split amalgamation: same file compiled 124 times with different
    // PART values. The -U flags strip CPU-specific intrinsics so the same
    // sources cross-compile on hosts without SSE/AVX (notably WASM).
    for (0..124) |part| {
        var buf: [32]u8 = undefined;
        const flag = std.fmt.bufPrint(&buf, "-DWEBP_AMALGAMATION_PART={d}", .{part}) catch unreachable;
        compile.addCSourceFile(.{
            .file = b.path("vendor/libwebp.c"),
            .flags = &.{ flag, "-U__SSE2__", "-U__SSE4_1__", "-U__AVX2__" },
        });
    }
}

/// Build a `publr_vendors` static library for the given target with all C
/// sources attached. Used by both the native exe and the WASM exe so vendor
/// compilation is cached separately from Zig sources.
pub fn library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: Opts,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "publr_vendors",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    addAll(b, lib, opts);
    return lib;
}

fn sqliteFlags(wasm: bool) []const []const u8 {
    return if (wasm) &.{
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_USE_ALLOCA=1",
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_TEMP_STORE=2",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_ENABLE_JSON1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
    } else &.{
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_USE_ALLOCA=1",
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_TEMP_STORE=2",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_ENABLE_JSON1",
    };
}
