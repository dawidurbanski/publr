//! Publr Template — splits `.publr` files and generates Zig code.
//!
//! The `.publr` format wraps a ZSX body with Zig frontmatter between `---` fences.
//! Fences must start at column 0 (no leading whitespace). Trailing whitespace
//! after `---` on fence lines is allowed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zsx_transpile = @import("zsx").transpile;

pub const TemplateParts = struct {
    frontmatter: []const u8, // slice into source (between fences)
    body: []const u8, // slice into source (after second fence)
    body_line_offset: u32, // 1-based line number where body starts
};

// =============================================================================
// Splitter
// =============================================================================

/// Split a `.publr` template into frontmatter and body.
/// Returns slices into the original source — no allocation needed.
pub fn splitTemplate(source: []const u8) TemplateParts {
    // First line must be a `---` fence to start frontmatter.
    const first_line_end = findLineEnd(source, 0);
    if (!isFence(source[0..first_line_end])) {
        // No frontmatter — entire file is body.
        return .{
            .frontmatter = source[0..0],
            .body = source,
            .body_line_offset = 1,
        };
    }

    // Skip past the first fence line (including newline).
    const fm_start = skipPastNewline(source, first_line_end);
    var line_number: u32 = 2; // We're now on line 2.
    var pos = fm_start;

    // Scan for closing fence.
    while (pos < source.len) {
        const line_end = findLineEnd(source, pos);
        if (isFence(source[pos..line_end])) {
            // Found closing fence.
            const frontmatter = source[fm_start..pos];
            const body_start = skipPastNewline(source, line_end);
            return .{
                .frontmatter = frontmatter,
                .body = source[body_start..],
                .body_line_offset = line_number + 1,
            };
        }
        pos = skipPastNewline(source, line_end);
        line_number += 1;
    }

    // No closing fence found — treat entire file as body (no frontmatter).
    return .{
        .frontmatter = source[0..0],
        .body = source,
        .body_line_offset = 1,
    };
}

/// Check if a line (without its newline) is a valid `---` fence.
/// Must be exactly `---` optionally followed by whitespace.
fn isFence(line: []const u8) bool {
    if (line.len < 3) return false;
    if (line[0] != '-' or line[1] != '-' or line[2] != '-') return false;
    for (line[3..]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// Find the end of the current line (index of \n or \r\n, or end of source).
/// Returns index just before the newline character(s).
fn findLineEnd(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (i > start and source[i - 1] == '\r') return i - 1;
            return i;
        }
    }
    return source.len;
}

/// Skip past the newline at `line_end`. Handles \n and \r\n.
fn skipPastNewline(source: []const u8, line_end: usize) usize {
    if (line_end >= source.len) return source.len;
    if (source[line_end] == '\r') {
        if (line_end + 1 < source.len and source[line_end + 1] == '\n') return line_end + 2;
        return line_end + 1;
    }
    if (source[line_end] == '\n') return line_end + 1;
    return line_end;
}

// =============================================================================
// Code Generation
// =============================================================================

/// Generate a complete `.zig` source file from a `.publr` template.
///
/// 1. Wraps the body in a synthetic `.zsx` function
/// 2. Transpiles through the vendored ZSX parser
/// 3. Injects frontmatter and source mapping into the output
pub fn generateZig(
    allocator: Allocator,
    parts: TemplateParts,
    source_path: []const u8,
    component_imports: []const zsx_transpile.ComponentImport,
) ![]u8 {
    // Build synthetic .zsx: wrap body in a render function with ctx param
    const synthetic_zsx = try buildSyntheticZsx(allocator, parts.body);
    defer allocator.free(synthetic_zsx);

    // Transpile through ZSX parser
    const transpiled = try zsx_transpile.transpileSource(
        allocator,
        synthetic_zsx,
        source_path,
        component_imports,
    );
    defer allocator.free(transpiled);

    // Post-process: replace header, inject frontmatter
    return try assembleOutput(allocator, transpiled, parts, source_path);
}

