//! Vendored C dependencies: SQLite (amalgamation), stb_image (stb_impl.c),
//! and libwebp (split amalgamation). Shared between the native exe library,
//! the WASM library, the test exe (direct compile), and the db_init tool.
//!
//! Native vs WASM differ only in SQLite flags (threading + load_extension).

const std = @import("std");

pub const Opts = struct {
    /// Build for WASM: single-threaded SQLite + no load_extension.
    wasm: bool = false,
};

/// Attach libc + vendor/ include path + SQLite + stb_image + libwebp C
/// sources to any compile step (exe, lib, test).
pub fn addAll(b: *std.Build, compile: *std.Build.Step.Compile, opts: Opts) void {
    compile.linkLibC();
    compile.addIncludePath(b.path("vendor"));
    addSqlite(b, compile, opts);
    addImage(b, compile);
}

/// Attach just SQLite (used by db_init, which doesn't need image processing).
pub fn addSqlite(b: *std.Build, compile: *std.Build.Step.Compile, opts: Opts) void {
    compile.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = sqliteFlags(opts.wasm),
    });
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
