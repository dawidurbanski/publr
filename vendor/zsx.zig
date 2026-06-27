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

/// Runtime string concatenation used by transpiled backtick templates that
/// appear as component-prop values (struct field initializers). The transpiler
/// converts `\`prefix ${expr} suffix\`` in component-prop position into a
/// `concatRt(&.{ "prefix ", expr, " suffix" })` call so the value is a single
/// `[]const u8` expression suitable for a struct field.
///
/// Allocates from page_allocator. Allocations are short-lived (live only for
/// the duration of a render) and freed implicitly on WASM page reclaim or
/// arena reset; we do not free here because the returned slice is consumed
/// by downstream `writer.writeAll` calls in the same render frame.
pub fn concatRt(parts: []const []const u8) []const u8 {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    if (total == 0) return "";
    const buf = std.heap.page_allocator.alloc(u8, total) catch return "";
    var i: usize = 0;
    for (parts) |p| {
        @memcpy(buf[i .. i + p.len], p);
        i += p.len;
    }
    return buf;
}

/// Render a component in INLINE (non-HMR) mode while forwarding any author
/// attributes the component doesn't declare (data-p-* directives, role,
/// tabindex, …) onto its ROOT element. `raw` is the full attribute struct the
/// call site built; fields matching a `Props` field become props, the rest are
/// spliced onto the rendered root. This is the inline-mode counterpart to the
/// HMR lift's `renderForwarding`, so forwarding works in dev (HMR) AND build
/// (inline) builds. Fast path: nothing to forward → render directly.
pub fn renderForwarding(comptime Component: anytype, comptime Props: type, writer: anytype, raw: anytype) !void {
    var props: Props = .{};
    const fields = std.meta.fields(@TypeOf(raw));
    var parts: [fields.len * 5][]const u8 = undefined;
    var n: usize = 0;
    inline for (fields) |f| {
        if (@hasField(Props, f.name)) {
            @field(props, f.name) = @field(raw, f.name);
        } else {
            const v: []const u8 = @field(raw, f.name);
            parts[n] = " ";
            parts[n + 1] = f.name;
            parts[n + 2] = "=\"";
            parts[n + 3] = v;
            parts[n + 4] = "\"";
            n += 5;
        }
    }
    if (n == 0) return Component(writer, props);
    const fwd = concatRt(parts[0..n]);
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.heap.page_allocator);
    try Component(buf.writer(std.heap.page_allocator), props);
    try spliceAttrsIntoRoot(writer, buf.items, fwd);
}

fn isTagStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Insert `attrs` (` name="value"` run) into the first opening tag of `html`,
/// before its closing `>` (or `/>`). Writes `html` unchanged if none found.
fn spliceAttrsIntoRoot(writer: anytype, html: []const u8, attrs: []const u8) !void {
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] == '<' and i + 1 < html.len and isTagStart(html[i + 1])) break;
    }
    if (i >= html.len) return writer.writeAll(html);
    var j = i + 1;
    var q: u8 = 0;
    while (j < html.len) : (j += 1) {
        const c = html[j];
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') {
            q = c;
        } else if (c == '>') break;
    }
    if (j >= html.len) return writer.writeAll(html);
    const at = if (j > 0 and html[j - 1] == '/') j - 1 else j;
    try writer.writeAll(html[0..at]);
    try writer.writeAll(attrs);
    try writer.writeAll(html[at..]);
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

pub const manifest_mod = struct {
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Literal = struct {
    slot: u32,
};

pub const ExprKind = enum { plain, raw, ternary, elvis, backtick };

pub const Expr = struct {
    kind: ExprKind,
    source: []const u8,
};

pub const AttrValue = union(enum) {
    string: []const u8,
    expr: []const u8,
    bool_present,
};

pub const Attr = struct {
    name: []const u8,
    value: AttrValue,
};

pub const Component = struct {
    name: []const u8,
    attrs: []const Attr,
    has_children: bool,
};

pub const ForHead = struct {
    iterable_source: []const u8,
    binding: []const u8,
};

pub const Node = union(enum) {
    literal: Literal,
    expr: Expr,
    component: Component,
    component_end,
    if_begin: []const u8,
    if_else,
    if_end,
    for_begin: ForHead,
    for_end,
    children_slot,
    /// A Zig-level `// ...` line comment that lived inside a function body
    /// (e.g. between sibling tags). Stored so emit can reproduce it verbatim;
    /// not part of the HMR-relevant structure but kept for regression parity.
    line_comment: []const u8,
    /// A raw Zig statement found at function-body level (e.g.
    /// `const x = if (cond) "a" else "b";`). The existing transpiler emits
    /// these verbatim outside the writeAll buffer.
    zig_stmt: []const u8,
};

pub const Manifest = struct {
    name: []const u8,
    sig: []const u8,
    nodes: []const Node,
    literals: []const []const u8,

    pub fn deinit(self: *Manifest, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.sig);
        for (self.nodes) |node| freeNode(allocator, node);
        allocator.free(self.nodes);
        for (self.literals) |lit| allocator.free(lit);
        allocator.free(self.literals);
        self.* = undefined;
    }
};

fn freeNode(allocator: Allocator, node: Node) void {
    switch (node) {
        .literal, .component_end, .if_else, .if_end, .for_end, .children_slot => {},
        .expr => |e| allocator.free(e.source),
        .component => |c| {
            allocator.free(c.name);
            for (c.attrs) |a| {
                allocator.free(a.name);
                switch (a.value) {
                    .string => |s| allocator.free(s),
                    .expr => |s| allocator.free(s),
                    .bool_present => {},
                }
            }
            allocator.free(c.attrs);
        },
        .if_begin => |s| allocator.free(s),
        .for_begin => |fh| {
            allocator.free(fh.iterable_source);
            allocator.free(fh.binding);
        },
        .line_comment => |s| allocator.free(s),
        .zig_stmt => |s| allocator.free(s),
    }
}

pub fn manifestEqual(a: Manifest, b: Manifest) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (!std.mem.eql(u8, a.sig, b.sig)) return false;
    if (a.nodes.len != b.nodes.len) return false;
    for (a.nodes, b.nodes) |na, nb| {
        if (!nodeEqual(na, nb)) return false;
    }
    return true;
}

pub fn nodeEqual(a: Node, b: Node) bool {
    const TagT = std.meta.Tag(Node);
    if (@as(TagT, a) != @as(TagT, b)) return false;
    return switch (a) {
        .literal => true,
        .expr => |ae| ae.kind == b.expr.kind and std.mem.eql(u8, ae.source, b.expr.source),
        .component => |ac| componentEqual(ac, b.component),
        .component_end, .if_else, .if_end, .for_end, .children_slot => true,
        .if_begin => |s| std.mem.eql(u8, s, b.if_begin),
        .for_begin => |fa| std.mem.eql(u8, fa.iterable_source, b.for_begin.iterable_source) and
            std.mem.eql(u8, fa.binding, b.for_begin.binding),
        // Comments and raw Zig statements don't affect HMR-relevant structure
        // — manifest equality ignores their content. The parser only emits
        // them for regression parity with the existing transpiler.
        .line_comment => true,
        .zig_stmt => true,
    };
}

fn componentEqual(a: Component, b: Component) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.has_children != b.has_children) return false;
    if (a.attrs.len != b.attrs.len) return false;
    for (a.attrs, b.attrs) |aa, ba| {
        if (!attrEqual(aa, ba)) return false;
    }
    return true;
}

fn attrEqual(a: Attr, b: Attr) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    const TagT = std.meta.Tag(AttrValue);
    if (@as(TagT, a.value) != @as(TagT, b.value)) return false;
    return switch (a.value) {
        .string => |s| std.mem.eql(u8, s, b.value.string),
        .expr => |s| std.mem.eql(u8, s, b.value.expr),
        .bool_present => true,
    };
}
};

pub const parse_mod = struct {
const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest_src = manifest_mod;

pub const Manifest = manifest_src.Manifest;
pub const Node = manifest_src.Node;
pub const Attr = manifest_src.Attr;
pub const AttrValue = manifest_src.AttrValue;
pub const Component = manifest_src.Component;
pub const Expr = manifest_src.Expr;
pub const ExprKind = manifest_src.ExprKind;
pub const Literal = manifest_src.Literal;
pub const ForHead = manifest_src.ForHead;
pub const manifestEqual = manifest_src.manifestEqual;

pub const ParseError = error{
    ExpectedFn,
    ExpectedFunctionName,
    ExpectedOpenParen,
    ExpectedOpenBrace,
    ExpectedCloseBrace,
    UnmatchedParen,
    UnmatchedBrace,
    UnterminatedString,
    UnterminatedTag,
    UnterminatedComponent,
    UnterminatedBacktick,
    UnterminatedComment,
    MalformedAttribute,
    MalformedIf,
    MalformedFor,
    OutOfMemory,
};

const void_elements = [_][]const u8{
    "area", "base", "br",     "col",   "embed", "hr", "img", "input",
    "link", "meta", "source", "track", "wbr",
};

fn isVoidElement(tag: []const u8) bool {
    for (void_elements) |v| {
        if (std.mem.eql(u8, v, tag)) return true;
    }
    return false;
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    allocator: Allocator,
    literal_buf: std.ArrayListUnmanaged(u8) = .{},
    literals: std.ArrayListUnmanaged([]const u8) = .{},
    nodes: std.ArrayListUnmanaged(Node) = .{},

    fn reset(self: *Parser) void {
        // Free everything held in builder state (used between parseAll iterations).
        self.literal_buf.deinit(self.allocator);
        for (self.literals.items) |lit| self.allocator.free(lit);
        self.literals.deinit(self.allocator);
        for (self.nodes.items) |n| freeNodeFromList(self.allocator, n);
        self.nodes.deinit(self.allocator);
        self.literal_buf = .{};
        self.literals = .{};
        self.nodes = .{};
    }

    fn deinitPartial(self: *Parser) void {
        self.literal_buf.deinit(self.allocator);
        for (self.literals.items) |lit| self.allocator.free(lit);
        self.literals.deinit(self.allocator);
        for (self.nodes.items) |n| freeNodeFromList(self.allocator, n);
        self.nodes.deinit(self.allocator);
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.i < self.src.len) self.src[self.i] else null;
    }

    fn peekAt(self: *const Parser, off: usize) ?u8 {
        const idx = self.i + off;
        return if (idx < self.src.len) self.src[idx] else null;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.i < self.src.len and isWs(self.src[self.i])) : (self.i += 1) {}
    }

    fn flushLiteral(self: *Parser) ParseError!void {
        if (self.literal_buf.items.len == 0) return;
        const owned = try self.literal_buf.toOwnedSlice(self.allocator);
        try self.literals.append(self.allocator, owned);
        const slot: u32 = @intCast(self.literals.items.len - 1);
        try self.nodes.append(self.allocator, .{ .literal = .{ .slot = slot } });
    }

    fn bake(self: *Parser, c: u8) ParseError!void {
        try self.literal_buf.append(self.allocator, c);
    }

    fn bakeSlice(self: *Parser, s: []const u8) ParseError!void {
        try self.literal_buf.appendSlice(self.allocator, s);
    }
};

// Public API

pub fn parse(allocator: Allocator, source: []const u8) ParseError!Manifest {
    var p = Parser{ .src = source, .allocator = allocator };
    errdefer p.deinitPartial();
    if (!findNextFunction(&p)) return ParseError.ExpectedFn;
    return try parseOneFunction(&p);
}

pub fn parseAll(allocator: Allocator, source: []const u8) ParseError![]Manifest {
    var list = std.ArrayListUnmanaged(Manifest){};
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }
    var p = Parser{ .src = source, .allocator = allocator };
    errdefer p.deinitPartial();

    while (findNextFunction(&p)) {
        const m = try parseOneFunction(&p);
        try list.append(allocator, m);
    }
    return try list.toOwnedSlice(allocator);
}

// Top-level scanning

/// Scan forward from p.i looking for a `pub fn ` or `fn ` that starts at column 0
/// (i.e. either p.i == 0 or the preceding char is '\n'). Sets p.i to the start of
/// the keyword and returns true; returns false on EOF.
fn findNextFunction(p: *Parser) bool {
    while (p.i < p.src.len) {
        const at_line_start = p.i == 0 or p.src[p.i - 1] == '\n';
        if (at_line_start) {
            if (slicePrefix(p.src, p.i, "pub fn ")) return true;
            if (slicePrefix(p.src, p.i, "fn ")) return true;
        }
        p.i += 1;
    }
    return false;
}

fn slicePrefix(src: []const u8, start: usize, kw: []const u8) bool {
    if (start + kw.len > src.len) return false;
    return std.mem.eql(u8, src[start .. start + kw.len], kw);
}

fn parseOneFunction(p: *Parser) ParseError!Manifest {
    if (matchKeyword(p, "pub")) p.skipWhitespace();
    if (!matchKeyword(p, "fn")) return ParseError.ExpectedFn;
    p.skipWhitespace();

    const name_start = p.i;
    while (p.i < p.src.len and isIdentChar(p.src[p.i])) : (p.i += 1) {}
    if (p.i == name_start) return ParseError.ExpectedFunctionName;
    const name_slice = p.src[name_start..p.i];

    p.skipWhitespace();
    if (p.peek() != @as(?u8, '(')) return ParseError.ExpectedOpenParen;
    p.i += 1;
    const sig_start = p.i;
    var paren_depth: usize = 1;
    while (p.i < p.src.len and paren_depth > 0) {
        const c = p.src[p.i];
        switch (c) {
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            else => {},
        }
        if (paren_depth > 0) p.i += 1;
    }
    if (paren_depth != 0) return ParseError.UnmatchedParen;
    const sig_slice = p.src[sig_start..p.i];
    p.i += 1; // ')'

    p.skipWhitespace();
    // Optional return type: `void`, `!void`, etc. — skip up to '{'.
    while (p.i < p.src.len and p.src[p.i] != '{') : (p.i += 1) {}
    if (p.peek() != @as(?u8, '{')) return ParseError.ExpectedOpenBrace;
    p.i += 1;

    try parseInnerBody(p, .end_brace);

    if (p.peek() != @as(?u8, '}')) return ParseError.ExpectedCloseBrace;
    p.i += 1;

    const name_copy = try p.allocator.dupe(u8, name_slice);
    errdefer p.allocator.free(name_copy);
    const sig_copy = try p.allocator.dupe(u8, sig_slice);
    errdefer p.allocator.free(sig_copy);

    const nodes_owned = try p.nodes.toOwnedSlice(p.allocator);
    const lits_owned = try p.literals.toOwnedSlice(p.allocator);
    p.literal_buf.deinit(p.allocator);
    p.literal_buf = .{};
    p.literals = .{};
    p.nodes = .{};

    return Manifest{
        .name = name_copy,
        .sig = sig_copy,
        .nodes = nodes_owned,
        .literals = lits_owned,
    };
}

// Inner node-stream parser

const Term = union(enum) {
    /// Stop at a top-level '}'. Consumed by the caller (not by parseInner).
    end_brace,
    /// Stop when p.i >= end.
    end_pos: usize,
    /// Stop at the next '</' (caller handles consuming it).
    end_close_tag,
};

fn termReached(p: *Parser, term: Term) bool {
    if (p.i >= p.src.len) return true;
    return switch (term) {
        .end_brace => p.src[p.i] == '}',
        .end_pos => |pos| p.i >= pos,
        .end_close_tag => p.src[p.i] == '<' and p.peekAt(1) == @as(?u8, '/'),
    };
}

fn parseInner(p: *Parser, term: Term) ParseError!void {
    return parseInnerCtx(p, term, false);
}

fn parseInnerBody(p: *Parser, term: Term) ParseError!void {
    return parseInnerCtx(p, term, true);
}

fn parseInnerCtx(p: *Parser, term: Term, is_body: bool) ParseError!void {
    while (p.i < p.src.len) {
        if (termReached(p, term)) {
            try p.flushLiteral();
            return;
        }
        const c = p.src[p.i];
        // In body mode, any non-tag, non-expression content that isn't pure
        // whitespace is Zig passthrough — emit as a verbatim Zig node so it
        // ends up in the generated source outside the writeAll buffer.
        if (is_body) {
            // Skip leading whitespace (it gets dropped — see emit's normalize).
            if (isWs(c)) {
                try p.bake(c);
                p.i += 1;
                continue;
            }
            const is_jsx_lt = c == '<' and p.i + 1 < p.src.len and
                (isAlpha(p.src[p.i + 1]) or p.src[p.i + 1] == '!');
            const is_jsx_expr = c == '{' and p.i + 1 < p.src.len and
                (p.src[p.i + 1] == '`' or isAlpha(p.src[p.i + 1]) or p.src[p.i + 1] == '@');
            if (!is_jsx_lt and !is_jsx_expr) {
                try p.flushLiteral();
                try parseZigPassthrough(p, term);
                continue;
            }
        }
        if (c == '/' and p.peekAt(1) == @as(?u8, '/')) {
            // Line comment at the start of a "logical line" (preceded only by
            // whitespace since the last newline in the literal buffer) — drop
            // it. This mirrors the existing transpiler's behaviour where
            // body-level `// ...` lines fall into the Zig passthrough path
            // and are emitted as comments outside the generated string. Our
            // manifest representation doesn't carry these comments, so the
            // safest approximation is to drop them. Comments embedded in
            // visible text content (rare) are not currently distinguishable
            // from line-start comments — see KNOWN_DIVERGENCES.md if this
            // ever bites.
            var at_line_start = true;
            var k = p.literal_buf.items.len;
            while (k > 0) : (k -= 1) {
                const lc = p.literal_buf.items[k - 1];
                if (lc == '\n') break;
                if (lc != ' ' and lc != '\t') {
                    at_line_start = false;
                    break;
                }
            }
            if (at_line_start) {
                const cmt_start = p.i;
                while (p.i < p.src.len and p.src[p.i] != '\n') : (p.i += 1) {}
                const cmt = p.src[cmt_start..p.i];
                // Strip any leading whitespace on this comment's line so it
                // doesn't leave an orphan indent literal.
                var kk = p.literal_buf.items.len;
                while (kk > 0 and (p.literal_buf.items[kk - 1] == ' ' or p.literal_buf.items[kk - 1] == '\t')) : (kk -= 1) {}
                p.literal_buf.shrinkRetainingCapacity(kk);
                try p.flushLiteral();
                const cmt_copy = try p.allocator.dupe(u8, cmt);
                try p.nodes.append(p.allocator, .{ .line_comment = cmt_copy });
                continue;
            }
            // Otherwise treat as ordinary text — bake the `/` and let the
            // loop handle the rest.
        }
        if (c == '{') {
            try p.flushLiteral();
            try parseExpression(p);
        } else if (c == '<') {
            const nxt = p.peekAt(1);
            if (nxt == @as(?u8, '!')) {
                try parseDoctypeOrComment(p);
            } else if (nxt != null and isUpper(nxt.?)) {
                try p.flushLiteral();
                try parseComponent(p);
            } else if (nxt != null and (isLower(nxt.?) or nxt.? == '_')) {
                try parseHtmlTag(p);
            } else {
                // Stray '<' — bake as literal.
                try p.bake('<');
                p.i += 1;
            }
        } else {
            try p.bake(c);
            p.i += 1;
        }
    }
    try p.flushLiteral();
}

/// Consume Zig source up to the next `<` (with alpha/!), `{` (with valid
/// JSX-expression next char), or the parser's term boundary. Tracks braces,
/// parens, brackets, strings, and chars so that Zig constructs like
/// `switch (x) { .foo => "bar" }` survive intact. Emits a single
/// `.zig_stmt` node containing the trimmed Zig text. Mirrors the existing
/// transpiler's `parseFunctionBody` Zig passthrough block.
fn parseZigPassthrough(p: *Parser, term: Term) ParseError!void {
    const start = p.i;
    var brace: usize = 0;
    var paren: usize = 0;
    var brack: usize = 0;
    while (p.i < p.src.len) {
        // At zero nesting depth, stop on term boundary, JSX, or expression
        // starts. Inside any depth, copy verbatim.
        if (brace == 0 and paren == 0 and brack == 0) {
            if (termReached(p, term)) break;
            const c = p.src[p.i];
            if (c == '<' and p.i + 1 < p.src.len) {
                const nxt = p.src[p.i + 1];
                if (isAlpha(nxt) or nxt == '!') break;
            }
            if (c == '{' and p.i + 1 < p.src.len) {
                const nxt = p.src[p.i + 1];
                if (nxt == '`' or isAlpha(nxt) or nxt == '@') break;
            }
        }
        // Line comments inside Zig passthrough are part of the Zig text —
        // skip past them so the inner `//` doesn't terminate parsing.
        if (p.src[p.i] == '/' and p.peekAt(1) == @as(?u8, '/')) {
            while (p.i < p.src.len and p.src[p.i] != '\n') : (p.i += 1) {}
            continue;
        }
        const c = p.src[p.i];
        switch (c) {
            '{' => brace += 1,
            '}' => if (brace > 0) {
                brace -= 1;
            },
            '(' => paren += 1,
            ')' => if (paren > 0) {
                paren -= 1;
            },
            '[' => brack += 1,
            ']' => if (brack > 0) {
                brack -= 1;
            },
            '"' => {
                p.i += 1;
                try skipStringLiteral(p, '"');
                continue;
            },
            '\'' => {
                p.i += 1;
                try skipStringLiteral(p, '\'');
                continue;
            },
            else => {},
        }
        p.i += 1;
    }
    const raw = p.src[start..p.i];
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    if (trimmed.len == 0) return;
    const copy = try p.allocator.dupe(u8, trimmed);
    try p.nodes.append(p.allocator, .{ .zig_stmt = copy });
}

// Expressions

fn parseExpression(p: *Parser) ParseError!void {
    // Caller guarantees src[p.i] == '{'.
    p.i += 1;

    // Backtick interpolation: { `...` }
    if (p.peek() == @as(?u8, '`')) {
        const bt_start_with_tick = p.i;
        p.i += 1; // skip opening `
        while (p.i < p.src.len and p.src[p.i] != '`') {
            if (p.src[p.i] == '\\' and p.i + 1 < p.src.len) {
                p.i += 2;
                continue;
            }
            p.i += 1;
        }
        if (p.i >= p.src.len) return ParseError.UnterminatedBacktick;
        p.i += 1; // closing `
        const bt_slice = p.src[bt_start_with_tick..p.i];
        // skip whitespace then closing '}'
        while (p.i < p.src.len and isWs(p.src[p.i])) : (p.i += 1) {}
        if (p.peek() != @as(?u8, '}')) return ParseError.UnmatchedBrace;
        p.i += 1;
        const src_copy = try p.allocator.dupe(u8, bt_slice);
        try p.nodes.append(p.allocator, .{ .expr = .{ .kind = .backtick, .source = src_copy } });
        return;
    }

    // {@raw expr}
    var is_raw = false;
    if (slicePrefix(p.src, p.i, "@raw ") or slicePrefix(p.src, p.i, "@raw\t")) {
        is_raw = true;
        p.i += 5;
    }

    // Skip whitespace inside the brace.
    while (p.i < p.src.len and isWs(p.src[p.i])) : (p.i += 1) {}

    // Control flow: {if ...} / {for ...}.
    if (!is_raw and (matchKeywordAt(p, "if(") or matchKeywordAt(p, "if "))) {
        try parseIfChain(p, true);
        return;
    }
    if (!is_raw and (matchKeywordAt(p, "for(") or matchKeywordAt(p, "for "))) {
        try parseFor(p);
        return;
    }

    // Plain (possibly ternary/elvis) expression.
    const start = p.i;
    var depth: usize = 1;
    while (p.i < p.src.len and depth > 0) {
        const c = p.src[p.i];
        switch (c) {
            '{' => depth += 1,
            '}' => depth -= 1,
            '"' => {
                p.i += 1;
                try skipStringLiteral(p, '"');
                continue;
            },
            '\'' => {
                p.i += 1;
                try skipStringLiteral(p, '\'');
                continue;
            },
            '`' => {
                p.i += 1;
                try skipBacktick(p);
                continue;
            },
            else => {},
        }
        if (depth > 0) p.i += 1;
    }
    if (depth != 0) return ParseError.UnmatchedBrace;
    const raw = std.mem.trim(u8, p.src[start..p.i], " \t\r\n");
    p.i += 1; // skip '}'

    // Detect children slot.
    if (!is_raw and std.mem.eql(u8, raw, "props.children")) {
        try p.nodes.append(p.allocator, .children_slot);
        return;
    }

    const kind = if (is_raw) ExprKind.raw else classifyTernary(raw);
    const src_copy = try p.allocator.dupe(u8, raw);
    try p.nodes.append(p.allocator, .{ .expr = .{ .kind = kind, .source = src_copy } });
}

