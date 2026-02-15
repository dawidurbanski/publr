//! Browser Bundle Tool — Creates cms-source.tar.gz for browser compilation
//!
//! Packages CMS source, pre-compiled C objects, translate-c bindings,
//! and a build manifest into a tarball that the browser WASM compiler
//! can use to compile the full CMS.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) {
        std.debug.print("Usage: browser_bundle <output-dir> <gen-views-dir>\n", .{});
        std.process.exit(1);
    }

    const out_dir = args[1];
    const gen_views_dir = args[2];

    std.debug.print("Creating browser bundle...\n", .{});

    // 1. Create directory structure
    for ([_][]const u8{
        "src/schema", "src/schemas", "src/plugins", "src/tools",
        "src/gen/views/admin/posts", "src/gen/views/admin/users",
        "src/gen/views/admin/media", "src/gen/views/admin/releases",
        "src/gen/views/components", "src/gen/views/error",
        "vendor", "bindings",
    }) |sub| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ out_dir, sub }) catch unreachable;
        try std.fs.cwd().makePath(path);
    }

    // 2. Copy source files
    std.debug.print("  Copying source files...\n", .{});
    try copyDir(alloc, "src", out_dir, "src", &.{ ".zig", ".sql" });
    try copyDir(alloc, gen_views_dir, out_dir, "src/gen/views", &.{".zig"});
    try copyFile("vendor/zsx.zig", out_dir, "vendor/zsx.zig");
    try copyFile("vendor/publr_ui.zig", out_dir, "vendor/publr_ui.zig");

    // 3. Compile C to .o and pre-compile WASI libc
    std.debug.print("  Compiling C dependencies...\n", .{});
    try compileCObjects(alloc, out_dir);
    std.debug.print("  Compiling WASI libc...\n", .{});
    try compileWasiLibc(alloc, out_dir);

    // 4. Generate translate-c bindings
    std.debug.print("  Generating C bindings...\n", .{});
    try generateBindings(alloc, out_dir);

    // 5. Patch @cImport files
    std.debug.print("  Patching @cImport references...\n", .{});
    try patchCImports(alloc, out_dir);

    // 6. Write build-manifest.json
    std.debug.print("  Writing manifest...\n", .{});
    try writeManifest(alloc, out_dir);

    // 7. Write config.zig template
    try writeFile(out_dir, "config.zig", "pub const setup_bg_dark: bool = false;\n");

    // 8. Create tar.gz
    std.debug.print("  Creating tar.gz...\n", .{});
    try createTar(alloc, out_dir);

    std.debug.print("Done: cms-source.tar.gz\n", .{});
}

// =========================================================================
// File operations
// =========================================================================

fn copyDir(alloc: Allocator, src_base: []const u8, out_base: []const u8, dest_prefix: []const u8, extensions: []const []const u8) !void {
    var src_dir = std.fs.cwd().openDir(src_base, .{ .iterate = true }) catch |e| {
        std.debug.print("Cannot open {s}: {}\n", .{ src_base, e });
        return e;
    };
    defer src_dir.close();

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        var matched = false;
        for (extensions) |ext| {
            if (std.mem.endsWith(u8, entry.basename, ext)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;

        // Build destination path
        const dest = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ out_base, dest_prefix, entry.path });
        defer alloc.free(dest);

        // Ensure parent directory exists
        if (std.fs.path.dirnamePosix(dest)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }

        // Copy file
        const src_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_base, entry.path });
        defer alloc.free(src_path);
        std.fs.cwd().copyFile(
            src_path,
            std.fs.cwd(),
            dest,
            .{},
        ) catch |e| {
            std.debug.print("Copy failed: {s} -> {s}: {}\n", .{ entry.path, dest, e });
            return e;
        };
    }
}

fn copyFile(src: []const u8, out_base: []const u8, dest: []const u8) !void {
    var buf: [512]u8 = undefined;
    const full_dest = std.fmt.bufPrint(&buf, "{s}/{s}", .{ out_base, dest }) catch unreachable;
    try std.fs.cwd().copyFile(src, std.fs.cwd(), full_dest, .{});
}

