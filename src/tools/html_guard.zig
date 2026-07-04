//! Build guard: fail the build if a production `.zig` file writes an HTML tag
//! literal to a writer. This locks the epic-#191 invariant — all html-like
//! output lives in `.zsx` components, never in Zig.
//!
//! What it flags: a line that emits an HTML tag literal through a writer, i.e.
//!   - `writer.writeAll("<div …")` / `w.print("…<span…", …)` — single-line, or
//!   - a `\\<div …` multiline-string-literal line (the body of a `writeAll(\\…)`).
//! It deliberately does NOT flag `ctx.html("<…")` (that sets a response body,
//! not a writer) — those are only used by test mocks — nor string comparisons
//! like `std.mem.startsWith(u8, x, "<input ")` (no writeAll/print on the line).
//!
//! Exceptions:
//!   - `tools/` and `tests/` directories, and `*.test.zig` files.
//!   - infra/tooling that legitimately handles raw HTML/SVG (see `excluded`).
//!   - any single line carrying a `// html-ok` opt-out comment.
//!
//! Usage: `html_guard <src-dir>` (cwd = repo root). Exits non-zero + prints the
//! violations if any are found.

const std = @import("std");

/// Infra/tooling files that legitimately emit HTML or SVG to a writer and are
/// outside the admin-view surface the invariant covers.
const excluded = [_][]const u8{
    "dev.zig", // dev server: HMR client injection
    "ssg.zig", // static-site generation
    "svg_sanitize.zig", // SVG sanitizer (rewrites markup)
    "hmr.zig",
    "hmr_loop.zig",
    "hmr_ws.zig",
    "css_jit.zig",
    "registry_gen.zig",
    "publr_template.zig",
    "publr_preprocess.zig",
};

fn isExcluded(rel_path: []const u8, basename: []const u8) bool {
    if (std.mem.indexOf(u8, rel_path, "tools/") != null) return true;
    if (std.mem.indexOf(u8, rel_path, "tests/") != null) return true;
    if (std.mem.endsWith(u8, basename, ".test.zig")) return true;
    if (std.mem.endsWith(u8, basename, "_test.zig")) return true;
    for (excluded) |e| {
        if (std.mem.eql(u8, basename, e)) return true;
    }
    return false;
}

fn isTagChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '/';
}

/// Does this line emit an HTML tag literal through a writer?
fn lineEmitsHtml(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "// html-ok") != null) return false;

    // (b) Multiline string literal whose content opens an HTML tag: `\\<div …`.
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "\\\\<") and trimmed.len > 3 and isTagChar(trimmed[3])) {
        return true;
    }

    // (a) A writer emit call on this line with a `"<tag` string literal.
    const has_emit = std.mem.indexOf(u8, line, "writeAll(") != null or
        std.mem.indexOf(u8, line, ".print(") != null;
    if (!has_emit) return false;

    // Find a `"<X` where X is a tag char (an HTML tag opening inside a string).
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, "\"<")) |pos| {
        if (pos + 2 < line.len and isTagChar(line[pos + 2])) return true;
        i = pos + 2;
    }
    return false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe name
    const src_dir = args.next() orelse "src";

    var dir = std.fs.cwd().openDir(src_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("html_guard: cannot open '{s}': {s}\n", .{ src_dir, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var violations: usize = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (isExcluded(entry.path, entry.basename)) continue;

        const contents = dir.readFileAlloc(alloc, entry.path, 8 * 1024 * 1024) catch continue;
        defer alloc.free(contents);

        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            line_no += 1;
            if (lineEmitsHtml(line)) {
                violations += 1;
                std.debug.print(
                    "  {s}/{s}:{d}: {s}\n",
                    .{ src_dir, entry.path, line_no, std.mem.trim(u8, line, " \t\r") },
                );
            }
        }
    }

    if (violations > 0) {
        std.debug.print(
            "\nhtml_guard: {d} HTML-in-Zig violation(s) — move this markup into a .zsx component\n" ++
                "(epic #191). If a line is a legitimate exception, add a `// html-ok` comment.\n",
            .{violations},
        );
        std.process.exit(1);
    }
}