fn classifyTernary(expr: []const u8) ExprKind {
    var paren_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var has_question = false;
    var has_colon = false;
    var is_elvis = false;
    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        switch (c) {
            '"' => {
                i += 1;
                while (i < expr.len) {
                    if (expr[i] == '\\' and i + 1 < expr.len) {
                        i += 2;
                        continue;
                    }
                    if (expr[i] == '"') {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
                continue;
            },
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => if (brace_depth > 0) {
                brace_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '?' => {
                if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                    // skip `.?` optional unwrap
                    if (i > 0 and expr[i - 1] == '.') {
                        i += 1;
                        continue;
                    }
                    if (!has_question) {
                        has_question = true;
                        if (i + 1 < expr.len and expr[i + 1] == ':') {
                            is_elvis = true;
                            i += 2;
                            continue;
                        }
                    }
                }
            },
            ':' => {
                if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                    if (has_question and !has_colon and !is_elvis) has_colon = true;
                }
            },
            else => {},
        }
        i += 1;
    }
    if (is_elvis) return .elvis;
    if (has_question and has_colon) return .ternary;
    return .plain;
}

fn skipStringLiteral(p: *Parser, quote: u8) ParseError!void {
    while (p.i < p.src.len) {
        const c = p.src[p.i];
        if (c == '\\' and p.i + 1 < p.src.len) {
            p.i += 2;
            continue;
        }
        if (c == quote) {
            p.i += 1;
            return;
        }
        p.i += 1;
    }
    return ParseError.UnterminatedString;
}

fn skipBacktick(p: *Parser) ParseError!void {
    while (p.i < p.src.len) {
        const c = p.src[p.i];
        if (c == '\\' and p.i + 1 < p.src.len) {
            p.i += 2;
            continue;
        }
        if (c == '`') {
            p.i += 1;
            return;
        }
        p.i += 1;
    }
    return ParseError.UnterminatedBacktick;
}

// Control flow: {if} / {for}

fn parseIfChain(p: *Parser, comptime is_first: bool) ParseError!void {
    // Caller has set p.i at the start of "if (" or "if(".
    if (matchKeyword(p, "if")) {} else return ParseError.MalformedIf;
    p.skipWhitespace();
    if (p.peek() != @as(?u8, '(')) return ParseError.MalformedIf;
    p.i += 1;
    const cond = try readBalancedParens(p);

    p.skipWhitespace();
    if (p.peek() != @as(?u8, '(')) return ParseError.MalformedIf;
    p.i += 1;
    const body_end = try scanBalancedParenEnd(p);
    const body_start = p.i;

    const cond_copy = try p.allocator.dupe(u8, cond);
    try p.nodes.append(p.allocator, .{ .if_begin = cond_copy });

    // Parse body nodes up to body_end. We must save/restore terminator state.
    p.i = body_start;
    try parseInnerBody(p, .{ .end_pos = body_end });
    p.i = body_end + 1; // skip ')'

    p.skipWhitespace();

    // else / else if
    if (matchKeyword(p, "else")) {
        try p.nodes.append(p.allocator, .if_else);
        p.skipWhitespace();
        if (matchKeywordAt(p, "if(") or matchKeywordAt(p, "if ")) {
            // Recurse — produces nested if_begin/.../if_end
            try parseIfChain(p, false);
            // The nested parseIfChain emitted its own if_end; we still need ours.
        } else {
            // else (body)
            if (p.peek() != @as(?u8, '(')) return ParseError.MalformedIf;
            p.i += 1;
            const else_end = try scanBalancedParenEnd(p);
            try parseInnerBody(p, .{ .end_pos = else_end });
            p.i = else_end + 1;
        }
    }

    try p.nodes.append(p.allocator, .if_end);

    if (is_first) {
        p.skipWhitespace();
        if (p.peek() == @as(?u8, '}')) p.i += 1;
    }
}

fn parseFor(p: *Parser) ParseError!void {
    if (!matchKeyword(p, "for")) return ParseError.MalformedFor;
    p.skipWhitespace();
    if (p.peek() != @as(?u8, '(')) return ParseError.MalformedFor;
    p.i += 1;
    const iter = try readBalancedParens(p);

    p.skipWhitespace();
    if (p.peek() != @as(?u8, '|')) return ParseError.MalformedFor;
    p.i += 1;
    const cap_start = p.i;
    while (p.i < p.src.len and p.src[p.i] != '|') : (p.i += 1) {}
    if (p.peek() != @as(?u8, '|')) return ParseError.MalformedFor;
    const binding = std.mem.trim(u8, p.src[cap_start..p.i], " \t\r\n");
    p.i += 1; // '|'

    p.skipWhitespace();
    if (p.peek() != @as(?u8, '(')) return ParseError.MalformedFor;
    p.i += 1;
    const body_end = try scanBalancedParenEnd(p);

    const iter_copy = try p.allocator.dupe(u8, iter);
    errdefer p.allocator.free(iter_copy);
    const binding_copy = try p.allocator.dupe(u8, binding);
    errdefer p.allocator.free(binding_copy);
    try p.nodes.append(p.allocator, .{ .for_begin = .{
        .iterable_source = iter_copy,
        .binding = binding_copy,
    } });

    try parseInnerBody(p, .{ .end_pos = body_end });
    p.i = body_end + 1; // ')'

    try p.nodes.append(p.allocator, .for_end);

    p.skipWhitespace();
    if (p.peek() == @as(?u8, '}')) p.i += 1;
}

/// Caller positioned p.i past the opening '('. Reads up to (but not past) the
/// matching ')'. Advances p.i to ')' position (caller skips it). Returns slice
/// between parens (string-aware).
fn readBalancedParens(p: *Parser) ParseError![]const u8 {
    const start = p.i;
    var depth: usize = 1;
    while (p.i < p.src.len and depth > 0) {
        const c = p.src[p.i];
        switch (c) {
            '(' => depth += 1,
            ')' => depth -= 1,
            '"' => {
                p.i += 1;
                try skipStringLiteral(p, '"');
                continue;
            },
            '\'' => {
                p.i += 1;
                try skipStringLiteral(p, '\'');
                continue;
            },
            else => {},
        }
        if (depth > 0) p.i += 1;
    }
    if (depth != 0) return ParseError.UnmatchedParen;
    const slice = p.src[start..p.i];
    p.i += 1; // skip ')'
    return slice;
}

/// Like readBalancedParens but does NOT advance past the ')'. Returns the
/// position of the matching ')'. Caller controls p.i.
fn scanBalancedParenEnd(p: *Parser) ParseError!usize {
    var j = p.i;
    var depth: usize = 1;
    while (j < p.src.len and depth > 0) {
        const c = p.src[j];
        switch (c) {
            '(' => depth += 1,
            ')' => depth -= 1,
            '"' => {
                j += 1;
                while (j < p.src.len) {
                    if (p.src[j] == '\\' and j + 1 < p.src.len) {
                        j += 2;
                        continue;
                    }
                    if (p.src[j] == '"') {
                        j += 1;
                        break;
                    }
                    j += 1;
                }
                continue;
            },
            else => {},
        }
        if (depth > 0) j += 1;
    }
    if (depth != 0) return ParseError.UnmatchedParen;
    return j;
}

// JSX tags

fn parseDoctypeOrComment(p: *Parser) ParseError!void {
    // src[p.i] == '<' and src[p.i+1] == '!'
    if (slicePrefix(p.src, p.i, "<!--")) {
        // HTML comment — drop entirely.
        p.i += 4;
        while (p.i + 2 < p.src.len) : (p.i += 1) {
            if (p.src[p.i] == '-' and p.src[p.i + 1] == '-' and p.src[p.i + 2] == '>') {
                p.i += 3;
                return;
            }
        }
        return ParseError.UnterminatedComment;
    }
    // DOCTYPE or other <!...>: bake verbatim.
    try p.bake('<');
    p.i += 1;
    while (p.i < p.src.len and p.src[p.i] != '>') : (p.i += 1) {
        try p.bake(p.src[p.i]);
    }
    if (p.i >= p.src.len) return ParseError.UnterminatedTag;
    try p.bake('>');
    p.i += 1;
}

// Temporary attribute holder used by parseHtmlTag. We collect all attrs
// up front then bake statics-then-dynamics, matching the existing transpiler's
// emit order. The dynamic-attr expression is stored as a borrowed source slice
// — we re-walk it when baking to produce the correct Node.
const HtmlAttrKind = enum { static, dynamic, enum_lit, boolean };
const HtmlAttr = struct {
    name: []const u8,
    kind: HtmlAttrKind,
    // For .static: the unescaped value string (slice into p.src).
    // For .dynamic / .enum_lit: the expression source.
    value: []const u8 = "",
};

fn parseHtmlTag(p: *Parser) ParseError!void {
    // src[p.i] == '<' and src[p.i+1] is lowercase or '_'.
    p.i += 1; // '<'
    const name_start = p.i;
    while (p.i < p.src.len and isTagNameChar(p.src[p.i])) : (p.i += 1) {}
    const tag_name = p.src[name_start..p.i];
    if (tag_name.len == 0) return ParseError.UnterminatedTag;

    // Collect attrs in source order; we'll re-order at bake time so static
    // attrs come first (matching the existing transpiler).
    var attrs = std.ArrayListUnmanaged(HtmlAttr){};
    defer attrs.deinit(p.allocator);

    var self_closing = false;
    while (true) {
        while (p.i < p.src.len and isWs(p.src[p.i])) : (p.i += 1) {}
        if (p.i >= p.src.len) return ParseError.UnterminatedTag;

        if (p.src[p.i] == '/' and p.peekAt(1) == @as(?u8, '>')) {
            p.i += 2;
            self_closing = true;
            break;
        }
        if (p.src[p.i] == '>') {
            p.i += 1;
            break;
        }

        // Attribute name.
        const attr_name_start = p.i;
        while (p.i < p.src.len and isAttrIdentChar(p.src[p.i])) : (p.i += 1) {}
        if (p.i == attr_name_start) return ParseError.MalformedAttribute;
        const attr_name = p.src[attr_name_start..p.i];

        if (p.peek() == @as(?u8, '=')) {
            p.i += 1;
            if (p.i >= p.src.len) return ParseError.MalformedAttribute;
            const vc = p.src[p.i];
            if (vc == '"') {
                p.i += 1;
                const val_start = p.i;
                while (p.i < p.src.len and p.src[p.i] != '"') : (p.i += 1) {}
                if (p.i >= p.src.len) return ParseError.UnterminatedString;
                const val_slice = p.src[val_start..p.i];
                p.i += 1;
                try attrs.append(p.allocator, .{
                    .name = attr_name,
                    .kind = .static,
                    .value = val_slice,
                });
            } else if (vc == '{') {
                p.i += 1;
                const val_start = p.i;
                var depth: usize = 1;
                while (p.i < p.src.len and depth > 0) {
                    const c = p.src[p.i];
                    switch (c) {
                        '{' => depth += 1,
                        '}' => depth -= 1,
                        '"' => {
                            p.i += 1;
                            try skipStringLiteral(p, '"');
                            continue;
                        },
                        '\'' => {
                            p.i += 1;
                            try skipStringLiteral(p, '\'');
                            continue;
                        },
                        '`' => {
                            p.i += 1;
                            try skipBacktick(p);
                            continue;
                        },
                        else => {},
                    }
                    if (depth > 0) p.i += 1;
                }
                if (depth != 0) return ParseError.UnmatchedBrace;
                const val_raw = std.mem.trim(u8, p.src[val_start..p.i], " \t\r\n");
                p.i += 1;
                try attrs.append(p.allocator, .{
                    .name = attr_name,
                    .kind = .dynamic,
                    .value = val_raw,
                });
            } else if (vc == '.') {
                const val_start = p.i;
                p.i += 1;
                while (p.i < p.src.len and isIdentChar(p.src[p.i])) : (p.i += 1) {}
                const val_raw = p.src[val_start..p.i];
                try attrs.append(p.allocator, .{
                    .name = attr_name,
                    .kind = .enum_lit,
                    .value = val_raw,
                });
            } else {
                return ParseError.MalformedAttribute;
            }
        } else {
            // Boolean HTML attribute. The existing transpiler treats these
            // as dynamic with value `true` (e.g. `disabled` → emits
            // `disabled="<render true>"`). Match that behaviour so the
            // output is byte-equal.
            try attrs.append(p.allocator, .{
                .name = attr_name,
                .kind = .dynamic,
                .value = "true",
            });
        }
    }

    // Bake "<tag" + static attrs first.
    try p.bake('<');
    try p.bakeSlice(tag_name);
    // Several `:attr` binds on one element each map to data-p-bind; HTML keeps
    // only the FIRST duplicate attribute, so accumulate them and emit a single
    // data-p-bind="a:x;b:y" (the runtime splits the value on ';').
    var bind_acc: std.ArrayListUnmanaged(u8) = .{};
    defer bind_acc.deinit(p.allocator);
    for (attrs.items) |a| {
        if (a.kind == .static) {
            // Spec §10: rewrite @event / :directive names to data-p-* (+ value).
            const md = try mapDirectiveAttr(p.allocator, a.name, a.value);
            if (std.mem.eql(u8, md.name, "data-p-bind")) {
                if (bind_acc.items.len > 0) try bind_acc.append(p.allocator, ';');
                try bind_acc.appendSlice(p.allocator, md.value);
            } else {
                try p.bake(' ');
                try p.bakeSlice(md.name);
                try p.bakeSlice("=\"");
                try p.bakeSlice(md.value);
                try p.bake('"');
            }
            // Baking copies the bytes, so free any value the mapping allocated.
            if (md.value.ptr != a.value.ptr) p.allocator.free(md.value);
        }
    }
    if (bind_acc.items.len > 0) {
        try p.bake(' ');
        try p.bakeSlice("data-p-bind=\"");
        try p.bakeSlice(bind_acc.items);
        try p.bake('"');
    }

    // Then bake dynamic/enum_lit attrs as `name="` + expr + `"` splits.
    for (attrs.items) |a| {
        switch (a.kind) {
            .static => {},
            .boolean => {
                // The existing transpiler emits boolean component-attrs as
                // `name = true` in component-prop position, but for HTML tags
                // the original parser also bakes nothing for boolean HTML
                // attrs (they go through emitComponentProps only on components).
                // We mirror that — HTML boolean attrs aren't expected; if they
                // appear, bake the name verbatim with a leading space.
                try p.bake(' ');
                try p.bakeSlice(a.name);
            },
            .dynamic, .enum_lit => {
                try p.bake(' ');
                try p.bakeSlice(directiveName(a.name) orelse a.name); // map @data/@store/:class… (value stays dynamic)
                try p.bakeSlice("=\"");
                try p.flushLiteral();
                const kind: ExprKind = if (a.kind == .enum_lit) .plain else blk: {
                    if (a.value.len >= 2 and a.value[0] == '`' and a.value[a.value.len - 1] == '`') {
                        break :blk .backtick;
                    }
                    break :blk classifyTernary(a.value);
                };
                const src_copy = try p.allocator.dupe(u8, a.value);
                try p.nodes.append(p.allocator, .{ .expr = .{ .kind = kind, .source = src_copy } });
                try p.bake('"');
            },
        }
    }

    // Self-closing HTML tags (and void elements) always bake as `<tag>` —
    // matches the existing transpiler's emitHtmlTag, which never emits `/>`.
    try p.bake('>');
    // For non-void HTML tags that were written as self-closing in source,
    // append a sentinel byte so the emitter can balance its tag-depth
    // counter without changing the visible output. The sentinel is `\x01`,
    // which doesn't appear in any well-formed template; emit strips it.
    if (self_closing and !isVoidElement(tag_name)) {
        try p.bake(0x01);
    }

    // If the tag is self-closing or void, we're done.
    if (self_closing or isVoidElement(tag_name)) return;

    // Otherwise, parse children, then bake the closing tag.
    try parseInner(p, .end_close_tag);

    // Consume `</tagname>` and bake it as literal text.
    if (p.i + 2 > p.src.len or p.src[p.i] != '<' or p.src[p.i + 1] != '/') {
        // Unterminated — bake as best-effort and return.
        return;
    }
    p.i += 2;
    const close_name_start = p.i;
    while (p.i < p.src.len and isTagNameChar(p.src[p.i])) : (p.i += 1) {}
    const close_name = p.src[close_name_start..p.i];
    // Skip optional whitespace and consume '>'.
    while (p.i < p.src.len and isWs(p.src[p.i])) : (p.i += 1) {}
    if (p.peek() != @as(?u8, '>')) return ParseError.UnterminatedTag;
    p.i += 1;
    // Bake `</name>` (normalised — no internal whitespace).
    try p.bakeSlice("</");
    try p.bakeSlice(close_name);
    try p.bake('>');
}

fn parseComponent(p: *Parser) ParseError!void {
    p.i += 1; // '<'
    const name_start = p.i;
    while (p.i < p.src.len and isIdentChar(p.src[p.i])) : (p.i += 1) {}
    const name_slice = p.src[name_start..p.i];

    var attrs = std.ArrayListUnmanaged(Attr){};
    errdefer {
        for (attrs.items) |a| {
            p.allocator.free(a.name);
            switch (a.value) {
                .string => |s| p.allocator.free(s),
                .expr => |s| p.allocator.free(s),
                .bool_present => {},
            }
        }
        attrs.deinit(p.allocator);
    }

    var has_children = false;

    while (true) {
        while (p.i < p.src.len and isWs(p.src[p.i])) : (p.i += 1) {}
        if (p.i >= p.src.len) return ParseError.UnterminatedComponent;

        if (p.src[p.i] == '/' and p.peekAt(1) == @as(?u8, '>')) {
            p.i += 2;
            break;
        }
        if (p.src[p.i] == '>') {
            p.i += 1;
            has_children = true;
            break;
        }

        const attr_name_start = p.i;
        while (p.i < p.src.len and isAttrIdentChar(p.src[p.i])) : (p.i += 1) {}
        if (p.i == attr_name_start) return ParseError.MalformedAttribute;
        const attr_name_slice = p.src[attr_name_start..p.i];

        var value: AttrValue = .bool_present;
        if (p.peek() == @as(?u8, '=')) {
            p.i += 1;
            if (p.i >= p.src.len) return ParseError.MalformedAttribute;
            const vc = p.src[p.i];
            if (vc == '"') {
                p.i += 1;
                const vs = p.i;
                while (p.i < p.src.len and p.src[p.i] != '"') : (p.i += 1) {}
                if (p.i >= p.src.len) return ParseError.UnterminatedString;
                const val = try p.allocator.dupe(u8, p.src[vs..p.i]);
                p.i += 1;
                value = .{ .string = val };
            } else if (vc == '{') {
                p.i += 1;
                const vs = p.i;
                var depth: usize = 1;
                while (p.i < p.src.len and depth > 0) {
                    const c = p.src[p.i];
                    switch (c) {
                        '{' => depth += 1,
                        '}' => depth -= 1,
                        '"' => {
                            p.i += 1;
                            try skipStringLiteral(p, '"');
                            continue;
                        },
                        '\'' => {
                            p.i += 1;
                            try skipStringLiteral(p, '\'');
                            continue;
                        },
                        '`' => {
                            p.i += 1;
                            try skipBacktick(p);
                            continue;
                        },
                        else => {},
                    }
                    if (depth > 0) p.i += 1;
                }
                if (depth != 0) return ParseError.UnmatchedBrace;
                const raw = std.mem.trim(u8, p.src[vs..p.i], " \t\r\n");
                p.i += 1;
                const val = try p.allocator.dupe(u8, raw);
                value = .{ .expr = val };
            } else if (vc == '.') {
                const vs = p.i;
                p.i += 1;
                while (p.i < p.src.len and isIdentChar(p.src[p.i])) : (p.i += 1) {}
                const val = try p.allocator.dupe(u8, p.src[vs..p.i]);
                value = .{ .expr = val };
            } else {
                return ParseError.MalformedAttribute;
            }
        }

        // Spec §10: rewrite @event / :directive names to data-p-* (+ value).
        var final_name = attr_name_slice;
        switch (value) {
            .string => |s| {
                const md = try mapDirectiveAttr(p.allocator, attr_name_slice, s);
                final_name = md.name;
                if (md.value.ptr != s.ptr) {
                    p.allocator.free(s); // mapping reallocated; release the orphaned dupe
                    value = .{ .string = md.value };
                }
            },
            else => {},
        }
        const name_copy = try p.allocator.dupe(u8, final_name);
        try attrs.append(p.allocator, .{ .name = name_copy, .value = value });
    }

    // Merge multiple data-p-bind attrs (several `:attr` on one component) into a
    // single ";"-separated value — HTML keeps only the first duplicate attribute.
    {
        var first: ?usize = null;
        var i: usize = 0;
        while (i < attrs.items.len) {
            const a = attrs.items[i];
            if (std.meta.activeTag(a.value) == .string and std.mem.eql(u8, a.name, "data-p-bind")) {
                if (first) |fi| {
                    const merged = try std.fmt.allocPrint(p.allocator, "{s};{s}", .{ attrs.items[fi].value.string, a.value.string });
                    p.allocator.free(attrs.items[fi].value.string);
                    p.allocator.free(a.value.string);
                    p.allocator.free(a.name);
                    attrs.items[fi].value = .{ .string = merged };
                    _ = attrs.orderedRemove(i);
                    continue; // don't advance: the next entry shifted into i
                }
                first = i;
            }
            i += 1;
        }
    }

    const name_copy = try p.allocator.dupe(u8, name_slice);
    const attrs_owned = try attrs.toOwnedSlice(p.allocator);
    try p.nodes.append(p.allocator, .{ .component = .{
        .name = name_copy,
        .attrs = attrs_owned,
        .has_children = has_children,
    } });

    if (!has_children) return;

    // Parse children until </Name>
    try parseInner(p, .end_close_tag);

    // Consume `</...>` — tolerate name mismatch (matches existing transpiler).
    if (p.i + 2 > p.src.len or p.src[p.i] != '<' or p.src[p.i + 1] != '/') {
        return ParseError.UnterminatedComponent;
    }
    p.i += 2;
    while (p.i < p.src.len and isIdentChar(p.src[p.i])) : (p.i += 1) {}
    while (p.i < p.src.len and isWs(p.src[p.i])) : (p.i += 1) {}
    if (p.peek() != @as(?u8, '>')) return ParseError.UnterminatedComponent;
    p.i += 1;

    try p.nodes.append(p.allocator, .component_end);
}

