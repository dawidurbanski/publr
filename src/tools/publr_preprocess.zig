//! Publr Preprocessor — converts `.publr` templates to synthetic `.zsx` files.
//!
//! Usage: publr_preprocess <theme_dir> <output_dir>
//!
//! Walks <theme_dir> for `.publr` files, splits frontmatter from body,
//! generates synthetic `.zsx` wrapping both into a render function,
//! and writes to <output_dir> preserving directory structure.
//!
//! The ZSX transpiler then processes the `.zsx` output as a second step.

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const template = @import("publr_template");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: publr_preprocess <theme_dir> <output_dir>\n", .{});
        std.process.exit(1);
    }

    const theme_dir = args[1];
    const output_dir = args[2];

    try preprocessTheme(allocator, theme_dir, output_dir);
}

fn preprocessTheme(allocator: Allocator, theme_dir: []const u8, output_dir: []const u8) !void {
    // Ensure output directory exists
    fs.cwd().makePath(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var dir = try fs.cwd().openDir(theme_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .directory) {
            // Create corresponding output subdirectory
            const sub_output = try fs.path.join(allocator, &.{ output_dir, entry.path });
            defer allocator.free(sub_output);
            fs.cwd().makePath(sub_output) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        } else if (entry.kind == .file and mem.endsWith(u8, entry.path, ".publr")) {
            try preprocessFile(allocator, theme_dir, output_dir, entry.path);
        }
    }
}

