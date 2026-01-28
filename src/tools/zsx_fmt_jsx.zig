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

// ============================================================
// Tests
// ============================================================

test "format simple nested tags" {
    const allocator = std.testing.allocator;
    const input =
        \\<div class="outer">
        \\<p>Hello</p>
        \\</div>
    ;
    const result = try formatJsx(allocator, input, 1);
    defer allocator.free(result);

    const expected =
        \\    <div class="outer">
        \\        <p>Hello</p>
        \\    </div>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format self-closing tag" {
    const allocator = std.testing.allocator;
    const input =
        \\<br />
        \\<img src="test.png" />
    ;
    const result = try formatJsx(allocator, input, 1);
    defer allocator.free(result);

    const expected =
        \\    <br />
        \\    <img src="test.png" />
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format void elements without explicit self-close" {
    const allocator = std.testing.allocator;
    const input =
        \\<div>
        \\<input type="text" name="foo">
        \\<br>
        \\</div>
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\<div>
        \\    <input type="text" name="foo">
        \\    <br>
        \\</div>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format DOCTYPE" {
    const allocator = std.testing.allocator;
    const input =
        \\<!DOCTYPE html>
        \\<html>
        \\</html>
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\<!DOCTYPE html>
        \\<html>
        \\</html>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format expressions" {
    const allocator = std.testing.allocator;
    const input =
        \\<div>
        \\{title}
        \\{!raw_html}
        \\</div>
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\<div>
        \\    {title}
        \\    {!raw_html}
        \\</div>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format if/else control flow" {
    const allocator = std.testing.allocator;
    const input =
        \\{if (has_posts) (
        \\<p>Has posts</p>
        \\) else (
        \\<p>No posts</p>
        \\)}
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\{if (has_posts) (
        \\    <p>Has posts</p>
        \\) else (
        \\    <p>No posts</p>
        \\)}
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format for loop" {
    const allocator = std.testing.allocator;
    const input =
        \\{for (items) |item| (
        \\<li>{item.name}</li>
        \\)}
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\{for (items) |item| (
        \\    <li>{item.name}</li>
        \\)}
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format attribute wrapping over 80 chars" {
    const allocator = std.testing.allocator;
    const input =
        \\<Dialog trigger_label="Open Dialog" title="Dismissable Dialog" body="Click outside, press Escape, or use the close button." dismiss_label="Close" confirm_label="Confirm" dismissable={true} />
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\<Dialog
        \\    trigger_label="Open Dialog"
        \\    title="Dismissable Dialog"
        \\    body="Click outside, press Escape, or use the close button."
        \\    dismiss_label="Close"
        \\    confirm_label="Confirm"
        \\    dismissable={true}
        \\/>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format short attributes stay inline" {
    const allocator = std.testing.allocator;
    const input =
        \\<div class="container" id="main">
        \\</div>
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\<div class="container" id="main">
        \\</div>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format mixed Zig and JSX" {
    const allocator = std.testing.allocator;
    const input =
        \\const x = 42;
        \\<div>
        \\<p>Hello</p>
        \\</div>
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\const x = 42;
        \\<div>
        \\    <p>Hello</p>
        \\</div>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format HTML comment" {
    const allocator = std.testing.allocator;
    const input =
        \\<!-- This is a comment -->
        \\<div>
        \\</div>
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\<!-- This is a comment -->
        \\<div>
        \\</div>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "format inline content with wrapped attributes" {
    const allocator = std.testing.allocator;
    // 109-char tag wraps at indent 0 (109 > 80)
    const input =
        \\<pre style="background: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 4px; overflow-x: auto; margin: 0;">error.{error_name}</pre>
    ;
    const result = try formatJsx(allocator, input, 0);
    defer allocator.free(result);

    const expected =
        \\<pre
        \\    style="background: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 4px; overflow-x: auto; margin: 0;"
        \\>
        \\    error.{error_name}
        \\</pre>
        \\
    ;
    try std.testing.expectEqualStrings(expected, result);
}