// Helpers

fn matchKeyword(p: *Parser, kw: []const u8) bool {
    if (!slicePrefix(p.src, p.i, kw)) return false;
    // Must be followed by non-ident (or EOF) — but only if kw ends in an ident char.
    const last = kw[kw.len - 1];
    if (isIdentChar(last)) {
        if (p.i + kw.len < p.src.len and isIdentChar(p.src[p.i + kw.len])) return false;
    }
    p.i += kw.len;
    return true;
}

/// Like matchKeyword but does not consume.
fn matchKeywordAt(p: *Parser, kw: []const u8) bool {
    if (!slicePrefix(p.src, p.i, kw)) return false;
    return true;
}

fn freeNodeFromList(allocator: Allocator, node: Node) void {
    switch (node) {
        .literal, .component_end, .if_else, .if_end, .for_end, .children_slot => {},
        .expr => |e| allocator.free(e.source),
        .component => |c| {
            allocator.free(c.name);
            for (c.attrs) |a| {
                allocator.free(a.name);
                switch (a.value) {
                    .string => |s| allocator.free(s),
                    .expr => |s| allocator.free(s),
                    .bool_present => {},
                }
            }
            allocator.free(c.attrs);
        },
        .if_begin => |s| allocator.free(s),
        .for_begin => |fh| {
            allocator.free(fh.iterable_source);
            allocator.free(fh.binding);
        },
        .line_comment => |s| allocator.free(s),
        .zig_stmt => |s| allocator.free(s),
    }
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isAlpha(c: u8) bool {
    return isUpper(c) or isLower(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}

fn isAttrIdentChar(c: u8) bool {
    return isIdentChar(c) or c == '-' or c == ':' or c == '@' or c == '.';
}

fn isTagNameChar(c: u8) bool {
    return isIdentChar(c) or c == '-';
}

const MappedAttr = struct { name: []const u8, value: []const u8 };

// Strip the optional `$` reactive-marker from a state-ref token. Authoring shape
// is `$path` so the value site signals "store reference, not a literal" (§10.0);
// the wire format (data-p-*) is the bare path. Permissive: bare tokens pass
// through so partial migrations keep building. NOTE: the runtime resolves bare
// paths only — it does NOT strip `$` — so the transpiler must strip it here.
fn stripDollar(value: []const u8) []const u8 {
    const t = std.mem.trim(u8, value, " \t\r\n");
    if (t.len > 0 and t[0] == '$') return t[1..];
    return t;
}

// Parse a :showIf/:hideIf/:bind/@renderIf predicate (§10.1) into the runtime's
// pipe wire format, evaluated without eval:
//   $ref                 -> "ref"            (truthy)
//   not $ref             -> "not:ref"        (boolean negation; bare refs only)
//   $ref <op> <literal>  -> "ref|<code>|literal"
// Comparison ops (longest-first): `<=` `>=` `==` `!=` `<` `>` → le ge eq ne lt gt.
// `$` is stripped from the path; the RHS literal is left as-is. `not` may not be
// combined with a comparison (write the positive form). Always allocates.
fn parsePredicate(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " ");

    var negated = false;
    var body = trimmed;
    if (std.mem.startsWith(u8, trimmed, "not ")) {
        negated = true;
        body = std.mem.trim(u8, trimmed[4..], " ");
    }

    const ops = [_]struct { token: []const u8, code: []const u8 }{
        .{ .token = "<=", .code = "le" },
        .{ .token = ">=", .code = "ge" },
        .{ .token = "==", .code = "eq" },
        .{ .token = "!=", .code = "ne" },
        .{ .token = "<", .code = "lt" },
        .{ .token = ">", .code = "gt" },
    };

    // `not` + comparison is invalid; emit the comparison best-effort (negation
    // dropped) rather than introducing a new error into the parser's error set.
    for (ops) |op| {
        if (std.mem.indexOf(u8, body, op.token)) |idx| {
            const lhs = stripDollar(std.mem.trim(u8, body[0..idx], " "));
            const rhs = std.mem.trim(u8, body[idx + op.token.len ..], " ");
            return std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ lhs, op.code, rhs });
        }
    }

    const ref = stripDollar(body);
    if (negated) return std.fmt.allocPrint(allocator, "not:{s}", .{ref});
    return allocator.dupe(u8, ref);
}

// `:class` / `:style` share an arrow shape (`lhs -> rhs[; …]`) but put the state
// ref on opposite sides: :class has $ on the LHS (state → classes), :style on the
// RHS (property → state). Strip `$` from the indicated side per segment, re-join.
// When `predicate` is set, the dollar side routes through parsePredicate so
// authors can write `$color == red -> bg-red-400`.
fn stripDollarArrow(allocator: std.mem.Allocator, value: []const u8, dollar_side: enum { lhs, rhs }, predicate: bool) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var parts = std.mem.splitScalar(u8, value, ';');
    var first = true;
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t\r\n");
        if (part.len == 0) continue;
        if (!first) try out.append(allocator, ';');
        first = false;
        const arrow = std.mem.indexOf(u8, part, "->") orelse {
            try out.appendSlice(allocator, part);
            continue;
        };
        const lhs_raw = std.mem.trim(u8, part[0..arrow], " \t\r\n");
        const rhs_raw = std.mem.trim(u8, part[arrow + 2 ..], " \t\r\n");
        const lhs_owned: ?[]const u8 = if (dollar_side == .lhs and predicate) try parsePredicate(allocator, lhs_raw) else null;
        defer if (lhs_owned) |s| allocator.free(s);
        const rhs_owned: ?[]const u8 = if (dollar_side == .rhs and predicate) try parsePredicate(allocator, rhs_raw) else null;
        defer if (rhs_owned) |s| allocator.free(s);
        const lhs = lhs_owned orelse (if (dollar_side == .lhs) stripDollar(lhs_raw) else lhs_raw);
        const rhs = rhs_owned orelse (if (dollar_side == .rhs) stripDollar(rhs_raw) else rhs_raw);
        try out.appendSlice(allocator, lhs);
        try out.appendSlice(allocator, " -> ");
        try out.appendSlice(allocator, rhs);
    }
    return out.toOwnedSlice(allocator);
}

// `@for="item of $items"` — only the collection (RHS of " of ") is a state ref.
fn stripDollarForOf(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const sep = " of ";
    if (std.mem.indexOf(u8, value, sep)) |idx| {
        const lhs = std.mem.trim(u8, value[0..idx], " ");
        const rhs = stripDollar(value[idx + sep.len ..]);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ lhs, sep, rhs });
    }
    return allocator.dupe(u8, std.mem.trim(u8, value, " "));
}

// Spec §10: map ZSX directive authoring to the emitted data-p-* attribute.
// State-ref values are `$`-stripped (the runtime resolves bare paths only).
//   onClick="add"           -> data-p-on   = "click:add"      (on<Event>, camelCase)
//   onKeydown.enter="go"    -> data-p-on   = "keydown.enter:go"  (+ .modifiers)
//   @for="item of $items"   -> data-p-for  = "item of items"
//   @store="demo"           -> data-p-store= "demo"  (or "local:tabs")
//   @data='{"n":1}'         -> data-p      = '{"n":1}'  (inline state seed)
//   @model[.mods]="$draft"  -> data-p-model= "draft" (or "draft|lazy|trim")
//   @renderIf="$x == y"     -> data-p-if   = "x|eq|y"  (conditional mount)
//   :showIf/:hideIf="..."   -> data-p-show / data-p-hide (predicate)
//   :text/:key="$v"         -> data-p-<name> = "v"
//   :class/:style="$a -> b" -> data-p-<name> ($-stripped per side)
//   :value="$draft" (other) -> data-p-bind  = "value:draft"
fn mapDirectiveAttr(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !MappedAttr {
    // Events: on + UpperCase, e.g. onClick / onChange / onKeydown.enter.prevent.
    if (name.len >= 3 and name[0] == 'o' and name[1] == 'n' and name[2] >= 'A' and name[2] <= 'Z') {
        const desc = try allocator.dupe(u8, name[2..]); // "Click.prevent"
        for (desc) |*ch| {
            if (ch.* >= 'A' and ch.* <= 'Z') ch.* += 32; // -> "click.prevent"
        }
        const out = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ desc, value });
        allocator.free(desc);
        return .{ .name = "data-p-on", .value = out };
    }
    if (name.len >= 2 and name[0] == '@') {
        const d = name[1..];
        // @for collection is a state ref; "item of " prefix is binding syntax.
        if (std.mem.eql(u8, d, "for")) return .{ .name = "data-p-for", .value = try stripDollarForOf(allocator, value) };
        // @store / @data values are NOT state refs (store name / JSON literal).
        if (std.mem.eql(u8, d, "watch")) return .{ .name = "data-p-watch", .value = value };
        if (std.mem.eql(u8, d, "store")) return .{ .name = "data-p-store", .value = value };
        if (std.mem.eql(u8, d, "data")) return .{ .name = "data-p", .value = value };
        if (std.mem.eql(u8, d, "portal")) return .{ .name = "data-p-portal", .value = value };
        if (std.mem.eql(u8, d, "renderIf")) return .{ .name = "data-p-if", .value = try parsePredicate(allocator, value) };
        // @model[.mod...] — two-way binding (§11.3): strip $, fold dot-modifiers
        // into "path|mod1|mod2". Modifier semantics live in the runtime.
        if (std.mem.startsWith(u8, d, "model") and (d.len == 5 or d[5] == '.')) {
            const stripped = stripDollar(value);
            if (d.len == 5) return .{ .name = "data-p-model", .value = try allocator.dupe(u8, stripped) };
            const mods = d[6..];
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(allocator);
            try out.appendSlice(allocator, stripped);
            try out.append(allocator, '|');
            for (mods) |c| try out.append(allocator, if (c == '.') '|' else c);
            return .{ .name = "data-p-model", .value = try out.toOwnedSlice(allocator) };
        }
        return .{ .name = name, .value = value }; // unknown @ — leave as-is
    }
    if (name.len >= 2 and name[0] == ':') {
        const d = name[1..];
        if (std.mem.eql(u8, d, "showIf")) return .{ .name = "data-p-show", .value = try parsePredicate(allocator, value) };
        if (std.mem.eql(u8, d, "hideIf")) return .{ .name = "data-p-hide", .value = try parsePredicate(allocator, value) };
        if (std.mem.eql(u8, d, "text")) return .{ .name = "data-p-text", .value = try allocator.dupe(u8, stripDollar(value)) };
        if (std.mem.eql(u8, d, "class")) return .{ .name = "data-p-class", .value = try stripDollarArrow(allocator, value, .lhs, true) };
        if (std.mem.eql(u8, d, "style")) return .{ .name = "data-p-style", .value = try stripDollarArrow(allocator, value, .rhs, false) };
        if (std.mem.eql(u8, d, "key")) return .{ .name = "data-p-key", .value = try allocator.dupe(u8, stripDollar(value)) };
        // Any other :attr is a bind. The value may use the predicate DSL
        // (e.g. :disabled="$step == 1"); parsePredicate strips $ from the path.
        const pv = try parsePredicate(allocator, value);
        defer allocator.free(pv);
        return .{ .name = "data-p-bind", .value = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ d, pv }) };
    }
    return .{ .name = name, .value = value };
}

// Output attribute name for directives whose VALUE passes through unchanged —
// used by the dynamic-value attr path (e.g. `@data={expr}`). Value-transforming
// directives (events, :bind, predicates) only take static literal values.
fn directiveName(name: []const u8) ?[]const u8 {
    if (name.len >= 2 and name[0] == '@') {
        const d = name[1..];
        if (std.mem.eql(u8, d, "data")) return "data-p";
        if (std.mem.eql(u8, d, "store")) return "data-p-store";
        if (std.mem.eql(u8, d, "for")) return "data-p-for";
        if (std.mem.eql(u8, d, "watch")) return "data-p-watch";
        if (std.mem.eql(u8, d, "model")) return "data-p-model"; // bare-name only; modifiers go through static-value path
        if (std.mem.eql(u8, d, "portal")) return "data-p-portal";
    }
    if (name.len >= 2 and name[0] == ':') {
        const d = name[1..];
        if (std.mem.eql(u8, d, "text")) return "data-p-text";
        if (std.mem.eql(u8, d, "class")) return "data-p-class";
        if (std.mem.eql(u8, d, "style")) return "data-p-style";
        if (std.mem.eql(u8, d, "key")) return "data-p-key";
    }
    return null;
}

const testing = std.testing;

const minimal_template =
    \\pub fn Foo(props: struct { x: []const u8 }) {
    \\    <section class="card">
    \\        <h1>Hello</h1>
    \\        <p>{props.x}</p>
    \\        <Bar />
    \\    </section>
    \\}
;

// ---------- @raw ----------

// ---------- Backtick ----------

// ---------- Ternary / Elvis ----------

// ---------- if / else if / else ----------

// ---------- for ----------

// ---------- Components with children ----------

// ---------- Void elements ----------

// ---------- DOCTYPE ----------

// ---------- HTML comments ----------

// ---------- {props.children} ----------

// ---------- HTML tag dynamic attrs ----------

// ---------- Enum-literal attrs ----------

// ---------- Top-level skipping ----------

// ---------- parseAll ----------

// ---------- Corpus (consumers) ----------

};

pub const emit_mod = struct {
const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

const parse_src = parse_mod;
const manifest_src = manifest_mod;
const transpile_src = transpile;

pub const Manifest = manifest_src.Manifest;
pub const Node = manifest_src.Node;
pub const ExprKind = manifest_src.ExprKind;
pub const Component = manifest_src.Component;
pub const Attr = manifest_src.Attr;
pub const AttrValue = manifest_src.AttrValue;

pub const ComponentImport = struct {
    name: []const u8, // PascalCase name, e.g. "Dialog"
    import_path: []const u8, // relative @import path, e.g. "../components/dialog.zig"
    /// True if the imported file exposes `pub const <Name>Props = struct{…}`.
    /// Required for attr-lifting (lift_attrs in EmitOptions): the per-callsite
    /// `var __p: NameProps = .{}` line needs a concrete type. Detected by the
    /// transpiler by scanning the imported file's source. Defaults to true
    /// for back-compat with callers that don't set it.
    /// True when the component is already in scope in the generated file —
    /// either the user wrote `const Name = @import(...)` (explicit import)
    /// or it's a sibling `fn Name` defined in the same file. The emitter
    /// then skips emitting its own `const Name = ...;` (would collide).
    explicit: bool = false,
    /// True iff this component's invocations can be lifted into the runtime
    /// A-table: its Props is a concrete struct, not `anytype`. Determined by
    /// the transpiler (scan local sources; external imports assumed liftable).
    /// When false the emitter falls back to the baked inline-attrs call and
    /// edits trigger a rebuild.
    liftable: bool = false,
    /// Zig type EXPRESSION naming the component's Props struct, spliced into
    /// the lifted call site as `var __p: <props_type_expr> = .{...}`. Forms:
    ///   - same-file `fn`:   "NameProps"  (a local const in this file)
    ///   - explicit import:  rhs with trailing `.Name` replaced by `Props`,
    ///                       e.g. `const B = ui.button.Button;` -> "ui.button.ButtonProps"
    ///   - auto-discovered:  "@import(\"<import_path>\").NameProps"
    /// Empty when `!liftable`.
    props_type_expr: []const u8 = "",
};

/// One component invocation eligible for the runtime A-table lift.
/// Accumulated by the Emitter and flushed as `initial_A` at file footer.
pub const CallSiteInit = struct {
    attrs: std.ArrayListUnmanaged(LiftedAttr) = .{},
    /// 0-based index of this component among all `.component` nodes in the
    /// file's manifest, flat pre-order. Baked into `lift_sites` so the dev
    /// loop can match this slot back to the freshly-parsed component when
    /// rebuilding A — see hmr.LiftSite.
    comp_index: u32 = 0,
};
pub const LiftedAttr = struct {
    name: []const u8,
    /// Source text of the attr value: for `.string`, the literal contents
    /// (`Primary`); for `.expr` constants, the source slice (`.primary`,
    /// `42`, `true`); for `.bool_present`, unused (not lifted).
    raw_value: []const u8,
};

pub const EmitOptions = struct {
    /// HMR mode: lifts string literals into a runtime-mutable `pub var L`
    /// table, emits a `pub const manifest_nodes`, and a `pub fn setL` setter.
    /// Default is `inline` mode (today's transpiler output).
    ///
    /// In `inline` mode the emitter writes `try writer.writeAll("…literal…")`
    /// directly and the output is run through `coalesceWriteAlls`.
    /// In `hmr` mode it writes `try writer.writeAll(L[N])` where N is the
    /// file-wide slot index, and the coalesce pass is skipped (L[N] refs
    /// can't legally merge).
    hmr: bool = false,
    /// Splice `data-component="<FnName>"` into the first opening tag of each
    /// `pub fn <FnName>` body so the CMS browser client can locate DOM nodes
    /// to swap. Only meaningful with `hmr = true`. The splice is applied to
    /// the manifest's literals before they're baked into `initial_L`, so a
    /// runtime re-parse must apply the same splice (call
    /// `spliceDomAttribute` on the fresh manifest) for the attribute to
    /// survive `setL`.
    dom_attribute: bool = false,
    /// Inject `try @import("hmr").captureProps("<view>:<FnName>", props);`
    /// at the top of every function body. Only meaningful with `hmr = true`
    /// and requires the consumer build graph to expose an `hmr` module
    /// providing `pub fn captureProps`. Off by default.
    capture_props: bool = false,
    /// Explicit view-name prefix used for `captureProps` keys and the
    /// `data-component` attribute value. Format is `<dir>/<basename>` with
    /// `.zsx` stripped (e.g. `"admin/variables"`). When null, falls back
    /// to deriving from `source_path` — which becomes absolute when the
    /// caller passes an absolute path, producing keys that won't match
    /// the registry's `<rel>:<Fn>` convention. Set explicitly from the
    /// transpiler CLI's `rel_path` so the registry, capture key, and
    /// data-component value all use the same string.
    view_name: ?[]const u8 = null,
    /// HMR attr-lift mode: at each component invocation, lift literal
    /// attrs (`label="X"`, `hierarchy=.primary`, `disabled={true}`) into
    /// a per-callsite slot in a runtime-mutable `pub var A` table. The
    /// generated call becomes:
    ///     var __p: NameProps = .{};
    ///     hmr.applyAttrs(NameProps, &__p, A[slot]);
    ///     __p.expr_attr = some_expr;   // non-lifted attrs assigned inline
    ///     try Name(writer, __p);
    /// On every save, the comparator can swap literal-attr values without
    /// triggering a `zig build`. Requires `hmr = true`. Generated views
    /// import the `hmr` module: build graph must expose it.
    lift_attrs: bool = false,
};

pub const EmitError = error{
    OutOfMemory,
};

// Public API

/// Emit a single `pub fn` (or `fn`) definition from one Manifest. No file
/// header — caller handles that via `emitFile`.
pub fn emit(allocator: Allocator, mfst: Manifest, opts: EmitOptions) EmitError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    var emitter = Emitter{
        .allocator = allocator,
        .out = &out,
        .indent = 1,
        .hmr = opts.hmr,
        .capture_props = opts.capture_props,
        .view_name = "",
        .slot_offset = 0,
    };

    try emitter.emitFunction(mfst, true, null);
    return try out.toOwnedSlice(allocator);
}