/// Build a synthetic `.zsx` source by wrapping body in a render function.
/// The ZSX transpiler will add `writer: anytype` and transform `ctx: anytype`.
fn buildSyntheticZsx(allocator: Allocator, body: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("pub fn render(ctx: anytype) {\n");
    try w.writeAll(body);
    // Ensure body ends with newline before closing brace
    if (body.len > 0 and body[body.len - 1] != '\n') {
        try w.writeByte('\n');
    }
    try w.writeAll("}\n");
    return try buf.toOwnedSlice(allocator);
}

/// Post-process transpiled output: replace ZSX header with .publr header,
/// inject frontmatter into the render function body.
fn assembleOutput(
    allocator: Allocator,
    transpiled: []const u8,
    parts: TemplateParts,
    source_path: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    // Header
    try w.writeAll("// Generated from .publr template - do not edit\n");

    // Source mapping comment
    try w.writeAll("// Source: ");
    try w.writeAll(source_path);
    try w.writeAll(" (");
    if (parts.frontmatter.len > 0) {
        const fm_lines = countLines(parts.frontmatter);
        try w.print("frontmatter: lines 2-{d}, ", .{1 + fm_lines});
    }
    try w.print("body: line {d}+", .{parts.body_line_offset});
    try w.writeAll(")\n");

    // Find where the ZSX header ends and the real content starts.
    // ZSX output starts with "// Generated from ZSX - do not edit\n"
    // followed by "const zsx = ..." and component imports, then the function.
    // We want everything from "const zsx" onward, but need to inject frontmatter.

    // Skip the ZSX comment line
    const after_comment = skipLine(transpiled);

    // Find the function body opening: ") !void {\n"
    const fn_body_marker = ") !void {\n";
    const fn_body_pos = std.mem.indexOf(u8, transpiled, fn_body_marker) orelse {
        // Fallback: return transpiled as-is if pattern not found
        out.clearAndFree(allocator);
        return try allocator.dupe(u8, transpiled);
    };
    const body_code_start = fn_body_pos + fn_body_marker.len;

    // Write everything from after the ZSX comment to the function body opening
    try w.writeAll(transpiled[after_comment..body_code_start]);

    // Inject frontmatter
    if (parts.frontmatter.len > 0) {
        try w.writeAll("    // --- frontmatter ---\n");
        // Indent each frontmatter line with 4 spaces
        var fm_pos: usize = 0;
        while (fm_pos < parts.frontmatter.len) {
            const line_end = std.mem.indexOfScalar(u8, parts.frontmatter[fm_pos..], '\n');
            if (line_end) |end| {
                const line = parts.frontmatter[fm_pos .. fm_pos + end];
                if (line.len > 0) {
                    try w.writeAll("    ");
                    try w.writeAll(line);
                }
                try w.writeByte('\n');
                fm_pos += end + 1;
            } else {
                // Last line without newline
                const line = parts.frontmatter[fm_pos..];
                if (line.len > 0) {
                    try w.writeAll("    ");
                    try w.writeAll(line);
                    try w.writeByte('\n');
                }
                break;
            }
        }
        try w.writeAll("\n    // --- body ---\n");
    }

    // Write the rest of the transpiled body
    try w.writeAll(transpiled[body_code_start..]);

    return try out.toOwnedSlice(allocator);
}

/// Count the number of lines in a string (number of \n characters, +1 if non-empty and no trailing \n).
fn countLines(s: []const u8) u32 {
    if (s.len == 0) return 0;
    var count: u32 = 0;
    for (s) |c| {
        if (c == '\n') count += 1;
    }
    // If the string doesn't end with \n, the last line still counts
    if (s[s.len - 1] != '\n') count += 1;
    return count;
}

/// Skip past the first line (including its newline).
fn skipLine(s: []const u8) usize {
    for (s, 0..) |c, i| {
        if (c == '\n') return i + 1;
    }
    return s.len;
}

// =============================================================================
// Splitter Tests
// =============================================================================

const testing = std.testing;

test "normal frontmatter and body" {
    const result = splitTemplate("---\ncode\n---\n<div>");
    try testing.expectEqualStrings("code\n", result.frontmatter);
    try testing.expectEqualStrings("<div>", result.body);
    try testing.expectEqual(@as(u32, 4), result.body_line_offset);
}