fn writeFile(out_base: []const u8, name: []const u8, content: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ out_base, name }) catch unreachable;
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// =========================================================================
// C compilation
// =========================================================================

fn compileWasiLibc(alloc: Allocator, out_dir: []const u8) !void {
    // Compile WASI libc and libzigc by building a dummy file with -lc.
    // The native compiler has LLVM and can produce these archives;
    // the browser compiler cannot, so we ship them pre-compiled.
    const dummy_path = try std.fmt.allocPrint(alloc, "{s}/_dummy_libc.zig", .{out_dir});
    defer alloc.free(dummy_path);

    try writeFile(out_dir, "_dummy_libc.zig", "export fn _start() void {}\n");

    const libc_out = try std.fmt.allocPrint(alloc, "{s}/vendor/libc.a", .{out_dir});
    defer alloc.free(libc_out);
    const zigc_out = try std.fmt.allocPrint(alloc, "{s}/vendor/libzigc.a", .{out_dir});
    defer alloc.free(zigc_out);
    const crt_out = try std.fmt.allocPrint(alloc, "{s}/vendor/libcompiler_rt.a", .{out_dir});
    defer alloc.free(crt_out);

    // Run zig build-exe with verbose-link to find the cached .a files.
    // The link step may fail (duplicate _start), but the .a files are
    // already compiled and cached by that point.
    var child = std.process.Child.init(&.{
        "zig", "build-exe", dummy_path,
        "-target", "wasm32-wasi", "-lc", "-fno-entry",
        "--verbose-link",
    }, alloc);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    _ = try child.spawn();

    // Verbose output goes to stderr in Zig
    const stdout = child.stdout.?.readToEndAlloc(alloc, 1024 * 1024) catch "";
    defer alloc.free(stdout);
    const stderr = child.stderr.?.readToEndAlloc(alloc, 1024 * 1024) catch "";
    defer alloc.free(stderr);
    _ = try child.wait();
    // Intentionally not checking exit code — linker may fail but .a files are cached

    // Parse verbose output (stderr) to find libc.a and libzigc.a paths
    // The linker command line contains the full paths
    var libc_src: ?[]const u8 = null;
    var zigc_src: ?[]const u8 = null;
    var crt_src: ?[]const u8 = null;

    // Search for paths in both stdout and stderr
    for ([_][]const u8{ stdout, stderr }) |output| {
        // Find paths like "/path/to/libc.a" in the linker command
        var i: usize = 0;
        while (i < output.len) {
            if (std.mem.startsWith(u8, output[i..], "/") and i + 6 < output.len) {
                // Find end of path (space or newline)
                var end = i + 1;
                while (end < output.len and output[end] != ' ' and output[end] != '\n') : (end += 1) {}
                const path = output[i..end];
                if (std.mem.endsWith(u8, path, "/libc.a")) {
                    libc_src = path;
                } else if (std.mem.endsWith(u8, path, "/libzigc.a")) {
                    zigc_src = path;
                } else if (std.mem.endsWith(u8, path, "/libcompiler_rt.a")) {
                    crt_src = path;
                }
                i = end;
            } else {
                i += 1;
            }
        }
    }

    if (libc_src) |src| {
        try std.fs.cwd().copyFile(src, std.fs.cwd(), libc_out, .{});
    } else {
        std.debug.print("Could not find libc.a in verbose output\n", .{});
        return error.LibcNotFound;
    }

    if (zigc_src) |src| {
        try std.fs.cwd().copyFile(src, std.fs.cwd(), zigc_out, .{});
    } else {
        std.debug.print("Could not find libzigc.a in verbose output\n", .{});
        return error.LibzigcNotFound;
    }

    if (crt_src) |src| {
        try std.fs.cwd().copyFile(src, std.fs.cwd(), crt_out, .{});
    } else {
        std.debug.print("Could not find libcompiler_rt.a in verbose output\n", .{});
        return error.CompilerRtNotFound;
    }

    // Clean up dummy file
    std.fs.cwd().deleteFile(dummy_path) catch {};
}