/// File-level emit: header + component imports + `pub const source_path`
/// + per-function emit + verbatim passthrough of top-level non-function
/// content (consts and `//` line comments). Mirrors the file-level work
/// `transpileSource` does today; we run the result through
/// `coalesceWriteAlls` to match the existing codegen byte-for-byte.
pub fn emitFile(
    allocator: Allocator,
    source: []const u8,
    source_path: []const u8,
    component_imports: []const ComponentImport,
    opts: EmitOptions,
) ![]u8 {
    var raw: std.ArrayListUnmanaged(u8) = .{};
    defer raw.deinit(allocator);

    // Header.
    try raw.appendSlice(allocator, "// Generated from ZSX - do not edit\n");
    try raw.appendSlice(allocator, "const zsx = @import(\"zsx\").runtime;\n");
    for (component_imports) |ci| {
        // Skip the `const Name = @import(...)` line when the component is
        // already in scope (user's explicit import, or a same-file `fn`).
        // The lift path references the Props TYPE via `ci.props_type_expr`
        // (e.g. `ui.button.ButtonProps`), so no separate `const NameProps`
        // import is emitted any more.
        if (!ci.explicit) {
            try raw.appendSlice(allocator, "const ");
            try raw.appendSlice(allocator, ci.name);
            try raw.appendSlice(allocator, " = @import(\"");
            try raw.appendSlice(allocator, ci.import_path);
            try raw.appendSlice(allocator, "\").");
            try raw.appendSlice(allocator, ci.name);
            try raw.appendSlice(allocator, ";\n");
        }
    }
    try raw.appendSlice(allocator, "\npub const source_path = \"");
    try raw.appendSlice(allocator, source_path);
    try raw.appendSlice(allocator, "\";\n\n");

    if (opts.hmr) {
        // HMR mode: parse every function in the file first, then emit a
        // file-scoped `initial_L` / `L` / `setL` / `manifest_nodes` header,
        // then walk the manifests again to emit the function bodies with
        // `writeAll(L[N])` references using file-wide slot indices.
        var manifests = std.ArrayListUnmanaged(Manifest){};
        defer {
            for (manifests.items) |*m| m.deinit(allocator);
            manifests.deinit(allocator);
        }
        // Track per-function (fn_slice, manifest_index) so emitFunction can
        // still see the original source (for `pub` detection).
        var fn_slices = std.ArrayListUnmanaged([]const u8){};
        defer fn_slices.deinit(allocator);

        // First pass: collect manifests + emit non-function passthrough into a
        // separate buffer so we can interleave header before functions.
        var head_buf: std.ArrayListUnmanaged(u8) = .{};
        defer head_buf.deinit(allocator);
        var ordered_chunks: std.ArrayListUnmanaged(Chunk) = .{};
        defer ordered_chunks.deinit(allocator);

        var pos: usize = 0;
        while (pos < source.len) {
            while (pos < source.len and isWs(source[pos])) : (pos += 1) {}
            if (pos >= source.len) break;
            if (startsWithKeyword(source, pos, "pub fn ") or startsWithKeyword(source, pos, "fn ")) {
                const fn_start = pos;
                const fn_end = try findFunctionEnd(source, pos);
                const slice = source[fn_start..fn_end];
                const mfst = try parse_src.parse(allocator, slice);
                try manifests.append(allocator, mfst);
                try fn_slices.append(allocator, slice);
                try ordered_chunks.append(allocator, .{ .kind = .function, .index = manifests.items.len - 1 });
                pos = fn_end;
            } else if (startsWithKeyword(source, pos, "const ") or startsWithKeyword(source, pos, "pub const ")) {
                const decl_start = pos;
                pos = passConstDecl(source, pos);
                const decl = source[decl_start..pos];
                const off_start = head_buf.items.len;
                if (mem.startsWith(u8, decl, "const ")) {
                    try head_buf.appendSlice(allocator, "pub ");
                }
                try head_buf.appendSlice(allocator, decl);
                try head_buf.append(allocator, '\n');
                try ordered_chunks.append(allocator, .{ .kind = .passthrough, .start = off_start, .end = head_buf.items.len });
            } else if (pos + 1 < source.len and source[pos] == '/' and source[pos + 1] == '/') {
                const cstart = pos;
                while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
                const off_start = head_buf.items.len;
                try head_buf.appendSlice(allocator, source[cstart..pos]);
                try head_buf.append(allocator, '\n');
                try ordered_chunks.append(allocator, .{ .kind = .passthrough, .start = off_start, .end = head_buf.items.len });
                if (pos < source.len) pos += 1;
            } else {
                pos += 1;
            }
        }

        // Pre-compute `view_name` for capture_props key construction.
        // Prefer the explicit opt (passed by the transpiler CLI as
        // `rel_path` minus `.zsx`); fall back to deriving from `source_path`
        // for legacy callers and tests. The derived form becomes an
        // absolute path when source_path is absolute, producing capture
        // keys that won't match the registry's `<rel>:<Fn>` convention —
        // which is why CMS now passes `opts.view_name` explicitly.
        const view_name: []const u8 = opts.view_name orelse if (mem.endsWith(u8, source_path, ".zsx"))
            source_path[0 .. source_path.len - 4]
        else
            source_path;

        // Apply the data-component attribute splice. Build-time AND runtime
        // (CMS swap loop) must use identical attribute values so that
        // `setL(fresh.literals)` doesn't shift the attribute on swap, and
        // so the client's `querySelectorAll('[data-component="<name>"]')`
        // resolves to the same nodes the broadcast addresses.
        //
        // When `opts.view_name` is set (CMS), the attribute is
        // `<view_name>:<fn_name>` — the same string as the registry's
        // entry name and the slow-path broadcast name. When unset (POC,
        // historical tests), it falls back to the bare fn name so existing
        // consumers aren't disturbed; the POC drives its own outer wrappers
        // with hardcoded names and doesn't read the inner splice value.
        if (opts.hmr and opts.dom_attribute) {
            for (manifests.items) |*m| {
                const dc_value: []u8 = if (opts.view_name) |vn| blk: {
                    if (vn.len == 0) break :blk try allocator.dupe(u8, m.name);
                    break :blk try std.fmt.allocPrint(allocator, "{s}:{s}", .{ vn, m.name });
                } else try allocator.dupe(u8, m.name);
                defer allocator.free(dc_value);
                try spliceDomAttribute(allocator, m, dc_value);
            }
        }

        // Emit file-scoped `initial_L`, `L`, `setL`, and `manifest_nodes`.
        try emitHmrPrelude(allocator, &raw, manifests.items);

        // File-wide call-site state. Shared across the per-function
        // Emitter instances below via pointers — slot IDs are file-wide
        // so they index into a single `A` table emitted at file footer.
        var file_call_site_id: u32 = 0;
        var file_call_site_initials: std.ArrayListUnmanaged(CallSiteInit) = .{};
        defer {
            for (file_call_site_initials.items) |*init| init.attrs.deinit(allocator);
            file_call_site_initials.deinit(allocator);
        }
        // File-wide component counter — incremented for EVERY component
        // invocation (lifted or not) in flat manifest order, so each
        // lifted slot can record the index the dev loop uses to find the
        // matching freshly-parsed component.
        var file_comp_index: u32 = 0;

        // Map of liftable component name -> its Props type expression
        // (e.g. "ui.button.ButtonProps", "PageHeaderProps"). Presence in the
        // map is componentLiftable's gate; the value is spliced into the
        // lifted call site's `var __p: <expr> = .{...}`.
        var props_expr_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer props_expr_map.deinit(allocator);
        for (component_imports) |ci| {
            if (ci.liftable) try props_expr_map.put(allocator, ci.name, ci.props_type_expr);
        }

        // Emit chunks in source order. Functions get a per-function slot_offset
        // that accumulates the literal count of all preceding functions.
        var slot_offset: u32 = 0;
        for (ordered_chunks.items) |chunk| {
            switch (chunk.kind) {
                .function => {
                    const m = manifests.items[chunk.index];
                    const slice = fn_slices.items[chunk.index];
                    var emitter = Emitter{
                        .allocator = allocator,
                        .out = &raw,
                        .indent = 1,
                        .hmr = true,
                        .capture_props = opts.capture_props,
                        .view_name = view_name,
                        .slot_offset = slot_offset,
                        .lift_attrs = opts.lift_attrs,
                        .props_expr = &props_expr_map,
                        .next_call_site_id = &file_call_site_id,
                        .call_site_initials = &file_call_site_initials,
                        .next_comp_index = &file_comp_index,
                    };
                    try emitter.emitFunction(m, true, slice);
                    slot_offset += @intCast(m.literals.len);
                },
                .passthrough => {
                    try raw.appendSlice(allocator, head_buf.items[chunk.start..chunk.end]);
                },
            }
        }

        // Flush the A-table after all function bodies have been emitted.
        // (Skipped when lift_attrs is off, or when no eligible call sites
        // were found — keeps the generated file lean.)
        if (opts.lift_attrs and file_call_site_initials.items.len > 0) {
            try emitCallSiteTable(allocator, &raw, file_call_site_initials.items);
        }

        // No coalesce in hmr mode (L[N] refs aren't legally mergeable).
        return try allocator.dupe(u8, raw.items);
    }

    // Inline mode (default): walk and emit in one pass, then coalesce.
    // Props-type map so inline component calls can forward non-prop attrs
    // (data-p-* etc.) onto the root via renderForwarding — same as the hmr path.
    var inline_props_expr: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer inline_props_expr.deinit(allocator);
    for (component_imports) |ci| {
        if (ci.liftable) try inline_props_expr.put(allocator, ci.name, ci.props_type_expr);
    }
    var pos: usize = 0;
    while (pos < source.len) {
        // Skip leading whitespace.
        while (pos < source.len and isWs(source[pos])) : (pos += 1) {}
        if (pos >= source.len) break;

        if (startsWithKeyword(source, pos, "pub fn ") or startsWithKeyword(source, pos, "fn ")) {
            // Find the end of this function (matching closing brace at depth 0).
            const fn_start = pos;
            const fn_end = try findFunctionEnd(source, pos);
            // Parse the slice and emit.
            const slice = source[fn_start..fn_end];
            var mfst = try parse_src.parse(allocator, slice);
            defer mfst.deinit(allocator);

            var emitter = Emitter{
                .allocator = allocator,
                .out = &raw,
                .indent = 1,
                .hmr = false,
                .capture_props = false,
                .view_name = "",
                .slot_offset = 0,
                .props_expr = &inline_props_expr,
            };
            try emitter.emitFunction(mfst, true, slice);
            pos = fn_end;
        } else if (startsWithKeyword(source, pos, "const ") or startsWithKeyword(source, pos, "pub const ")) {
            const decl_start = pos;
            pos = passConstDecl(source, pos);
            const decl = source[decl_start..pos];
            // Match existing transpiler: prefix `pub ` if not already pub.
            if (mem.startsWith(u8, decl, "const ")) {
                try raw.appendSlice(allocator, "pub ");
            }
            try raw.appendSlice(allocator, decl);
            try raw.append(allocator, '\n');
        } else if (pos + 1 < source.len and source[pos] == '/' and source[pos + 1] == '/') {
            // Line comment passthrough — captures `///` doc comments too.
            const cstart = pos;
            while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
            try raw.appendSlice(allocator, source[cstart..pos]);
            try raw.append(allocator, '\n');
            if (pos < source.len) pos += 1;
        } else {
            pos += 1;
        }
    }

    return try coalesceWriteAlls(allocator, raw.items);
}

const Chunk = struct {
    kind: enum { function, passthrough },
    /// For .function: index into the manifests list.
    /// For .passthrough: unused.
    index: usize = 0,
    /// For .passthrough: byte range into head_buf.
    /// For .function: unused.
    start: usize = 0,
    end: usize = 0,
};

/// Emit the file-scoped HMR prelude: `initial_L`, `L`, `setL`, and
/// `manifest_nodes`. The L array contains every literal from every function
/// in source order; slot indices in `manifest_nodes` are file-wide.
fn emitHmrPrelude(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    manifests: []const Manifest,
) EmitError!void {
    // initial_L
    try out.appendSlice(allocator, "var initial_L = [_][]const u8{\n");
    for (manifests) |m| {
        for (m.literals) |lit| {
            try out.appendSlice(allocator, "    \"");
            // Strip the parser's `0x01` self-closing-non-void sentinel before
            // baking into the literal (Bug A). Inline mode's `emitSeg` strips
            // it during whitespace normalisation; hmr mode bakes raw literals,
            // so Zig would reject `\x01` as an invalid byte in a string
            // literal. The sentinel only matters for inline-mode tag-depth
            // accounting; at L-table runtime it's purely noise.
            try writeEscapedStripSentinel(allocator, out, lit);
            try out.appendSlice(allocator, "\",\n");
        }
    }
    try out.appendSlice(allocator, "};\n");
    try out.appendSlice(allocator, "pub var L: []const []const u8 = &initial_L;\n");
    try out.appendSlice(allocator, "pub fn setL(new_L: []const []const u8) void { L = new_L; }\n\n");

    // manifest_nodes — file-wide, with slot indices offset per function so
    // they index into the file-wide L array.
    try out.appendSlice(allocator, "pub const manifest_nodes: []const @import(\"zsx\").manifest_mod.Node = &.{\n");
    var slot_offset: u32 = 0;
    for (manifests) |m| {
        for (m.nodes) |node| {
            try emitManifestNode(allocator, out, node, slot_offset);
        }
        slot_offset += @intCast(m.literals.len);
    }
    try out.appendSlice(allocator, "};\n\n");

    // Per-function baked Manifest constants. Naming: `<FnName>_manifest`,
    // a `@import("zsx").manifest_mod.Manifest` value with `.name`, `.sig`,
    // `.nodes` (subslice of file-wide nodes, with the same slot offsets),
    // and an empty `.literals` slice (literals live in the file-wide L
    // table; the comparator ignores `.literals` content). The runtime reads
    // `views.<file>.<Fn>_manifest` and compares against a freshly-parsed
    // Manifest via `zsx.manifestEqual` for HMR fast/slow path routing.
    //
    // The `manifest_mod` qualification is needed because Zig flags an
    // ambiguous reference if we expose `Manifest` flat at top level of zsx.zig
    // — see the amalgamation script's footer comment for the full reason.
    slot_offset = 0;
    for (manifests) |m| {
        try out.appendSlice(allocator, "pub const ");
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, "_manifest: @import(\"zsx\").manifest_mod.Manifest = .{\n");
        try out.appendSlice(allocator, "    .name = \"");
        try writeEscaped(allocator, out, m.name);
        try out.appendSlice(allocator, "\",\n");
        try out.appendSlice(allocator, "    .sig = \"");
        try writeEscaped(allocator, out, m.sig);
        try out.appendSlice(allocator, "\",\n");
        try out.appendSlice(allocator, "    .nodes = &.{\n");
        for (m.nodes) |node| {
            try emitManifestNode(allocator, out, node, slot_offset);
        }
        try out.appendSlice(allocator, "    },\n");
        try out.appendSlice(allocator, "    .literals = &.{},\n");
        try out.appendSlice(allocator, "};\n\n");
        slot_offset += @intCast(m.literals.len);
    }
}

/// Emit the file-scoped runtime A-table + the `lift_sites` descriptor the
/// dev loop uses to rebuild A from a fresh parse:
///     var initial_A_<N> = [_]hmr.Attr{ … };
///     var initial_A = [_][]const hmr.Attr{ &initial_A_0, &initial_A_1, … };
///     pub var A: []const []const hmr.Attr = &initial_A;
///     pub fn setA(new_A: []const []const hmr.Attr) void { A = new_A; }
///     pub const lift_sites: []const hmr.LiftSite = &.{ … };
fn emitCallSiteTable(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    initials: []const CallSiteInit,
) EmitError!void {
    for (initials, 0..) |init, idx| {
        try out.appendSlice(allocator, "var initial_A_");
        try appendUsize(allocator, out, @intCast(idx));
        try out.appendSlice(allocator, " = [_]@import(\"hmr\").Attr{");
        if (init.attrs.items.len > 0) try out.appendSlice(allocator, "\n");
        for (init.attrs.items) |a| {
            try out.appendSlice(allocator, "    .{ .name = \"");
            try writeEscaped(allocator, out, a.name);
            try out.appendSlice(allocator, "\", .value = \"");
            try writeEscaped(allocator, out, a.raw_value);
            try out.appendSlice(allocator, "\" },\n");
        }
        try out.appendSlice(allocator, "};\n");
    }
    try out.appendSlice(allocator, "var initial_A = [_][]const @import(\"hmr\").Attr{");
    if (initials.len > 0) try out.appendSlice(allocator, "\n");
    for (initials, 0..) |_, idx| {
        try out.appendSlice(allocator, "    &initial_A_");
        try appendUsize(allocator, out, @intCast(idx));
        try out.appendSlice(allocator, ",\n");
    }
    try out.appendSlice(allocator, "};\n");
    try out.appendSlice(allocator, "pub var A: []const []const @import(\"hmr\").Attr = &initial_A;\n");
    try out.appendSlice(allocator, "pub fn setA(new_A: []const []const @import(\"hmr\").Attr) void { A = new_A; }\n");

    // lift_sites — one entry per slot, in slot order, carrying the flat
    // component ordinal + lifted attr names. The dev loop walks fresh
    // manifest nodes, collects components in the same flat order, and uses
    // comp_index + attr_names to rebuild each A slot with current values.
    try out.appendSlice(allocator, "pub const lift_sites: []const @import(\"hmr\").LiftSite = &.{\n");
    for (initials) |init| {
        try out.appendSlice(allocator, "    .{ .comp_index = ");
        try appendUsize(allocator, out, init.comp_index);
        try out.appendSlice(allocator, ", .attr_names = &.{");
        for (init.attrs.items, 0..) |a, k| {
            if (k > 0) try out.appendSlice(allocator, ",");
            try out.appendSlice(allocator, " \"");
            try writeEscaped(allocator, out, a.name);
            try out.appendSlice(allocator, "\"");
        }
        if (init.attrs.items.len > 0) try out.appendSlice(allocator, " ");
        try out.appendSlice(allocator, "} },\n");
    }
    try out.appendSlice(allocator, "};\n\n");
}

fn emitManifestNode(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    node: Node,
    slot_offset: u32,
) EmitError!void {
    try out.appendSlice(allocator, "    ");
    switch (node) {
        .literal => |lit| {
            try out.appendSlice(allocator, ".{ .literal = .{ .slot = ");
            try appendUsize(allocator, out, lit.slot + slot_offset);
            try out.appendSlice(allocator, " } },\n");
        },
        .expr => |e| {
            try out.appendSlice(allocator, ".{ .expr = .{ .kind = .");
            try out.appendSlice(allocator, @tagName(e.kind));
            try out.appendSlice(allocator, ", .source = \"");
            try writeEscaped(allocator, out, e.source);
            try out.appendSlice(allocator, "\" } },\n");
        },
        .component => |c| {
            try out.appendSlice(allocator, ".{ .component = .{ .name = \"");
            try writeEscaped(allocator, out, c.name);
            try out.appendSlice(allocator, "\", .has_children = ");
            try out.appendSlice(allocator, if (c.has_children) "true" else "false");
            try out.appendSlice(allocator, ", .attrs = &.{");
            for (c.attrs, 0..) |a, idx| {
                if (idx > 0) try out.appendSlice(allocator, ",");
                try out.appendSlice(allocator, " .{ .name = \"");
                try writeEscaped(allocator, out, a.name);
                try out.appendSlice(allocator, "\", .value = ");
                switch (a.value) {
                    .string => |s| {
                        try out.appendSlice(allocator, ".{ .string = \"");
                        try writeEscaped(allocator, out, s);
                        try out.appendSlice(allocator, "\" }");
                    },
                    .expr => |s| {
                        try out.appendSlice(allocator, ".{ .expr = \"");
                        try writeEscaped(allocator, out, s);
                        try out.appendSlice(allocator, "\" }");
                    },
                    .bool_present => {
                        try out.appendSlice(allocator, ".bool_present");
                    },
                }
                try out.appendSlice(allocator, " }");
            }
            // Closing brace balance: attrs>0 case has one extra open from the
            // `&.{` slice that the in-loop close on line ~398 doesn't cover,
            // so we need 3 closes (attrs slice + component struct + Node tagged
            // union) plus the trailing comma. Empty-attrs uses `&.{}` self-closed.
            try out.appendSlice(allocator, if (c.attrs.len > 0) " } } },\n" else "} } },\n");
        },
        .component_end => try out.appendSlice(allocator, ".component_end,\n"),
        .if_begin => |s| {
            try out.appendSlice(allocator, ".{ .if_begin = \"");
            try writeEscaped(allocator, out, s);
            try out.appendSlice(allocator, "\" },\n");
        },
        .if_else => try out.appendSlice(allocator, ".if_else,\n"),
        .if_end => try out.appendSlice(allocator, ".if_end,\n"),
        .for_begin => |fh| {
            try out.appendSlice(allocator, ".{ .for_begin = .{ .iterable_source = \"");
            try writeEscaped(allocator, out, fh.iterable_source);
            try out.appendSlice(allocator, "\", .binding = \"");
            try writeEscaped(allocator, out, fh.binding);
            try out.appendSlice(allocator, "\" } },\n");
        },
        .for_end => try out.appendSlice(allocator, ".for_end,\n"),
        .children_slot => try out.appendSlice(allocator, ".children_slot,\n"),
        .line_comment => |s| {
            try out.appendSlice(allocator, ".{ .line_comment = \"");
            try writeEscaped(allocator, out, s);
            try out.appendSlice(allocator, "\" },\n");
        },
        .zig_stmt => |s| {
            try out.appendSlice(allocator, ".{ .zig_stmt = \"");
            try writeEscaped(allocator, out, s);
            try out.appendSlice(allocator, "\" },\n");
        },
    }
}

fn appendUsize(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), n: u32) EmitError!void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    try out.appendSlice(allocator, s);
}

// Emitter — walks one function manifest and writes Zig.

const Context = enum { body, children };

