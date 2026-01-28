const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const formatJsx = @import("zsx_fmt_jsx.zig").formatJsx;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zsx_format <dir>\n", .{});
        std.process.exit(1);
    }

    try formatDirectory(allocator, args[1]);
}

fn formatDirectory(allocator: Allocator, dir_path: []const u8) !void {
    var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.path, ".zsx")) {
            const full_path = try fs.path.join(allocator, &.{ dir_path, entry.path });
            defer allocator.free(full_path);
            try formatFile(allocator, full_path);
        }
    }
}

fn formatFile(allocator: Allocator, path: []const u8) !void {
    const source = try fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(source);

    // Extract JSX bodies and get Zig-valid source with placeholders
    var extraction = try extractBodies(allocator, source);
    defer extraction.deinit(allocator);

    // Run zig fmt on the modified source
    const formatted = runZigFmt(allocator, extraction.modified) catch extraction.modified;
    defer if (formatted.ptr != extraction.modified.ptr) allocator.free(formatted);

    // Re-insert original bodies (unformatted — task-02 will add JSX formatting)
    const result = try stitchBodies(allocator, formatted, extraction.bodies.items);
    defer allocator.free(result);

    // Only write if content changed
    if (!mem.eql(u8, result, source)) {
        var file = try fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(result);
        std.debug.print("Formatted: {s}\n", .{path});
    }
}

/// Result of extracting JSX function bodies from a ZSX source file.
const Extraction = struct {
    modified: []u8,
    bodies: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *Extraction, allocator: Allocator) void {
        allocator.free(self.modified);
        self.bodies.deinit(allocator);
    }
};

/// Scan ZSX source, find function bodies, replace with placeholders, inject void return types.
pub fn extractBodies(allocator: Allocator, source: []const u8) !Extraction {
    var output = std.ArrayListUnmanaged(u8){};
    var bodies = std.ArrayListUnmanaged([]const u8){};
    var pos: usize = 0;

    while (pos < source.len) {
        // Detect function declaration at current position
        const fn_match = matchFnKeyword(source, pos);
        if (fn_match) |fn_start| {
            // Copy everything before the fn keyword
            try output.appendSlice(allocator, source[pos..fn_start.keyword_pos]);

            // Copy the fn signature up to and including params
            const after_params = fn_start.after_params;
            try output.appendSlice(allocator, source[fn_start.keyword_pos..after_params]);

            // Check if there's already a return type before {
            var scan = after_params;
            while (scan < source.len and (source[scan] == ' ' or source[scan] == '\t' or source[scan] == '\n' or source[scan] == '\r')) {
                scan += 1;
            }

            if (scan < source.len and source[scan] == '{') {
                // No return type — inject void
                try output.appendSlice(allocator, " void ");
            } else {
                // There's something between ) and { — it's the return type
                // Find the opening brace first, then copy everything up to it
                var brace_pos = scan;
                while (brace_pos < source.len and source[brace_pos] != '{') brace_pos += 1;
                try output.appendSlice(allocator, source[after_params..brace_pos]);
                scan = brace_pos;
            }

            // scan should now be at the opening brace
            if (scan >= source.len) {
                // Malformed — copy rest verbatim
                try output.appendSlice(allocator, source[after_params..]);
                pos = source.len;
                continue;
            }

            try output.append(allocator, '{');
            scan += 1; // skip {

            // Extract body via brace matching
            const body_start = scan;
            var depth: usize = 1;
            while (scan < source.len and depth > 0) {
                if (source[scan] == '{') depth += 1;
                if (source[scan] == '}') depth -= 1;
                if (depth > 0) scan += 1;
            }
            const body = source[body_start..scan];

            // Stash body, emit placeholder
            try bodies.append(allocator, body);
            const block_idx = bodies.items.len - 1;
            var idx_buf: [20]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{block_idx}) catch unreachable;
            try output.appendSlice(allocator, "\n    _ = \"ZSX_BLOCK_");
            try output.appendSlice(allocator, idx_str);
            try output.appendSlice(allocator, "\";\n");

            // Skip past closing }
            if (scan < source.len) scan += 1;
            try output.append(allocator, '}');

            pos = scan;
        } else {
            // No fn keyword at this position — copy one byte and advance
            try output.append(allocator, source[pos]);
            pos += 1;
        }
    }

    return .{
        .modified = try output.toOwnedSlice(allocator),
        .bodies = bodies,
    };
}

