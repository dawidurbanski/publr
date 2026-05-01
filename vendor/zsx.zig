// ZSX Amalgamation — generated from zsx/src/*.zig
// Do not edit directly. Regenerate: ./scripts/amalgamate-zsx.sh

pub const runtime = struct {
const std = @import("std");

/// HTML-escape a string for safe output
pub fn escape(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#x27;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Render an integer (no escaping needed)
pub fn renderInt(writer: anytype, value: anytype) !void {
    try writer.print("{d}", .{value});
}

/// Render a value based on its type
pub fn render(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);

    // Handle []const u8 (strings) directly
    if (T == []const u8) {
        try escape(writer, value);
        return;
    }

    // Handle *const [N]u8 (string literals)
    const info = @typeInfo(T);
    switch (info) {
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .pointer => |ptr| {
            // Check for pointer to u8 array (string literal type)
            const child_info = @typeInfo(ptr.child);
            if (child_info == .array and child_info.array.child == u8) {
                try escape(writer, value);
            } else if (ptr.size == .one) {
                try render(writer, value.*);
            } else {
                try writer.print("{s}", .{value});
            }
        },
        .@"enum" => try escape(writer, @tagName(value)),
        .@"fn" => {
            try value(writer);
            return;
        },
        .optional => {
            if (value) |v| {
                try render(writer, v);
            }
        },
        else => try writer.print("{any}", .{value}),
    }
}

/// Compute return type for withDefaults: if all Defaults fields exist in Raw,
/// return Raw directly (preserving original types); otherwise return Defaults.
fn WithDefaultsReturn(comptime Defaults: type, comptime Raw: type) type {
    for (@typeInfo(Defaults).@"struct".fields) |field| {
        if (!@hasField(Raw, field.name)) return Defaults;
    }
    return Raw;
}

/// Merge props with defaults: fields present in raw are used as-is,
/// missing fields get their default values from the Defaults type.
/// When all fields are present, returns raw directly (no type coercion).
pub fn withDefaults(comptime Defaults: type, raw: anytype) WithDefaultsReturn(Defaults, @TypeOf(raw)) {
    const needs_defaults = comptime needs: {
        for (@typeInfo(Defaults).@"struct".fields) |field| {
            if (!@hasField(@TypeOf(raw), field.name)) break :needs true;
        }
        break :needs false;
    };

    if (needs_defaults) {
        var result: Defaults = undefined;
        inline for (@typeInfo(Defaults).@"struct".fields) |field| {
            if (@hasField(@TypeOf(raw), field.name)) {
                @field(result, field.name) = @field(raw, field.name);
            } else {
                @field(result, field.name) = field.defaultValue().?;
            }
        }
        return result;
    } else {
        return raw;
    }
}

/// Concatenate class strings with spaces. Comptime string builder for class attributes.
/// Usage: class={mix(.{"flex", "gap-md", font, pad})}
pub inline fn mix(comptime parts: anytype) []const u8 {
    comptime var result: []const u8 = "";
    inline for (parts) |part| {
        if (part.len > 0) {
            result = result ++ (if (result.len == 0) "" else " ") ++ part;
        }
    }
    return result;
}

};