test "no frontmatter" {
    const result = splitTemplate("<div>hello</div>");
    try testing.expectEqualStrings("", result.frontmatter);
    try testing.expectEqualStrings("<div>hello</div>", result.body);
    try testing.expectEqual(@as(u32, 1), result.body_line_offset);
}

test "empty frontmatter" {
    const result = splitTemplate("---\n---\n<div>");
    try testing.expectEqualStrings("", result.frontmatter);
    try testing.expectEqualStrings("<div>", result.body);
    try testing.expectEqual(@as(u32, 3), result.body_line_offset);
}

test "trailing whitespace on fence" {
    const result = splitTemplate("---  \ncode\n---\t\n<div>");
    try testing.expectEqualStrings("code\n", result.frontmatter);
    try testing.expectEqualStrings("<div>", result.body);
    try testing.expectEqual(@as(u32, 4), result.body_line_offset);
}

test "indented --- is NOT a fence" {
    const result = splitTemplate("  ---\nmore");
    try testing.expectEqualStrings("", result.frontmatter);
    try testing.expectEqualStrings("  ---\nmore", result.body);
    try testing.expectEqual(@as(u32, 1), result.body_line_offset);
}

test "--- in body after frontmatter" {
    const result = splitTemplate("---\ncode\n---\n<div>\n---\n</div>");
    try testing.expectEqualStrings("code\n", result.frontmatter);
    try testing.expectEqualStrings("<div>\n---\n</div>", result.body);
    try testing.expectEqual(@as(u32, 4), result.body_line_offset);
}

test "only frontmatter, no body" {
    const result = splitTemplate("---\ncode\n---\n");
    try testing.expectEqualStrings("code\n", result.frontmatter);
    try testing.expectEqualStrings("", result.body);
    try testing.expectEqual(@as(u32, 4), result.body_line_offset);
}

test "only frontmatter, no trailing newline" {
    const result = splitTemplate("---\ncode\n---");
    try testing.expectEqualStrings("code\n", result.frontmatter);
    try testing.expectEqualStrings("", result.body);
    try testing.expectEqual(@as(u32, 4), result.body_line_offset);
}

test "file with just ---" {
    const result = splitTemplate("---");
    try testing.expectEqualStrings("", result.frontmatter);
    try testing.expectEqualStrings("---", result.body);
    try testing.expectEqual(@as(u32, 1), result.body_line_offset);
}

test "empty file" {
    const result = splitTemplate("");
    try testing.expectEqualStrings("", result.frontmatter);
    try testing.expectEqualStrings("", result.body);
    try testing.expectEqual(@as(u32, 1), result.body_line_offset);
}

test "windows line endings" {
    const result = splitTemplate("---\r\ncode\r\n---\r\n<div>");
    try testing.expectEqualStrings("code\r\n", result.frontmatter);
    try testing.expectEqualStrings("<div>", result.body);
    try testing.expectEqual(@as(u32, 4), result.body_line_offset);
}

// =============================================================================
// Code Generation Tests
// =============================================================================

test "generateZig: simple frontmatter and body" {
    const allocator = testing.allocator;
    const source = "---\nconst post = ctx.get(.post);\n---\n<article>\n  <h1>{post.title}</h1>\n</article>\n";
    const parts = splitTemplate(source);
    const result = try generateZig(allocator, parts, "pages/blog.publr", &.{});
    defer allocator.free(result);

    // Should have .publr header
    try testing.expect(std.mem.startsWith(u8, result, "// Generated from .publr template - do not edit\n"));
    // Should have source mapping
    try testing.expect(std.mem.indexOf(u8, result, "// Source: pages/blog.publr") != null);
    // Should have zsx import
    try testing.expect(std.mem.indexOf(u8, result, "const zsx = @import(\"zsx\").runtime;") != null);
    // Should have source_path
    try testing.expect(std.mem.indexOf(u8, result, "pub const source_path = \"pages/blog.publr\";") != null);
    // Should have render function with both writer and ctx
    try testing.expect(std.mem.indexOf(u8, result, "pub fn render(writer: anytype, ctx: anytype) !void {") != null);
    // Should have frontmatter section
    try testing.expect(std.mem.indexOf(u8, result, "// --- frontmatter ---") != null);
    try testing.expect(std.mem.indexOf(u8, result, "const post = ctx.get(.post);") != null);
    // Should have body section
    try testing.expect(std.mem.indexOf(u8, result, "// --- body ---") != null);
    // Should have transpiled body (writer.writeAll calls)
    try testing.expect(std.mem.indexOf(u8, result, "writer.writeAll") != null);
}