const Emitter = struct {
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    indent: usize,
    /// HMR mode: writeAll calls reference `L[N]` instead of inlining the
    /// literal text. Also skips literal-content normalisation (the L table
    /// holds the parser's raw literals so a runtime re-parse produces a
    /// drop-in replacement).
    hmr: bool = false,
    /// Capture-props mode: emit a `try @import("hmr").captureProps(name, props)`
    /// at the top of each function body. Only meaningful when `hmr == true`.
    capture_props: bool = false,
    /// View name for capture_props key construction: typically the
    /// source_path with `.zsx` stripped. Empty when neither hmr nor
    /// capture_props is set.
    view_name: []const u8 = "",
    /// File-wide slot offset added to each manifest's per-function slot
    /// indices so literals from successive functions occupy disjoint slots
    /// in the file-scoped L array. Only meaningful when `hmr == true`.
    slot_offset: u32 = 0,
    children_depth: u8 = 0,
    /// Open-tag depth tracked across emitted literals. Used by
    /// `emitLiteralText` to distinguish body-level pure-whitespace literals
    /// (drop entirely) from inside-tag pure-whitespace ones (collapse to `\n`).
    tag_depth: i32 = 0,
    /// Lexical context stack: pushed on `if_begin`/`for_begin` (body) and on
    /// entering a children buffer (children). The top determines how pure-WS
    /// literals are handled when `tag_depth == 0`. Fixed-size, since real
    /// templates rarely nest deeper than ~10.
    ctx_buf: [64]Context = undefined,
    ctx_len: usize = 0,
    /// When a previous literal ended in mid-tag (carrying over a dynamic
    /// attribute value into the next literal), this stores the tag's name
    /// so the next literal can apply the correct `tag_depth` delta on close.
    pending_open_name: [64]u8 = undefined,
    pending_open_len: usize = 0,
    pending_open_self_closing: bool = false,
    /// True when the previous emitted literal ended mid-attribute (i.e. with
    /// `="`), so the next expr/backtick is in attribute-value context. Used
    /// to switch backtick emit from `zsx.render` (body) to `zsx.escape` (attr).
    in_attr_value: bool = false,
    /// Parallel stack of saved tag_depths for body-context entries; pushed
    /// when we enter an `if`/`for` body so the body starts at depth 0,
    /// regardless of the enclosing HTML tag depth.
    tag_depth_save: [64]i32 = undefined,
    tag_depth_save_len: usize = 0,

    /// Lift mode (see EmitOptions.lift_attrs). When true, emitComponent
    /// allocates a slot ID per qualifying invocation and emits the
    /// `var __p; applyAttrs; try Name(writer, __p);` block instead of
    /// the inline-attrs call.
    lift_attrs: bool = false,
    /// Liftable components -> their Props type expression (key is the
    /// component name; value is e.g. "ui.button.ButtonProps"). Presence in
    /// the map is the lift gate; the value is spliced into the call site as
    /// `var __p: <expr> = .{...}`.
    props_expr: *const std.StringHashMapUnmanaged([]const u8) = &empty_props_expr,
    /// Per-file slot counter — incremented every time emitComponent
    /// emits a lifted invocation. Lives in emitFile's scope (shared
    /// across the per-function Emitter instances) so slot IDs are
    /// file-wide.
    next_call_site_id: *u32 = &dummy_call_site_id,
    /// Per-file initials buffer — flushed as `var initial_A` at file
    /// footer once every function body has been emitted. Same lifetime
    /// rationale as next_call_site_id.
    call_site_initials: *std.ArrayListUnmanaged(CallSiteInit) = &dummy_call_site_initials,
    /// Per-file component counter — incremented at the top of every
    /// emitComponent (flat manifest order, all components, lifted or not).
    /// Recorded into each lifted CallSiteInit.comp_index so the dev loop
    /// can match a slot back to the freshly-parsed component.
    next_comp_index: *u32 = &dummy_comp_index,

    fn write(self: *Emitter, s: []const u8) EmitError!void {
        try self.out.appendSlice(self.allocator, s);
    }

    fn writeIndent(self: *Emitter) EmitError!void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) try self.write("    ");
    }

    fn writerVar(self: *const Emitter) []const u8 {
        if (self.children_depth == 0) return "writer";
        const idx = self.children_depth - 1;
        return childWriterName(idx);
    }

    fn writeTryWriter(self: *Emitter) EmitError!void {
        try self.write("try ");
        try self.write(self.writerVar());
        try self.write(".");
    }

    fn topCtx(self: *const Emitter) Context {
        if (self.ctx_len == 0) return .body;
        return self.ctx_buf[self.ctx_len - 1];
    }

    fn pushCtx(self: *Emitter, ctx: Context) void {
        if (self.ctx_len >= self.ctx_buf.len) return;
        self.ctx_buf[self.ctx_len] = ctx;
        self.ctx_len += 1;
    }

    fn popCtx(self: *Emitter) void {
        if (self.ctx_len > 0) self.ctx_len -= 1;
    }

    fn pushCtxSavingTagDepth(self: *Emitter, ctx: Context) void {
        self.pushCtx(ctx);
        if (self.tag_depth_save_len < self.tag_depth_save.len) {
            self.tag_depth_save[self.tag_depth_save_len] = self.tag_depth;
            self.tag_depth_save_len += 1;
            self.tag_depth = 0;
        }
    }

    fn popCtxRestoringTagDepth(self: *Emitter) void {
        self.popCtx();
        if (self.tag_depth_save_len > 0) {
            self.tag_depth_save_len -= 1;
            self.tag_depth = self.tag_depth_save[self.tag_depth_save_len];
        }
    }

    fn emitFunction(self: *Emitter, mfst: Manifest, is_pub: bool, original_slice: ?[]const u8) EmitError!void {
        // Determine actual `pub` from the source if available; mfst.name
        // alone doesn't carry that.
        var pub_prefix = is_pub;
        if (original_slice) |slice| {
            pub_prefix = mem.startsWith(u8, slice, "pub ");
        }

        // Inspect signature for an inline struct param so we can mirror the
        // existing transpiler's `XxxProps` + `withDefaults` emit.
        const props_info = scanPropsParam(mfst.sig);

        // Emit `pub const NameProps = struct {...};` line when applicable.
        if (props_info.struct_type) |st| {
            if (pub_prefix) try self.write("pub ");
            try self.write("const ");
            try self.write(mfst.name);
            try self.write("Props = ");
            try self.write(st);
            try self.write(";\n");
        }

        // Function signature.
        if (pub_prefix) try self.write("pub ");
        try self.write("fn ");
        try self.write(mfst.name);
        try self.write("(writer: anytype");

        // Walk the signature's comma-separated params and emit each as `name: anytype`.
        const sig_empty = mem.trim(u8, mfst.sig, " \t\n\r").len == 0;
        try emitParams(self, mfst.sig, props_info.concrete_props_param);

        // Bug B fix (uniform across inline + hmr): a prop-less `pub fn Foo()`
        // source emits `(writer: anytype, _props: anytype) !void` with a `_ = _props;`
        // discard. This keeps call sites consistent: hmr-mode emits `try Foo(writer, .{})`
        // for every component invocation, and CMS's `tpl.zig` was updated to pass
        // `.{.{}}` for prop-less views via `renderStatic`. Both modes share the
        // 2-arg call shape.
        const synth_props = sig_empty;
        if (synth_props) {
            try self.write(", _props: anytype");
        }

        try self.write(") !void {\n");

        // capture_props (hmr-only) MUST be the first body statement. The CMS
        // consumer can also see it through compile-time grep ("captureProps"),
        // which the demos rely on for the negative test ("no `@import("hmr")`
        // when --hmr-capture-props isn't passed").
        const captured = self.hmr and self.capture_props;
        if (captured) {
            try self.write("    try @import(\"hmr\").captureProps(\"");
            try self.write(self.view_name);
            try self.write(":");
            try self.write(mfst.name);
            try self.write("\", ");
            // Pass the user-facing props param when known, otherwise the
            // synthesised `_props`. With defaults the user variable is the
            // concrete name (set below); without defaults but with explicit
            // params we pass the first param name (anytype) as-is.
            if (props_info.concrete_props_param) |cpp| {
                try self.write("_");
                try self.write(cpp);
            } else if (!sig_empty) {
                try self.write(firstParamName(mfst.sig));
            } else {
                try self.write("_props");
            }
            try self.write(");\n");
        }

        // Discard the synthesised `_props` placeholder when it would otherwise
        // be unused. capture_props already consumes it. Only relevant when
        // we actually synthesised the param (hmr-mode + prop-less).
        if (synth_props and !captured) {
            try self.write("    _ = _props;\n");
        }

        // `const props = zsx.withDefaults(NameProps, _props);` when defaults exist.
        if (props_info.concrete_props_param) |cpp| {
            try self.write("const ");
            try self.write(cpp);
            try self.write(" = zsx.withDefaults(");
            try self.write(mfst.name);
            try self.write("Props, _");
            try self.write(cpp);
            try self.write(");\n");
        }

        // Body.
        try self.emitNodes(mfst);

        try self.write("}\n\n");
    }

    fn emitNodes(self: *Emitter, mfst: Manifest) EmitError!void {
        var i: usize = 0;
        try self.emitNodeStream(mfst, &i, .all);
    }

    const StopMode = union(enum) {
        all,
        until_component_end,
    };

    /// Walk the manifest from `i.*` forward, emitting Zig. Stops when:
    ///   - mode=.all: end of nodes
    ///   - mode=.until_component_end: we encounter a top-level `component_end`
    ///     (matching the caller's component), advancing past it.
    ///
    /// `if_begin` chains are flattened on the fly: an `if_else` followed by
    /// an `if_begin` collapses to `} else if (...) {`, and the inner chain's
    /// trailing `if_end` consumes the outer `if_end` as well so we don't emit
    /// a stray closing brace.
    fn emitNodeStream(self: *Emitter, mfst: Manifest, i: *usize, mode: StopMode) EmitError!void {
        // Track nested if-chain depth introduced by collapsed else-if so we
        // know when to consume outer `if_end` markers.
        var elseif_collapse_pending: usize = 0;
        while (i.* < mfst.nodes.len) : (i.* += 1) {
            const node = mfst.nodes[i.*];
            switch (node) {
                .literal => |lit| {
                    if (self.hmr) {
                        // Each literal slot keeps its own writeAll call: L[N]
                        // is a runtime []const u8, so adjacent calls cannot
                        // legally merge. The L table holds raw literals from
                        // the parser; runtime re-parse produces a drop-in
                        // replacement for setL.
                        try self.emitLiteralRef(mfst, lit.slot);
                    } else {
                        // Inline mode: coalesce consecutive `literal` nodes
                        // before normalisation, because the parser flushes
                        // the literal buffer on every structural boundary
                        // (e.g. inside an HTML tag's children walk) — these
                        // splits are an artefact of the parser, not a real
                        // text boundary, and would otherwise defeat the
                        // inter-tag whitespace collapse.
                        var combined: std.ArrayListUnmanaged(u8) = .{};
                        defer combined.deinit(self.allocator);
                        while (i.* < mfst.nodes.len) : (i.* += 1) {
                            const n = mfst.nodes[i.*];
                            if (n != .literal) break;
                            try combined.appendSlice(self.allocator, mfst.literals[n.literal.slot]);
                        }
                        // Loop will `i.* += 1` again — back up so the next
                        // iteration sees the first non-literal node.
                        i.* -= 1;
                        try self.emitLiteralText(combined.items);
                    }
                },
                .expr => |e| try self.emitExpr(e),
                .if_begin => |cond| {
                    try self.writeIndent();
                    try self.write("if (");
                    try self.write(cond);
                    try self.write(") {\n");
                    self.indent += 1;
                    self.pushCtxSavingTagDepth(.body);
                },
                .if_else => {
                    if (self.indent > 0) self.indent -= 1;
                    self.popCtxRestoringTagDepth();
                    try self.writeIndent();
                    if (i.* + 1 < mfst.nodes.len and mfst.nodes[i.* + 1] == .if_begin) {
                        const c2 = mfst.nodes[i.* + 1].if_begin;
                        try self.write("} else if (");
                        try self.write(c2);
                        try self.write(") {\n");
                        self.indent += 1;
                        self.pushCtxSavingTagDepth(.body);
                        i.* += 1; // skip consumed if_begin
                        elseif_collapse_pending += 1;
                    } else {
                        try self.write("} else {\n");
                        self.indent += 1;
                        self.pushCtxSavingTagDepth(.body);
                    }
                },
                .if_end => {
                    if (self.indent > 0) self.indent -= 1;
                    self.popCtxRestoringTagDepth();
                    try self.writeIndent();
                    try self.write("}\n");
                    // After closing a chain that collapsed N else-ifs into a
                    // single Zig if-chain, the N outer `if_end`s must be
                    // consumed silently — one `}` already closed all of them.
                    while (elseif_collapse_pending > 0) : (elseif_collapse_pending -= 1) {
                        if (i.* + 1 < mfst.nodes.len and mfst.nodes[i.* + 1] == .if_end) {
                            i.* += 1;
                        } else break;
                    }
                },
                .for_begin => |fh| {
                    try self.writeIndent();
                    try self.write("for (");
                    try self.write(fh.iterable_source);
                    try self.write(") |");
                    try self.write(fh.binding);
                    try self.write("| {\n");
                    self.indent += 1;
                    self.pushCtxSavingTagDepth(.body);
                },
                .for_end => {
                    if (self.indent > 0) self.indent -= 1;
                    self.popCtxRestoringTagDepth();
                    try self.writeIndent();
                    try self.write("}\n");
                },
                .children_slot => {
                    try self.writeIndent();
                    try self.write("try zsx.render(");
                    try self.write(self.writerVar());
                    try self.write(", props.children);\n");
                },
                .component => |comp| try self.emitComponent(mfst, i, comp),
                .component_end => {
                    if (mode == .until_component_end) return;
                    // Stray component_end at top level — ignore.
                },
                .line_comment => |s| {
                    try self.writeIndent();
                    try self.write(s);
                    try self.write("\n");
                },
                .zig_stmt => |s| {
                    try self.writeIndent();
                    try self.write(s);
                    try self.write("\n");
                },
            }
        }
    }

    fn emitLiteralText(self: *Emitter, raw_text: []const u8) EmitError!void {
        // Children-context flag: if the surrounding scope is a component
        // children buffer, *all* WS uses children rules.
        const ctx_children = self.topCtx() == .children;

        // Pending-open carry-over: if a previous literal ended mid-tag
        // (e.g. `<button ... value="`), the present literal closes that tag
        // (`">...`). Account for the depth delta before processing this one
        // so inter-tag WS rules use the right tag_depth.
        if (raw_text.len > 0 and raw_text[0] == '"' and self.pending_open_len > 0) {
            const name = self.pending_open_name[0..self.pending_open_len];
            if (!self.pending_open_self_closing and !isVoid(name)) {
                self.tag_depth += 1;
            }
            self.pending_open_len = 0;
            self.pending_open_self_closing = false;
        }

        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);
        try normalizeLiteralCtx(self.allocator, &buf, raw_text, self.tag_depth, ctx_children);
        self.tag_depth += countTagDelta(raw_text);

        // Detect mid-tag carry-out: if the literal ends with an unclosed
        // `<tagname ...="` pattern (no `>` after the last `<` and ending in
        // an unmatched `"`), remember the tag name for the next literal.
        recordPendingOpen(self, raw_text);

        // The pending_open detection has already determined whether the
        // literal ends mid-attribute. We treat *any* literal ending with `="`
        // (with an unclosed `"`) as attr-value context for the next expr.
        self.in_attr_value = endsInAttrValue(raw_text);

        const text = buf.items;
        if (text.len == 0) return;
        try self.writeIndent();
        try self.writeTryWriter();
        try self.write("writeAll(\"");
        try writeEscaped(self.allocator, self.out, text);
        try self.write("\");\n");
    }

    /// HMR-mode literal reference: emit `try writer.writeAll(L[N])` where N
    /// is the file-wide slot index (per-function slot + `slot_offset`). The
    /// literal text itself is not emitted, but the tag-depth / pending-open
    /// / in-attr-value state is updated from the raw text so subsequent
    /// expression emissions (e.g. backticks in attribute context) still get
    /// the correct shape.
    fn emitLiteralRef(self: *Emitter, mfst: Manifest, per_fn_slot: u32) EmitError!void {
        const raw_text = mfst.literals[per_fn_slot];
        // Mirror the pending-open-tag carryover from `emitLiteralText` so
        // tag_depth tracking stays correct across split literals.
        if (raw_text.len > 0 and raw_text[0] == '"' and self.pending_open_len > 0) {
            const name = self.pending_open_name[0..self.pending_open_len];
            if (!self.pending_open_self_closing and !isVoid(name)) {
                self.tag_depth += 1;
            }
            self.pending_open_len = 0;
            self.pending_open_self_closing = false;
        }
        self.tag_depth += countTagDelta(raw_text);
        recordPendingOpen(self, raw_text);
        self.in_attr_value = endsInAttrValue(raw_text);

        const idx = per_fn_slot + self.slot_offset;
        try self.writeIndent();
        try self.writeTryWriter();
        try self.write("writeAll(L[");
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch return;
        try self.write(s);
        try self.write("]);\n");
    }

    fn emitExpr(self: *Emitter, e: manifest_src.Expr) EmitError!void {
        switch (e.kind) {
            .plain => {
                try self.writeIndent();
                try self.write("try zsx.render(");
                try self.write(self.writerVar());
                try self.write(", ");
                try self.write(e.source);
                try self.write(");\n");
            },
            .raw => {
                try self.writeIndent();
                try self.writeTryWriter();
                try self.write("writeAll(");
                try self.write(e.source);
                try self.write(");\n");
            },
            .ternary => try self.emitTernaryOrElvis(e.source, .ternary, false),
            .elvis => try self.emitTernaryOrElvis(e.source, .elvis, false),
            .backtick => {
                // Strip outer backticks if present.
                var inner = e.source;
                if (inner.len >= 2 and inner[0] == '`' and inner[inner.len - 1] == '`') {
                    inner = inner[1 .. inner.len - 1];
                }
                try self.emitBacktickString(inner, self.in_attr_value);
            },
        }
    }

    fn emitTernaryOrElvis(self: *Emitter, expr: []const u8, kind: enum { ternary, elvis }, is_raw: bool) EmitError!void {
        // Find the `?` at depth 0 (skipping strings, parens, brackets, braces).
        const qpos = findTopLevel(expr, '?', true) orelse {
            // Shouldn't happen if parser classified as ternary/elvis. Fall back.
            try self.writeIndent();
            try self.write("try zsx.render(");
            try self.write(self.writerVar());
            try self.write(", ");
            try self.write(expr);
            try self.write(");\n");
            return;
        };
        if (kind == .elvis) {
            const lhs = mem.trim(u8, expr[0..qpos], " \t\n\r");
            const rhs = mem.trim(u8, expr[qpos + 2 ..], " \t\n\r");
            try self.writeIndent();
            if (is_raw) {
                try self.writeTryWriter();
                try self.write("writeAll(");
            } else {
                try self.write("try zsx.render(");
                try self.write(self.writerVar());
                try self.write(", ");
            }
            try self.write(lhs);
            try self.write(" orelse ");
            try self.write(rhs);
            try self.write(");\n");
        } else {
            const cpos = findTopLevel(expr[qpos + 1 ..], ':', false) orelse {
                try self.emitExpr(.{ .kind = .plain, .source = expr });
                return;
            };
            const colon_pos = qpos + 1 + cpos;
            const cond = mem.trim(u8, expr[0..qpos], " \t\n\r");
            const then_val = mem.trim(u8, expr[qpos + 1 .. colon_pos], " \t\n\r");
            const else_val = mem.trim(u8, expr[colon_pos + 1 ..], " \t\n\r");
            try self.writeIndent();
            if (is_raw) {
                try self.writeTryWriter();
                try self.write("writeAll(");
            } else {
                try self.write("try zsx.render(");
                try self.write(self.writerVar());
                try self.write(", ");
            }
            try self.write("if (");
            try self.write(cond);
            try self.write(") ");
            try self.write(then_val);
            try self.write(" else ");
            try self.write(else_val);
            try self.write(");\n");
        }
    }

    fn emitBacktickString(self: *Emitter, content: []const u8, use_escape: bool) EmitError!void {
        var i: usize = 0;
        var text_start: usize = 0;
        while (i < content.len) {
            if (i + 1 < content.len and content[i] == '$' and content[i + 1] == '{') {
                if (i > text_start) {
                    try self.writeIndent();
                    try self.writeTryWriter();
                    try self.write("writeAll(\"");
                    try writeEscaped(self.allocator, self.out, content[text_start..i]);
                    try self.write("\");\n");
                }
                i += 2;
                const is_raw = i + 5 <= content.len and mem.eql(u8, content[i .. i + 5], "@raw ");
                if (is_raw) i += 5;
                const expr_start = i;
                var depth: usize = 1;
                while (i < content.len and depth > 0) {
                    if (content[i] == '{') depth += 1;
                    if (content[i] == '}') depth -= 1;
                    if (depth > 0) i += 1;
                }
                const expr = mem.trim(u8, content[expr_start..i], " \t\n\r");
                if (i < content.len) i += 1;
                try self.writeIndent();
                if (is_raw) {
                    try self.writeTryWriter();
                    try self.write("writeAll(");
                    try self.write(expr);
                    try self.write(");\n");
                } else if (use_escape) {
                    try self.write("try zsx.escape(");
                    try self.write(self.writerVar());
                    try self.write(", ");
                    try self.write(expr);
                    try self.write(");\n");
                } else {
                    try self.write("try zsx.render(");
                    try self.write(self.writerVar());
                    try self.write(", ");
                    try self.write(expr);
                    try self.write(");\n");
                }
                text_start = i;
            } else {
                i += 1;
            }
        }
        if (text_start < content.len) {
            try self.writeIndent();
            try self.writeTryWriter();
            try self.write("writeAll(\"");
            try writeEscaped(self.allocator, self.out, content[text_start..content.len]);
            try self.write("\");\n");
        }
    }

    fn emitBacktickAsConcat(self: *Emitter, content: []const u8) EmitError!void {
        try self.write("zsx.concatRt(&.{");
        var i: usize = 0;
        var text_start: usize = 0;
        var first = true;
        while (i < content.len) {
            if (i + 1 < content.len and content[i] == '$' and content[i + 1] == '{') {
                if (i > text_start) {
                    if (!first) try self.write(", ") else try self.write(" ");
                    try self.write("\"");
                    try writeEscaped(self.allocator, self.out, content[text_start..i]);
                    try self.write("\"");
                    first = false;
                }
                i += 2;
                const is_raw = i + 5 <= content.len and mem.eql(u8, content[i .. i + 5], "@raw ");
                if (is_raw) i += 5;
                const expr_start = i;
                var depth: usize = 1;
                while (i < content.len and depth > 0) {
                    if (content[i] == '{') depth += 1;
                    if (content[i] == '}') depth -= 1;
                    if (depth > 0) i += 1;
                }
                const expr = mem.trim(u8, content[expr_start..i], " \t\n\r");
                if (i < content.len) i += 1;
                if (!first) try self.write(", ") else try self.write(" ");
                try self.write(expr);
                first = false;
                text_start = i;
            } else {
                i += 1;
            }
        }
        if (text_start < content.len) {
            if (!first) try self.write(", ") else try self.write(" ");
            try self.write("\"");
            try writeEscaped(self.allocator, self.out, content[text_start..content.len]);
            try self.write("\"");
        }
        try self.write(" })");
    }

    /// The Props type expression for a liftable component, or null if the
    /// component isn't liftable (not in the map).
    fn propsExprOf(self: *const Emitter, name: []const u8) ?[]const u8 {
        return self.props_expr.get(name);
    }

    /// True iff this invocation is eligible for the A-table lift: lift mode
    /// is on, the component is liftable (concrete struct Props, recorded in
    /// `props_expr`), and at least one attr is a literal/const-expr worth
    /// swapping. Components with only expression attrs (`{someVar}`) have
    /// nothing to lift — they fall back to the inline call and rebuild on
    /// edit (expressions reference runtime scope, not swappable anyway).
    fn componentLiftable(self: *const Emitter, comp: Component) bool {
        if (!self.lift_attrs) return false;
        if (!self.props_expr.contains(comp.name)) return false;
        for (comp.attrs) |a| {
            const kind = classifyAttr(a.value);
            if (kind == .string or kind == .const_expr) return true;
        }
        return false;
    }

    /// Record the liftable attrs (every literal / const-expr) for this call
    /// site and return the slot ID. `comp_index` is the flat-manifest ordinal
    /// baked into `lift_sites` so the dev loop matches the slot to a fresh node.
    fn pushCallSite(self: *Emitter, comp: Component, comp_index: u32) EmitError!u32 {
        const id = self.next_call_site_id.*;
        self.next_call_site_id.* += 1;
        var init = CallSiteInit{ .comp_index = comp_index };
        for (comp.attrs) |a| {
            const kind = classifyAttr(a.value);
            const raw: []const u8 = switch (kind) {
                .string => a.value.string,
                .const_expr => a.value.expr,
                else => continue, // expr / bool_present aren't swappable
            };
            try init.attrs.append(self.allocator, .{ .name = a.name, .raw_value = raw });
        }
        try self.call_site_initials.append(self.allocator, init);
        return id;
    }

    /// Emit the lifted props setup. Universal form (works for any concrete-
    /// struct component — local, same-file, imported, or external):
    ///     var __p: <PropsExpr> = @import("hmr").propsFrom(<PropsExpr>, .{ <NON-lifted attrs> });
    ///     @import("hmr").applyAttrs(<PropsExpr>, &__p, A[N]);
    ///
    /// Only NON-lifted attrs (expressions referencing runtime scope, and
    /// `bool_present` shorthands) go into the inline init — they can't live
    /// in the A table. Every lifted literal/const-expr attr goes ONLY through
    /// A + applyAttrs, which soft-fails (logs + keeps default) on a bad value
    /// instead of breaking the build. That's why e.g. `as=.label` (an invalid
    /// enum tag) degrades gracefully rather than failing to compile — putting
    /// it in the inline init would be a hard comptime coercion error.
    /// `propsFrom` ignores attrs the component doesn't declare (matching the
    /// component's own `withDefaults` leniency). `children_items_expr`, when
    /// non-null, is added as `.children = <expr>`. Caller emits the call.
    fn emitLiftedPropsSetup(
        self: *Emitter,
        comp: Component,
        slot_id: u32,
        children_items_expr: ?[]const u8,
    ) EmitError!void {
        const props_expr = self.propsExprOf(comp.name) orelse unreachable;
        try self.writeIndent();
        try self.write("var __p: ");
        try self.write(props_expr);
        try self.write(" = @import(\"hmr\").propsFrom(");
        try self.write(props_expr);
        try self.write(", .{");
        // Inline init: NON-lifted attrs only (exprs + bool_present). Lifted
        // literals/const-exprs are excluded — they flow through A.
        var wrote_any = false;
        for (comp.attrs) |attr| {
            const kind = classifyAttr(attr.value);
            if (kind == .string or kind == .const_expr) continue; // lifted → A
            if (wrote_any) try self.write(",");
            try self.write(" .");
            try self.write(attr.name);
            try self.write(" = ");
            switch (attr.value) {
                .expr => |s| {
                    if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') {
                        try self.emitBacktickAsConcat(s[1 .. s.len - 1]);
                    } else {
                        try self.write(s);
                    }
                },
                .bool_present => try self.write("true"),
                .string => unreachable,
            }
            wrote_any = true;
        }
        if (children_items_expr) |cx| {
            if (wrote_any) try self.write(",");
            try self.write(" .children = ");
            try self.write(cx);
            wrote_any = true;
        }
        if (wrote_any) try self.write(" ");
        try self.write("});\n");
        try self.writeIndent();
        try self.write("@import(\"hmr\").applyAttrs(");
        try self.write(props_expr);
        try self.write(", &__p, A[");
        try appendUsize(self.allocator, self.out, slot_id);
        try self.write("]);\n");
        // Forwarded (non-prop) attrs — data-p-* directives etc. — that
        // applyAttrs can't place on the concrete props struct. renderForwarding
        // splices them onto the component root so they survive the HMR lift.
        try self.writeIndent();
        try self.write("const __fwd = @import(\"hmr\").forwardedAttrs(");
        try self.write(props_expr);
        try self.write(", A[");
        try appendUsize(self.allocator, self.out, slot_id);
        try self.write("]);\n");
    }

    fn emitComponent(self: *Emitter, mfst: Manifest, i: *usize, comp: Component) EmitError!void {
        // Claim this component's flat-manifest ordinal up front (pre-order),
        // before recursing into children. Children claim larger indices;
        // this component's lifted slot (assigned post-children) records the
        // index captured here so the dev loop's lockstep walk matches.
        const my_comp_index = self.next_comp_index.*;
        self.next_comp_index.* += 1;
        if (comp.has_children) {
            // Pre-render children to a buffer, then call the component with
            // `.children = buf.items` as a pre-rendered HTML string.
            try self.writeIndent();
            try self.write("{\n");
            self.indent += 1;

            const depth_suffix = depthSuffix(self.children_depth);
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
            try self.writeIndent();
            try self.write("const _children_w_");
            try self.write(depth_suffix);
            try self.write(" = _children_buf_");
            try self.write(depth_suffix);
            try self.write(".writer(_children_alloc_");
            try self.write(depth_suffix);
            try self.write(");\n");
            try self.writeIndent();
            try self.write("_ = &_children_w_");
            try self.write(depth_suffix);
            try self.write(";\n");

            // Render children into the buffer.
            self.children_depth += 1;
            self.pushCtx(.children);
            // tag_depth is conceptually per-buffer — the children buffer
            // starts fresh. Save and restore so any unbalanced state inside
            // doesn't leak.
            const saved_tag_depth = self.tag_depth;
            self.tag_depth = 0;
            i.* += 1;
            try self.emitNodeStream(mfst, i, .until_component_end);
            self.tag_depth = saved_tag_depth;
            self.popCtx();
            self.children_depth -= 1;

            // Call component with children = buf.items
            if (self.componentLiftable(comp)) {
                const slot = try self.pushCallSite(comp, my_comp_index);
                const children_expr = try std.fmt.allocPrint(
                    self.allocator,
                    "_children_buf_{s}.items",
                    .{depth_suffix},
                );
                defer self.allocator.free(children_expr);
                try self.emitLiftedPropsSetup(comp, slot, children_expr);
                try self.writeIndent();
                try self.write("try @import(\"hmr\").renderForwarding(");
                try self.write(comp.name);
                try self.write(", ");
                try self.write(self.writerVar());
                try self.write(", __p, __fwd);\n");
            } else {
                // Inline mode: forward non-prop attrs (data-p-* etc.) onto the
                // component root via renderForwarding when we know its Props
                // type and it carries a forwardable attr (so forwarding works in
                // build/inline, not just HMR).
                const fwd_props: ?[]const u8 = if (hasForwardableAttr(comp.attrs)) self.propsExprOf(comp.name) else null;
                try self.writeIndent();
                if (fwd_props) |props_expr| {
                    try self.write("try @import(\"zsx\").runtime.renderForwarding(");
                    try self.write(comp.name);
                    try self.write(", ");
                    try self.write(props_expr);
                    try self.write(", ");
                    try self.write(self.writerVar());
                } else {
                    try self.write("try ");
                    try self.write(comp.name);
                    try self.write("(");
                    try self.write(self.writerVar());
                }
                try self.write(", .{");
                try self.emitComponentProps(comp.attrs);
                if (comp.attrs.len > 0) try self.write(",");
                try self.write(" .children = _children_buf_");
                try self.write(depth_suffix);
                try self.write(".items });\n");
            }

            if (self.indent > 0) self.indent -= 1;
            try self.writeIndent();
            try self.write("}\n");
        } else {
            if (self.componentLiftable(comp)) {
                try self.writeIndent();
                try self.write("{\n");
                self.indent += 1;
                const slot = try self.pushCallSite(comp, my_comp_index);
                try self.emitLiftedPropsSetup(comp, slot, null);
                try self.writeIndent();
                try self.write("try @import(\"hmr\").renderForwarding(");
                try self.write(comp.name);
                try self.write(", ");
                try self.write(self.writerVar());
                try self.write(", __p, __fwd);\n");
                if (self.indent > 0) self.indent -= 1;
                try self.writeIndent();
                try self.write("}\n");
            } else {
                const fwd_props: ?[]const u8 = if (hasForwardableAttr(comp.attrs)) self.propsExprOf(comp.name) else null;
                try self.writeIndent();
                if (fwd_props) |props_expr| {
                    try self.write("try @import(\"zsx\").runtime.renderForwarding(");
                    try self.write(comp.name);
                    try self.write(", ");
                    try self.write(props_expr);
                    try self.write(", ");
                    try self.write(self.writerVar());
                } else {
                    try self.write("try ");
                    try self.write(comp.name);
                    try self.write("(");
                    try self.write(self.writerVar());
                }
                try self.write(", .{");
                try self.emitComponentProps(comp.attrs);
                try self.write(" });\n");
            }
        }
    }

    fn emitComponentProps(self: *Emitter, attrs: []const Attr) EmitError!void {
        var first = true;
        for (attrs) |attr| {
            if (!first) try self.write(", ");
            try self.write(" .");
            // Hyphenated names (data-p-* directives, data-*, aria-*) aren't bare
            // Zig identifiers — quote with @"". route() splits prop-vs-forward at
            // comptime via @hasField; the transpiler just passes everything.
            const hyphenated = std.mem.indexOfScalar(u8, attr.name, '-') != null;
            if (hyphenated) try self.write("@\"");
            try self.write(attr.name);
            if (hyphenated) try self.write("\"");
            try self.write(" = ");
            switch (attr.value) {
                .string => |s| {
                    try self.write("\"");
                    try self.write(s);
                    try self.write("\"");
                },
                .expr => |s| {
                    if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') {
                        try self.emitBacktickAsConcat(s[1 .. s.len - 1]);
                    } else {
                        try self.write(s);
                    }
                },
                .bool_present => {
                    try self.write("true");
                },
            }
            first = false;
        }
    }
};