const FnMatch = struct {
    keyword_pos: usize,
    after_params: usize,
};

/// Check if source at `pos` starts a file-level function declaration.
/// Returns positions if matched, null otherwise.
fn matchFnKeyword(source: []const u8, pos: usize) ?FnMatch {
    // Must be at start of line (pos == 0 or preceded by newline)
    if (pos > 0 and source[pos - 1] != '\n') return null;

    var p = pos;

    // Skip leading whitespace on line (shouldn't be any for file-level, but be tolerant)
    while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;

    const keyword_pos = p;

    // Match "pub fn " or "fn "
    if (p + 7 <= source.len and mem.eql(u8, source[p .. p + 7], "pub fn ")) {
        p += 7;
    } else if (p + 3 <= source.len and mem.eql(u8, source[p .. p + 3], "fn ")) {
        p += 3;
    } else {
        return null;
    }

    // Skip function name
    while (p < source.len and (std.ascii.isAlphanumeric(source[p]) or source[p] == '_')) {
        p += 1;
    }

    // Skip whitespace
    while (p < source.len and (source[p] == ' ' or source[p] == '\t' or source[p] == '\n' or source[p] == '\r')) {
        p += 1;
    }

    // Must find opening paren
    if (p >= source.len or source[p] != '(') return null;
    p += 1;

    // Match balanced parens
    var depth: usize = 1;
    while (p < source.len and depth > 0) {
        if (source[p] == '(') depth += 1;
        if (source[p] == ')') depth -= 1;
        if (depth > 0) p += 1;
    }
    if (depth != 0) return null;
    p += 1; // skip closing )

    return .{
        .keyword_pos = keyword_pos,
        .after_params = p,
    };
}

/// Pipe source through `zig fmt --stdin` and return formatted output.
fn runZigFmt(allocator: Allocator, source: []const u8) ![]u8 {
    var child = std.process.Child.init(
        &.{ "zig", "fmt", "--stdin" },
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Write source to stdin and close
    child.stdin.?.writeAll(source) catch {};
    child.stdin.?.close();
    child.stdin = null;

    // Read stdout
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);

    // Drain stderr so the child doesn't block
    if (child.stderr.?.readToEndAlloc(allocator, 64 * 1024)) |stderr| {
        allocator.free(stderr);
    } else |_| {}

    const term = try child.wait();
    if (term.Exited != 0) {
        allocator.free(stdout);
        return error.ZigFmtFailed;
    }

    return stdout;
}

/// Replace placeholders with formatted JSX bodies and strip injected void return types.
fn stitchBodies(allocator: Allocator, formatted: []const u8, bodies: []const []const u8) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};

    var pos: usize = 0;
    while (pos < formatted.len) {
        // Look for placeholder pattern: _ = "ZSX_BLOCK_N";
        if (mem.startsWith(u8, formatted[pos..], "_ = \"ZSX_BLOCK_")) {
            const idx_start = pos + "_ = \"ZSX_BLOCK_".len;
            const idx_end = mem.indexOfPos(u8, formatted, idx_start, "\";") orelse {
                try output.append(allocator, formatted[pos]);
                pos += 1;
                continue;
            };

            const idx_str = formatted[idx_start..idx_end];
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                try output.append(allocator, formatted[pos]);
                pos += 1;
                continue;
            };

            if (idx < bodies.len) {
                // Find start of placeholder line and measure its indentation
                const line_start = if (mem.lastIndexOfScalar(u8, formatted[0..pos], '\n')) |nl| nl + 1 else 0;
                const indent_len = pos - line_start; // spaces before "_ = ..."
                const base_indent = indent_len / 4; // convert spaces to indent levels (4 spaces per level)

                // Truncate output back to before the placeholder line
                const truncate_to = if (line_start > 0) line_start - 1 else 0;
                output.shrinkRetainingCapacity(output.items.len - (pos - truncate_to));

                // Format the JSX body with the correct base indentation
                const formatted_body = formatJsx(allocator, bodies[idx], base_indent) catch bodies[idx];
                defer if (formatted_body.ptr != bodies[idx].ptr) allocator.free(formatted_body);

                // Append the formatted body (prepend newline since we removed it with truncation)
                try output.append(allocator, '\n');
                try output.appendSlice(allocator, formatted_body);
            }

            pos = idx_end + 2; // skip past ";
            // Skip trailing newline if present
            if (pos < formatted.len and formatted[pos] == '\n') pos += 1;
        } else if (mem.startsWith(u8, formatted[pos..], ") void {")) {
            // Strip injected void — restore ZSX convention
            try output.appendSlice(allocator, ") {");
            pos += ") void {".len;
        } else {
            try output.append(allocator, formatted[pos]);
            pos += 1;
        }
    }

    return try output.toOwnedSlice(allocator);
}