pub const fmt_jsx = struct {
const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const Out = std.ArrayListUnmanaged(u8);

/// Format a JSX function body with tag-aware indentation.
/// Takes the raw body text (between function braces) and a base indent level.
/// Returns formatted text with proper indentation.
pub fn formatJsx(allocator: Allocator, body: []const u8, base_indent: usize) Allocator.Error![]u8 {
    var out = Out{};
    errdefer out.deinit(allocator);

    var indent = base_indent;
    var pos: usize = 0;

    while (pos < body.len) {
        // Skip blank lines / leading whitespace on current line
        pos = skipWhitespace(body, pos);
        if (pos >= body.len) break;

        // Newlines: skip and continue
        if (body[pos] == '\n') {
            pos += 1;
            continue;
        }

        // Closing tag: </tag>
        if (pos + 1 < body.len and body[pos] == '<' and body[pos + 1] == '/') {
            const end = mem.indexOfScalarPos(u8, body, pos, '>') orelse break;
            if (indent > 0) indent -= 1;
            try writeIndent(allocator, &out, indent);
            try out.appendSlice(allocator, body[pos .. end + 1]);
            try out.append(allocator, '\n');
            pos = end + 1;
            continue;
        }

        // DOCTYPE
        if (body.len > pos + 9 and mem.startsWith(u8, body[pos..], "<!DOCTYPE") or
            (body.len > pos + 9 and mem.startsWith(u8, body[pos..], "<!doctype")))
        {
            const end = mem.indexOfScalarPos(u8, body, pos, '>') orelse break;
            try writeIndent(allocator, &out, indent);
            try out.appendSlice(allocator, body[pos .. end + 1]);
            try out.append(allocator, '\n');
            pos = end + 1;
            continue;
        }

        // HTML comment <!-- ... -->
        if (body.len > pos + 4 and mem.startsWith(u8, body[pos..], "<!--")) {
            const end = mem.indexOf(u8, body[pos..], "-->") orelse break;
            const abs_end = pos + end + 3;
            try writeIndent(allocator, &out, indent);
            try out.appendSlice(allocator, body[pos..abs_end]);
            try out.append(allocator, '\n');
            pos = abs_end;
            continue;
        }

        // Opening tag or self-closing
        if (body[pos] == '<' and pos + 1 < body.len and (std.ascii.isAlphabetic(body[pos + 1]) or body[pos + 1] == '!')) {
            const tag_result = parseTag(body, pos);
            if (tag_result.end > pos) {
                const tag_text = body[pos..tag_result.end];
                const is_self_closing = tag_result.self_closing;
                const is_void = tag_result.is_void;

                // Check for inline content: <tag>content</tag> on one line
                if (!is_self_closing and !is_void) {
                    const after_tag = tag_result.end;
                    const line_end = mem.indexOfScalarPos(u8, body, after_tag, '\n') orelse body.len;
                    const rest_of_line = body[after_tag..line_end];
                    // Look for closing tag on same line
                    const close_tag = std.fmt.allocPrint(allocator, "</{s}>", .{tag_result.tag_name}) catch unreachable;
                    defer allocator.free(close_tag);
                    if (mem.indexOf(u8, rest_of_line, close_tag)) |close_pos| {
                        // Emit entire inline: <tag>content</tag>
                        const full_end = after_tag + close_pos + close_tag.len;
                        if (needsAttrWrapping(tag_text, indent)) {
                            // Wrap attributes, then emit content + close tag on new line
                            try writeWrappedTag(allocator, &out, tag_text, indent, tag_result.tag_name);
                            try out.append(allocator, '\n');
                            try writeIndent(allocator, &out, indent + 1);
                            try out.appendSlice(allocator, mem.trim(u8, rest_of_line[0..close_pos], " \t"));
                            try out.append(allocator, '\n');
                            try writeIndent(allocator, &out, indent);
                            try out.appendSlice(allocator, close_tag);
                        } else {
                            try writeIndent(allocator, &out, indent);
                            try out.appendSlice(allocator, body[pos..full_end]);
                        }
                        try out.append(allocator, '\n');
                        pos = full_end;
                        continue;
                    }
                }

                // Check if attributes need wrapping
                if (needsAttrWrapping(tag_text, indent)) {
                    try writeWrappedTag(allocator, &out, tag_text, indent, tag_result.tag_name);
                } else {
                    try writeIndent(allocator, &out, indent);
                    try out.appendSlice(allocator, tag_text);
                }
                try out.append(allocator, '\n');

                if (!is_self_closing and !is_void) {
                    indent += 1;
                }

                pos = tag_result.end;
                continue;
            }
        }

        // Expression: {expr} or {!expr}
        if (body[pos] == '{') {
            // Check if this is control flow
            const inner_start = pos + 1;
            const trimmed = skipWhitespace(body, inner_start);

            if (trimmed < body.len and (mem.startsWith(u8, body[trimmed..], "if ") or mem.startsWith(u8, body[trimmed..], "if("))) {
                pos = try formatControlFlow(allocator, &out, body, pos, indent, .if_else);
                continue;
            }

            if (trimmed < body.len and (mem.startsWith(u8, body[trimmed..], "for ") or mem.startsWith(u8, body[trimmed..], "for("))) {
                pos = try formatControlFlow(allocator, &out, body, pos, indent, .for_loop);
                continue;
            }

            // Simple expression
            const expr_end = findMatchingBrace(body, pos);
            if (expr_end > pos) {
                try writeIndent(allocator, &out, indent);
                try out.appendSlice(allocator, body[pos..expr_end]);
                try out.append(allocator, '\n');
                pos = expr_end;
                continue;
            }
        }

        // Text node or Zig code pass-through: consume to end of line
        const line_end = mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const line = mem.trim(u8, body[pos..line_end], " \t");
        if (line.len > 0) {
            try writeIndent(allocator, &out, indent);
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
        pos = if (line_end < body.len) line_end + 1 else body.len;
    }

    return out.toOwnedSlice(allocator);
}

const ControlFlowKind = enum { if_else, for_loop };

/// Format {if (cond) (...) else (...)} or {for (iter) |cap| (...)}
fn formatControlFlow(allocator: Allocator, out: *Out, body: []const u8, start: usize, indent: usize, kind: ControlFlowKind) Allocator.Error!usize {
    // Find the matching closing brace for the entire expression
    const expr_end = findMatchingBrace(body, start);
    if (expr_end <= start) {
        // Couldn't parse — emit as-is
        try writeIndent(allocator, out, indent);
        const line_end = mem.indexOfScalarPos(u8, body, start, '\n') orelse body.len;
        try out.appendSlice(allocator, body[start..line_end]);
        try out.append(allocator, '\n');
        return if (line_end < body.len) line_end + 1 else body.len;
    }

    const expr = body[start..expr_end];

    // For simple single-line expressions that fit, emit inline
    if (mem.indexOfScalar(u8, expr, '\n') == null and expr.len + indent * 4 <= 80) {
        try writeIndent(allocator, out, indent);
        try out.appendSlice(allocator, expr);
        try out.append(allocator, '\n');
        return expr_end;
    }

    // Multi-line: extract and format the parts
    const inner = body[start + 1 .. expr_end - 1];
    const inner_trimmed_start = skipWhitespace(inner, 0);

    switch (kind) {
        .if_else => {
            try writeIndent(allocator, out, indent);
            const keyword_end = findPastCondition(inner, inner_trimmed_start);
            if (keyword_end) |ke| {
                // Emit "{if (cond) (" — header is everything up to body_start minus the opening paren
                try out.appendSlice(allocator, "{");
                try out.appendSlice(allocator, mem.trim(u8, inner[inner_trimmed_start .. ke.body_start - 1], " \t\n"));
                try out.appendSlice(allocator, " (\n");

                const if_body = inner[ke.body_start..ke.body_end];
                const formatted_if = try formatJsx(allocator, if_body, indent + 1);
                defer allocator.free(formatted_if);
                try out.appendSlice(allocator, formatted_if);

                // Check for else
                var after_body = skipWhitespace(inner, ke.body_end);
                if (after_body < inner.len and inner[after_body] == ')') after_body += 1;
                after_body = skipWhitespace(inner, after_body);

                if (after_body < inner.len and mem.startsWith(u8, inner[after_body..], "else")) {
                    after_body += 4;
                    after_body = skipWhitespace(inner, after_body);

                    try writeIndent(allocator, out, indent);
                    try out.appendSlice(allocator, ") else (\n");

                    if (after_body < inner.len and inner[after_body] == '(') {
                        after_body += 1;
                        const else_paren_end = findMatchingParen(inner, after_body - 1);
                        const else_body = inner[after_body .. else_paren_end - 1];
                        const formatted_else = try formatJsx(allocator, else_body, indent + 1);
                        defer allocator.free(formatted_else);
                        try out.appendSlice(allocator, formatted_else);
                    }
                    try writeIndent(allocator, out, indent);
                    try out.appendSlice(allocator, ")}\n");
                } else {
                    try writeIndent(allocator, out, indent);
                    try out.appendSlice(allocator, ")}\n");
                }
            } else {
                try out.appendSlice(allocator, expr);
                try out.append(allocator, '\n');
            }
        },
        .for_loop => {
            try writeIndent(allocator, out, indent);
            const keyword_end = findPastForHeader(inner, inner_trimmed_start);
            if (keyword_end) |ke| {
                try out.appendSlice(allocator, "{");
                try out.appendSlice(allocator, mem.trim(u8, inner[inner_trimmed_start .. ke.body_start - 1], " \t\n"));
                try out.appendSlice(allocator, " (\n");

                const for_body = inner[ke.body_start..ke.body_end];
                const formatted_for = try formatJsx(allocator, for_body, indent + 1);
                defer allocator.free(formatted_for);
                try out.appendSlice(allocator, formatted_for);

                try writeIndent(allocator, out, indent);
                try out.appendSlice(allocator, ")}\n");
            } else {
                try out.appendSlice(allocator, expr);
                try out.append(allocator, '\n');
            }
        },
    }

    return expr_end;
}

const CondResult = struct {
    body_start: usize,
    body_end: usize,
};

/// Find past "if (cond) (" and return the body range inside the parens
fn findPastCondition(inner: []const u8, start: usize) ?CondResult {
    var pos = start;
    if (!mem.startsWith(u8, inner[pos..], "if")) return null;
    pos += 2;
    pos = skipWhitespace(inner, pos);

    if (pos >= inner.len or inner[pos] != '(') return null;
    const cond_end = findMatchingParen(inner, pos);
    if (cond_end == 0) return null;
    pos = cond_end;
    pos = skipWhitespace(inner, pos);

    if (pos >= inner.len or inner[pos] != '(') return null;
    const body_paren_end = findMatchingParen(inner, pos);
    if (body_paren_end == 0) return null;

    return .{
        .body_start = pos + 1,
        .body_end = body_paren_end - 1,
    };
}

/// Find past "for (iter) |cap| (" and return the body range
fn findPastForHeader(inner: []const u8, start: usize) ?CondResult {
    var pos = start;
    if (!mem.startsWith(u8, inner[pos..], "for")) return null;
    pos += 3;
    pos = skipWhitespace(inner, pos);

    if (pos >= inner.len or inner[pos] != '(') return null;
    const iter_end = findMatchingParen(inner, pos);
    if (iter_end == 0) return null;
    pos = iter_end;
    pos = skipWhitespace(inner, pos);

    if (pos < inner.len and inner[pos] == '|') {
        const cap_end = mem.indexOfScalarPos(u8, inner, pos + 1, '|') orelse return null;
        pos = cap_end + 1;
        pos = skipWhitespace(inner, pos);
    }

    if (pos >= inner.len or inner[pos] != '(') return null;
    const body_paren_end = findMatchingParen(inner, pos);
    if (body_paren_end == 0) return null;

    return .{
        .body_start = pos + 1,
        .body_end = body_paren_end - 1,
    };
}

const TagParseResult = struct {
    end: usize,
    self_closing: bool,
    is_void: bool,
    tag_name: []const u8,
};

fn parseTag(body: []const u8, start: usize) TagParseResult {
    var pos = start + 1; // skip <

    const name_start = pos;
    while (pos < body.len and (std.ascii.isAlphanumeric(body[pos]) or body[pos] == '-' or body[pos] == '_')) {
        pos += 1;
    }
    const tag_name = body[name_start..pos];

    while (pos < body.len and body[pos] != '>') {
        if (body[pos] == '/' and pos + 1 < body.len and body[pos + 1] == '>') {
            return .{
                .end = pos + 2,
                .self_closing = true,
                .is_void = false,
                .tag_name = tag_name,
            };
        }
        if (body[pos] == '{') {
            const brace_end = findMatchingBrace(body, pos);
            pos = if (brace_end > pos) brace_end else pos + 1;
            continue;
        }
        if (body[pos] == '"') {
            pos += 1;
            while (pos < body.len and body[pos] != '"') pos += 1;
            if (pos < body.len) pos += 1;
            continue;
        }
        pos += 1;
    }

    if (pos < body.len and body[pos] == '>') pos += 1;

    return .{
        .end = pos,
        .self_closing = false,
        .is_void = isVoidElement(tag_name),
        .tag_name = tag_name,
    };
}

fn isVoidElement(name: []const u8) bool {
    const void_elements = [_][]const u8{
        "area", "base", "br",     "col",   "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    };
    for (&void_elements) |ve| {
        if (mem.eql(u8, name, ve)) return true;
    }
    return false;
}

fn needsAttrWrapping(tag_text: []const u8, indent: usize) bool {
    const first_space = mem.indexOfScalar(u8, tag_text, ' ') orelse return false;
    const after_name = tag_text[first_space..];
    const trimmed = mem.trimLeft(u8, after_name, " ");
    if (trimmed.len == 0 or trimmed[0] == '>' or (trimmed[0] == '/' and trimmed.len > 1 and trimmed[1] == '>')) {
        return false;
    }
    return tag_text.len + indent * 4 > 80;
}

fn writeWrappedTag(allocator: Allocator, out: *Out, tag_text: []const u8, indent: usize, tag_name: []const u8) Allocator.Error!void {
    try writeIndent(allocator, out, indent);
    try out.append(allocator, '<');
    try out.appendSlice(allocator, tag_name);
    try out.append(allocator, '\n');

    var pos: usize = 1 + tag_name.len; // skip < and tag name
    const attr_indent = indent + 1;

    while (pos < tag_text.len) {
        // Skip whitespace including newlines (for already-wrapped tags)
        while (pos < tag_text.len and (tag_text[pos] == ' ' or tag_text[pos] == '\t' or tag_text[pos] == '\n' or tag_text[pos] == '\r')) {
            pos += 1;
        }
        if (pos >= tag_text.len) break;

        if (tag_text[pos] == '>' or (tag_text[pos] == '/' and pos + 1 < tag_text.len and tag_text[pos + 1] == '>')) {
            break;
        }

        const attr_start = pos;
        while (pos < tag_text.len and tag_text[pos] != '=' and tag_text[pos] != ' ' and tag_text[pos] != '>' and tag_text[pos] != '/' and tag_text[pos] != '\n') {
            pos += 1;
        }

        if (pos < tag_text.len and tag_text[pos] == '=') {
            pos += 1;
            if (pos < tag_text.len and tag_text[pos] == '"') {
                pos += 1;
                while (pos < tag_text.len and tag_text[pos] != '"') pos += 1;
                if (pos < tag_text.len) pos += 1;
            } else if (pos < tag_text.len and tag_text[pos] == '{') {
                const brace_end = findMatchingBrace(tag_text, pos);
                pos = if (brace_end > pos) brace_end else pos + 1;
            }
        }

        const attr_text = tag_text[attr_start..pos];
        if (attr_text.len > 0) {
            try writeIndent(allocator, out, attr_indent);
            try out.appendSlice(allocator, attr_text);
            try out.append(allocator, '\n');
        }
    }

    try writeIndent(allocator, out, indent);
    if (mem.endsWith(u8, tag_text, "/>")) {
        try out.appendSlice(allocator, "/>");
    } else {
        try out.append(allocator, '>');
    }
}

fn findMatchingBrace(text: []const u8, start: usize) usize {
    if (start >= text.len or text[start] != '{') return 0;
    var depth: usize = 0;
    var pos = start;
    while (pos < text.len) {
        if (text[pos] == '{') {
            depth += 1;
        } else if (text[pos] == '}') {
            depth -= 1;
            if (depth == 0) return pos + 1;
        } else if (text[pos] == '"') {
            pos += 1;
            while (pos < text.len and text[pos] != '"') {
                if (text[pos] == '\\') pos += 1;
                pos += 1;
            }
        }
        pos += 1;
    }
    return 0;
}

fn findMatchingParen(text: []const u8, start: usize) usize {
    if (start >= text.len or text[start] != '(') return 0;
    var depth: usize = 0;
    var pos = start;
    while (pos < text.len) {
        if (text[pos] == '(') {
            depth += 1;
        } else if (text[pos] == ')') {
            depth -= 1;
            if (depth == 0) return pos + 1;
        } else if (text[pos] == '"') {
            pos += 1;
            while (pos < text.len and text[pos] != '"') {
                if (text[pos] == '\\') pos += 1;
                pos += 1;
            }
        }
        pos += 1;
    }
    return 0;
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var pos = start;
    while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t' or text[pos] == '\r')) {
        pos += 1;
    }
    return pos;
}

fn skipWhitespaceInline(text: []const u8, start: usize) usize {
    var pos = start;
    while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) {
        pos += 1;
    }
    return pos;
}

fn writeIndent(allocator: Allocator, out: *Out, level: usize) Allocator.Error!void {
    for (0..level) |_| {
        try out.appendSlice(allocator, "    ");
    }
}

};

pub const format = struct {
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const formatJsx = fmt_jsx.formatJsx;

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

};

pub const transpile = struct {
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: zsx_transpile <input_dir> <output_dir>\n", .{});
        std.process.exit(1);
    }

    const input_dir = args[1];
    const output_dir = args[2];

    try transpileDirectory(allocator, input_dir, output_dir);
}