fn compileCObjects(alloc: Allocator, out_dir: []const u8) !void {
    // SQLite
    const sqlite_out = try std.fmt.allocPrint(alloc, "{s}/vendor/sqlite3.o", .{out_dir});
    defer alloc.free(sqlite_out);
    try runZigCC(alloc, &.{
        "vendor/sqlite3.c",
    }, sqlite_out, &.{
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_USE_ALLOCA=1",
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_TEMP_STORE=2",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_ENABLE_JSON1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-I",
        "vendor",
    });

    // stb_image
    const stb_out = try std.fmt.allocPrint(alloc, "{s}/vendor/stb_impl.o", .{out_dir});
    defer alloc.free(stb_out);
    try runZigCC(alloc, &.{
        "vendor/stb_impl.c",
    }, stb_out, &.{
        "-fno-sanitize=alignment",
        "-I",
        "vendor",
    });

    // libwebp (124 parts)
    for (0..124) |part| {
        const out_path = try std.fmt.allocPrint(alloc, "{s}/vendor/libwebp_{d}.o", .{ out_dir, part });
        defer alloc.free(out_path);
        const flag = try std.fmt.allocPrint(alloc, "-DWEBP_AMALGAMATION_PART={d}", .{part});
        defer alloc.free(flag);
        try runZigCC(alloc, &.{
            "vendor/libwebp.c",
        }, out_path, &.{ flag, "-I", "vendor" });
    }
}

fn runZigCC(alloc: Allocator, sources: []const []const u8, output: []const u8, extra_flags: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(alloc);

    try argv.appendSlice(alloc, &.{ "zig", "cc", "-c" });
    try argv.appendSlice(alloc, sources);
    try argv.appendSlice(alloc, &.{ "-o", output, "-target", "wasm32-wasi", "-O2" });
    try argv.appendSlice(alloc, extra_flags);

    var child = std.process.Child.init(argv.items, alloc);
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term.Exited != 0) {
        std.debug.print("zig cc failed for {s}\n", .{sources[0]});
        return error.CompilationFailed;
    }
}

// =========================================================================
// Translate-C bindings
// =========================================================================

fn generateBindings(alloc: Allocator, out_dir: []const u8) !void {
    // Find Zig lib directory for WASI libc headers
    const zig_lib = try getZigLibDir(alloc);
    defer alloc.free(zig_lib);

    const wasi_include = try std.fmt.allocPrint(alloc, "{s}/libc/include/wasm-wasi-musl", .{zig_lib});
    defer alloc.free(wasi_include);
    const generic_include = try std.fmt.allocPrint(alloc, "{s}/libc/include/generic-musl", .{zig_lib});
    defer alloc.free(generic_include);

    // SQLite bindings
    const sqlite_out = try runTranslateC(alloc, "vendor/sqlite3.h", &.{
        "-I",           "vendor",
        "-isystem",     wasi_include,
        "-isystem",     generic_include,
        "-DSQLITE_DQS=0",
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
    });
    defer alloc.free(sqlite_out);
    try writeFile(out_dir, "bindings/sqlite3_c.zig", sqlite_out);

    // stb + libwebp combined bindings — create shim header
    const shim = "/tmp/publr_stb_all.h";
    {
        const f = try std.fs.cwd().createFile(shim, .{});
        defer f.close();
        try f.writeAll(
            \\#include "stb_image.h"
            \\#include "stb_image_resize2.h"
            \\#include "stb_image_write.h"
            \\#include "libwebp.h"
            \\
        );
    }
    const stb_out = try runTranslateC(alloc, shim, &.{
        "-I",       "vendor",
        "-isystem", wasi_include,
        "-isystem", generic_include,
    });
    defer alloc.free(stb_out);
    try writeFile(out_dir, "bindings/stb_c.zig", stb_out);
}