// Tests
test "extract bodies — single function" {
    const allocator = std.testing.allocator;
    const source =
        \\pub fn Hello() {
        \\    <div>Hello</div>
        \\}
    ;

    var extraction = try extractBodies(allocator, source);
    defer extraction.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), extraction.bodies.items.len);
    try std.testing.expect(mem.indexOf(u8, extraction.modified, "ZSX_BLOCK_0") != null);
    try std.testing.expect(mem.indexOf(u8, extraction.modified, "void") != null);
    try std.testing.expect(mem.indexOf(u8, extraction.bodies.items[0], "<div>Hello</div>") != null);
}

test "extract bodies — multiple functions" {
    const allocator = std.testing.allocator;
    const source =
        \\pub fn Foo() {
        \\    <div>Foo</div>
        \\}
        \\
        \\pub fn Bar() {
        \\    <span>Bar</span>
        \\}
    ;

    var extraction = try extractBodies(allocator, source);
    defer extraction.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), extraction.bodies.items.len);
    try std.testing.expect(mem.indexOf(u8, extraction.modified, "ZSX_BLOCK_0") != null);
    try std.testing.expect(mem.indexOf(u8, extraction.modified, "ZSX_BLOCK_1") != null);
}

test "extract bodies — zig-only file" {
    const allocator = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\const Foo = struct { x: u32 };
    ;

    var extraction = try extractBodies(allocator, source);
    defer extraction.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), extraction.bodies.items.len);
    try std.testing.expectEqualStrings(source, extraction.modified);
}

test "extract bodies — preserves const and comments" {
    const allocator = std.testing.allocator;
    const source =
        \\// A comment
        \\const X = 42;
        \\
        \\pub fn Foo() {
        \\    <div>test</div>
        \\}
    ;

    var extraction = try extractBodies(allocator, source);
    defer extraction.deinit(allocator);

    try std.testing.expect(mem.indexOf(u8, extraction.modified, "// A comment") != null);
    try std.testing.expect(mem.indexOf(u8, extraction.modified, "const X = 42;") != null);
    try std.testing.expectEqual(@as(usize, 1), extraction.bodies.items.len);
}

test "void injection — no return type" {
    const allocator = std.testing.allocator;
    const source =
        \\pub fn Foo() {
        \\    <div />
        \\}
    ;

    var extraction = try extractBodies(allocator, source);
    defer extraction.deinit(allocator);

    try std.testing.expect(mem.indexOf(u8, extraction.modified, ") void {") != null);
}

test "existing return type — not double-injected" {
    const allocator = std.testing.allocator;
    const source =
        \\pub fn Foo() !void {
        \\    <div />
        \\}
    ;

    var extraction = try extractBodies(allocator, source);
    defer extraction.deinit(allocator);

    // Should have !void, not !void void or void !void
    try std.testing.expect(mem.indexOf(u8, extraction.modified, "void void") == null);
    try std.testing.expect(mem.indexOf(u8, extraction.modified, "!void") != null);
}

test "stitch bodies — replaces placeholder and strips void" {
    const allocator = std.testing.allocator;
    const formatted =
        \\pub fn Foo() void {
        \\    _ = "ZSX_BLOCK_0";
        \\}
    ;
    const bodies = [_][]const u8{
        "\n    <div>Hello</div>\n",
    };

    const result = try stitchBodies(allocator, formatted, &bodies);
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, ") {") != null);
    try std.testing.expect(mem.indexOf(u8, result, ") void {") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<div>Hello</div>") != null);
    try std.testing.expect(mem.indexOf(u8, result, "ZSX_BLOCK") == null);
}
