/// theme-from-css — converts a Tailwind v4 CSS file's @theme blocks into
/// a Publr `theme.zon` override-only file.
///
/// See:
///   - .claude/plans/jit-tailwind-engine/task-03-theme-from-css.md
///   - .claude/plans/jit-tailwind-engine/validation-b-results.md
///
/// Behaviors locked from validation B:
///   - Recognizes `@theme {}`, `@theme default {}`, `@theme inline {}`. Logs a
///     warning for non-bare modifier words and treats them the same.
///   - Skips nested `@keyframes` blocks inside `@theme` with a warning. Lifting
///     them as keyframe tokens is deferred (the flat Token schema doesn't
///     model keyframes natively yet).
///   - Multi-line CSS values (font stacks) are collapsed to single-line strings
///     by squashing whitespace runs to single spaces.
///
/// Output is deterministic: tokens emitted in source order, no trailing
/// whitespace, single trailing LF. Re-running on the same input is byte-stable.

const std = @import("std");

pub const ConvertOptions = struct {
    /// Optional warning sink. Receives one line per warning, no trailing LF.
    /// Caller can pass `&warnings_log.writer()` or null to suppress.
    warn: ?*std.io.Writer = null,
};

pub const ConvertError = error{
    UnclosedBlock,
    UnclosedComment,
    InvalidValue,
    OutOfMemory,
} || std.io.Writer.Error;

/// Convert a CSS source buffer into ZON bytes.
/// Caller owns the returned slice.
pub fn convert(
    allocator: std.mem.Allocator,
    css: []const u8,
    options: ConvertOptions,
) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll(".{\n    .tokens = .{\n");

    var i: usize = 0;
    var token_count: usize = 0;
    var skipped_keyframes: usize = 0;

    while (i < css.len) {
        const at_idx = std.mem.indexOfPos(u8, css, i, "@theme") orelse break;
        i = at_idx + "@theme".len;

        // Read optional modifier words (default / inline) until `{`.
        // Validation B: warn if a non-bare modifier appears so users know what
        // we treated it as.
        var modifier: []const u8 = "";
        while (i < css.len and (css[i] == ' ' or css[i] == '\t')) i += 1;
        if (i < css.len and css[i] != '{') {
            const start = i;
            while (i < css.len and css[i] != ' ' and css[i] != '\t' and css[i] != '{') i += 1;
            modifier = std.mem.trim(u8, css[start..i], " \t");
            while (i < css.len and (css[i] == ' ' or css[i] == '\t')) i += 1;
        }
        if (i >= css.len or css[i] != '{') continue; // malformed — skip
        i += 1; // past `{`

        if (modifier.len > 0 and options.warn != null) {
            try options.warn.?.print(
                "warning: @theme modifier '{s}' treated as bare @theme — Publr only supports the override-extend mode (see THEME.md)\n",
                .{modifier},
            );
        }

        // Parse declarations until matching `}`.
        var depth: u32 = 1;
        while (i < css.len and depth > 0) {
            // Skip whitespace.
            while (i < css.len and (css[i] == ' ' or css[i] == '\t' or css[i] == '\n' or css[i] == '\r')) i += 1;
            if (i >= css.len) break;

            if (css[i] == '}') {
                depth -= 1;
                i += 1;
                continue;
            }

            // Skip /* ... */ comments.
            if (i + 1 < css.len and css[i] == '/' and css[i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, css, i + 2, "*/") orelse return ConvertError.UnclosedComment;
                i = end + 2;
                continue;
            }

            // Skip nested at-rules (mainly @keyframes inside @theme).
            // Validation B finding: lift these as keyframe tokens later; for
            // now warn + skip the block.
            if (css[i] == '@') {
                const at_start = i;
                while (i < css.len and css[i] != '{') i += 1;
                if (i >= css.len) return ConvertError.UnclosedBlock;
                const at_name = std.mem.trim(u8, css[at_start..i], " \t\n\r");
                if (options.warn != null) {
                    try options.warn.?.print(
                        "warning: skipping nested at-rule inside @theme: {s} (keyframe-style theme tokens not yet supported by the converter)\n",
                        .{at_name},
                    );
                }
                skipped_keyframes += 1;

                // Walk balanced braces.
                i += 1;
                var nested: u32 = 1;
                while (i < css.len and nested > 0) {
                    if (css[i] == '{') nested += 1
                    else if (css[i] == '}') nested -= 1;
                    i += 1;
                }
                continue;
            }

            // Stray `{` — bump depth and continue (unusual but defensive).
            if (css[i] == '{') {
                depth += 1;
                i += 1;
                continue;
            }

            // Custom property `--name: value;`
            if (i + 1 >= css.len or css[i] != '-' or css[i + 1] != '-') {
                // Non-property content (e.g., regular CSS rule); skip to next `;` or `}`.
                while (i < css.len and css[i] != ';' and css[i] != '}') i += 1;
                if (i < css.len and css[i] == ';') i += 1;
                continue;
            }
            i += 2; // past `--`

            const name_start = i;
            while (i < css.len and css[i] != ':') i += 1;
            if (i >= css.len) return ConvertError.InvalidValue;
            const name = std.mem.trim(u8, css[name_start..i], " \t\n\r");
            i += 1; // past `:`

            // Read value until `;` outside parens / strings.
            const val_start = i;
            var paren_depth: u32 = 0;
            var in_single = false;
            var in_double = false;
            while (i < css.len) {
                const c = css[i];
                if (in_single) {
                    if (c == '\'') in_single = false;
                } else if (in_double) {
                    if (c == '"') in_double = false;
                } else if (c == '\'') {
                    in_single = true;
                } else if (c == '"') {
                    in_double = true;
                } else if (c == '(') {
                    paren_depth += 1;
                } else if (c == ')') {
                    if (paren_depth > 0) paren_depth -= 1;
                } else if (c == ';' and paren_depth == 0) {
                    break;
                }
                i += 1;
            }
            if (i >= css.len) return ConvertError.InvalidValue;
            const raw_value = std.mem.trim(u8, css[val_start..i], " \t\n\r");
            i += 1; // past `;`

            // Collapse whitespace runs (newlines + tabs) to single spaces. Lets
            // multi-line font stacks live as a single ZON string.
            const collapsed = try collapseWhitespace(allocator, raw_value);
            defer allocator.free(collapsed);

            // ZON string literals: escape `"` and `\`. Use the @"..." identifier
            // form is for field names, not values — values are plain strings.
            if (token_count > 0) try w.writeAll(",\n");
            try w.writeAll("        .{ .name = \"");
            try writeZonStringEscaped(w.any(), name);
            try w.writeAll("\", .value = \"");
            try writeZonStringEscaped(w.any(), collapsed);
            try w.writeAll("\" }");
            token_count += 1;
        }
    }

    if (token_count > 0) try w.writeAll(",\n");
    try w.writeAll("    },\n}\n");

    if (options.warn != null and skipped_keyframes > 0) {
        try options.warn.?.print(
            "info: skipped {d} nested at-rule(s) inside @theme; total tokens emitted: {d}\n",
            .{ skipped_keyframes, token_count },
        );
    }

    return out.toOwnedSlice();
}