fn transpileDirectory(allocator: Allocator, input_dir: []const u8, output_dir: []const u8) !void {
    // Ensure output directory exists
    fs.cwd().makePath(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Phase 1: Collect all .zsx file paths
    var zsx_files = std.ArrayListUnmanaged([]u8){};
    defer {
        for (zsx_files.items) |f| allocator.free(f);
        zsx_files.deinit(allocator);
    }

    {
        var dir = try fs.cwd().openDir(input_dir, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.path, ".zsx")) {
                const duped = try allocator.dupe(u8, entry.path);
                try zsx_files.append(allocator, duped);
            } else if (entry.kind == .directory) {
                const sub_output = try fs.path.join(allocator, &.{ output_dir, entry.path });
                defer allocator.free(sub_output);
                fs.cwd().makePath(sub_output) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
            }
        }
    }

    // Build component registry (PascalCase name → relative .zsx path under components/)
    var component_registry = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var key_iter = component_registry.keyIterator();
        while (key_iter.next()) |key| allocator.free(key.*);
        component_registry.deinit(allocator);
    }

    for (zsx_files.items) |rel_path| {
        // Check if this file is under components/ or layouts/ directory
        const is_component = mem.startsWith(u8, rel_path, "components/") or mem.startsWith(u8, rel_path, "components\\");
        const is_layout = mem.startsWith(u8, rel_path, "layouts/") or mem.startsWith(u8, rel_path, "layouts\\");
        if (is_component or is_layout) {
            const basename = fs.path.basename(rel_path);
            const name_no_ext = basename[0 .. basename.len - 4]; // strip .zsx
            // Convert to PascalCase component name
            if (toPascalCase(allocator, name_no_ext)) |pascal_name| {
                try component_registry.put(allocator, pascal_name, rel_path);
            } else |_| {}
        }
    }

    // Phase 2a: Extract class patterns from component sources
    var component_class_patterns = std.StringHashMapUnmanaged([]const ClassPattern){};
    defer {
        var pat_iter = component_class_patterns.iterator();
        while (pat_iter.next()) |entry| {
            for (entry.value_ptr.*) |p| {
                allocator.free(p.prefix);
                allocator.free(p.prop_name);
                if (p.value_map) |vm| {
                    for (vm) |m| {
                        allocator.free(m.enum_value);
                        allocator.free(m.classes);
                    }
                    allocator.free(vm);
                }
            }
            allocator.free(entry.value_ptr.*);
        }
        component_class_patterns.deinit(allocator);
    }

    {
        var reg_iter = component_registry.iterator();
        while (reg_iter.next()) |entry| {
            const comp_name = entry.key_ptr.*;
            const comp_rel = entry.value_ptr.*;
            const comp_path = try fs.path.join(allocator, &.{ input_dir, comp_rel });
            defer allocator.free(comp_path);

            const comp_source = fs.cwd().readFileAlloc(allocator, comp_path, 1024 * 1024) catch continue;
            defer allocator.free(comp_source);

            const patterns = extractClassPatterns(allocator, comp_source) catch continue;
            if (patterns.len > 0) {
                try component_class_patterns.put(allocator, comp_name, patterns);
            } else {
                allocator.free(patterns);
            }
        }
    }

    // Phase 2: Transpile each file
    var css_classes = std.StringHashMapUnmanaged(void){};
    defer {
        var css_it = css_classes.keyIterator();
        while (css_it.next()) |key| allocator.free(key.*);
        css_classes.deinit(allocator);
    }

    for (zsx_files.items) |rel_path| {
        try transpileFile(allocator, input_dir, output_dir, rel_path, &component_registry, &css_classes, &component_class_patterns);
    }

    // Write css_classes.txt to output dir
    {
        const css_path = try std.fmt.allocPrint(allocator, "{s}/css_classes.txt", .{output_dir});
        defer allocator.free(css_path);

        var css_file = try fs.cwd().createFile(css_path, .{});
        defer css_file.close();

        var class_iter = css_classes.keyIterator();
        while (class_iter.next()) |key| {
            try css_file.writeAll(key.*);
            try css_file.writeAll("\n");
        }
    }

    // Phase 3: Generate views.zig namespace module
    try generateViewsModule(allocator, output_dir, zsx_files.items);

    // Phase 4: Generate gallery_defaults.zig (imports gallery.zon from each component dir)
    try generateGalleryDefaults(allocator, input_dir, output_dir, zsx_files.items);
}

fn transpileFile(
    allocator: Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
    rel_path: []const u8,
    component_registry: *const std.StringHashMapUnmanaged([]const u8),
    css_classes: ?*std.StringHashMapUnmanaged(void),
    component_class_patterns: ?*const std.StringHashMapUnmanaged([]const ClassPattern),
) !void {
    const input_path = try fs.path.join(allocator, &.{ input_dir, rel_path });
    defer allocator.free(input_path);

    // Generate output path: foo/bar.zsx -> foo/bar.zig
    const base = rel_path[0 .. rel_path.len - 4]; // strip .zsx
    const zig_name = try makeZigName(allocator, base);
    defer allocator.free(zig_name);

    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ output_dir, zig_name });
    defer allocator.free(output_path);

    const source = try fs.cwd().readFileAlloc(allocator, input_path, 1024 * 1024);
    defer allocator.free(source);

    // Skip Zig generation if output is newer than input, but always collect CSS classes
    const input_stat = try fs.cwd().statFile(input_path);
    const skip_zig_gen = if (fs.cwd().statFile(output_path)) |output_stat|
        output_stat.mtime >= input_stat.mtime
    else |_|
        false;

    // Scan for PascalCase component usage and build imports
    var component_imports = std.ArrayListUnmanaged(ComponentImport){};
    defer {
        for (component_imports.items) |ci| allocator.free(ci.import_path);
        component_imports.deinit(allocator);
    }
    try scanComponentUsage(allocator, source, rel_path, component_registry, &component_imports);

    // Parse and generate
    var parser = Parser.init(allocator, source, input_path);
    defer parser.deinit();
    parser.component_imports = component_imports.items;
    parser.css_classes = css_classes;
    parser.component_class_patterns = component_class_patterns;
    const zig_code = try parser.generate();
    defer allocator.free(zig_code);

    // Write output (skip if Zig is already up to date)
    if (!skip_zig_gen) {
        const out_dir = fs.path.dirname(output_path) orelse ".";
        fs.cwd().makePath(out_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var file = try fs.cwd().createFile(output_path, .{});
        defer file.close();
        try file.writeAll(zig_code);
    }
}

pub const ComponentImport = struct {
    name: []const u8, // PascalCase name, e.g. "Dialog"
    import_path: []const u8, // relative @import path, e.g. "../components/dialog.zig"
};

pub const ClassPattern = struct {
    kind: enum { prefix, field_map },
    prefix: []const u8,
    prop_name: []const u8,
    value_map: ?[]const ValueMapping = null,
};

pub const ValueMapping = struct {
    enum_value: []const u8,
    classes: []const u8,
};

/// Extract class patterns from a component source file.
/// Recognizes two patterns:
///   1. class={` prefix-${@raw @tagName(props.X)} `} → prefix pattern
///   2. @field(mapName, @tagName(props.X)) → field_map pattern
pub fn extractClassPatterns(allocator: Allocator, source: []const u8) ![]ClassPattern {
    var patterns = std.ArrayListUnmanaged(ClassPattern){};

    var pos: usize = 0;
    while (pos < source.len) {
        // Pattern 1: class={` prefix-${@raw @tagName(props.X)} `}
        if (pos + 8 < source.len and mem.startsWith(u8, source[pos..], "class={`")) {
            const bt_start = pos + 8;
            // Find the closing `}
            var bt_end = bt_start;
            while (bt_end < source.len and source[bt_end] != '`') : (bt_end += 1) {}
            if (bt_end < source.len) {
                const bt_content = source[bt_start..bt_end];
                // Look for ${@raw @tagName(props.X)} pattern
                if (mem.indexOf(u8, bt_content, "${@raw @tagName(props.")) |tag_start| {
                    const prefix = mem.trim(u8, bt_content[0..tag_start], " \t\n\r");
                    const after_props = bt_content[tag_start + 22 ..]; // skip "${@raw @tagName(props."
                    if (mem.indexOf(u8, after_props, ")}")) |name_end| {
                        const prop_name = after_props[0..name_end];
                        try patterns.append(allocator, .{
                            .kind = .prefix,
                            .prefix = try allocator.dupe(u8, prefix),
                            .prop_name = try allocator.dupe(u8, prop_name),
                        });
                    }
                }
                pos = bt_end + 1;
                continue;
            }
        }

        // Pattern 2: @field(mapName, @tagName(props.X))
        if (pos + 7 < source.len and mem.startsWith(u8, source[pos..], "@field(")) {
            const field_start = pos + 7;
            // Find the comma separating map name from @tagName
            if (mem.indexOf(u8, source[field_start..], ", @tagName(props.")) |comma_offset| {
                const map_path = mem.trim(u8, source[field_start .. field_start + comma_offset], " \t\n\r");
                const after_tag = source[field_start + comma_offset + 17 ..]; // skip ", @tagName(props."
                if (mem.indexOf(u8, after_tag, "))")) |name_end| {
                    const prop_name = after_tag[0..name_end];
                    // Extract value mappings from the map definition in source
                    const value_map = try extractFieldMapValues(allocator, source, map_path);
                    try patterns.append(allocator, .{
                        .kind = .field_map,
                        .prefix = try allocator.dupe(u8, map_path),
                        .prop_name = try allocator.dupe(u8, prop_name),
                        .value_map = value_map,
                    });
                }
            }
        }

        pos += 1;
    }

    return try patterns.toOwnedSlice(allocator);
}

/// Given source and a map path like "sizes.font", find the const definition
/// and extract .key = "value" pairs.
pub fn extractFieldMapValues(allocator: Allocator, source: []const u8, map_path: []const u8) ![]const ValueMapping {
    var mappings = std.ArrayListUnmanaged(ValueMapping){};

    // Split map_path on "." to find nested access (e.g., "sizes.font")
    // First find the root identifier
    const dot_pos = mem.indexOf(u8, map_path, ".");
    const root_name = if (dot_pos) |dp| map_path[0..dp] else map_path;

    // Find "const <root_name> =" or "var <root_name> ="
    const search_const = blk: {
        var search_buf: [256]u8 = undefined;
        const prefix = "const ";
        const suffix = " =";
        if (prefix.len + root_name.len + suffix.len > search_buf.len) break :blk null;
        @memcpy(search_buf[0..prefix.len], prefix);
        @memcpy(search_buf[prefix.len .. prefix.len + root_name.len], root_name);
        @memcpy(search_buf[prefix.len + root_name.len .. prefix.len + root_name.len + suffix.len], suffix);
        break :blk mem.indexOf(u8, source, search_buf[0 .. prefix.len + root_name.len + suffix.len]);
    };

    const def_start = search_const orelse return try mappings.toOwnedSlice(allocator);

    // Find the struct literal body - look for the opening brace
    var search_pos = def_start;
    while (search_pos < source.len and source[search_pos] != '{') : (search_pos += 1) {}
    if (search_pos >= source.len) return try mappings.toOwnedSlice(allocator);

    // If we have a nested path like "sizes.font", we need to find the nested field
    if (dot_pos) |dp| {
        const field_name = map_path[dp + 1 ..];
        // Find ".field_name = " or ".field_name=" inside the struct
        var nest_pos = search_pos;
        while (nest_pos < source.len) {
            if (source[nest_pos] == '.' and nest_pos + 1 + field_name.len < source.len) {
                if (mem.eql(u8, source[nest_pos + 1 .. nest_pos + 1 + field_name.len], field_name)) {
                    // Found the field, now find its opening brace
                    search_pos = nest_pos + 1 + field_name.len;
                    while (search_pos < source.len and source[search_pos] != '{') : (search_pos += 1) {}
                    break;
                }
            }
            nest_pos += 1;
        }
    }

    if (search_pos >= source.len) return try mappings.toOwnedSlice(allocator);

    // Now parse .key = "value" pairs within this brace-delimited block
    var brace_depth: usize = 0;
    var scan = search_pos;
    while (scan < source.len) {
        switch (source[scan]) {
            '{' => brace_depth += 1,
            '}' => {
                brace_depth -= 1;
                if (brace_depth == 0) break;
            },
            '.' => {
                if (brace_depth == 1) {
                    // Parse .key = "value"
                    scan += 1;
                    const key_start = scan;
                    while (scan < source.len and (std.ascii.isAlphanumeric(source[scan]) or source[scan] == '_')) : (scan += 1) {}
                    const key = source[key_start..scan];
                    if (key.len == 0) continue;

                    // Skip to = and then to opening quote
                    while (scan < source.len and source[scan] != '"') : (scan += 1) {}
                    if (scan >= source.len) break;
                    scan += 1; // skip opening "
                    const val_start = scan;
                    while (scan < source.len and source[scan] != '"') : (scan += 1) {}
                    const val = source[val_start..scan];

                    try mappings.append(allocator, .{
                        .enum_value = try allocator.dupe(u8, key),
                        .classes = try allocator.dupe(u8, val),
                    });
                }
            },
            else => {},
        }
        scan += 1;
    }

    return try mappings.toOwnedSlice(allocator);
}

/// Transpile a ZSX source string to Zig code. Public API for use by .publr code generation.
pub fn transpileSource(allocator: Allocator, source: []const u8, source_path: []const u8, component_imports: []const ComponentImport) ![]u8 {
    var parser = Parser.init(allocator, source, source_path);
    defer parser.deinit();
    parser.component_imports = component_imports;
    return try parser.generate();
}

pub const TranspileResult = struct {
    zig_code: []u8,
    css_classes: std.StringHashMapUnmanaged(void),

    pub fn deinit(self: *TranspileResult, allocator: Allocator) void {
        allocator.free(self.zig_code);
        var it = self.css_classes.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.css_classes.deinit(allocator);
    }
};