fn getZigLibDir(alloc: Allocator) ![]const u8 {
    var child = std.process.Child.init(&.{ "zig", "env" }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(stdout);
    _ = try child.wait();

    // Parse .lib_dir from zig env output (Zig struct literal format)
    // Look for: .lib_dir = "path",
    var it = std.mem.splitSequence(u8, stdout, ".lib_dir");
    _ = it.next();
    const rest = it.next() orelse return error.ZigEnvParseFailed;
    const start = (std.mem.indexOf(u8, rest, "\"") orelse return error.ZigEnvParseFailed) + 1;
    const end = std.mem.indexOf(u8, rest[start..], "\"") orelse return error.ZigEnvParseFailed;
    return try alloc.dupe(u8, rest[start..][0..end]);
}

fn runTranslateC(alloc: Allocator, header: []const u8, flags: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(alloc);

    try argv.appendSlice(alloc, &.{ "zig", "translate-c", header, "-target", "wasm32-wasi" });
    try argv.appendSlice(alloc, flags);

    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(alloc, 4 * 1024 * 1024);
    const term = try child.wait();
    if (term.Exited != 0) {
        std.debug.print("translate-c failed for {s}\n", .{header});
        return error.TranslateCFailed;
    }
    return stdout;
}

// =========================================================================
// Patch @cImport → @import
// =========================================================================

fn patchCImports(alloc: Allocator, out_dir: []const u8) !void {
    // db.zig: module-level @cImport for sqlite3
    try patchFile(alloc, out_dir, "src/db.zig",
        \\const c = @cImport({
        \\    @cInclude("sqlite3.h");
        \\});
    ,
        \\const c = @import("sqlite3_c");
    );

    // image.zig: module-level @cImport for stb + libwebp
    try patchFile(alloc, out_dir, "src/image.zig",
        \\const c = @cImport({
        \\    @cInclude("stb_image.h");
        \\    @cInclude("stb_image_resize2.h");
        \\    @cInclude("stb_image_write.h");
        \\    @cInclude("libwebp.h");
        \\});
    ,
        \\const c = @import("stb_c");
    );

    // media_sync.zig: function-level @cImport for stb_image
    try patchFile(alloc, out_dir, "src/media_sync.zig",
        \\    const c = @cImport({
        \\        @cInclude("stb_image.h");
        \\    });
    ,
        \\    const c = @import("stb_c");
    );
}

fn patchFile(alloc: Allocator, out_dir: []const u8, rel_path: []const u8, needle: []const u8, replacement: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ out_dir, rel_path });
    defer alloc.free(path);

    const content = try std.fs.cwd().readFileAlloc(alloc, path, 2 * 1024 * 1024);
    defer alloc.free(content);

    const idx = std.mem.indexOf(u8, content, needle) orelse {
        std.debug.print("WARNING: patch target not found in {s}\n", .{rel_path});
        return;
    };

    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(content[0..idx]);
    try f.writeAll(replacement);
    try f.writeAll(content[idx + needle.len ..]);
}

// =========================================================================
// Build manifest
// =========================================================================

const Module = struct {
    name: []const u8,
    src: []const u8,
    deps: []const []const u8,
};