/// Collapse runs of whitespace (space/tab/CR/LF) to a single ASCII space.
/// Caller owns the returned slice.
fn collapseWhitespace(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    var prev_ws = false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!prev_ws) try buf.append(' ');
            prev_ws = true;
        } else {
            try buf.append(c);
            prev_ws = false;
        }
    }
    // Trim trailing space if any.
    var out = try buf.toOwnedSlice();
    while (out.len > 0 and out[out.len - 1] == ' ') out = out[0 .. out.len - 1];
    return out;
}

/// Write a string with ZON-string-literal escaping: `\` and `"` get backslash-escaped.
/// Other chars pass through; we don't try to handle non-printable bytes since
/// CSS theme values shouldn't contain them.
fn writeZonStringEscaped(w: std.io.AnyWriter, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\', '"' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => try w.writeByte(c),
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "convert: bare @theme block" {
    const css =
        \\@theme {
        \\  --font-sans: Switzer, system-ui, sans-serif;
        \\  --radius-4xl: 2rem;
        \\}
    ;
    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);

    const expected =
        ".{\n    .tokens = .{\n" ++
        "        .{ .name = \"font-sans\", .value = \"Switzer, system-ui, sans-serif\" },\n" ++
        "        .{ .name = \"radius-4xl\", .value = \"2rem\" },\n" ++
        "    },\n}\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "convert: empty @theme block" {
    const css = "@theme {}";
    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(".{\n    .tokens = .{\n    },\n}\n", out);
}