const empty_props_expr: std.StringHashMapUnmanaged([]const u8) = .empty;
var dummy_call_site_id: u32 = 0;
var dummy_call_site_initials: std.ArrayListUnmanaged(CallSiteInit) = .{};
var dummy_comp_index: u32 = 0;

/// How an attr value should be treated for the A-table lift.
const AttrLiftKind = enum {
    /// `.string` form — value is the raw text, lift verbatim.
    string,
    /// `.expr` form whose source is a constant Zig expression — enum
    /// tag (.primary), bool (true/false), null, int (42), float (3.14).
    /// Liftable as the source slice.
    const_expr,
    /// `.expr` form referencing local scope (`{someVar}`, `{props.x}`).
    /// NOT liftable — must stay inline at the call site.
    expr,
    /// `<Foo disabled />` shorthand — no value to lift.
    bool_present,
};

fn classifyAttr(value: AttrValue) AttrLiftKind {
    return switch (value) {
        .string => .string,
        .bool_present => .bool_present,
        .expr => |s| if (isConstExpr(s)) .const_expr else .expr,
    };
}

/// True if any attr is one a component is unlikely to declare as a prop and so
/// should forward onto the root: hyphenated names (data-p-* directives, data-*,
/// aria-*) or the global `role`/`tabindex`. Gate for emitting the inline
/// `renderForwarding` wrapper — the runtime helper still does the real
/// prop-vs-forward split via `@hasField`.
fn hasForwardableAttr(attrs: []const Attr) bool {
    for (attrs) |a| {
        if (std.mem.indexOfScalar(u8, a.name, '-') != null) return true;
        if (std.mem.eql(u8, a.name, "role") or std.mem.eql(u8, a.name, "tabindex")) return true;
    }
    return false;
}

/// True if `s` is a pure literal — i.e., parseable at runtime without
/// reference to surrounding scope. Used to decide whether an `.expr`
/// attr (which covers both `.primary` enum tags and `{someVar}` real
/// expressions) is safe to lift into the A-table.
fn isConstExpr(s: []const u8) bool {
    if (s.len == 0) return false;
    // Enum tag: `.primary` or `.@"error"` (with optional whitespace stripped).
    if (s[0] == '.') {
        if (s.len == 1) return false;
        const rest = s[1..];
        // `.@"foo"` form
        if (rest.len >= 3 and rest[0] == '@' and rest[1] == '"' and rest[rest.len - 1] == '"') return true;
        // `.identifier` — must be all alnum/_
        for (rest) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        return true;
    }
    // true / false / null
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) return true;
    // Numeric literal: optional leading -, digits, optional `.digits`.
    var i: usize = 0;
    if (s[0] == '-') i = 1;
    if (i >= s.len) return false;
    var saw_dot = false;
    var saw_digit = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isDigit(c)) {
            saw_digit = true;
        } else if (c == '.' and !saw_dot) {
            saw_dot = true;
        } else return false;
    }
    return saw_digit;
}

// Helpers

fn childWriterName(idx: u8) []const u8 {
    return switch (idx) {
        0 => "_children_w_0",
        1 => "_children_w_1",
        2 => "_children_w_2",
        3 => "_children_w_3",
        4 => "_children_w_4",
        5 => "_children_w_5",
        6 => "_children_w_6",
        7 => "_children_w_7",
        8 => "_children_w_8",
        9 => "_children_w_9",
        else => "_children_w_x",
    };
}

fn depthSuffix(d: u8) []const u8 {
    return switch (d) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        else => "x",
    };
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn startsWithKeyword(src: []const u8, pos: usize, kw: []const u8) bool {
    if (pos + kw.len > src.len) return false;
    return mem.eql(u8, src[pos .. pos + kw.len], kw);
}

/// Caller: pos points at `pub fn ` or `fn `. Walk forward to find the
/// matching closing brace of the function body. Returns the position just
/// past the closing `}`.
fn findFunctionEnd(src: []const u8, start: usize) !usize {
    var pos = start;
    // Skip to first `{` — but track parentheses so we don't trip on the
    // signature's `(...)` paren depth and skip over a `{` that lives inside
    // the param list (struct types). The first `{` we want is at paren_depth
    // == 0 AND after the closing paren of the param list.
    var paren_depth: usize = 0;
    var saw_paren = false;
    while (pos < src.len) : (pos += 1) {
        const c = src[pos];
        if (c == '(') {
            paren_depth += 1;
            saw_paren = true;
        } else if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == '{' and paren_depth == 0 and saw_paren) {
            break;
        }
    }
    if (pos >= src.len) return src.len;
    pos += 1;
    var depth: usize = 1;
    while (pos < src.len and depth > 0) {
        const c = src[pos];
        switch (c) {
            '{' => {
                depth += 1;
                pos += 1;
            },
            '}' => {
                depth -= 1;
                pos += 1;
            },
            '"' => {
                pos += 1;
                while (pos < src.len) {
                    if (src[pos] == '\\' and pos + 1 < src.len) {
                        pos += 2;
                        continue;
                    }
                    if (src[pos] == '"') {
                        pos += 1;
                        break;
                    }
                    pos += 1;
                }
            },
            '\'' => {
                pos += 1;
                while (pos < src.len) {
                    if (src[pos] == '\\' and pos + 1 < src.len) {
                        pos += 2;
                        continue;
                    }
                    if (src[pos] == '\'') {
                        pos += 1;
                        break;
                    }
                    pos += 1;
                }
            },
            '`' => {
                pos += 1;
                while (pos < src.len and src[pos] != '`') : (pos += 1) {}
                if (pos < src.len) pos += 1;
            },
            '/' => {
                // Line comments — `//` runs to end of line. Important to skip
                // because comments may contain unbalanced braces.
                if (pos + 1 < src.len and src[pos + 1] == '/') {
                    while (pos < src.len and src[pos] != '\n') : (pos += 1) {}
                } else {
                    pos += 1;
                }
            },
            else => pos += 1,
        }
    }
    return pos;
}

fn passConstDecl(src: []const u8, start: usize) usize {
    var pos = start;
    var depth: usize = 0;
    while (pos < src.len) : (pos += 1) {
        switch (src[pos]) {
            '{' => depth += 1,
            '}' => if (depth > 0) {
                depth -= 1;
            },
            ';' => if (depth == 0) {
                return pos + 1;
            },
            else => {},
        }
    }
    return pos;
}

const PropsInfo = struct {
    struct_type: ?[]const u8 = null,
    concrete_props_param: ?[]const u8 = null,
};

/// Scan the function-signature text for an inline struct param. Returns the
/// param's struct-type slice (for emitting `NameProps = struct {...}`), and
/// the param's name (for `withDefaults`) IF the struct has default values.
fn scanPropsParam(sig: []const u8) PropsInfo {
    const raw_params = mem.trim(u8, sig, " \t\n\r");
    if (raw_params.len == 0) return .{};

    // Find first ':' at depth 0.
    var p: usize = 0;
    var d: usize = 0;
    while (p < raw_params.len) : (p += 1) {
        switch (raw_params[p]) {
            '{' => d += 1,
            '}' => if (d == 0) return .{} else {
                d -= 1;
            },
            ':' => if (d == 0) break,
            else => {},
        }
    }
    if (p >= raw_params.len) return .{};

    const type_text = mem.trim(u8, raw_params[p + 1 ..], " \t\n\r");
    if (!mem.startsWith(u8, type_text, "struct")) return .{};
    if (mem.indexOf(u8, type_text, "anytype") != null) return .{};

    var info = PropsInfo{ .struct_type = type_text };

    // Detect default values: scan for `=` at brace depth 1 (struct body).
    var brace_d: usize = 0;
    var scan: usize = 0;
    while (scan < type_text.len) : (scan += 1) {
        switch (type_text[scan]) {
            '{' => brace_d += 1,
            '}' => if (brace_d > 0) {
                brace_d -= 1;
            },
            '=' => if (brace_d == 1 and scan + 1 < type_text.len and type_text[scan + 1] != '=') {
                info.concrete_props_param = mem.trim(u8, raw_params[0..p], " \t");
                break;
            },
            else => {},
        }
    }
    return info;
}

/// Extract the first parameter name from a signature slice. Used by
/// capture_props emit when the user's signature has explicit params but no
/// `struct {}` defaults (so we can't use `concrete_props_param`). Returns
/// the source-level identifier (e.g. `"props"`) or empty string on failure.
fn firstParamName(sig: []const u8) []const u8 {
    const trimmed = mem.trim(u8, sig, " \t\n\r");
    if (trimmed.len == 0) return "";
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ',' and trimmed[end] != ':') : (end += 1) {}
    return mem.trim(u8, trimmed[0..end], " \t");
}