// Full module graph for the WASM build — must match build.zig browser_wasm section
const modules = [_]Module{
    // Binding modules (generated)
    .{ .name = "sqlite3_c", .src = "bindings/sqlite3_c.zig", .deps = &.{} },
    .{ .name = "stb_c", .src = "bindings/stb_c.zig", .deps = &.{} },
    // Config (template, modified at compile time)
    .{ .name = "config", .src = "config.zig", .deps = &.{} },
    // Schema layer
    .{ .name = "field", .src = "src/schema/field.zig", .deps = &.{} },
    .{ .name = "content_type", .src = "src/schema/content_type.zig", .deps = &.{"field"} },
    .{ .name = "schema_post", .src = "src/schemas/post.zig", .deps = &.{ "field", "content_type" } },
    .{ .name = "schema_page", .src = "src/schemas/page.zig", .deps = &.{ "field", "content_type" } },
    .{ .name = "schema_media", .src = "src/schemas/media.zig", .deps = &.{ "field", "content_type" } },
    .{ .name = "schemas", .src = "src/schemas/mod.zig", .deps = &.{ "field", "content_type", "schema_post", "schema_page", "schema_media" } },
    .{ .name = "schema_registry", .src = "src/schema/registry.zig", .deps = &.{ "field", "content_type", "schemas" } },
    // Core modules
    .{ .name = "time_util", .src = "src/time_util.zig", .deps = &.{} },
    .{ .name = "middleware", .src = "src/middleware.zig", .deps = &.{} },
    .{ .name = "db", .src = "src/db.zig", .deps = &.{"sqlite3_c"} },
    .{ .name = "seed", .src = "src/schema/seed.zig", .deps = &.{ "schema_registry", "field" } },
    .{ .name = "cms", .src = "src/cms.zig", .deps = &.{ "field", "schema_registry", "db", "time_util" } },
    .{ .name = "storage", .src = "src/storage.zig", .deps = &.{"time_util"} },
    .{ .name = "svg_sanitize", .src = "src/svg_sanitize.zig", .deps = &.{} },
    .{ .name = "media", .src = "src/media.zig", .deps = &.{ "db", "cms", "schema_media", "storage", "svg_sanitize", "wasm_storage" } },
    .{ .name = "media_sync", .src = "src/media_sync.zig", .deps = &.{ "db", "media", "storage", "svg_sanitize", "stb_c" } },
    .{ .name = "tpl", .src = "src/tpl.zig", .deps = &.{} },
    .{ .name = "auth", .src = "src/auth.zig", .deps = &.{ "db", "time_util" } },
    .{ .name = "auth_middleware", .src = "src/auth_middleware.zig", .deps = &.{ "middleware", "auth", "db" } },
    .{ .name = "csrf", .src = "src/csrf.zig", .deps = &.{ "middleware", "auth_middleware" } },
    .{ .name = "admin_api", .src = "src/admin_api.zig", .deps = &.{"middleware"} },
    .{ .name = "image", .src = "src/image.zig", .deps = &.{"stb_c"} },
    .{ .name = "media_handler", .src = "src/media_handler.zig", .deps = &.{ "storage", "auth_middleware", "middleware", "image" } },
    .{ .name = "icons", .src = "src/icons.zig", .deps = &.{} },
    .{ .name = "gravatar", .src = "src/gravatar.zig", .deps = &.{} },
    // WASM-specific modules
    .{ .name = "wasm_storage", .src = "src/wasm_storage.zig", .deps = &.{ "db", "storage" } },
    .{ .name = "wasm_media_handler", .src = "src/wasm_media_handler.zig", .deps = &.{ "middleware", "wasm_storage", "auth_middleware", "media_handler", "image", "storage" } },
    .{ .name = "wasm_router", .src = "src/wasm_router.zig", .deps = &.{ "middleware", "admin_api" } },
    // Views
    .{ .name = "zsx", .src = "vendor/zsx.zig", .deps = &.{} },
    .{ .name = "views", .src = "src/gen/views/views.zig", .deps = &.{ "zsx", "icons" } },
    // Plugins
    .{ .name = "plugin_dashboard", .src = "src/plugins/dashboard.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "db", "csrf", "auth_middleware", "media", "views", "registry" } },
    .{ .name = "plugin_users", .src = "src/plugins/users.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "auth", "csrf", "auth_middleware", "views", "registry" } },
    .{ .name = "plugin_settings", .src = "src/plugins/settings.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "csrf", "auth", "auth_middleware", "views", "registry" } },
    .{ .name = "plugin_components", .src = "src/plugins/components.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "csrf", "views", "registry" } },
    .{ .name = "plugin_design_system", .src = "src/plugins/design_system.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "csrf", "views", "registry" } },
    .{ .name = "plugin_content_types", .src = "src/plugins/content_types.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "views", "registry" } },
    .{ .name = "plugin_media", .src = "src/plugins/media.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "csrf", "auth_middleware", "media", "media_sync", "storage", "schema_media", "media_handler", "db", "views", "wasm_storage", "registry" } },
    .{ .name = "plugin_releases", .src = "src/plugins/releases.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "csrf", "auth_middleware", "cms", "views", "registry" } },
    // Registry (imports all plugins)
    .{ .name = "registry", .src = "src/registry.zig", .deps = &.{ "admin_api", "icons", "middleware", "tpl", "csrf", "auth_middleware", "gravatar", "views", "plugin_dashboard", "plugin_media", "plugin_users", "plugin_settings", "plugin_components", "plugin_design_system", "plugin_content_types", "plugin_releases" } },
};

// Root module deps — what wasm_main.zig imports
const root_deps = [_][]const u8{
    "config",      "db",        "tpl",               "auth",
    "middleware",   "admin_api", "registry",           "wasm_router",
    "auth_middleware", "csrf",   "icons",              "storage",
    "svg_sanitize", "cms",      "media",              "image",
    "schema_media", "media_handler", "wasm_storage",  "wasm_media_handler",
    "views",       "seed",
};

fn writeManifest(alloc: Allocator, out_dir: []const u8) !void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("{\n");
    try w.writeAll("  \"entry\": \"src/wasm_main.zig\",\n");
    try w.writeAll("  \"target\": \"wasm32-wasi\",\n");
    try w.writeAll("  \"flags\": [\"-fno-entry\", \"-fno-llvm\", \"-fno-lld\", \"-fno-ubsan-rt\", \"-rdynamic\", \"-OReleaseSafe\"],\n");

    // Object files (includes pre-compiled WASI libc and compiler-rt)
    try w.writeAll("  \"object_files\": [\n");
    try w.writeAll("    \"vendor/libc.a\",\n");
    try w.writeAll("    \"vendor/libzigc.a\",\n");
    try w.writeAll("    \"vendor/libcompiler_rt.a\",\n");
    try w.writeAll("    \"vendor/sqlite3.o\",\n");
    try w.writeAll("    \"vendor/stb_impl.o\"");
    for (0..124) |part| {
        try w.print(",\n    \"vendor/libwebp_{d}.o\"", .{part});
    }
    try w.writeAll("\n  ],\n");

    // Modules
    try w.writeAll("  \"modules\": {\n");

    // Root module
    try w.writeAll("    \"root\": { \"src\": \"src/wasm_main.zig\", \"deps\": [");
    for (root_deps, 0..) |dep, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{dep});
    }
    try w.writeAll("] }");

    for (modules) |mod| {
        try w.writeAll(",\n");
        try w.print("    \"{s}\": {{ \"src\": \"{s}\", \"deps\": [", .{ mod.name, mod.src });
        for (mod.deps, 0..) |dep, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{dep});
        }
        try w.writeAll("] }");
    }
    try w.writeAll("\n  },\n");

    // Config options
    try w.writeAll("  \"config_options\": {\n");
    try w.writeAll("    \"setup_bg_dark\": { \"type\": \"bool\", \"default\": false }\n");
    try w.writeAll("  }\n");
    try w.writeAll("}\n");

    try writeFile(out_dir, "build-manifest.json", buf.items);
}

// =========================================================================
// Tar creation
// =========================================================================

fn createTar(alloc: Allocator, out_dir: []const u8) !void {
    const tar_path = try std.fmt.allocPrint(alloc, "{s}/cms-source.tar.gz", .{out_dir});
    defer alloc.free(tar_path);
    var child = std.process.Child.init(&.{
        "tar", "czf", tar_path, "-C", out_dir,
        "src", "vendor", "bindings", "config.zig", "build-manifest.json",
    }, alloc);
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term.Exited != 0) return error.TarFailed;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}