test "generateZig: no frontmatter" {
    const allocator = testing.allocator;
    const source = "<div>hello</div>\n";
    const parts = splitTemplate(source);
    const result = try generateZig(allocator, parts, "pages/index.publr", &.{});
    defer allocator.free(result);

    // Should have render function
    try testing.expect(std.mem.indexOf(u8, result, "pub fn render(writer: anytype, ctx: anytype) !void {") != null);
    // Should NOT have frontmatter section
    try testing.expect(std.mem.indexOf(u8, result, "// --- frontmatter ---") == null);
    // Should have transpiled body
    try testing.expect(std.mem.indexOf(u8, result, "writer.writeAll") != null);
}

test "generateZig: empty frontmatter" {
    const allocator = testing.allocator;
    const source = "---\n---\n<p>hi</p>\n";
    const parts = splitTemplate(source);
    const result = try generateZig(allocator, parts, "pages/empty.publr", &.{});
    defer allocator.free(result);

    // Empty frontmatter = no frontmatter section
    try testing.expect(std.mem.indexOf(u8, result, "// --- frontmatter ---") == null);
    try testing.expect(std.mem.indexOf(u8, result, "writer.writeAll") != null);
}

test "generateZig: expressions in body" {
    const allocator = testing.allocator;
    const source = "---\nconst x = 1;\n---\n<div>{x}</div>\n";
    const parts = splitTemplate(source);
    const result = try generateZig(allocator, parts, "test.publr", &.{});
    defer allocator.free(result);

    // Expression should be transpiled to zsx.render call
    try testing.expect(std.mem.indexOf(u8, result, "zsx.render(writer, x)") != null);
}

test "generateZig: line offset comment is accurate" {
    const allocator = testing.allocator;
    const source = "---\nconst a = 1;\nconst b = 2;\n---\n<div>body</div>\n";
    const parts = splitTemplate(source);
    const result = try generateZig(allocator, parts, "test.publr", &.{});
    defer allocator.free(result);

    // Frontmatter is lines 2-3, body starts at line 5
    try testing.expect(std.mem.indexOf(u8, result, "frontmatter: lines 2-3") != null);
    try testing.expect(std.mem.indexOf(u8, result, "body: line 5+") != null);
}

test "generateZig: body-only template" {
    const allocator = testing.allocator;
    const source = "<main>\n  <p>just body</p>\n</main>\n";
    const parts = splitTemplate(source);
    const result = try generateZig(allocator, parts, "pages/simple.publr", &.{});
    defer allocator.free(result);

    // Should have body line offset 1
    try testing.expect(std.mem.indexOf(u8, result, "body: line 1+") != null);
    try testing.expect(std.mem.indexOf(u8, result, "writer.writeAll") != null);
}

test "buildSyntheticZsx wraps body in function" {
    const allocator = testing.allocator;
    const result = try buildSyntheticZsx(allocator, "<div>hello</div>\n");
    defer allocator.free(result);

    try testing.expectEqualStrings(
        "pub fn render(ctx: anytype) {\n<div>hello</div>\n}\n",
        result,
    );
}

test "buildSyntheticZsx adds trailing newline" {
    const allocator = testing.allocator;
    const result = try buildSyntheticZsx(allocator, "<div>no newline</div>");
    defer allocator.free(result);

    try testing.expectEqualStrings(
        "pub fn render(ctx: anytype) {\n<div>no newline</div>\n}\n",
        result,
    );
}

test "countLines" {
    try testing.expectEqual(@as(u32, 0), countLines(""));
    try testing.expectEqual(@as(u32, 1), countLines("hello"));
    try testing.expectEqual(@as(u32, 1), countLines("hello\n"));
    try testing.expectEqual(@as(u32, 2), countLines("a\nb"));
    try testing.expectEqual(@as(u32, 2), countLines("a\nb\n"));
    try testing.expectEqual(@as(u32, 3), countLines("a\nb\nc\n"));
}