fn emitParams(self: *Emitter, sig: []const u8, concrete_props_param: ?[]const u8) EmitError!void {
    const trimmed = mem.trim(u8, sig, " \t\n\r");
    if (trimmed.len == 0) return;

    var param_pos: usize = 0;
    while (param_pos < trimmed.len) {
        var scan = param_pos;
        var brace_depth: usize = 0;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        while (scan < trimmed.len) : (scan += 1) {
            switch (trimmed[scan]) {
                '{' => brace_depth += 1,
                '}' => brace_depth -= 1,
                '(' => paren_depth += 1,
                ')' => paren_depth -= 1,
                '[' => bracket_depth += 1,
                ']' => bracket_depth -= 1,
                ',' => if (brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) break,
                else => {},
            }
        }
        const param = mem.trim(u8, trimmed[param_pos..scan], " \t\n\r");
        if (param.len > 0) {
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
        param_pos = if (scan < trimmed.len) scan + 1 else scan;
    }
}

fn writeEscaped(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) EmitError!void {
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
}

/// Like `writeEscaped` but drops the `0x01` self-closing-non-void sentinel
/// that the parser appends to keep inline-mode tag-depth accounting balanced.
/// Hmr-mode bakes raw literals into `initial_L`; Zig rejects `\x01` inside a
/// string literal with "string literal contains invalid byte". Stripping
/// here matches what inline-mode's `emitSeg` does during normalisation, so
/// runtime literal contents stay identical to the inline emission.
fn writeEscapedStripSentinel(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) EmitError!void {
    for (text) |c| {
        switch (c) {
            0x01 => {},
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
}

// data-component attribute splice

/// Inject `data-component="<FnName>"` into the first opening HTML tag of
/// the function body (carried inside `manifest.literals[0]`). Strategies,
/// in priority order:
///
///   1. Body starts with `<!DOCTYPE …>` then a lowercase HTML tag → skip
///      the DOCTYPE, splice into the next opening tag.
///   2. Body starts with a static lowercase HTML tag → splice directly.
///   3. Body starts with a PascalCase component tag (`<Foo ...>`) → skip
///      decoration; the inner component owns its own `data-component`.
///   4. Fallback (no opening tag at start) → wrap the function body in a
///      `<div data-component="..." style="display:contents">…</div>`
///      and emit a stderr warning so authors can refactor.
///
/// MUST be called by both the emitter (build time) and any runtime
/// HMR re-parse (CMS swap loop) so build-time and runtime-parsed literal
/// arrays produce identical visible HTML — otherwise `setL(fresh.literals)`
/// would strip the attribute on every swap.
///
/// Re-entrant: if the targeted opening tag already carries a
/// `data-component="..."`, the existing value is replaced (no duplication).
pub fn spliceDomAttribute(allocator: Allocator, manifest: *Manifest, dc_value: []const u8) EmitError!void {
    if (manifest.nodes.len == 0) return;

    // The first non-trivial node determines strategy:
    //   * `.component` (PascalCase) → skip; inner component decorates itself.
    //   * `.literal` → inspect the literal text and try strategies 1-2.
    //   * anything else (`.if_begin`, `.expr`, etc.) → fallback wrapper.
    //
    // Whitespace-only `.literal` slots at the start (rare, but the parser
    // can emit one for templates indented inside an `if`/`for`) are skipped.
    var first_idx: usize = 0;
    var lit_slot: ?u32 = null;
    while (first_idx < manifest.nodes.len) : (first_idx += 1) {
        switch (manifest.nodes[first_idx]) {
            .literal => |l| {
                const txt = manifest.literals[l.slot];
                // Skip pure-whitespace slots (they're parser artefacts).
                var only_ws = true;
                for (txt) |c| {
                    if (!isWs(c)) {
                        only_ws = false;
                        break;
                    }
                }
                if (only_ws and txt.len > 0) continue;
                if (txt.len == 0) continue;
                lit_slot = l.slot;
                break;
            },
            // PascalCase root component: previously this returned early
            // with the reasoning "the inner component owns its own
            // data-component". That's wrong for CMS-style usage where
            // every top-level view function is broadcast under its own
            // registry name (`<view>:<Fn>`) — the inner component's
            // attribute uses a DIFFERENT name (`<other-view>:<OtherFn>`),
            // so the client's selector for THIS view finds nothing.
            // Fall through to the wrapper fallback so every function
            // gets its own data-component anchor.
            .component => break,
            .line_comment, .zig_stmt => continue,
            else => break,
        }
    }
    if (lit_slot == null) {
        try spliceDomAttributeFallback(allocator, manifest, dc_value);
        return;
    }
    const slot_idx: u32 = lit_slot.?;
    const lit = manifest.literals[slot_idx];

    // Walk past any leading whitespace, comments, and DOCTYPE.
    var scan: usize = 0;
    while (scan < lit.len) {
        // Skip whitespace.
        while (scan < lit.len and isWs(lit[scan])) : (scan += 1) {}
        if (scan >= lit.len) break;
        // Skip a single line/HTML comment-style `<!-- ... -->`.
        if (scan + 3 < lit.len and lit[scan] == '<' and lit[scan + 1] == '!' and lit[scan + 2] == '-' and lit[scan + 3] == '-') {
            const close = mem.indexOfPos(u8, lit, scan, "-->") orelse break;
            scan = close + 3;
            continue;
        }
        // Skip DOCTYPE.
        if (scan + 1 < lit.len and lit[scan] == '<' and lit[scan + 1] == '!') {
            const close = mem.indexOfScalarPos(u8, lit, scan, '>') orelse break;
            scan = close + 1;
            continue;
        }
        break;
    }
    if (scan >= lit.len) {
        try spliceDomAttributeFallback(allocator, manifest, dc_value);
        return;
    }

    // We're at the first non-WS/non-DOCTYPE byte. Must be `<` followed by
    // an ASCII letter to qualify as an opening tag.
    if (lit[scan] != '<' or scan + 1 >= lit.len or !isAsciiAlpha(lit[scan + 1])) {
        try spliceDomAttributeFallback(allocator, manifest, dc_value);
        return;
    }

    // PascalCase first letter → skip self-decoration entirely.
    if (lit[scan + 1] >= 'A' and lit[scan + 1] <= 'Z') return;

    // Lowercase HTML tag — find the tag's name end and the closing `>` /
    // `/>`. String-aware scan so attribute values with `>` don't trip us.
    const tag_start = scan;
    var tname_end = scan + 1;
    while (tname_end < lit.len and (isAsciiAlphaNum(lit[tname_end]) or lit[tname_end] == '-')) : (tname_end += 1) {}
    var i: usize = tname_end;
    var existing_dc: ?struct { start: usize, end: usize } = null;
    var saw_close = false;
    var self_closing = false;
    while (i < lit.len) {
        const c = lit[i];
        if (c == '"') {
            // Attribute value start: skim to closing quote.
            i += 1;
            while (i < lit.len and lit[i] != '"') : (i += 1) {}
            if (i < lit.len) i += 1;
            continue;
        }
        if (c == '\'') {
            i += 1;
            while (i < lit.len and lit[i] != '\'') : (i += 1) {}
            if (i < lit.len) i += 1;
            continue;
        }
        if (c == '>') {
            saw_close = true;
            if (i > tag_start and lit[i - 1] == '/') self_closing = true;
            break;
        }
        // Look for existing `data-component=` to support replacement.
        if (existing_dc == null and c == 'd' and i + 15 < lit.len and mem.startsWith(u8, lit[i..], "data-component=")) {
            // Confirm we're at an attribute boundary (preceded by WS).
            if (i > tag_start and isWs(lit[i - 1])) {
                const attr_start = i;
                var ai: usize = i + 15; // past `data-component=`
                if (ai < lit.len and lit[ai] == '"') {
                    ai += 1;
                    while (ai < lit.len and lit[ai] != '"') : (ai += 1) {}
                    if (ai < lit.len) ai += 1;
                } else {
                    // Bare/unquoted value — consume to next WS or `>`.
                    while (ai < lit.len and !isWs(lit[ai]) and lit[ai] != '>' and lit[ai] != '/') : (ai += 1) {}
                }
                existing_dc = .{ .start = attr_start, .end = ai };
                i = ai;
                continue;
            }
        }
        i += 1;
    }
    if (!saw_close) {
        // Malformed tag (mid-attribute split across literals?) — fall back.
        try spliceDomAttributeFallback(allocator, manifest, dc_value);
        return;
    }

    // Build the new literal: either replace the existing data-component
    // attribute, or insert one before the closing `>` / `/>`.
    var new_lit: std.ArrayListUnmanaged(u8) = .{};
    errdefer new_lit.deinit(allocator);

    if (existing_dc) |dc| {
        try new_lit.appendSlice(allocator, lit[0..dc.start]);
        try new_lit.appendSlice(allocator, "data-component=\"");
        try new_lit.appendSlice(allocator, dc_value);
        try new_lit.appendSlice(allocator, "\"");
        try new_lit.appendSlice(allocator, lit[dc.end..]);
    } else {
        const insert_at = if (self_closing) i - 1 else i;
        try new_lit.appendSlice(allocator, lit[0..insert_at]);
        // Avoid emitting `<foo data-component="..."/>` without a space.
        if (insert_at > 0 and !isWs(lit[insert_at - 1])) {
            try new_lit.append(allocator, ' ');
        }
        try new_lit.appendSlice(allocator, "data-component=\"");
        try new_lit.appendSlice(allocator, dc_value);
        try new_lit.appendSlice(allocator, "\"");
        try new_lit.appendSlice(allocator, lit[insert_at..]);
    }

    const owned = try new_lit.toOwnedSlice(allocator);
    // Replace the slot.
    allocator.free(lit);
    // `manifest.literals` is `[]const []const u8`; we own the backing slice
    // (parser returns owned arrays). Mutate via a discarded const cast.
    const mut_lits: [*][]const u8 = @constCast(@ptrCast(manifest.literals.ptr));
    mut_lits[slot_idx] = owned;
}

/// Wrapper-fallback: prepend a `<div data-component="..." style="display:contents">`
/// and append `</div>`. Warns on stderr because authors should refactor —
/// flexbox/grid/`<tr>` parents will treat the wrapper as a real flow-level
/// box and break layout.
fn spliceDomAttributeFallback(
    allocator: Allocator,
    manifest: *Manifest,
    dc_value: []const u8,
) EmitError!void {
    std.debug.print(
        "[zsx] warning: function `{s}` body doesn't start with a static HTML tag — wrapping in `<div data-component=\"{s}\" style=\"display:contents\">…</div>`. Consider refactoring so the body's first emitted node is a static HTML element.\n",
        .{ manifest.name, dc_value },
    );

    // Prepend an opening wrapper to literals[0] (or insert a new literals[0]
    // if it's empty). Append a closing wrapper to literals[last].
    //
    // To avoid disturbing slot numbering / nodes (which reference slots by
    // index), we mutate the existing slot 0 in place and slot N-1 in place
    // rather than inserting a new slot.

    if (manifest.literals.len == 0) return;

    const open = try std.fmt.allocPrint(
        allocator,
        "<div data-component=\"{s}\" style=\"display:contents\">",
        .{dc_value},
    );
    defer allocator.free(open);

    const close = "</div>";

    // Mutate slot 0: prepend open.
    {
        const lit = manifest.literals[0];
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, open);
        try buf.appendSlice(allocator, lit);
        const owned = try buf.toOwnedSlice(allocator);
        allocator.free(lit);
        const mut_lits: [*][]const u8 = @constCast(@ptrCast(manifest.literals.ptr));
        mut_lits[0] = owned;
    }
    // Mutate last slot: append close.
    {
        const last_idx = manifest.literals.len - 1;
        const lit = manifest.literals[last_idx];
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, lit);
        try buf.appendSlice(allocator, close);
        const owned = try buf.toOwnedSlice(allocator);
        allocator.free(lit);
        const mut_lits: [*][]const u8 = @constCast(@ptrCast(manifest.literals.ptr));
        mut_lits[last_idx] = owned;
    }
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Find `c` in `s` at depth 0 (skipping strings, parens, brackets, braces).
/// If `allow_qq` is true, `?` following `.` (Zig optional unwrap) is skipped.
fn findTopLevel(s: []const u8, c: u8, allow_qq: bool) ?usize {
    var i: usize = 0;
    var paren: usize = 0;
    var brace: usize = 0;
    var brack: usize = 0;
    var in_string = false;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (in_string) {
            if (ch == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '(' => paren += 1,
            ')' => if (paren > 0) {
                paren -= 1;
            },
            '{' => brace += 1,
            '}' => if (brace > 0) {
                brace -= 1;
            },
            '[' => brack += 1,
            ']' => if (brack > 0) {
                brack -= 1;
            },
            else => {},
        }
        if (ch == c and paren == 0 and brace == 0 and brack == 0) {
            if (allow_qq and c == '?' and i > 0 and s[i - 1] == '.') continue;
            return i;
        }
    }
    return null;
}

/// Normalise whitespace in a baked literal to match the existing transpiler's
/// emitText/parseFunctionBody behaviour:
///   - Leading whitespace before the first `<` (body-level WS) is dropped.
///   - Trailing whitespace after the last `>` (body-level WS) is dropped.
///   - Pure-whitespace segments between `>` and `<` collapse to `\n` if they
///     contain a newline, or are dropped entirely if no newline is present.
///   - Non-whitespace text segments (visible content inside an element) are
///     preserved verbatim, including their internal indentation.
/// Walk a baked literal and emit it with whitespace normalised to match the
/// existing transpiler's `emitText`/`parseFunctionBody` rules.
///
/// At a WS boundary, the rule depends on the *current* HTML tag depth and the
/// outer context:
///   * tag_depth > 0 OR ctx_children: children rules — WS+newline → `\n`,
///     drop WS-no-newline.
///   * tag_depth == 0 AND !ctx_children: body rules — drop all WS.
///
/// `start_tag_depth` is the tag depth as we enter this literal. As we walk
/// `<...>` boundaries, we update an internal cursor so subsequent decisions
/// reflect what tags we've crossed.
fn normalizeLiteralCtx(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
    start_tag_depth: i32,
    ctx_children: bool,
) EmitError!void {
    var tag_depth = start_tag_depth;

    const emitSeg = struct {
        fn call(
            a: Allocator,
            o: *std.ArrayListUnmanaged(u8),
            seg: []const u8,
            td: i32,
            cc: bool,
        ) EmitError!void {
            var only_ws = true;
            var has_nl = false;
            for (seg) |c| {
                if (c == '\n') has_nl = true;
                if (!isWs(c)) {
                    only_ws = false;
                    break;
                }
            }
            if (!only_ws) {
                try o.appendSlice(a, seg);
            } else if ((td > 0 or cc) and has_nl) {
                try o.append(a, '\n');
            }
        }
    }.call;

    var i: usize = 0;
    var seg_start: usize = 0;

    // The literal may start *inside* a tag body — a previous literal opened
    // an attr string `name="` that this one closes (`">...`). Handle that
    // before entering the main walker.
    if (text.len > 0 and text[0] == '"') {
        i += 1; // past the closing "
        while (i < text.len and text[i] != '>') {
            if (text[i] == '"') {
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {}
                if (i < text.len) i += 1;
                continue;
            }
            i += 1;
        }
        if (i < text.len and text[i] == '>') {
            i += 1;
        }
        try out.appendSlice(allocator, text[seg_start..i]);
        // After closing the tag, tag_depth changes — find the tag name to
        // determine if it was a close-tag (depth-1) or open (depth+1).
        // The carried-over tag was an open (since dynamic attrs only appear
        // in opening tags). Increment unless it's self-closing or a void.
        // The simplest correct approach: re-scan the slice we just emitted.
        const slice = text[seg_start..i];
        tag_depth += tagDeltaForSlice(slice);
        seg_start = i;
    }

    while (i < text.len) {
        const c = text[i];
        if (c == 0x01) {
            // Self-closing-non-void sentinel; skip without emitting and
            // without changing depth (the parser already incremented +1 via
            // the open tag we just emitted; the sentinel cancels that).
            tag_depth -= 1;
            i += 1;
            seg_start = i;
            continue;
        }
        if (c == '<') {
            // Emit pre-tag segment.
            try emitSeg(allocator, out, text[seg_start..i], tag_depth, ctx_children);
            // Walk the tag body verbatim.
            const tag_start = i;
            var j = i + 1;
            while (j < text.len) {
                const cc = text[j];
                if (cc == '"') {
                    j += 1;
                    while (j < text.len and text[j] != '"') : (j += 1) {}
                    if (j < text.len) j += 1;
                    continue;
                }
                if (cc == '>') {
                    j += 1;
                    break;
                }
                j += 1;
            }
            try out.appendSlice(allocator, text[tag_start..j]);
            tag_depth += tagDeltaForSlice(text[tag_start..j]);
            i = j;
            seg_start = i;
            continue;
        }
        i += 1;
    }

    // Trailing segment.
    try emitSeg(allocator, out, text[seg_start..], tag_depth, ctx_children);
}

/// Tag delta for a single `<...>` slice. Returns +1 for an open tag, -1 for
/// a close tag, 0 for self-closing or DOCTYPE/comment/void elements.
fn tagDeltaForSlice(slice: []const u8) i32 {
    if (slice.len < 2 or slice[0] != '<') return 0;
    if (slice[1] == '!' or slice[1] == '?') return 0;
    if (slice[1] == '/') return -1;
    // Open or self-closing: check for `/>` at end (before the `>`).
    if (slice.len >= 3 and slice[slice.len - 2] == '/') return 0;
    // Open: check if void element.
    var i: usize = 1;
    while (i < slice.len and (isAsciiAlphaNum(slice[i]) or slice[i] == '-' or slice[i] == '_')) : (i += 1) {}
    const name = slice[1..i];
    if (isVoid(name)) return 0;
    return 1;
}

// Kept for backward compatibility (used by the previous emitLiteralText
// implementation in callers we may not have updated). New code should use
// `normalizeLiteralCtx`.
fn normalizeLiteral(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
    inside_tag: bool,
    end_inside_tag: bool,
) EmitError!void {
    // Split the literal into segments. A segment boundary occurs at every
    // `>` (end-of-tag) and every `<` (start-of-tag). Tag bodies are emitted
    // verbatim. Between-tag and at-boundary WS segments are classified:
    //   * preserve as-is if any non-WS char is present
    //   * collapse to `\n` if WS-only with a newline AND in children context
    //   * drop entirely otherwise
    //
    // Children-context flags:
    //   - `inside_tag`: governs the leading segment (before the first `<` or
    //     between segments at the start of the literal up to the first `>`).
    //   - `end_inside_tag`: governs the trailing segment (after the last `>`,
    //     i.e. anything that comes after this literal's final tag close).
    //   - WS between a `>` and a `<` within the literal is always
    //     children-like (the `>` we just saw was a real tag close).

    const Classifier = struct {
        fn emit(a: Allocator, o: *std.ArrayListUnmanaged(u8), seg: []const u8, ws_is_children: bool) EmitError!void {
            var only_ws = true;
            var has_nl = false;
            for (seg) |c| {
                if (c == '\n') has_nl = true;
                if (!isWs(c)) {
                    only_ws = false;
                    break;
                }
            }
            if (!only_ws) {
                try o.appendSlice(a, seg);
            } else if (ws_is_children and has_nl) {
                try o.append(a, '\n');
            }
        }
    };

    // State machine. The literal can start either:
    //   * outside any tag (between sibling elements / at body level)
    //   * inside a tag body that began in the previous literal (because a
    //     dynamic attr `value={expr}` splits the tag literal mid-tag — the
    //     fragment after `expr` begins with `">...rest of tag.>`).
    //
    // We can't tell from the literal alone which it is. Heuristic: if the
    // literal starts with `"` (closing the carried-over attr string), we're
    // inside a tag and need to walk to the next `>` verbatim before WS
    // normalisation resumes. Otherwise, we start out-of-tag.
    var i: usize = 0;
    var seg_start: usize = 0;
    var seen_tag_boundary = false;
    var in_tag = false;

    if (text.len > 0 and text[0] == '"') {
        // The leading `"` is the *closing* quote of the previous literal's
        // open `"`. After it, we're still inside the tag — walk verbatim to
        // the next `>` that closes the tag.
        in_tag = true;
        i += 1; // past the closing "
        while (i < text.len and text[i] != '>') {
            if (text[i] == '"') {
                // Start of a new attr value string — skip its body.
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {}
                if (i < text.len) i += 1;
                continue;
            }
            i += 1;
        }
        if (i < text.len and text[i] == '>') {
            i += 1;
        }
        try out.appendSlice(allocator, text[seg_start..i]);
        in_tag = false;
        seen_tag_boundary = true;
        seg_start = i;
    }

    while (i < text.len) {
        const c = text[i];
        if (c == '<') {
            // Emit pending segment up to this `<` with the current ws ctx.
            const seg = text[seg_start..i];
            const ws_is_children = if (seen_tag_boundary) true else inside_tag;
            try Classifier.emit(allocator, out, seg, ws_is_children);
            // Walk the tag body verbatim.
            const tag_start = i;
            var j = i + 1;
            while (j < text.len) {
                const cc = text[j];
                if (cc == '"') {
                    j += 1;
                    while (j < text.len and text[j] != '"') : (j += 1) {}
                    if (j < text.len) j += 1;
                    continue;
                }
                if (cc == '>') {
                    j += 1;
                    break;
                }
                j += 1;
            }
            try out.appendSlice(allocator, text[tag_start..j]);
            seen_tag_boundary = true;
            i = j;
            seg_start = i;
            continue;
        }
        i += 1;
    }

    // Trailing segment.
    const tail = text[seg_start..];
    const ws_is_children = if (seen_tag_boundary) end_inside_tag else inside_tag;
    try Classifier.emit(allocator, out, tail, ws_is_children);
}

fn countTagDelta(text: []const u8) i32 {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x01) {
            // Self-closing-non-void sentinel: cancels the +1 from the open
            // tag immediately preceding it.
            depth -= 1;
            i += 1;
            continue;
        }
        if (text[i] != '<') {
            i += 1;
            continue;
        }
        // Find the matching `>`. Skip inside attribute strings.
        var j = i + 1;
        var is_close = false;
        var is_self_close = false;
        if (j < text.len and text[j] == '/') {
            is_close = true;
            j += 1;
        }
        // Skip the rest of the tag, tracking strings.
        while (j < text.len) {
            const c = text[j];
            if (c == '"') {
                j += 1;
                while (j < text.len and text[j] != '"') : (j += 1) {}
                if (j < text.len) j += 1;
                continue;
            }
            if (c == '>') break;
            if (c == '/' and j + 1 < text.len and text[j + 1] == '>') {
                is_self_close = true;
                break;
            }
            j += 1;
        }
        if (j >= text.len) break;
        // Identify tag name to skip DOCTYPE & comments & void elements.
        const name_start = i + 1 + (if (is_close) @as(usize, 1) else 0);
        var name_end = name_start;
        while (name_end < text.len and (isAsciiAlphaNum(text[name_end]) or text[name_end] == '-' or text[name_end] == '_')) : (name_end += 1) {}
        const name = text[name_start..name_end];
        // Skip <!...> and <?...> entirely.
        if (i + 1 < text.len and (text[i + 1] == '!' or text[i + 1] == '?')) {
            i = j + 1;
            continue;
        }
        if (!is_close and !is_self_close and !isVoid(name)) {
            depth += 1;
        } else if (is_close) {
            depth -= 1;
        }
        i = j + 1;
    }
    return depth;
}

/// Inspect a literal that's just been emitted. If its trailing portion is
/// `<tagname ...="` (an open tag whose dynamic attribute value spills into
/// the next literal), capture the tag name and self-closing flag on the
/// emitter so the next literal can apply the depth delta correctly.
fn recordPendingOpen(self: *Emitter, text: []const u8) void {
    // Find the last `<` in `text` whose `>` does NOT appear before the end.
    // Walk backwards to the last `<`.
    if (text.len == 0) return;
    var last_lt: ?usize = null;
    var i: usize = text.len;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '<') {
            last_lt = i - 1;
            break;
        }
    }
    const lt = last_lt orelse return;
    // Check there's no `>` between `lt` and end (considering quoted
    // attributes — but if we ended at `="` mid-attr the `"` was unmatched).
    var j = lt + 1;
    var saw_gt = false;
    while (j < text.len) {
        if (text[j] == '"') {
            j += 1;
            // Scan to matching closing `"` if present.
            var matched = false;
            while (j < text.len) : (j += 1) {
                if (text[j] == '"') {
                    matched = true;
                    j += 1;
                    break;
                }
            }
            if (!matched) break; // unmatched `"` — we ended mid-attr.
            continue;
        }
        if (text[j] == '>') {
            saw_gt = true;
            break;
        }
        j += 1;
    }
    if (saw_gt) return;

    // We're carrying the open tag forward. Extract the tag name.
    var ni = lt + 1;
    if (ni < text.len and text[ni] == '/') return; // close tag — shouldn't be unclosed.
    const name_start = ni;
    while (ni < text.len and (isAsciiAlphaNum(text[ni]) or text[ni] == '-' or text[ni] == '_')) : (ni += 1) {}
    const name = text[name_start..ni];
    if (name.len == 0 or name.len >= self.pending_open_name.len) return;
    @memcpy(self.pending_open_name[0..name.len], name);
    self.pending_open_len = name.len;
    self.pending_open_self_closing = false; // we never see `/>` mid-attr.
}

/// Does the literal end with `="` (an opening attribute-value quote, no
/// closing quote)? Used by emit to flip the next expression into
/// attribute-value emission mode (e.g. backtick → zsx.escape, not zsx.render).
fn endsInAttrValue(text: []const u8) bool {
    if (text.len < 2) return false;
    return text[text.len - 2] == '=' and text[text.len - 1] == '"';
}

fn isAsciiAlphaNum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

fn isVoid(name: []const u8) bool {
    const voids = [_][]const u8{
        "area", "base", "br",     "col",   "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    };
    for (voids) |v| {
        if (mem.eql(u8, v, name)) return true;
    }
    return false;
}

// coalesceWriteAlls — merge adjacent `try W.writeAll("...");` calls

/// Parsed shape of a single `try <writer>.writeAll("<literal>");` line.
const WriteAllLine = struct {
    indent: []const u8,
    writer: []const u8,
    literal: []const u8,
};

/// Try to recognize the line as `try <writer>.writeAll("<literal>");`.
/// Returns null for any other shape (control flow, prints, raw children flushes).
/// The literal slice still contains escape sequences as written (\\, \", \n, …) —
/// merging two literals byte-wise produces a valid Zig string literal.
fn parseWriteAllLine(line: []const u8) ?WriteAllLine {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const indent = line[0..i];

    const try_kw = "try ";
    if (i + try_kw.len > line.len) return null;
    if (!std.mem.eql(u8, line[i .. i + try_kw.len], try_kw)) return null;
    i += try_kw.len;

    // Find ".writeAll(\"" — the writer is everything between `try ` and that.
    const sentinel = ".writeAll(\"";
    const dot_idx = std.mem.indexOfPos(u8, line, i, sentinel) orelse return null;
    const writer = line[i..dot_idx];
    // The writer must be a plain identifier (no parens, no method calls) so we
    // can safely treat it as a value reused across coalesced calls. Anything
    // more complex (e.g. `_buf.writer(_alloc)`) means the line was emitted
    // before the writer-cache landed — bail out and pass through unchanged.
    for (writer) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return null,
    };
    if (writer.len == 0) return null;
    i = dot_idx + sentinel.len;

    // Find the closing `"` of the literal, respecting `\<x>` escapes so we
    // don't terminate inside a `\"` sequence.
    var j = i;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\') {
            j += 1;
            if (j >= line.len) return null;
            continue;
        }
        if (line[j] == '"') break;
    }
    if (j >= line.len) return null;
    const literal = line[i..j];

    // Suffix must be `");` exactly.
    const suffix = "\");";
    if (j + suffix.len > line.len) return null;
    if (!std.mem.eql(u8, line[j .. j + suffix.len], suffix)) return null;
    // Anything after `");` (besides whitespace) means a different statement.
    var k: usize = j + suffix.len;
    while (k < line.len) : (k += 1) {
        if (line[k] != ' ' and line[k] != '\t') return null;
    }

    return .{ .indent = indent, .writer = writer, .literal = literal };
}