pub fn transpileWithCssCollection(
    allocator: Allocator,
    source: []const u8,
    source_path: []const u8,
    component_imports: []const ComponentImport,
    component_class_patterns: ?*const std.StringHashMapUnmanaged([]const ClassPattern),
) !TranspileResult {
    var css_classes = std.StringHashMapUnmanaged(void){};
    var parser = Parser.init(allocator, source, source_path);
    defer parser.deinit();
    parser.component_imports = component_imports;
    parser.css_classes = &css_classes;
    parser.component_class_patterns = component_class_patterns;
    const zig_code = try parser.generate();
    return .{
        .zig_code = zig_code,
        .css_classes = css_classes,
    };
}

/// Scan source for PascalCase tag usage and resolve to component @imports
fn scanComponentUsage(
    allocator: Allocator,
    source: []const u8,
    current_rel_path: []const u8,
    component_registry: *const std.StringHashMapUnmanaged([]const u8),
    imports: *std.ArrayListUnmanaged(ComponentImport),
) !void {
    // Track which names we've already added
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var pos: usize = 0;
    while (pos < source.len) {
        // Look for < followed by uppercase letter (PascalCase component tag)
        if (source[pos] == '<' and pos + 1 < source.len and std.ascii.isUpper(source[pos + 1])) {
            pos += 1;
            const name_start = pos;
            while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_')) {
                pos += 1;
            }
            const tag_name = source[name_start..pos];

            if (tag_name.len > 0 and !seen.contains(tag_name)) {
                // Skip if source already has an explicit import for this name
                if (hasExplicitImport(source, tag_name)) {
                    try seen.put(allocator, tag_name, {});
                } else if (component_registry.get(tag_name)) |component_rel_path| {
                    // Build relative import path from current file to component file
                    const import_path = try buildRelativeImportPath(allocator, current_rel_path, component_rel_path);
                    try imports.append(allocator, .{
                        .name = tag_name,
                        .import_path = import_path,
                    });
                    try seen.put(allocator, tag_name, {});
                }
            }
        } else {
            pos += 1;
        }
    }
}

/// Check if the source already contains a `const Name = @import(...)` for a given identifier
fn hasExplicitImport(source: []const u8, name: []const u8) bool {
    // Search for pattern: "const <name> = @import("
    // This prevents auto-discovery from duplicating hand-written imports
    var search_pos: usize = 0;
    while (search_pos < source.len) {
        const idx = mem.indexOf(u8, source[search_pos..], name) orelse return false;
        const abs_pos = search_pos + idx;

        // Check it's preceded by "const " (with possible whitespace)
        if (abs_pos >= 6) {
            // Walk backwards past whitespace
            var back = abs_pos - 1;
            while (back > 0 and (source[back] == ' ' or source[back] == '\t')) back -= 1;
            // Check for "const" ending
            if (back >= 4 and mem.eql(u8, source[back - 4 .. back + 1], "const")) {
                // Check that the name is followed by whitespace/= and @import
                const after = abs_pos + name.len;
                if (after < source.len and (source[after] == ' ' or source[after] == '=')) {
                    // Found an explicit import declaration
                    return true;
                }
            }
        }
        search_pos = abs_pos + name.len;
    }
    return false;
}

/// Build a relative @import path from one .zsx file to another's generated .zig output
fn buildRelativeImportPath(allocator: Allocator, from_rel: []const u8, to_rel: []const u8) ![]const u8 {
    // Both paths are relative to input root, e.g. "admin/dashboard.zsx" and "components/dialog.zsx"
    // Generated .zig files mirror this structure in output dir
    // We need: from "admin/dashboard.zig" import "../components/dialog.zig"

    const from_dir = fs.path.dirname(from_rel) orelse "";
    const to_base = to_rel[0 .. to_rel.len - 4]; // strip .zsx
    const to_zig_name = try makeZigName(allocator, to_base);
    defer allocator.free(to_zig_name);

    // Count depth of from_dir to know how many "../" we need
    var depth: usize = 0;
    if (from_dir.len > 0) {
        depth = 1;
        for (from_dir) |c| {
            if (c == '/' or c == '\\') depth += 1;
        }
    }

    // Build path: "../" * depth + to_zig_name + ".zig"
    var result = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try result.appendSlice(allocator, "../");
    }
    try result.appendSlice(allocator, to_zig_name);
    try result.appendSlice(allocator, ".zig");

    return try result.toOwnedSlice(allocator);
}

/// Convert a kebab-case/snake_case name to PascalCase.
/// e.g. "dialog" → "Dialog", "my-button" → "MyButton", "toggle_switch" → "ToggleSwitch"
fn toPascalCase(allocator: Allocator, name: []const u8) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    var capitalize_next = true;

    for (name) |c| {
        if (c == '-' or c == '_') {
            capitalize_next = true;
        } else {
            if (capitalize_next) {
                try result.append(allocator, std.ascii.toUpper(c));
                capitalize_next = false;
            } else {
                try result.append(allocator, c);
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Convert a filename (without extension) to a valid Zig identifier.
/// e.g. "my-component" → "my_component", "123file" → "_123file"
fn makeZigIdentifier(allocator: Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return try allocator.dupe(u8, "_");

    var result = std.ArrayListUnmanaged(u8){};

    // Leading digit needs underscore prefix
    if (std.ascii.isDigit(name[0])) {
        try result.append(allocator, '_');
    }

    for (name) |c| {
        if (c == '-') {
            try result.append(allocator, '_');
        } else if (std.ascii.isAlphanumeric(c) or c == '_') {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '_');
        }
    }

    const ident = try result.toOwnedSlice(allocator);

    // Escape Zig keywords with @"" syntax
    if (isZigKeyword(ident)) {
        const escaped = try std.fmt.allocPrint(allocator, "@\"{s}\"", .{ident});
        allocator.free(ident);
        return escaped;
    }

    return ident;
}

fn isZigKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace", "align",     "allowzero",   "and",         "anyframe",
        "anytype",   "asm",       "async",       "await",       "break",
        "callconv",  "catch",     "comptime",    "const",       "continue",
        "defer",     "else",      "enum",        "errdefer",    "error",
        "export",    "extern",    "false",       "fn",          "for",
        "if",        "inline",    "linksection", "noalias",     "nosuspend",
        "null",      "opaque",    "or",          "orelse",      "packed",
        "pub",       "resume",    "return",      "struct",      "suspend",
        "switch",    "test",      "threadlocal", "true",        "try",
        "type",      "undefined", "union",       "unreachable", "var",
        "volatile",  "while",
    };
    for (keywords) |kw| {
        if (mem.eql(u8, name, kw)) return true;
    }
    return false;
}

/// Generate views.zig namespace module from collected file list
fn generateViewsModule(allocator: Allocator, output_dir: []const u8, zsx_files: []const []u8) !void {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "// Generated from ZSX - do not edit\n\n");

    // Build a tree structure: dir path → list of (name, is_dir, import_path)
    // We'll use a simpler approach: sort files, then group by directory level

    // Sort files for deterministic output
    var sorted = try allocator.alloc([]const u8, zsx_files.len);
    defer allocator.free(sorted);
    for (zsx_files, 0..) |f, i| sorted[i] = f;
    mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    try emitNamespaceLevel(allocator, &output, sorted, "", 0);

    const views_path = try std.fmt.allocPrint(allocator, "{s}/views.zig", .{output_dir});
    defer allocator.free(views_path);

    var file = try fs.cwd().createFile(views_path, .{});
    defer file.close();
    try file.writeAll(output.items);

    std.debug.print("Generated: {s}\n", .{views_path});
}

/// Emit namespace declarations for a given directory prefix at a given indent level
fn emitNamespaceLevel(
    allocator: Allocator,
    output: *std.ArrayListUnmanaged(u8),
    sorted_files: []const []const u8,
    prefix: []const u8,
    indent: usize,
) !void {
    // Collect direct children at this level: files and immediate subdirectories
    var files_at_level = std.ArrayListUnmanaged([]const u8){};
    defer files_at_level.deinit(allocator);

    var subdirs = std.StringHashMapUnmanaged(void){};
    defer subdirs.deinit(allocator);

    for (sorted_files) |rel_path| {
        // Must be under our prefix
        if (prefix.len > 0) {
            if (!mem.startsWith(u8, rel_path, prefix)) continue;
        }

        const suffix = if (prefix.len > 0) rel_path[prefix.len..] else rel_path;

        // Check if this is a direct child (no more /)
        if (mem.indexOfScalar(u8, suffix, '/')) |slash_pos| {
            // Has subdirectory — record the immediate subdir name
            const subdir_name = suffix[0..slash_pos];
            if (!subdirs.contains(subdir_name)) {
                try subdirs.put(allocator, subdir_name, {});
            }
        } else if (mem.indexOfScalar(u8, suffix, '\\')) |slash_pos| {
            const subdir_name = suffix[0..slash_pos];
            if (!subdirs.contains(subdir_name)) {
                try subdirs.put(allocator, subdir_name, {});
            }
        } else {
            // Direct file at this level
            try files_at_level.append(allocator, rel_path);
        }
    }

    // Emit file imports (sorted — they already are since input is sorted)
    for (files_at_level.items) |rel_path| {
        const basename = fs.path.basename(rel_path);
        const name_no_ext = basename[0 .. basename.len - 4]; // strip .zsx
        const ident = try makeZigIdentifier(allocator, name_no_ext);
        defer allocator.free(ident);

        const zig_rel = try makeZigName(allocator, rel_path[0 .. rel_path.len - 4]);
        defer allocator.free(zig_rel);

        try writeViewsIndent(output, allocator, indent);
        try output.appendSlice(allocator, "pub const ");
        try output.appendSlice(allocator, ident);
        try output.appendSlice(allocator, " = @import(\"");
        try output.appendSlice(allocator, zig_rel);
        try output.appendSlice(allocator, ".zig\");\n");
    }

    // Collect and sort subdirectory names
    var subdir_names = std.ArrayListUnmanaged([]const u8){};
    defer subdir_names.deinit(allocator);

    var subdir_iter = subdirs.iterator();
    while (subdir_iter.next()) |entry| {
        try subdir_names.append(allocator, entry.key_ptr.*);
    }
    mem.sort([]const u8, subdir_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Emit subdirectory structs (or flat imports for colocated components)
    for (subdir_names.items) |subdir_name| {
        const ident = try makeZigIdentifier(allocator, subdir_name);
        defer allocator.free(ident);

        const new_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}/", .{ prefix, subdir_name })
        else
            try std.fmt.allocPrint(allocator, "{s}/", .{subdir_name});
        defer allocator.free(new_prefix);

        // Colocated component detection: if a directory contains exactly one .zsx file
        // whose name matches the directory (e.g., button/button.zsx), emit a flat import
        // instead of a nested struct. This supports the convention:
        //   src/components/button/button.zsx → pub const button = @import("button/button.zig");
        const colocated_path = blk: {
            const expected = std.fmt.allocPrint(allocator, "{s}{s}.zsx", .{ new_prefix, subdir_name }) catch break :blk null;
            defer allocator.free(expected);

            var subdir_file_count: usize = 0;
            var found_match = false;
            for (sorted_files) |rel_path| {
                if (!mem.startsWith(u8, rel_path, new_prefix)) continue;
                const sub_suffix = rel_path[new_prefix.len..];
                // Only count direct children (no further nesting)
                if (mem.indexOfScalar(u8, sub_suffix, '/') != null) continue;
                if (mem.indexOfScalar(u8, sub_suffix, '\\') != null) continue;
                subdir_file_count += 1;
                if (mem.eql(u8, rel_path, expected)) found_match = true;
            }
            if (found_match and subdir_file_count == 1) {
                break :blk std.fmt.allocPrint(allocator, "{s}{s}", .{ new_prefix, subdir_name }) catch null;
            }
            break :blk null;
        };

        if (colocated_path) |col_path| {
            defer allocator.free(col_path);
            const zig_rel = try makeZigName(allocator, col_path);
            defer allocator.free(zig_rel);

            // Add blank line between file imports and struct declarations
            if (files_at_level.items.len > 0 or subdir_names.items.len > 1) {
                try output.append(allocator, '\n');
            }

            try writeViewsIndent(output, allocator, indent);
            try output.appendSlice(allocator, "pub const ");
            try output.appendSlice(allocator, ident);
            try output.appendSlice(allocator, " = @import(\"");
            try output.appendSlice(allocator, zig_rel);
            try output.appendSlice(allocator, ".zig\");\n");
        } else {
            // Add blank line between file imports and struct declarations
            if (files_at_level.items.len > 0 or subdir_names.items.len > 1) {
                try output.append(allocator, '\n');
            }

            try writeViewsIndent(output, allocator, indent);
            try output.appendSlice(allocator, "pub const ");
            try output.appendSlice(allocator, ident);
            try output.appendSlice(allocator, " = struct {\n");

            try emitNamespaceLevel(allocator, output, sorted_files, new_prefix, indent + 1);

            try writeViewsIndent(output, allocator, indent);
            try output.appendSlice(allocator, "};\n");
        }
    }
}