fn preprocessFile(allocator: Allocator, theme_dir: []const u8, output_dir: []const u8, rel_path: []const u8) !void {
    const input_path = try fs.path.join(allocator, &.{ theme_dir, rel_path });
    defer allocator.free(input_path);

    // Output path: foo/bar.publr -> foo/bar.zsx
    const base = rel_path[0 .. rel_path.len - 6]; // strip ".publr"
    const output_rel = try std.fmt.allocPrint(allocator, "{s}.zsx", .{base});
    defer allocator.free(output_rel);

    const output_path = try fs.path.join(allocator, &.{ output_dir, output_rel });
    defer allocator.free(output_path);

    // Ensure output subdirectory exists
    if (fs.path.dirname(output_path)) |dir| {
        fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    // Read source
    const source = try fs.cwd().readFileAlloc(allocator, input_path, 1024 * 1024);
    defer allocator.free(source);

    // Split and generate synthetic .zsx
    const parts = template.splitTemplate(source);

    // Determine function name: PascalCase for layouts/components, "render" for pages
    const fn_name = if (mem.startsWith(u8, rel_path, "layouts/") or
        mem.startsWith(u8, rel_path, "components/"))
    blk: {
        const basename = fs.path.basename(rel_path);
        const name_no_ext = basename[0 .. basename.len - 6]; // strip ".publr"
        break :blk try toPascalCase(allocator, name_no_ext);
    } else null;
    defer if (fn_name) |n| allocator.free(n);

    const synthetic = try generateSyntheticZsx(allocator, parts, rel_path, fn_name);
    defer allocator.free(synthetic);

    // Write output
    var file = try fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(synthetic);
}

/// Generate a synthetic `.zsx` file from split `.publr` parts.
/// Embeds frontmatter as Zig code passthrough (the ZSX parser copies it verbatim)
/// and the body as JSX markup for transpilation.
fn generateSyntheticZsx(allocator: Allocator, parts: template.TemplateParts, source_path: []const u8, fn_name: ?[]const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Source mapping comment (preserved by ZSX transpiler's parseLineComment)
    try w.print("// .publr source: {s}", .{source_path});
    if (parts.frontmatter.len > 0) {
        const fm_lines = countLines(parts.frontmatter);
        try w.print(" (frontmatter: lines 2-{d}, body: line {d}+)", .{ 1 + fm_lines, parts.body_line_offset });
    } else {
        try w.print(" (body: line {d}+)", .{parts.body_line_offset});
    }
    try w.writeByte('\n');

    // Function declaration — ZSX transpiler adds writer: anytype
    // Layouts/components use PascalCase name (for auto-import), pages use "render"
    if (fn_name) |name| {
        try w.print("pub fn {s}(props: anytype) {{\n", .{name});
    } else {
        try w.writeAll("pub fn render(ctx: anytype) {\n");
    }

    // Ensure parameter is always referenced (avoids unused parameter error).
    if (fn_name != null) {
        try w.writeAll("const _props_ref = @as(@TypeOf(props), props);\n_ = &_props_ref;\n");
    } else {
        try w.writeAll("const _ctx_ref = @as(@TypeOf(ctx), ctx);\n_ = &_ctx_ref;\n");
    }

    // Frontmatter as Zig passthrough code
    if (parts.frontmatter.len > 0) {
        try w.writeAll(parts.frontmatter);
        // Ensure frontmatter ends with newline
        if (parts.frontmatter.len > 0 and parts.frontmatter[parts.frontmatter.len - 1] != '\n') {
            try w.writeByte('\n');
        }
    }

    // Body as JSX markup
    try w.writeAll(parts.body);
    // Ensure body ends with newline
    if (parts.body.len > 0 and parts.body[parts.body.len - 1] != '\n') {
        try w.writeByte('\n');
    }

    try w.writeAll("}\n");
    return try buf.toOwnedSlice(allocator);
}

/// Convert a kebab-case or snake_case name to PascalCase.
/// "post-card" → "PostCard", "base" → "Base"
fn toPascalCase(allocator: Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    var capitalize_next = true;
    for (name) |c| {
        if (c == '-' or c == '_') {
            capitalize_next = true;
        } else if (capitalize_next) {
            try result.append(allocator, std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            try result.append(allocator, c);
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn countLines(s: []const u8) u32 {
    if (s.len == 0) return 0;
    var count: u32 = 0;
    for (s) |c| {
        if (c == '\n') count += 1;
    }
    if (s[s.len - 1] != '\n') count += 1;
    return count;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "generateSyntheticZsx: frontmatter and body" {
    const allocator = testing.allocator;
    const source = "---\nconst x = ctx.get(.x);\n---\n<div>{x}</div>\n";
    const parts = template.splitTemplate(source);
    const result = try generateSyntheticZsx(allocator, parts, "pages/test.publr", null);
    defer allocator.free(result);

    // Should have source mapping comment
    try testing.expect(mem.indexOf(u8, result, "// .publr source: pages/test.publr") != null);
    // Should have render function
    try testing.expect(mem.indexOf(u8, result, "pub fn render(ctx: anytype) {") != null);
    // Should have frontmatter code
    try testing.expect(mem.indexOf(u8, result, "const x = ctx.get(.x);") != null);
    // Should have body
    try testing.expect(mem.indexOf(u8, result, "<div>{x}</div>") != null);
    // Should close function
    try testing.expect(mem.endsWith(u8, result, "}\n"));
}

test "generateSyntheticZsx: no frontmatter" {
    const allocator = testing.allocator;
    const source = "<p>hello</p>\n";
    const parts = template.splitTemplate(source);
    const result = try generateSyntheticZsx(allocator, parts, "pages/index.publr", null);
    defer allocator.free(result);

    // Should have render function with body (after ctx reference)
    try testing.expect(mem.indexOf(u8, result, "pub fn render(ctx: anytype) {") != null);
    try testing.expect(mem.indexOf(u8, result, "<p>hello</p>") != null);
}

test "generateSyntheticZsx: empty body" {
    const allocator = testing.allocator;
    const source = "---\nconst x = 1;\n---\n";
    const parts = template.splitTemplate(source);
    const result = try generateSyntheticZsx(allocator, parts, "pages/empty.publr", null);
    defer allocator.free(result);

    // Should still produce valid .zsx
    try testing.expect(mem.indexOf(u8, result, "pub fn render(ctx: anytype) {") != null);
    try testing.expect(mem.endsWith(u8, result, "}\n"));
}