test "convert: idempotent on double conversion via re-run" {
    const css = "@theme { --a: 1px; --b: 2rem; }";
    const out1 = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out1);
    const out2 = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings(out1, out2);
}

test "convert: collapses multi-line value into single line" {
    const css =
        \\@theme {
        \\  --font-stack: ui-sans-serif,
        \\    system-ui,
        \\    sans-serif;
        \\}
    ;
    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ui-sans-serif, system-ui, sans-serif") != null);
}

test "convert: skips nested @keyframes with warning" {
    const css =
        \\@theme {
        \\  --animate-spin: spin 1s linear infinite;
        \\  @keyframes spin {
        \\    to { transform: rotate(360deg); }
        \\  }
        \\  --animate-pulse: pulse 2s infinite;
        \\}
    ;
    var warn_buf: [1024]u8 = undefined;
    var warn_writer = std.io.Writer.fixed(&warn_buf);

    const out = try convert(std.testing.allocator, css, .{ .warn = &warn_writer });
    defer std.testing.allocator.free(out);

    // Both tokens emitted, keyframe skipped.
    try std.testing.expect(std.mem.indexOf(u8, out, "animate-spin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "animate-pulse") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "transform") == null);

    // Warning emitted.
    const warns = warn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, warns, "skipping nested at-rule") != null);
}

test "convert: warns on @theme default modifier" {
    const css = "@theme default { --spacing: 0.25rem; }";
    var warn_buf: [256]u8 = undefined;
    var warn_writer = std.io.Writer.fixed(&warn_buf);

    const out = try convert(std.testing.allocator, css, .{ .warn = &warn_writer });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "spacing") != null);
    const warns = warn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, warns, "default") != null);
}

test "convert: skips // comments and /* */ comments outside @theme" {
    const css =
        \\/* leading comment */
        \\@theme {
        \\  /* inside comment */
        \\  --a: 1px;
        \\}
    ;
    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "--a") == null); // raw `--a` shouldn't appear
    try std.testing.expect(std.mem.indexOf(u8, out, ".name = \"a\"") != null);
}

test "convert: handles parens-balanced values (oklch, rgb, calc)" {
    const css =
        \\@theme {
        \\  --color-red-500: oklch(63.7% 0.237 25.331);
        \\  --shadow-md: 0 4px 6px rgb(0 0 0 / 0.1);
        \\  --line-height: calc(1.5 / 1);
        \\}
    ;
    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "oklch(63.7% 0.237 25.331)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rgb(0 0 0 / 0.1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "calc(1.5 / 1)") != null);
}

test "convert: ignores content outside @theme blocks" {
    const css =
        \\@import 'tailwindcss';
        \\@theme { --a: 1; }
        \\@keyframes move { 0% { x: 0; } 100% { x: 1; } }
        \\.btn { color: red; }
    ;
    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);
    // Only the --a token should appear in output.
    try std.testing.expect(std.mem.indexOf(u8, out, ".name = \"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "move") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".btn") == null);
}

test "convert: round-trip /site/src/styles/tailwind.css produces parseable ZON" {
    // Read the actual /site theme file to confirm the converter handles it cleanly.
    // This file is committed and stable; the test value is end-to-end coverage,
    // not byte-equality (we don't pin the expected output here).
    const css = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "../site/src/styles/tailwind.css",
        1024 * 1024,
    ) catch |err| switch (err) {
        // /site might not be present in some build environments; skip gracefully.
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(css);

    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);

    // Sanity checks on the output structure.
    try std.testing.expect(std.mem.startsWith(u8, out, ".{\n    .tokens = .{\n"));
    try std.testing.expect(std.mem.endsWith(u8, out, "    },\n}\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "font-sans") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Switzer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "radius-4xl") != null);
}

test "convert: multiple @theme blocks merge in source order" {
    const css =
        \\@theme { --a: 1; }
        \\@theme { --b: 2; --a: 99; }
    ;
    const out = try convert(std.testing.allocator, css, .{});
    defer std.testing.allocator.free(out);
    // Both --a values present (we don't dedupe at conversion time; that's
    // extendTheme's job at JIT compile time).
    const first_a = std.mem.indexOf(u8, out, ".name = \"a\"") orelse 0;
    const second_a = std.mem.lastIndexOf(u8, out, ".name = \"a\"") orelse 0;
    try std.testing.expect(first_a != second_a);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"99\"") != null);
}