/// Merge runs of `try <writer>.writeAll("a"); / try <writer>.writeAll("b");`
/// (same writer + same indent) into one call. Templates with lots of static
/// markup can produce hundreds of these, and Zig's semantic-analysis
/// backwards-branch quota (default 1000) is exhausted around ~600 such calls
/// inside a function body. Merging contiguous literal writes into a single
/// call keeps generated code inside the default ceiling regardless of
/// template size.
pub fn coalesceWriteAlls(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const line_end = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
        const line = input[i..line_end];

        if (parseWriteAllLine(line)) |first| {
            // Merge subsequent lines that match writer + indent.
            var combined: std.ArrayListUnmanaged(u8) = .{};
            defer combined.deinit(allocator);
            try combined.appendSlice(allocator, first.literal);

            var j = if (line_end < input.len) line_end + 1 else input.len;
            while (j < input.len) {
                const next_end = std.mem.indexOfScalarPos(u8, input, j, '\n') orelse input.len;
                const next_line = input[j..next_end];
                const next = parseWriteAllLine(next_line) orelse break;
                if (!std.mem.eql(u8, next.indent, first.indent)) break;
                if (!std.mem.eql(u8, next.writer, first.writer)) break;
                try combined.appendSlice(allocator, next.literal);
                j = if (next_end < input.len) next_end + 1 else input.len;
            }

            try out.appendSlice(allocator, first.indent);
            try out.appendSlice(allocator, "try ");
            try out.appendSlice(allocator, first.writer);
            try out.appendSlice(allocator, ".writeAll(\"");
            try out.appendSlice(allocator, combined.items);
            try out.appendSlice(allocator, "\");\n");
            i = j;
        } else {
            try out.appendSlice(allocator, line);
            if (line_end < input.len) {
                try out.append(allocator, '\n');
                i = line_end + 1;
            } else {
                i = line_end;
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

};

pub const transpile = struct {
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const emit_src = emit_mod;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse positional + optional `--hmr` / `--hmr-capture-props` / `--lift-attrs`
    // flags. `--hmr-capture-props` and `--lift-attrs` both imply `--hmr`. The
    // data-component splice is always-on with `--hmr` (the flags travel together
    // at the CLI; the EmitOptions struct still exposes them independently for
    // callers).
    var hmr = false;
    var capture_props = false;
    var lift_attrs = false;
    var positionals: [2][]const u8 = .{ "", "" };
    var pos_count: usize = 0;
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const a = args[ai];
        if (mem.eql(u8, a, "--hmr")) {
            hmr = true;
            continue;
        }
        if (mem.eql(u8, a, "--hmr-capture-props")) {
            capture_props = true;
            hmr = true;
            continue;
        }
        if (mem.eql(u8, a, "--lift-attrs")) {
            // Implies --hmr (lifting only makes sense in hmr mode — the
            // A table parallels the L table and uses the same setX swap
            // mechanism). Build graph must expose an `hmr` module.
            lift_attrs = true;
            hmr = true;
            continue;
        }
        if (pos_count < 2) {
            positionals[pos_count] = a;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        std.debug.print("Usage: zsx_transpile [--hmr] [--hmr-capture-props] [--lift-attrs] <input_dir> <output_dir>\n", .{});
        std.process.exit(1);
    }

    const input_dir = positionals[0];
    const output_dir = positionals[1];

    try transpileDirectory(allocator, input_dir, output_dir, .{
        .hmr = hmr,
        .dom_attribute = hmr, // CLI policy: --hmr implies the splice.
        .capture_props = capture_props,
        .lift_attrs = lift_attrs,
    });
}

fn transpileDirectory(allocator: Allocator, input_dir: []const u8, output_dir: []const u8, opts: emit_src.EmitOptions) !void {
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

            // Also register every `pub fn PascalName(` export in the file —
            // e.g. card.zsx exports CardHeader, CardTitle, StatCard, …
            // Without this, consumers can't auto-import sibling exports.
            const abs_path = fs.path.join(allocator, &.{ input_dir, rel_path }) catch continue;
            defer allocator.free(abs_path);
            const src = fs.cwd().readFileAlloc(allocator, abs_path, 1024 * 1024) catch continue;
            defer allocator.free(src);

            var scan_pos: usize = 0;
            while (scan_pos < src.len) {
                const idx = mem.indexOfPos(u8, src, scan_pos, "pub fn ") orelse break;
                const after = idx + "pub fn ".len;
                if (after >= src.len or !std.ascii.isUpper(src[after])) {
                    scan_pos = after;
                    continue;
                }
                var end = after;
                while (end < src.len and (std.ascii.isAlphanumeric(src[end]) or src[end] == '_')) end += 1;
                const fn_name = src[after..end];
                if (fn_name.len > 0 and !component_registry.contains(fn_name)) {
                    const name_copy = try allocator.dupe(u8, fn_name);
                    try component_registry.put(allocator, name_copy, rel_path);
                }
                scan_pos = end;
            }
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
        try transpileFile(allocator, input_dir, output_dir, rel_path, &component_registry, &css_classes, &component_class_patterns, opts);
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
    opts: emit_src.EmitOptions,
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
        for (component_imports.items) |ci| {
            if (ci.import_path.len > 0) allocator.free(ci.import_path);
            if (ci.props_type_expr.len > 0) allocator.free(ci.props_type_expr);
        }
        component_imports.deinit(allocator);
    }
    try scanComponentUsage(allocator, source, rel_path, component_registry, &component_imports);

    // Decide which components are liftable and compute each one's Props
    // TYPE EXPRESSION (spliced into the lifted call site's `var __p: <expr>`).
    // A component is liftable iff its Props is a concrete struct, not
    // `anytype`. Three kinds:
    //   - same-file `fn Name`:  scan THIS source; expr = "NameProps"
    //     (a local const the emitter generates next to the fn).
    //   - explicit import:      scan the registry target if local, else
    //     assume liftable (external modules like publr_ui). expr is derived
    //     from the user's `const Name = EXPR.Name;` as `EXPR.NameProps`.
    //   - auto-discovered:      scan the registry target; expr =
    //     `@import("<import_path>").NameProps`.
    // Reflection on the component fn's signature can't help (every emitted
    // component is `fn Name(writer: anytype, _props: anytype)`), so we name
    // the concrete `<Name>Props` type the emitter always generates.
    if (opts.lift_attrs) {
        for (component_imports.items) |*ci| {
            if (sourceDeclaresFn(source, ci.name)) {
                // Same-file sibling `fn`. Liftable iff struct props (not anytype).
                if (sourceDeclaresPropsFor(source, ci.name)) {
                    ci.liftable = true;
                    ci.props_type_expr = try std.fmt.allocPrint(allocator, "{s}Props", .{ci.name});
                }
            } else if (component_registry.get(ci.name)) |target_rel| {
                // Local component (registered). Scan its .zsx.
                const target_path = try fs.path.join(allocator, &.{ input_dir, target_rel });
                defer allocator.free(target_path);
                const target_src = fs.cwd().readFileAlloc(allocator, target_path, 1024 * 1024) catch continue;
                defer allocator.free(target_src);
                if (sourceDeclaresPropsFor(target_src, ci.name)) {
                    ci.liftable = true;
                    if (ci.explicit) {
                        // `const Name = EXPR.Name;` -> EXPR.NameProps.
                        ci.props_type_expr = (try extractPropsTypeExpr(allocator, source, ci.name)) orelse {
                            ci.liftable = false;
                            continue;
                        };
                    } else {
                        ci.props_type_expr = try std.fmt.allocPrint(allocator, "@import(\"{s}\").{s}Props", .{ ci.import_path, ci.name });
                    }
                }
            } else if (ci.explicit) {
                // External explicit import (not in the local registry, e.g.
                // `const Button = ui.button.Button;`). Can't scan the foreign
                // module; assume its Props follows the `<Name>Props` convention
                // (publr_ui does). Derive `EXPR.NameProps` from the user's decl.
                if (try extractPropsTypeExpr(allocator, source, ci.name)) |expr| {
                    ci.liftable = true;
                    ci.props_type_expr = expr;
                }
            }
        }
    }

    // Collect CSS classes from the source (orthogonal to code generation).
    if (css_classes) |map| {
        try collectCssClassesFromSource(allocator, source, map, component_class_patterns);
    }

    // Emit Zig code via the new parse → emit pipeline.
    //
    // Override `opts.view_name` with `base` (the rel_path stripped of `.zsx`).
    // emitFile would otherwise derive view_name from `input_path`, which the
    // CMS build passes as an absolute path — producing capture-props keys
    // and data-component values that won't match the registry's
    // `<rel>:<Fn>` convention. Always passing the relative form ensures
    // the registry name, captureProps key, data-component attribute, and
    // slow-path broadcast name are all the same string.
    var emit_opts = opts;
    emit_opts.view_name = base;
    const zig_code = try emit_src.emitFile(allocator, source, input_path, component_imports.items, emit_opts);
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

// ComponentImport is owned by zsx_emit (it's the type emit's public API takes).
// Re-exported here so existing call sites (cms, downstream code) keep working
// via `zsx_transpile.ComponentImport`.
pub const ComponentImport = emit_src.ComponentImport;

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
    return try emit_src.emitFile(allocator, source, source_path, component_imports, .{});
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
    errdefer {
        var it = css_classes.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        css_classes.deinit(allocator);
    }

    try collectCssClassesFromSource(allocator, source, &css_classes, component_class_patterns);

    const zig_code = try emit_src.emitFile(allocator, source, source_path, component_imports, .{});
    return .{
        .zig_code = zig_code,
        .css_classes = css_classes,
    };
}

// CSS class collection (operates on raw .zsx source — orthogonal to emit).

/// Walk a .zsx source string and add every Tailwind-like class token to
/// `css_map`. Covers three sources:
///   1. `class="..."` literal attributes on HTML elements and components.
///   2. `class={`...${...}...`}` backtick templates — only literal portions.
///   3. `<Component prop=.enumValue />` — resolved through
///      `component_class_patterns` if provided.
/// Also harvests utility-shaped tokens out of every `"..."` Zig string literal
/// in the source (mirrors design-system/src/class_extract.zig).
fn collectCssClassesFromSource(
    allocator: Allocator,
    source: []const u8,
    css_map: *std.StringHashMapUnmanaged(void),
    component_class_patterns: ?*const std.StringHashMapUnmanaged([]const ClassPattern),
) !void {
    try collectClassAttributes(allocator, source, css_map);
    try collectComponentEnumPropClasses(allocator, source, css_map, component_class_patterns);
    try harvestZigStringClasses(allocator, source, css_map);
}

/// Tokenize a whitespace-separated class string and add each token to css_map.
fn addClassTokens(allocator: Allocator, css_map: *std.StringHashMapUnmanaged(void), classes: []const u8) !void {
    var it = mem.tokenizeAny(u8, classes, " \t\n\r");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (css_map.contains(token)) continue;
        const duped = allocator.dupe(u8, token) catch continue;
        css_map.put(allocator, duped, {}) catch {
            allocator.free(duped);
        };
    }
}

/// Walk the source looking for `class="..."` and `class={`...`}` attribute
/// shapes — works for both HTML elements and component calls (component
/// attrs go through the same JSX-like syntax).
fn collectClassAttributes(allocator: Allocator, source: []const u8, css_map: *std.StringHashMapUnmanaged(void)) !void {
    var i: usize = 0;
    while (i < source.len) {
        // Match the literal token `class` only when it sits in attribute
        // position: preceded by whitespace and followed by `=`.
        if (source[i] != 'c') {
            i += 1;
            continue;
        }
        if (i + 5 > source.len) break;
        if (!mem.eql(u8, source[i .. i + 5], "class")) {
            i += 1;
            continue;
        }
        // Must be preceded by whitespace (or start of file — not realistic in .zsx, but be safe).
        if (i == 0 or !(source[i - 1] == ' ' or source[i - 1] == '\t' or source[i - 1] == '\n' or source[i - 1] == '\r')) {
            i += 1;
            continue;
        }
        // Must be followed by `=`.
        const after = i + 5;
        if (after >= source.len or source[after] != '=') {
            i += 1;
            continue;
        }
        const val_start = after + 1;
        if (val_start >= source.len) break;

        if (source[val_start] == '"') {
            // class="literal classes"
            var end = val_start + 1;
            while (end < source.len and source[end] != '"') : (end += 1) {
                if (source[end] == '\\' and end + 1 < source.len) end += 1;
            }
            if (end >= source.len) break;
            try addClassTokens(allocator, css_map, source[val_start + 1 .. end]);
            i = end + 1;
            continue;
        }

        if (source[val_start] == '{') {
            // class={...} — only harvest literal segments of backtick templates.
            const inner_start = val_start + 1;
            // Find matching `}` honoring brace depth and backtick strings.
            var depth: usize = 1;
            var p: usize = inner_start;
            while (p < source.len and depth > 0) : (p += 1) {
                const c = source[p];
                if (c == '{') depth += 1
                else if (c == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (p > source.len) break;
            const inner = source[inner_start..p];
            // If inner is a backtick template, harvest literal parts.
            const trimmed = mem.trim(u8, inner, " \t\n\r");
            if (trimmed.len >= 2 and trimmed[0] == '`' and trimmed[trimmed.len - 1] == '`') {
                try collectBacktickLiteralClasses(allocator, css_map, trimmed[1 .. trimmed.len - 1]);
            }
            i = if (p < source.len) p + 1 else source.len;
            continue;
        }

        i += 1;
    }
}

/// Within a backtick-template body (with the outer backticks stripped), add
/// every whitespace-separated token from the LITERAL portions (i.e. outside
/// every `${...}` interpolation) to css_map.
fn collectBacktickLiteralClasses(
    allocator: Allocator,
    css_map: *std.StringHashMapUnmanaged(void),
    inner: []const u8,
) !void {
    var i: usize = 0;
    var literal_start: usize = 0;
    while (i < inner.len) {
        if (i + 1 < inner.len and inner[i] == '$' and inner[i + 1] == '{') {
            if (i > literal_start) {
                try addClassTokens(allocator, css_map, inner[literal_start..i]);
            }
            i += 2;
            var depth: usize = 1;
            while (i < inner.len and depth > 0) : (i += 1) {
                if (inner[i] == '{') depth += 1;
                if (inner[i] == '}') depth -= 1;
            }
            literal_start = i;
            continue;
        }
        i += 1;
    }
    if (literal_start < inner.len) {
        try addClassTokens(allocator, css_map, inner[literal_start..]);
    }
}

/// Walk the source for `<ComponentName ... prop=.enumValue ... />` shapes and
/// resolve each enum value through component_class_patterns into class tokens.
fn collectComponentEnumPropClasses(
    allocator: Allocator,
    source: []const u8,
    css_map: *std.StringHashMapUnmanaged(void),
    component_class_patterns: ?*const std.StringHashMapUnmanaged([]const ClassPattern),
) !void {
    const patterns_map = component_class_patterns orelse return;

    var i: usize = 0;
    while (i < source.len) {
        if (source[i] != '<') {
            i += 1;
            continue;
        }
        // Must look like a PascalCase tag open.
        if (i + 1 >= source.len) break;
        const c1 = source[i + 1];
        if (!std.ascii.isUpper(c1)) {
            i += 1;
            continue;
        }
        // Tag name.
        var name_end = i + 1;
        while (name_end < source.len and (std.ascii.isAlphanumeric(source[name_end]) or source[name_end] == '_')) : (name_end += 1) {}
        const tag_name = source[i + 1 .. name_end];
        const patterns = patterns_map.get(tag_name) orelse {
            i = name_end;
            continue;
        };

        // Find the end of the open tag (`>` or `/>`).
        var tag_end = name_end;
        while (tag_end < source.len and source[tag_end] != '>') : (tag_end += 1) {
            if (source[tag_end] == '"') {
                tag_end += 1;
                while (tag_end < source.len and source[tag_end] != '"') : (tag_end += 1) {
                    if (source[tag_end] == '\\' and tag_end + 1 < source.len) tag_end += 1;
                }
                if (tag_end >= source.len) break;
            } else if (source[tag_end] == '{') {
                // Skip JSX expression with brace nesting.
                tag_end += 1;
                var depth: usize = 1;
                while (tag_end < source.len and depth > 0) : (tag_end += 1) {
                    if (source[tag_end] == '{') depth += 1;
                    if (source[tag_end] == '}') depth -= 1;
                }
                if (tag_end >= source.len) break;
                tag_end -= 1; // step back so loop's `+= 1` doesn't skip past `>`
            }
        }
        if (tag_end >= source.len) break;
        const attrs_slice = source[name_end..tag_end];

        // For each pattern, scan attrs_slice for `<prop_name>=.<enum_value>`.
        for (patterns) |pattern| {
            const enum_value = findEnumPropValue(attrs_slice, pattern.prop_name) orelse continue;
            switch (pattern.kind) {
                .prefix => {
                    const class = std.fmt.allocPrint(allocator, "{s}{s}", .{ pattern.prefix, enum_value }) catch continue;
                    if (!css_map.contains(class)) {
                        css_map.put(allocator, class, {}) catch {
                            allocator.free(class);
                        };
                    } else {
                        allocator.free(class);
                    }
                },
                .field_map => {
                    const value_map = pattern.value_map orelse continue;
                    for (value_map) |mapping| {
                        if (mem.eql(u8, mapping.enum_value, enum_value)) {
                            try addClassTokens(allocator, css_map, mapping.classes);
                            break;
                        }
                    }
                },
            }
        }

        i = tag_end + 1;
    }
}

/// Find `prop_name=.value` in an attrs slice and return the value identifier.
fn findEnumPropValue(attrs: []const u8, prop_name: []const u8) ?[]const u8 {
    var p: usize = 0;
    while (p < attrs.len) {
        // Look for token `prop_name` at attribute boundary (whitespace before, `=` after).
        if (p + prop_name.len + 2 > attrs.len) return null;
        if (!mem.eql(u8, attrs[p .. p + prop_name.len], prop_name)) {
            p += 1;
            continue;
        }
        // Boundary checks.
        if (p > 0 and !(attrs[p - 1] == ' ' or attrs[p - 1] == '\t' or attrs[p - 1] == '\n' or attrs[p - 1] == '\r')) {
            p += 1;
            continue;
        }
        const after = p + prop_name.len;
        if (after >= attrs.len or attrs[after] != '=') {
            p += 1;
            continue;
        }
        const val_start = after + 1;
        if (val_start >= attrs.len or attrs[val_start] != '.') return null;
        // Read identifier.
        var v_end = val_start + 1;
        while (v_end < attrs.len and (std.ascii.isAlphanumeric(attrs[v_end]) or attrs[v_end] == '_')) : (v_end += 1) {}
        if (v_end == val_start + 1) return null;
        return attrs[val_start + 1 .. v_end];
    }
    return null;
}

/// Walk the entire source and tokenize every `"..."` Zig string literal,
/// adding utility-shaped tokens to css_map. Skips `//` and `/* */` comments
/// so prose in doc comments doesn't pollute the manifest. Filter mirrors
/// design-system/src/class_extract.zig:looksLikeUtility.
fn harvestZigStringClasses(
    allocator: Allocator,
    source: []const u8,
    css_map: *std.StringHashMapUnmanaged(void),
) !void {
    var i: usize = 0;
    while (i < source.len) {
        // Line comment
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        // Block comment
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            if (i + 1 < source.len) i += 2 else i = source.len;
            continue;
        }
        if (source[i] != '"') {
            i += 1;
            continue;
        }
        // Scan to matching `"` honoring `\` escapes.
        const start = i + 1;
        i += 1;
        while (i < source.len and source[i] != '"') {
            if (source[i] == '\\' and i + 1 < source.len) i += 2 else i += 1;
        }
        if (i >= source.len) break;
        const value = source[start..i];
        i += 1;
        var it = mem.tokenizeAny(u8, value, " \t\n\r");
        while (it.next()) |raw| {
            const token = mem.trim(u8, raw, "\"'`{}?;,");
            if (token.len < 2 or token.len > 256) continue;
            if (!looksLikeUtilityClass(token)) continue;
            if (css_map.contains(token)) continue;
            const duped = allocator.dupe(u8, token) catch continue;
            css_map.put(allocator, duped, {}) catch {
                allocator.free(duped);
            };
        }
    }
}

/// Heuristic: token starts with lowercase letter or `-`, contains only the
/// Tailwind char set, and includes at least one `-` or `:`. Used to filter
/// prose strings out of the JIT manifest. Mirrors
/// design-system/src/class_extract.zig:looksLikeUtility.
fn looksLikeUtilityClass(t: []const u8) bool {
    if (t.len < 2) return false;
    const c0 = t[0];
    if (!(c0 == '-' or (c0 >= 'a' and c0 <= 'z'))) return false;
    var has_separator = false;
    for (t) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '/', '.', '[', ']', '%', '#', '(', ')', ',', '@', '*', '&', '\'' => {},
            '-', ':' => has_separator = true,
            else => return false,
        }
    }
    return has_separator;
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
        // Skip Zig line comments so `<Foo />` examples inside `///` docs
        // don't get auto-discovered as imports — vendored DS components
        // include lots of `///   <SelfName ...>` usage examples that would
        // otherwise emit a self-import for every component.
        if (source[pos] == '/' and pos + 1 < source.len and source[pos + 1] == '/') {
            while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
            continue;
        }
        // Look for < followed by uppercase letter (PascalCase component tag)
        if (source[pos] == '<' and pos + 1 < source.len and std.ascii.isUpper(source[pos + 1])) {
            pos += 1;
            const name_start = pos;
            while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_')) {
                pos += 1;
            }
            const tag_name = source[name_start..pos];

            if (tag_name.len > 0 and !seen.contains(tag_name)) {
                if (hasExplicitImport(source, tag_name)) {
                    // User declared `const Name = …;` themselves. Already in
                    // scope, so explicit=true (no const re-emit). The lift
                    // post-pass derives the Props type expr from the decl.
                    try seen.put(allocator, tag_name, {});
                    try imports.append(allocator, .{
                        .name = tag_name,
                        .import_path = "",
                        .explicit = true,
                    });
                } else if (sourceDeclaresFn(source, tag_name)) {
                    // Sibling `fn Name` defined in THIS file. In scope already
                    // (explicit=true → no import emitted); the lift post-pass
                    // uses the generated local `NameProps` const.
                    try seen.put(allocator, tag_name, {});
                    try imports.append(allocator, .{
                        .name = tag_name,
                        .import_path = "",
                        .explicit = true,
                    });
                } else if (component_registry.get(tag_name)) |component_rel_path| {
                    if (mem.eql(u8, component_rel_path, current_rel_path)) {
                        // Resolves to this same file but isn't a plain `fn`
                        // here (e.g. odd registry alias). Treat as in-scope.
                        try seen.put(allocator, tag_name, {});
                        try imports.append(allocator, .{
                            .name = tag_name,
                            .import_path = "",
                            .explicit = true,
                        });
                    } else {
                        // Auto-discovered: emit `const Name = @import(path).Name`.
                        const import_path = try buildRelativeImportPath(allocator, current_rel_path, component_rel_path);
                        try imports.append(allocator, .{
                            .name = tag_name,
                            .import_path = import_path,
                            .explicit = false,
                        });
                        try seen.put(allocator, tag_name, {});
                    }
                }
            }
        } else {
            pos += 1;
        }
    }
}

/// True iff the source declares `<Name>(props: struct {…})` as a `fn` or
/// `pub fn` — i.e. a concrete inline struct param the emitter mirrors as
/// a `<Name>Props` const. Returns false when the function isn't found or
/// its params are `anytype` (no concrete struct to instantiate). This is
/// the lift gate: a component with a concrete Props struct can be lifted
/// (its `<Name>Props` type instantiated + applyAttrs'd); an `anytype`
/// component falls back to the baked inline call and rebuilds on edit.
fn sourceDeclaresPropsFor(source: []const u8, name: []const u8) bool {
    return findPropsStructBody(source, name) != null;
}

/// True iff the source declares a `fn <Name>(` or `pub fn <Name>(` — used
/// to detect a component defined as a sibling function in the current file
/// (regardless of whether its props are a struct or anytype).
fn sourceDeclaresFn(source: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (pos < source.len) {
        const idx = mem.indexOfPos(u8, source, pos, "fn ") orelse return false;
        const after = idx + "fn ".len;
        if (after + name.len > source.len) return false;
        if (mem.eql(u8, source[after .. after + name.len], name)) {
            var p = after + name.len;
            while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
            if (p < source.len and source[p] == '(') return true;
        }
        pos = after;
    }
    return false;
}

/// Return the byte offset just inside the `struct {` body of
/// `[pub] fn <name>(props: struct { … })`, or null when the function
/// isn't found or its params are `anytype` / not an inline struct.
/// Matches both `fn ` and `pub fn ` (same-file siblings are often non-pub).
fn findPropsStructBody(source: []const u8, name: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < source.len) {
        const idx = mem.indexOfPos(u8, source, pos, "fn ") orelse return null;
        const after = idx + "fn ".len;
        if (after + name.len + 1 > source.len) return null;
        if (!mem.eql(u8, source[after .. after + name.len], name)) {
            pos = after;
            continue;
        }
        var p = after + name.len;
        while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
        if (p >= source.len or source[p] != '(') {
            pos = after;
            continue;
        }
        var i: usize = p + 1;
        while (i < source.len) : (i += 1) {
            if (i + 7 <= source.len and mem.eql(u8, source[i .. i + 7], "anytype")) return null;
            if (i + 8 <= source.len and mem.eql(u8, source[i .. i + 8], "struct {")) return i + 8;
            if (i + 7 <= source.len and mem.eql(u8, source[i .. i + 7], "struct{")) return i + 7;
            if (source[i] == ')') return null;
        }
        return null;
    }
    return null;
}

/// Derive the Props TYPE EXPRESSION from a `const Name = EXPR.Name;`
/// declaration: the RHS with `Props` appended, since the RHS ends with the
/// component name. Examples:
///   `const Button = ui.button.Button;`               -> `ui.button.ButtonProps`
///   `const PageHeader = @import("x.zig").PageHeader;` -> `@import("x.zig").PageHeaderProps`
/// Returns null when the decl isn't found or its RHS doesn't end with
/// `.Name` (so we don't fabricate a bogus type) — caller skips lift.
fn extractPropsTypeExpr(allocator: Allocator, source: []const u8, name: []const u8) !?[]u8 {
    var search_pos: usize = 0;
    while (search_pos < source.len) {
        const idx = mem.indexOfPos(u8, source, search_pos, name) orelse return null;
        if (idx < 6) {
            search_pos = idx + name.len;
            continue;
        }
        // Preceded by `const ` (whitespace-tolerant)?
        var back = idx - 1;
        while (back > 0 and (source[back] == ' ' or source[back] == '\t')) back -= 1;
        if (back < 4 or !mem.eql(u8, source[back - 4 .. back + 1], "const")) {
            search_pos = idx + name.len;
            continue;
        }
        // `Name = ` then capture the RHS up to `;`.
        var p = idx + name.len;
        while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
        if (p >= source.len or source[p] != '=') {
            search_pos = idx + name.len;
            continue;
        }
        p += 1;
        while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
        const rhs_start = p;
        const semi = mem.indexOfScalarPos(u8, source, p, ';') orelse return null;
        const rhs = mem.trim(u8, source[rhs_start..semi], " \t\n\r");
        // RHS must end with `.Name` so appending `Props` yields `.NameProps`.
        if (rhs.len <= name.len + 1) return null;
        const tail_start = rhs.len - name.len;
        if (rhs[tail_start - 1] != '.' or !mem.eql(u8, rhs[tail_start..], name)) return null;
        return try std.fmt.allocPrint(allocator, "{s}Props", .{rhs});
    }
    return null;
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

};

// =====================================================================
// Top-level public API — flat function entry points + namespace re-exports.
// Downstream code:
//   const m = try zsx.parse(allocator, src);          // function entry
//   if (zsx.manifestEqual(a, b)) { ... }              // comparator
//   const ManifestT = zsx.manifest_mod.Manifest;      // namespaced type
//   const Node = zsx.manifest_mod.Node;
//   const ParseError = zsx.parse_mod.ParseError;
//   const EmitOptions = zsx.emit_mod.EmitOptions;
// Type aliases are namespaced (not flat) because Zig's scope rules treat a
// same-named file-level alias as an ambiguous reference inside the namespace
// body. The `_mod` paths cost two extra characters; the demos and the CMS
// HMR endpoint use them directly.
// =====================================================================

pub const parse = parse_mod.parse;
pub const parseAll = parse_mod.parseAll;
pub const emit = emit_mod.emit;
pub const emitFile = emit_mod.emitFile;
pub const manifestEqual = manifest_mod.manifestEqual;