fn writeViewsIndent(output: *std.ArrayListUnmanaged(u8), allocator: Allocator, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try output.appendSlice(allocator, "    ");
    }
}

/// Generate gallery_defaults.zig — imports gallery.zon from each colocated component directory.
/// This allows html_variants.zig and wasm_bridge.zig to access gallery-only defaults at comptime.
fn generateGalleryDefaults(allocator: Allocator, input_dir: []const u8, output_dir: []const u8, zsx_files: []const []u8) !void {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "// Generated from gallery.zon files - do not edit\n\n");

    // Find colocated components (button/button.zsx pattern) that have a gallery.zon
    var sorted = try allocator.alloc([]const u8, zsx_files.len);
    defer allocator.free(sorted);
    for (zsx_files, 0..) |f, i| sorted[i] = f;
    mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (sorted) |rel_path| {
        const basename = fs.path.basename(rel_path);
        const name_no_ext = basename[0 .. basename.len - 4]; // strip .zsx

        // Check if this is a colocated component (e.g., button/button.zsx)
        const dir_path = fs.path.dirname(rel_path) orelse continue;
        const parent_name = fs.path.basename(dir_path);
        if (!mem.eql(u8, name_no_ext, parent_name)) continue;

        // Check if gallery.zon exists in the source component directory
        const gallery_path = try std.fmt.allocPrint(allocator, "{s}/{s}/gallery.zon", .{ input_dir, dir_path });
        defer allocator.free(gallery_path);

        const gallery_exists = blk: {
            const f = fs.cwd().openFile(gallery_path, .{}) catch break :blk false;
            f.close();
            break :blk true;
        };

        if (gallery_exists) {
            const ident = try makeZigIdentifier(allocator, name_no_ext);
            defer allocator.free(ident);

            // Import path relative to output dir (src/gen/components/).
            // gallery.zon is at src/components/<name>/gallery.zon.
            // From src/gen/components/ → ../../components/<name>/gallery.zon
            try output.appendSlice(allocator, "pub const ");
            try output.appendSlice(allocator, ident);
            try output.appendSlice(allocator, " = @import(\"../../components/");
            try output.appendSlice(allocator, name_no_ext);
            try output.appendSlice(allocator, "/gallery.zon\");\n");
        }
    }

    const gallery_path = try std.fmt.allocPrint(allocator, "{s}/gallery_defaults.zig", .{output_dir});
    defer allocator.free(gallery_path);

    var file = try fs.cwd().createFile(gallery_path, .{});
    defer file.close();
    try file.writeAll(output.items);
}

