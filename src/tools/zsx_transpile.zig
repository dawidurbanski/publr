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

    var dir = try fs.cwd().openDir(input_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.path, ".zsx")) {
            try transpileFile(allocator, input_dir, output_dir, entry.path);
        } else if (entry.kind == .directory) {
            const sub_output = try fs.path.join(allocator, &.{ output_dir, entry.path });
            defer allocator.free(sub_output);
            fs.cwd().makePath(sub_output) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }
}

fn transpileFile(allocator: Allocator, input_dir: []const u8, output_dir: []const u8, rel_path: []const u8) !void {
    const input_path = try fs.path.join(allocator, &.{ input_dir, rel_path });
    defer allocator.free(input_path);

    // Generate output path: foo/bar.zsx -> foo/bar.zig
    const base = rel_path[0 .. rel_path.len - 4]; // strip .zsx
    const zig_name = try makeZigName(allocator, base);
    defer allocator.free(zig_name);

    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ output_dir, zig_name });
    defer allocator.free(output_path);

    // Skip if output is newer than input
    const input_stat = try fs.cwd().statFile(input_path);
    if (fs.cwd().statFile(output_path)) |output_stat| {
        if (output_stat.mtime >= input_stat.mtime) return;
    } else |_| {}

    const source = try fs.cwd().readFileAlloc(allocator, input_path, 1024 * 1024);
    defer allocator.free(source);

    // Parse and generate
    var parser = Parser.init(allocator, source, input_path);
    defer parser.deinit();
    const zig_code = try parser.generate();
    defer allocator.free(zig_code);

    // Write output
    const out_dir = fs.path.dirname(output_path) orelse ".";
    fs.cwd().makePath(out_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var file = try fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(zig_code);

    std.debug.print("Transpiled: {s} -> {s}\n", .{ input_path, output_path });
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
        try self.write("const zsx = @import(\"zsx_runtime\");\n\n");
        try self.write("pub const source_path = \"");
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
        // Copy const declaration verbatim until semicolon
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != ';') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1; // skip ;

        try self.write(self.source[start..self.pos]);
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
                    if (next == '!' or next == 'i' or next == 'f' or std.ascii.isAlphabetic(next) or next == '@') {
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
                        if (next == '!' or next == 'i' or next == 'f' or std.ascii.isAlphabetic(next) or next == '@') {
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
            try self.emitComponentCall(tag_name, attrs.items, self_closing);
        } else {
            try self.emitHtmlTag(tag_name, attrs.items);
        }

        // Parse children
        if (!self_closing and !is_void) {
            try self.parseChildren(tag_name);
        }
    }

    fn parseDoctype(self: *Parser) Error!void {
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '>') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1; // skip >

        try self.writeIndent();
        try self.write("try writer.writeAll(\"");
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
        try self.write("try writer.writeAll(\"");
        try self.writeEscaped(self.source[start..self.pos]);
        try self.write("\");\n");
    }

    fn parseChildren(self: *Parser, parent_tag: []const u8) Error!void {
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

                // Emit closing tag
                try self.writeIndent();
                try self.write("try writer.writeAll(\"</");
                try self.write(parent_tag);
                try self.write(">\");\n");
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

        // Check for raw expression {!...}
        const is_raw = self.pos < self.source.len and self.source[self.pos] == '!';
        if (is_raw) self.pos += 1;

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

        try self.writeIndent();
        if (is_raw) {
            try self.write("try writer.writeAll(");
            try self.write(expr);
            try self.write(");\n");
        } else {
            try self.write("try zsx.render(writer, ");
            try self.write(expr);
            try self.write(");\n");
        }
    }

    fn parseIf(self: *Parser) Error!void {
        // Already consumed {, positioned at "if"
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

        // Check for else
        var else_body: ?[]const u8 = null;
        if (self.matchKeyword("else ") or self.matchKeyword("else(")) {
            if (self.matchKeyword("else ")) self.pos += 5;
            if (self.matchKeyword("else(")) self.pos += 4;
            self.skipWhitespace();

            if (self.pos < self.source.len and self.source[self.pos] == '(') {
                self.pos += 1;
                const else_start = self.pos;
                depth = 1;
                while (self.pos < self.source.len and depth > 0) {
                    if (self.source[self.pos] == '(') depth += 1;
                    if (self.source[self.pos] == ')') depth -= 1;
                    if (depth > 0) self.pos += 1;
                }
                else_body = self.source[else_start..self.pos];
                self.pos += 1; // skip )
            }

            self.skipWhitespace();
        }

        // Skip closing }
        if (self.pos < self.source.len and self.source[self.pos] == '}') {
            self.pos += 1;
        }

        // Emit if statement
        try self.writeIndent();
        try self.write("if (");
        try self.write(cond);
        try self.write(") {\n");

        self.indent += 1;
        try self.parseFunctionBody(body);
        self.indent -= 1;

        if (else_body) |eb| {
            try self.writeIndent();
            try self.write("} else {\n");
            self.indent += 1;
            try self.parseFunctionBody(eb);
            self.indent -= 1;
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
        try self.write("try writer.writeAll(\"<");
        try self.write(tag);

        // Emit static attributes
        for (attrs) |attr| {
            if (!attr.is_expr and !attr.is_spread) {
                try self.write(" ");
                try self.write(attr.name);
                try self.write("=\\\"");
                try self.writeEscaped(attr.value);
                try self.write("\\\"");
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
                    try self.writeIndent();
                    try self.write("try writer.writeAll(\" ");
                    try self.write(attr.name);
                    try self.write("=\\\"\");\n");
                    try self.writeIndent();
                    try self.write("try zsx.escape(writer, ");
                    try self.write(attr.value);
                    try self.write(");\n");
                    try self.writeIndent();
                    try self.write("try writer.writeAll(\"\\\"\");\n");
                }
            }
            try self.writeIndent();
            try self.write("try writer.writeAll(\">\");\n");
        } else {
            try self.write(">\");\n");
        }
    }

    fn emitComponentCall(self: *Parser, name: []const u8, attrs: []const Attr, self_closing: bool) Error!void {
        _ = self_closing;
        try self.writeIndent();
        try self.write("try ");
        try self.write(name);
        try self.write("(writer, .{");

        var first = true;
        for (attrs) |attr| {
            if (attr.is_spread) {
                // Spread: merge fields
                if (!first) try self.write(", ");
                try self.write("// TODO: spread ");
                try self.write(attr.value);
                first = false;
            } else {
                if (!first) try self.write(", ");
                try self.write(" .");
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

        try self.write(" });\n");
    }

    fn emitText(self: *Parser, text: []const u8) Error!void {
        const trimmed = mem.trim(u8, text, " \t\n\r");
        if (trimmed.len == 0) {
            // Only whitespace - check if there's any at all
            if (text.len > 0 and mem.indexOf(u8, text, "\n") != null) {
                // Multi-line whitespace - emit newline
                try self.writeIndent();
                try self.write("try writer.writeAll(\"\\n\");\n");
            }
            return;
        }

        try self.writeIndent();
        try self.write("try writer.writeAll(\"");
        try self.writeEscaped(text);
        try self.write("\");\n");
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

// Tests
test "transpile simple function" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator,
        \\pub fn Hello(props: struct { name: []const u8 }) {
        \\    <div>Hello {props.name}</div>
        \\}
    , "test.zsx");
    defer parser.deinit();
    const result = try parser.generate();
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "fn Hello(writer: anytype, props:") != null);
    try std.testing.expect(mem.indexOf(u8, result, "!void") != null);
}

test "transpile self-closing tag" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator,
        \\pub fn Test() {
        \\    <br />
        \\}
    , "test.zsx");
    defer parser.deinit();
    const result = try parser.generate();
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "<br>") != null);
}

test "transpile component call" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator,
        \\pub fn Test() {
        \\    <MyComponent name="test" value={42} />
        \\}
    , "test.zsx");
    defer parser.deinit();
    const result = try parser.generate();
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "try MyComponent(writer,") != null);
}