fn makeZigName(allocator: Allocator, base: []const u8) ![]u8 {
    const needs_prefix = base.len > 0 and std.ascii.isDigit(base[0]);
    const len = if (needs_prefix) base.len + 1 else base.len;
    var result = try allocator.alloc(u8, len);
    var out: usize = 0;

    if (needs_prefix) {
        result[out] = '_';
        out += 1;
    }

    for (base) |c| {
        if (c == '/' or c == '\\') {
            result[out] = '/';
        } else if (c == '-') {
            result[out] = '_';
        } else {
            result[out] = c;
        }
        out += 1;
    }

    return result;
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    source_path: []const u8,
    pos: usize = 0,
    output: std.ArrayListUnmanaged(u8) = .{},
    indent: usize = 1,
    component_imports: []const ComponentImport = &.{},
    children_depth: u8 = 0, // nesting depth for children anonymous functions
    css_classes: ?*std.StringHashMapUnmanaged(void) = null,
    component_class_patterns: ?*const std.StringHashMapUnmanaged([]const ClassPattern) = null,

    const Error = error{
        UnexpectedChar,
        UnterminatedString,
        UnterminatedExpression,
        UnterminatedTag,
        MismatchedClosingTag,
        OutOfMemory,
    };

    const void_elements = [_][]const u8{
        "area", "base", "br",     "col",   "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    };

    fn init(allocator: Allocator, source: []const u8, source_path: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .source_path = source_path,
        };
    }

    fn deinit(self: *Parser) void {
        self.output.deinit(self.allocator);
    }

    fn generate(self: *Parser) Error![]u8 {
        // Write header
        try self.write("// Generated from ZSX - do not edit\n");
        try self.write("const zsx = @import(\"zsx\").runtime;\n");

        // Emit component auto-discovery imports
        for (self.component_imports) |ci| {
            try self.write("const ");
            try self.write(ci.name);
            try self.write(" = @import(\"");
            try self.write(ci.import_path);
            try self.write("\").");
            try self.write(ci.name);
            try self.write(";\n");
        }

        try self.write("\npub const source_path = \"");
        try self.write(self.source_path);
        try self.write("\";\n\n");

        // Parse file content
        try self.parseFile();

        return try self.output.toOwnedSlice(self.allocator);
    }

    fn parseFile(self: *Parser) Error!void {
        while (self.pos < self.source.len) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;

            // Check for function definition
            if (self.matchKeyword("pub fn ") or self.matchKeyword("fn ")) {
                try self.parseFunction();
            } else if (self.matchKeyword("const ") or self.matchKeyword("pub const ")) {
                try self.parseConstDecl();
            } else if (self.matchKeyword("//")) {
                try self.parseLineComment();
            } else {
                // Skip any other content for now
                self.pos += 1;
            }
        }
    }

    fn parseConstDecl(self: *Parser) Error!void {
        // Copy const declaration verbatim until semicolon at depth 0.
        // Track brace depth so multi-line struct/enum blocks are captured whole.
        const start = self.pos;
        var depth: usize = 0;
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '{' => depth += 1,
                '}' => {
                    if (depth > 0) depth -= 1;
                },
                ';' => {
                    if (depth == 0) {
                        self.pos += 1; // skip ;
                        break;
                    }
                },
                else => {},
            }
            self.pos += 1;
        }

        const decl = self.source[start..self.pos];
        // Ensure all const declarations are pub (for @typeInfo introspection)
        if (mem.startsWith(u8, decl, "const ")) {
            try self.write("pub ");
        }
        try self.write(decl);
        try self.write("\n");
    }

    fn parseLineComment(self: *Parser) Error!void {
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        try self.write(self.source[start..self.pos]);
        try self.write("\n");
        if (self.pos < self.source.len) self.pos += 1;
    }

    fn parseFunction(self: *Parser) Error!void {
        // Capture visibility
        const is_pub = self.matchKeyword("pub ");
        if (is_pub) self.pos += 4;

        // Skip "fn "
        if (!self.matchKeyword("fn ")) return;
        self.pos += 3;

        // Get function name
        const name_start = self.pos;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }
        const func_name = self.source[name_start..self.pos];

        // Skip to opening paren
        self.skipWhitespace();
        if (self.pos >= self.source.len or self.source[self.pos] != '(') return;
        self.pos += 1;

        // Parse params
        const params_start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '(') depth += 1;
            if (self.source[self.pos] == ')') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const params = self.source[params_start..self.pos];
        self.pos += 1; // skip )

        // Skip whitespace and any return type
        self.skipWhitespace();
        // Skip any return type declaration (void, !void, etc)
        if (self.pos < self.source.len and self.source[self.pos] != '{') {
            while (self.pos < self.source.len and self.source[self.pos] != '{') {
                self.pos += 1;
            }
        }

        // Find function body
        if (self.pos >= self.source.len or self.source[self.pos] != '{') return;
        self.pos += 1;

        const body_start = self.pos;
        depth = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '{') depth += 1;
            if (self.source[self.pos] == '}') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const body = self.source[body_start..self.pos];
        self.pos += 1; // skip }

        // Emit Props type for component functions with inline struct params
        // Find first colon at brace depth 0 (the param name:type separator)
        var concrete_props_param: ?[]const u8 = null;
        emit_props: {
            const raw_params = mem.trim(u8, params, " \t\n\r");
            var p: usize = 0;
            var d: usize = 0;
            while (p < raw_params.len) : (p += 1) {
                switch (raw_params[p]) {
                    '{' => d += 1,
                    '}' => {
                        if (d == 0) break :emit_props;
                        d -= 1;
                    },
                    ':' => if (d == 0) break,
                    else => {},
                }
            }
            if (p >= raw_params.len) break :emit_props;
            const type_text = mem.trim(u8, raw_params[p + 1 ..], " \t\n\r");
            if (!mem.startsWith(u8, type_text, "struct")) break :emit_props;
            // Skip Props emission if struct contains anytype fields (not valid in struct defs)
            if (mem.indexOf(u8, type_text, "anytype") != null) break :emit_props;
            if (is_pub) try self.write("pub ");
            try self.write("const ");
            try self.write(func_name);
            try self.write("Props = ");
            try self.write(type_text);
            try self.write(";\n");
            // Only use withDefaults if the struct has fields with default values.
            // Scan for '=' at brace depth 1 (inside the struct body).
            has_defaults: {
                var scan_d: usize = 0;
                var brace_d: usize = 0;
                while (scan_d < type_text.len) : (scan_d += 1) {
                    switch (type_text[scan_d]) {
                        '{' => brace_d += 1,
                        '}' => brace_d -= 1,
                        '=' => if (brace_d == 1 and scan_d + 1 < type_text.len and type_text[scan_d + 1] != '=') {
                            concrete_props_param = mem.trim(u8, raw_params[0..p], " \t");
                            break :has_defaults;
                        },
                        else => {},
                    }
                }
            }
        }

        // Emit transformed function
        if (is_pub) try self.write("pub ");
        try self.write("fn ");
        try self.write(func_name);
        try self.write("(writer: anytype");

        // Parse individual params and emit each as name: anytype
        const trimmed_params = mem.trim(u8, params, " \t\n\r");
        if (trimmed_params.len > 0) {
            // Split params on commas (respecting nested braces/parens/brackets)
            var param_pos: usize = 0;
            while (param_pos < trimmed_params.len) {
                // Find the next comma at depth 0
                var scan = param_pos;
                var brace_depth: usize = 0;
                var paren_depth: usize = 0;
                var bracket_depth: usize = 0;
                while (scan < trimmed_params.len) {
                    switch (trimmed_params[scan]) {
                        '{' => brace_depth += 1,
                        '}' => brace_depth -= 1,
                        '(' => paren_depth += 1,
                        ')' => paren_depth -= 1,
                        '[' => bracket_depth += 1,
                        ']' => bracket_depth -= 1,
                        ',' => if (brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) break,
                        else => {},
                    }
                    scan += 1;
                }

                const param = mem.trim(u8, trimmed_params[param_pos..scan], " \t\n\r");
                if (param.len > 0) {
                    // Extract param name (everything before the first colon)
                    if (mem.indexOf(u8, param, ":")) |colon| {
                        const name = mem.trim(u8, param[0..colon], " \t");
                        try self.write(", ");
                        if (concrete_props_param != null and mem.eql(u8, name, concrete_props_param.?)) {
                            try self.write("_");
                        }
                        try self.write(name);
                        try self.write(": anytype");
                    } else {
                        try self.write(", ");
                        try self.write(param);
                    }
                }

                // Skip past comma
                param_pos = if (scan < trimmed_params.len) scan + 1 else scan;
            }
        }
        try self.write(") !void {\n");

        // Emit defaults merging for concrete props
        if (concrete_props_param) |cpp| {
            try self.write("const ");
            try self.write(cpp);
            try self.write(" = zsx.withDefaults(");
            try self.write(func_name);
            try self.write("Props, _");
            try self.write(cpp);
            try self.write(");\n");
        }

        // Parse and emit body
        try self.parseFunctionBody(body);

        try self.write("}\n\n");
    }

    fn parseFunctionBody(self: *Parser, body: []const u8) Error!void {
        const saved_source = self.source;
        const saved_pos = self.pos;
        self.source = body;
        self.pos = 0;

        while (self.pos < self.source.len) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;

            if (self.source[self.pos] == '<') {
                // JSX or less-than?
                if (self.pos + 1 < self.source.len) {
                    const next = self.source[self.pos + 1];
                    if (std.ascii.isAlphabetic(next) or next == '!') {
                        try self.parseJsx();
                        continue;
                    }
                }
            }

            if (self.source[self.pos] == '{') {
                // Check for expression in top-level (not in JSX context)
                if (self.pos + 1 < self.source.len) {
                    const next = self.source[self.pos + 1];
                    if (next == '`' or next == 'i' or next == 'f' or std.ascii.isAlphabetic(next) or next == '@') {
                        try self.parseExpression();
                        continue;
                    }
                }
            }

            // Zig code passthrough - copy until we hit JSX or expression
            const start = self.pos;
            while (self.pos < self.source.len) {
                if (self.source[self.pos] == '<') {
                    if (self.pos + 1 < self.source.len and
                        (std.ascii.isAlphabetic(self.source[self.pos + 1]) or self.source[self.pos + 1] == '!'))
                    {
                        break;
                    }
                }
                if (self.source[self.pos] == '{') {
                    if (self.pos + 1 < self.source.len) {
                        const next = self.source[self.pos + 1];
                        if (next == '`' or next == 'i' or next == 'f' or std.ascii.isAlphabetic(next) or next == '@') {
                            break;
                        }
                    }
                }
                self.pos += 1;
            }
            if (self.pos > start) {
                try self.writeIndent();
                try self.write(mem.trim(u8, self.source[start..self.pos], " \t\n\r"));
                try self.write("\n");
            }
        }

        self.source = saved_source;
        self.pos = saved_pos;
    }

    fn parseJsx(self: *Parser) Error!void {
        if (self.pos >= self.source.len or self.source[self.pos] != '<') return;

        // Check for DOCTYPE
        if (self.matchAt(self.pos, "<!DOCTYPE") or self.matchAt(self.pos, "<!doctype")) {
            try self.parseDoctype();
            return;
        }

        // Check for HTML comment
        if (self.matchAt(self.pos, "<!--")) {
            try self.parseHtmlComment();
            return;
        }

        self.pos += 1; // skip <

        // Get tag name
        const tag_start = self.pos;
        while (self.pos < self.source.len and
            (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '-' or self.source[self.pos] == '_'))
        {
            self.pos += 1;
        }
        const tag_name = self.source[tag_start..self.pos];

        if (tag_name.len == 0) return;

        const is_component = std.ascii.isUpper(tag_name[0]);

        // Parse attributes
        var attrs = std.ArrayListUnmanaged(Attr){};
        defer attrs.deinit(self.allocator);

        while (self.pos < self.source.len) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;

            if (self.source[self.pos] == '/' or self.source[self.pos] == '>') break;

            // Check for spread: {...expr}
            if (self.source[self.pos] == '{' and self.pos + 1 < self.source.len and
                self.source[self.pos + 1] == '.' and self.pos + 2 < self.source.len and
                self.source[self.pos + 2] == '.' and self.pos + 3 < self.source.len and
                self.source[self.pos + 3] == '.')
            {
                self.pos += 4; // skip {...
                const expr_start = self.pos;
                var depth: usize = 1;
                while (self.pos < self.source.len and depth > 0) {
                    if (self.source[self.pos] == '{') depth += 1;
                    if (self.source[self.pos] == '}') depth -= 1;
                    if (depth > 0) self.pos += 1;
                }
                const expr = self.source[expr_start..self.pos];
                self.pos += 1; // skip }
                try attrs.append(self.allocator, .{ .name = "", .value = expr, .is_expr = true, .is_spread = true });
                continue;
            }

            // Parse attribute name
            const attr_start = self.pos;
            while (self.pos < self.source.len and
                (std.ascii.isAlphanumeric(self.source[self.pos]) or
                    self.source[self.pos] == '-' or self.source[self.pos] == '_'))
            {
                self.pos += 1;
            }
            const attr_name = self.source[attr_start..self.pos];
            if (attr_name.len == 0) break;

            self.skipWhitespace();

            // Check for = and value
            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();

                if (self.pos < self.source.len and self.source[self.pos] == '"') {
                    // String value
                    self.pos += 1;
                    const val_start = self.pos;
                    while (self.pos < self.source.len and self.source[self.pos] != '"') {
                        self.pos += 1;
                    }
                    const val = self.source[val_start..self.pos];
                    if (self.pos < self.source.len) self.pos += 1; // skip "
                    try attrs.append(self.allocator, .{ .name = attr_name, .value = val, .is_expr = false, .is_spread = false });
                } else if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    // Expression value
                    self.pos += 1;
                    const val_start = self.pos;
                    var depth: usize = 1;
                    while (self.pos < self.source.len and depth > 0) {
                        if (self.source[self.pos] == '{') depth += 1;
                        if (self.source[self.pos] == '}') depth -= 1;
                        if (depth > 0) self.pos += 1;
                    }
                    const val = self.source[val_start..self.pos];
                    if (self.pos < self.source.len) self.pos += 1; // skip }
                    try attrs.append(self.allocator, .{ .name = attr_name, .value = val, .is_expr = true, .is_spread = false });
                } else if (self.pos < self.source.len and self.source[self.pos] == '.') {
                    // Enum value: =.identifier
                    const val_start = self.pos;
                    self.pos += 1; // skip .
                    while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
                        self.pos += 1;
                    }
                    const val = self.source[val_start..self.pos];
                    try attrs.append(self.allocator, .{ .name = attr_name, .value = val, .is_expr = true, .is_spread = false });
                }
            } else {
                // Boolean attribute
                try attrs.append(self.allocator, .{ .name = attr_name, .value = "true", .is_expr = true, .is_spread = false });
            }
        }

        self.skipWhitespace();

        // Self-closing?
        var self_closing = false;
        if (self.pos < self.source.len and self.source[self.pos] == '/') {
            self_closing = true;
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '>') {
            self.pos += 1;
        }

        // Check if void element
        const is_void = for (void_elements) |ve| {
            if (mem.eql(u8, tag_name, ve)) break true;
        } else false;

        // Emit code
        if (is_component) {
            // Check for children attribute (not allowed)
            for (attrs.items) |attr| {
                if (!attr.is_spread and mem.eql(u8, attr.name, "children")) {
                    try self.writeIndent();
                    try self.write("@compileError(\"ZSX: 'children' cannot be set as attribute, use <Component>body</Component>\");\n");
                    if (!self_closing) try self.skipToClosingTag(tag_name);
                    return;
                }
            }

            if (self_closing) {
                try self.emitComponentCall(tag_name, attrs.items);
            } else {
                try self.emitComponentCallWithChildren(tag_name, attrs.items);
            }
        } else {
            try self.emitHtmlTag(tag_name, attrs.items);
            if (!self_closing and !is_void) {
                try self.parseChildren(tag_name, true);
            }
        }
    }

    fn parseDoctype(self: *Parser) Error!void {
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '>') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1; // skip >

        try self.writeIndent();
        try self.writeTryWriter();
        try self.write("writeAll(\"");
        try self.writeEscaped(self.source[start..self.pos]);
        try self.write("\");\n");
    }

    fn parseHtmlComment(self: *Parser) Error!void {
        const start = self.pos;
        while (self.pos + 2 < self.source.len) {
            if (self.source[self.pos] == '-' and self.source[self.pos + 1] == '-' and self.source[self.pos + 2] == '>') {
                self.pos += 3;
                break;
            }
            self.pos += 1;
        }

        try self.writeIndent();
        try self.writeTryWriter();
        try self.write("writeAll(\"");
        try self.writeEscaped(self.source[start..self.pos]);
        try self.write("\");\n");
    }

    fn parseChildren(self: *Parser, parent_tag: []const u8, emit_close: bool) Error!void {
        var text_start: ?usize = null;

        while (self.pos < self.source.len) {
            // Check for closing tag
            if (self.matchAt(self.pos, "</")) {
                // Emit any pending text
                if (text_start) |start| {
                    try self.emitText(self.source[start..self.pos]);
                    text_start = null;
                }

                self.pos += 2; // skip </
                const close_start = self.pos;
                while (self.pos < self.source.len and self.source[self.pos] != '>') {
                    self.pos += 1;
                }
                const close_tag = mem.trim(u8, self.source[close_start..self.pos], " \t\n\r");
                if (self.pos < self.source.len) self.pos += 1; // skip >

                if (!mem.eql(u8, close_tag, parent_tag)) {
                    // Mismatch but continue
                }

                // Emit closing tag (only for HTML elements, not components)
                if (emit_close) {
                    try self.writeIndent();
                    try self.writeTryWriter();
                    try self.write("writeAll(\"</");
                    try self.write(parent_tag);
                    try self.write(">\");\n");
                }
                return;
            }

            // Check for nested JSX
            if (self.source[self.pos] == '<') {
                if (self.pos + 1 < self.source.len) {
                    const next = self.source[self.pos + 1];
                    if (std.ascii.isAlphabetic(next) or next == '!') {
                        if (text_start) |start| {
                            try self.emitText(self.source[start..self.pos]);
                            text_start = null;
                        }
                        try self.parseJsx();
                        continue;
                    }
                }
            }

            // Check for expression
            if (self.source[self.pos] == '{') {
                if (text_start) |start| {
                    try self.emitText(self.source[start..self.pos]);
                    text_start = null;
                }
                try self.parseExpression();
                continue;
            }

            // Regular text
            if (text_start == null) {
                text_start = self.pos;
            }
            self.pos += 1;
        }

        // Emit remaining text
        if (text_start) |start| {
            try self.emitText(self.source[start..self.pos]);
        }
    }

    fn parseExpression(self: *Parser) Error!void {
        if (self.pos >= self.source.len or self.source[self.pos] != '{') return;
        self.pos += 1;

        // Check for backtick interpolation {`...`}
        if (self.pos < self.source.len and self.source[self.pos] == '`') {
            self.pos += 1; // skip opening `
            const bt_start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != '`') {
                self.pos += 1;
            }
            const bt_content = self.source[bt_start..self.pos];
            if (self.pos < self.source.len) self.pos += 1; // skip closing `
            if (self.pos < self.source.len and self.source[self.pos] == '}') self.pos += 1; // skip }
            try self.emitBacktickString(bt_content, false);
            return;
        }

        // Check for raw expression {@raw ...}
        const is_raw = self.matchKeyword("@raw ");
        if (is_raw) self.pos += 5;

        self.skipWhitespace();

        // Check for control flow
        if (self.matchKeyword("if ") or self.matchKeyword("if(")) {
            try self.parseIf();
            return;
        }

        if (self.matchKeyword("for ") or self.matchKeyword("for(")) {
            try self.parseFor();
            return;
        }

        // Simple expression
        const start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '{') depth += 1;
            if (self.source[self.pos] == '}') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const expr = mem.trim(u8, self.source[start..self.pos], " \t\n\r");
        if (self.pos < self.source.len) self.pos += 1; // skip }

        try self.emitSimpleExpression(expr, is_raw);
    }

    const TernaryScan = struct {
        question_pos: ?usize = null,
        colon_pos: ?usize = null,
        is_elvis: bool = false,
        is_nested: bool = false,
    };

    fn scanTernary(_: *Parser, expr: []const u8) TernaryScan {
        var result = TernaryScan{};
        var i: usize = 0;
        var paren_depth: usize = 0;
        var brace_depth: usize = 0;
        var bracket_depth: usize = 0;
        var in_string = false;

        while (i < expr.len) {
            if (in_string) {
                if (expr[i] == '\\' and i + 1 < expr.len) {
                    i += 2;
                    continue;
                }
                if (expr[i] == '"') in_string = false;
                i += 1;
                continue;
            }

            switch (expr[i]) {
                '"' => in_string = true,
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                '{' => brace_depth += 1,
                '}' => {
                    if (brace_depth > 0) brace_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                },
                '?' => {
                    if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                        // Skip .? (Zig optional unwrap)
                        if (i > 0 and expr[i - 1] == '.') {
                            i += 1;
                            continue;
                        }
                        if (result.question_pos != null) {
                            result.is_nested = true;
                            return result;
                        }
                        result.question_pos = i;
                        if (i + 1 < expr.len and expr[i + 1] == ':') {
                            result.is_elvis = true;
                        }
                    }
                },
                ':' => {
                    if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                        if (result.question_pos != null and !result.is_elvis and result.colon_pos == null) {
                            result.colon_pos = i;
                        }
                    }
                },
                else => {},
            }
            i += 1;
        }
        return result;
    }

    fn emitSimpleExpression(self: *Parser, expr: []const u8, is_raw: bool) Error!void {
        const scan = self.scanTernary(expr);

        if (scan.is_nested) {
            try self.writeIndent();
            try self.write("@compileError(\"ZSX: nested ternaries not supported, use if/else\");\n");
            return;
        }

        if (scan.question_pos) |qpos| {
            if (scan.is_elvis) {
                // expr ?: fallback → expr orelse fallback
                const lhs = mem.trim(u8, expr[0..qpos], " \t\n\r");
                const rhs = mem.trim(u8, expr[qpos + 2 ..], " \t\n\r");
                try self.writeIndent();
                if (is_raw) {
                    try self.writeTryWriter();
                    try self.write("writeAll(");
                } else {
                    try self.write("try zsx.render(");
                    try self.writeWriterVar();
                    try self.write(", ");
                }
                try self.write(lhs);
                try self.write(" orelse ");
                try self.write(rhs);
                try self.write(");\n");
            } else if (scan.colon_pos) |cpos| {
                // expr ? a : b → if (expr) a else b
                const cond = mem.trim(u8, expr[0..qpos], " \t\n\r");
                const then_val = mem.trim(u8, expr[qpos + 1 .. cpos], " \t\n\r");
                const else_val = mem.trim(u8, expr[cpos + 1 ..], " \t\n\r");
                try self.writeIndent();
                if (is_raw) {
                    try self.writeTryWriter();
                    try self.write("writeAll(");
                } else {
                    try self.write("try zsx.render(");
                    try self.writeWriterVar();
                    try self.write(", ");
                }
                try self.write("if (");
                try self.write(cond);
                try self.write(") ");
                try self.write(then_val);
                try self.write(" else ");
                try self.write(else_val);
                try self.write(");\n");
            } else {
                // ? without : — pass through as-is (might be valid Zig)
                try self.emitPlainExpression(expr, is_raw);
            }
        } else {
            try self.emitPlainExpression(expr, is_raw);
        }
    }

    fn emitPlainExpression(self: *Parser, expr: []const u8, is_raw: bool) Error!void {
        try self.writeIndent();
        if (is_raw) {
            try self.writeTryWriter();
            try self.write("writeAll(");
        } else {
            try self.write("try zsx.render(");
            try self.writeWriterVar();
            try self.write(", ");
        }
        try self.write(expr);
        try self.write(");\n");
    }

    fn parseIf(self: *Parser) Error!void {
        try self.parseIfChain(true);
    }

    /// Parse an if/else-if/else chain. `is_first` controls whether we emit
    /// "if" or "} else if" and whether we consume the closing `}`.
    fn parseIfChain(self: *Parser, is_first: bool) Error!void {
        // Consume "if " or "if(" keyword
        if (self.matchKeyword("if ")) self.pos += 3;
        if (self.matchKeyword("if(")) self.pos += 2;

        self.skipWhitespace();

        // Parse condition (...)
        if (self.pos >= self.source.len or self.source[self.pos] != '(') return;
        self.pos += 1;
        const cond_start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '(') depth += 1;
            if (self.source[self.pos] == ')') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const cond = self.source[cond_start..self.pos];
        self.pos += 1; // skip )

        self.skipWhitespace();

        // Parse body (...)
        if (self.pos >= self.source.len or self.source[self.pos] != '(') return;
        self.pos += 1;
        const body_start = self.pos;
        depth = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '(') depth += 1;
            if (self.source[self.pos] == ')') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const body = self.source[body_start..self.pos];
        self.pos += 1; // skip )

        self.skipWhitespace();

        // Emit "if (...) {" or "} else if (...) {"
        if (is_first) {
            try self.writeIndent();
            try self.write("if (");
        } else {
            try self.writeIndent();
            try self.write("} else if (");
        }
        try self.write(cond);
        try self.write(") {\n");

        self.indent += 1;
        try self.parseFunctionBody(body);
        self.indent -= 1;

        // Check for else / else if
        if (self.matchKeyword("else ") or self.matchKeyword("else(")) {
            if (self.matchKeyword("else ")) self.pos += 5;
            if (self.matchKeyword("else(")) self.pos += 4;
            self.skipWhitespace();

            if (self.matchKeyword("if ") or self.matchKeyword("if(")) {
                // else if — recurse (will emit "} else if ..." and handle further chains)
                try self.parseIfChain(false);
                return; // closing } already emitted by recursive call
            }

            // Plain else — parse body
            if (self.pos < self.source.len and self.source[self.pos] == '(') {
                self.pos += 1;
                const else_start = self.pos;
                depth = 1;
                while (self.pos < self.source.len and depth > 0) {
                    if (self.source[self.pos] == '(') depth += 1;
                    if (self.source[self.pos] == ')') depth -= 1;
                    if (depth > 0) self.pos += 1;
                }
                const else_body = self.source[else_start..self.pos];
                self.pos += 1; // skip )

                try self.writeIndent();
                try self.write("} else {\n");
                self.indent += 1;
                try self.parseFunctionBody(else_body);
                self.indent -= 1;
            }

            self.skipWhitespace();
        }

        // Skip closing }
        if (self.pos < self.source.len and self.source[self.pos] == '}') {
            self.pos += 1;
        }

        try self.writeIndent();
        try self.write("}\n");
    }

    fn parseFor(self: *Parser) Error!void {
        if (self.matchKeyword("for ")) self.pos += 4;
        if (self.matchKeyword("for(")) self.pos += 3;

        self.skipWhitespace();

        // Parse iterable (...)
        if (self.pos >= self.source.len or self.source[self.pos] != '(') return;
        self.pos += 1;
        const iter_start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '(') depth += 1;
            if (self.source[self.pos] == ')') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const iterable = self.source[iter_start..self.pos];
        self.pos += 1; // skip )

        self.skipWhitespace();

        // Parse capture |item|
        if (self.pos >= self.source.len or self.source[self.pos] != '|') return;
        self.pos += 1;
        const cap_start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '|') {
            self.pos += 1;
        }
        const capture = mem.trim(u8, self.source[cap_start..self.pos], " \t");
        if (self.pos < self.source.len) self.pos += 1; // skip |

        self.skipWhitespace();

        // Parse body (...)
        if (self.pos >= self.source.len or self.source[self.pos] != '(') return;
        self.pos += 1;
        const body_start = self.pos;
        depth = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '(') depth += 1;
            if (self.source[self.pos] == ')') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const body = self.source[body_start..self.pos];
        self.pos += 1; // skip )

        self.skipWhitespace();

        // Skip closing }
        if (self.pos < self.source.len and self.source[self.pos] == '}') {
            self.pos += 1;
        }

        // Emit for loop
        try self.writeIndent();
        try self.write("for (");
        try self.write(iterable);
        try self.write(") |");
        try self.write(capture);
        try self.write("| {\n");

        self.indent += 1;
        try self.parseFunctionBody(body);
        self.indent -= 1;

        try self.writeIndent();
        try self.write("}\n");
    }

    fn emitHtmlTag(self: *Parser, tag: []const u8, attrs: []const Attr) Error!void {
        try self.writeIndent();
        try self.writeTryWriter();
        try self.write("writeAll(\"<");
        try self.write(tag);

        // Emit static attributes
        for (attrs) |attr| {
            if (!attr.is_expr and !attr.is_spread) {
                try self.write(" ");
                try self.write(attr.name);
                try self.write("=\\\"");
                try self.writeEscaped(attr.value);
                try self.write("\\\"");

                // Collect CSS classes from static class attributes
                if (self.css_classes) |css_map| {
                    if (mem.eql(u8, attr.name, "class")) {
                        var it = mem.tokenizeAny(u8, attr.value, " \t\n\r");
                        while (it.next()) |token| {
                            if (!css_map.contains(token)) {
                                const duped = self.allocator.dupe(u8, token) catch continue;
                                css_map.put(self.allocator, duped, {}) catch {
                                    self.allocator.free(duped);
                                };
                            }
                        }
                    }
                }
            }
        }

        // Check if we have dynamic attrs
        var has_dynamic = false;
        for (attrs) |attr| {
            if (attr.is_expr and !attr.is_spread) {
                has_dynamic = true;
                break;
            }
        }

        if (has_dynamic) {
            try self.write("\");\n");
            // Emit dynamic attributes
            for (attrs) |attr| {
                if (attr.is_expr and !attr.is_spread) {
                    if (attr.value.len >= 2 and attr.value[0] == '`' and attr.value[attr.value.len - 1] == '`') {
                        // Backtick attribute: emit sequential calls
                        try self.writeIndent();
                        try self.writeTryWriter();
                        try self.write("writeAll(\" ");
                        try self.write(attr.name);
                        try self.write("=\\\"\");\n");
                        const inner = attr.value[1 .. attr.value.len - 1];
                        try self.emitBacktickString(inner, true);
                        try self.writeIndent();
                        try self.writeTryWriter();
                        try self.write("writeAll(\"\\\"\");\n");
                    } else {
                        try self.writeIndent();
                        try self.writeTryWriter();
                        try self.write("writeAll(\" ");
                        try self.write(attr.name);
                        try self.write("=\\\"\");\n");
                        try self.writeIndent();
                        try self.write("try zsx.render(");
                        try self.writeWriterVar();
                        try self.write(", ");
                        try self.write(attr.value);
                        try self.write(");\n");
                        try self.writeIndent();
                        try self.writeTryWriter();
                        try self.write("writeAll(\"\\\"\");\n");
                    }
                }
            }
            try self.writeIndent();
            try self.writeTryWriter();
            try self.write("writeAll(\">\");\n");
        } else {
            try self.write(">\");\n");
        }
    }

    fn emitComponentCall(self: *Parser, name: []const u8, attrs: []const Attr) Error!void {
        try self.writeIndent();
        try self.write("try ");
        try self.write(name);
        try self.write("(");
        try self.writeWriterVar();
        try self.write(", .{");
        try self.emitComponentProps(attrs);
        try self.write(" });\n");
        try self.collectComponentCssClasses(name, attrs);
    }

    fn emitComponentCallWithChildren(self: *Parser, name: []const u8, attrs: []const Attr) Error!void {
        // Pre-render children to a buffer so runtime variables are accessible
        // (anonymous functions can't capture runtime locals in Zig).
        // The component receives .children as a []u8 string and uses {@raw props.children}.
        try self.writeIndent();
        try self.write("{\n");
        self.indent += 1;

        // Use depth-unique variable names to avoid shadowing in nested children
        const depth_suffix: []const u8 = switch (self.children_depth) {
            0 => "0", 1 => "1", 2 => "2", 3 => "3", 4 => "4",
            5 => "5", 6 => "6", 7 => "7", 8 => "8", 9 => "9",
            else => "x",
        };

        // Create children buffer using page allocator (freed when scope exits)
        try self.writeIndent();
        try self.write("var _children_buf_");
        try self.write(depth_suffix);
        try self.write(": @import(\"std\").ArrayListUnmanaged(u8) = .{};\n");
        try self.writeIndent();
        try self.write("const _children_alloc_");
        try self.write(depth_suffix);
        try self.write(" = @import(\"std\").heap.page_allocator;\n");
        try self.writeIndent();
        try self.write("defer _children_buf_");
        try self.write(depth_suffix);
        try self.write(".deinit(_children_alloc_");
        try self.write(depth_suffix);
        try self.write(");\n");

        // Render children into the buffer
        self.children_depth += 1;
        try self.parseChildren(name, false);
        self.children_depth -= 1;

        // Call the component with children as pre-rendered HTML
        try self.writeIndent();
        try self.write("try ");
        try self.write(name);
        try self.write("(");
        try self.writeWriterVar();
        try self.write(", .{");
        try self.emitComponentProps(attrs);
        if (attrs.len > 0) try self.write(",");
        try self.write(" .children = _children_buf_");
        try self.write(depth_suffix);
        try self.write(".items });\n");
        try self.collectComponentCssClasses(name, attrs);

        self.indent -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    fn emitComponentProps(self: *Parser, attrs: []const Attr) Error!void {
        var first = true;
        for (attrs) |attr| {
            if (attr.is_spread) {
                if (!first) try self.write(", ");
                try self.write("// TODO: spread ");
                try self.write(attr.value);
                first = false;
            } else {
                if (!first) try self.write(", ");
                try self.write(" .");
                if (isZigKeyword(attr.name)) {
                    try self.write("@compileError(\"ZSX: prop name '");
                    try self.write(attr.name);
                    try self.write("' is a Zig keyword. Use a non-colliding name (e.g., snake_case convention).\")");
                    return;
                }
                try self.write(attr.name);
                try self.write(" = ");
                if (attr.is_expr) {
                    try self.write(attr.value);
                } else {
                    try self.write("\"");
                    try self.write(attr.value);
                    try self.write("\"");
                }
                first = false;
            }
        }
    }

    fn collectComponentCssClasses(self: *Parser, name: []const u8, attrs: []const Attr) Error!void {
        const css_map = self.css_classes orelse return;
        const patterns_map = self.component_class_patterns orelse return;
        const patterns = patterns_map.get(name) orelse return;

        for (patterns) |pattern| {
            // Find the attr that matches this pattern's prop_name
            var enum_value: ?[]const u8 = null;
            for (attrs) |attr| {
                if (!attr.is_spread and mem.eql(u8, attr.name, pattern.prop_name)) {
                    // Enum attrs come as ".value" (with leading dot)
                    if (attr.value.len > 1 and attr.value[0] == '.') {
                        enum_value = attr.value[1..];
                    }
                    break;
                }
            }
            const ev = enum_value orelse continue;

            switch (pattern.kind) {
                .prefix => {
                    // Concatenate prefix + enum value (e.g., "badge-" + "xs" = "badge-xs")
                    const class = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ pattern.prefix, ev }) catch continue;
                    if (!css_map.contains(class)) {
                        css_map.put(self.allocator, class, {}) catch {
                            self.allocator.free(class);
                        };
                    } else {
                        self.allocator.free(class);
                    }
                },
                .field_map => {
                    // Look up enum value in the value_map
                    const value_map = pattern.value_map orelse continue;
                    for (value_map) |mapping| {
                        if (mem.eql(u8, mapping.enum_value, ev)) {
                            // Split classes on spaces and add each
                            var it = mem.tokenizeAny(u8, mapping.classes, " \t\n\r");
                            while (it.next()) |token| {
                                if (!css_map.contains(token)) {
                                    const duped = self.allocator.dupe(u8, token) catch continue;
                                    css_map.put(self.allocator, duped, {}) catch {
                                        self.allocator.free(duped);
                                    };
                                }
                            }
                            break;
                        }
                    }
                },
            }
        }
    }

    fn skipToClosingTag(self: *Parser, tag_name: []const u8) Error!void {
        var depth: usize = 1;
        while (self.pos < self.source.len) {
            if (self.matchAt(self.pos, "</")) {
                const after = self.pos + 2;
                var end = after;
                while (end < self.source.len and self.source[end] != '>') end += 1;
                const name = mem.trim(u8, self.source[after..end], " \t\n\r");
                if (mem.eql(u8, name, tag_name)) {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos = if (end < self.source.len) end + 1 else end;
                        return;
                    }
                }
            }
            // Check for opening tags of the same name (non-self-closing)
            if (self.source[self.pos] == '<' and self.pos + 1 < self.source.len and
                self.source[self.pos + 1] != '/')
            {
                const ts = self.pos + 1;
                var te = ts;
                while (te < self.source.len and
                    (std.ascii.isAlphanumeric(self.source[te]) or self.source[te] == '-' or self.source[te] == '_'))
                {
                    te += 1;
                }
                if (mem.eql(u8, self.source[ts..te], tag_name)) {
                    // Check if self-closing
                    var sc = te;
                    while (sc < self.source.len and self.source[sc] != '>') {
                        if (self.source[sc] == '/') break;
                        sc += 1;
                    }
                    if (sc >= self.source.len or self.source[sc] != '/') {
                        depth += 1;
                    }
                }
            }
            self.pos += 1;
        }
    }

    fn emitText(self: *Parser, text: []const u8) Error!void {
        const trimmed = mem.trim(u8, text, " \t\n\r");
        if (trimmed.len == 0) {
            // Only whitespace - check if there's any at all
            if (text.len > 0 and mem.indexOf(u8, text, "\n") != null) {
                // Multi-line whitespace - emit newline
                try self.writeIndent();
                try self.writeTryWriter();
                try self.write("writeAll(\"\\n\");\n");
            }
            return;
        }

        try self.writeIndent();
        try self.writeTryWriter();
        try self.write("writeAll(\"");
        try self.writeEscaped(text);
        try self.write("\");\n");
    }

    fn emitBacktickString(self: *Parser, content: []const u8, use_escape: bool) Error!void {
        var i: usize = 0;
        var text_start: usize = 0;

        while (i < content.len) {
            if (i + 1 < content.len and content[i] == '$' and content[i + 1] == '{') {
                // Emit preceding literal text
                if (i > text_start) {
                    try self.writeIndent();
                    try self.writeTryWriter();
                    try self.write("writeAll(\"");
                    try self.writeEscaped(content[text_start..i]);
                    try self.write("\");\n");
                }

                i += 2; // skip ${

                // Check for @raw
                const is_raw = i + 5 <= content.len and mem.eql(u8, content[i .. i + 5], "@raw ");
                if (is_raw) i += 5;

                // Find matching }
                const expr_start = i;
                var depth: usize = 1;
                while (i < content.len and depth > 0) {
                    if (content[i] == '{') depth += 1;
                    if (content[i] == '}') depth -= 1;
                    if (depth > 0) i += 1;
                }
                const expr = mem.trim(u8, content[expr_start..i], " \t\n\r");
                if (i < content.len) i += 1; // skip }

                // Emit expression
                try self.writeIndent();
                if (is_raw) {
                    try self.writeTryWriter();
                    try self.write("writeAll(");
                    try self.write(expr);
                    try self.write(");\n");
                } else if (use_escape) {
                    try self.write("try zsx.escape(");
                    try self.writeWriterVar();
                    try self.write(", ");
                    try self.write(expr);
                    try self.write(");\n");
                } else {
                    try self.write("try zsx.render(");
                    try self.writeWriterVar();
                    try self.write(", ");
                    try self.write(expr);
                    try self.write(");\n");
                }

                text_start = i;
            } else {
                i += 1;
            }
        }

        // Emit trailing literal text
        if (text_start < content.len) {
            try self.writeIndent();
            try self.writeTryWriter();
            try self.write("writeAll(\"");
            try self.writeEscaped(content[text_start..content.len]);
            try self.write("\");\n");
        }
    }

    fn writeEscaped(self: *Parser, text: []const u8) Error!void {
        for (text) |c| {
            switch (c) {
                '"' => try self.write("\\\""),
                '\\' => try self.write("\\\\"),
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                else => try self.writeByte(c),
            }
        }
    }

    fn write(self: *Parser, data: []const u8) Error!void {
        try self.output.appendSlice(self.allocator, data);
    }

    fn writeByte(self: *Parser, byte: u8) Error!void {
        try self.output.append(self.allocator, byte);
    }

    fn writeIndent(self: *Parser) Error!void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) {
            try self.write("    ");
        }
    }

    /// Emit the current writer variable name (changes in children context)
    fn writeWriterVar(self: *Parser) Error!void {
        if (self.children_depth == 0) {
            try self.write("writer");
        } else {
            // Children are pre-rendered to depth-specific buffer
            const depth_suffix: []const u8 = switch (self.children_depth - 1) {
                0 => "0", 1 => "1", 2 => "2", 3 => "3", 4 => "4",
                5 => "5", 6 => "6", 7 => "7", 8 => "8", 9 => "9",
                else => "x",
            };
            try self.write("_children_buf_");
            try self.write(depth_suffix);
            try self.write(".writer(_children_alloc_");
            try self.write(depth_suffix);
            try self.write(")");
        }
    }

    /// Emit "try <writer>." prefix for writer method calls
    fn writeTryWriter(self: *Parser) Error!void {
        try self.write("try ");
        try self.writeWriterVar();
        try self.write(".");
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.source.len and
            (self.source[self.pos] == ' ' or self.source[self.pos] == '\t' or
                self.source[self.pos] == '\n' or self.source[self.pos] == '\r'))
        {
            self.pos += 1;
        }
    }

    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        return mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword);
    }

    fn matchAt(self: *Parser, pos: usize, needle: []const u8) bool {
        if (pos + needle.len > self.source.len) return false;
        return std.ascii.eqlIgnoreCase(self.source[pos .. pos + needle.len], needle);
    }

    const Attr = struct {
        name: []const u8,
        value: []const u8,
        is_expr: bool,
        is_spread: bool,
    };
};

// views.zig namespace generation tests

// CSS class collection tests

};
