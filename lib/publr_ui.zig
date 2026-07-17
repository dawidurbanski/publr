// Publr UI Amalgamation — generated from design-system/src/gen/components/*.zig
// Do not edit directly. Regenerate: ./scripts/amalgamate-design-system.sh

// Self-reference for cross-component imports within the amalgamation.
const root = @This();

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

/// Emit a conditionally-present HTML attribute — the runtime side of the
/// `name?={expr}` syntax. Dispatches on the value's type at comptime:
///   - `bool`      → ` name` (bare presence attribute) when true, else nothing.
///                   For HTML boolean attrs (required/checked/disabled/…).
///   - optional `?T` → ` name="<value>"` when non-null, else nothing.
///                   For attrs that vanish when unset (maxlength/min/step/…).
///   - anything else → ` name="<value>"` (always present) — a degenerate but
///                   safe fallback so `?=` never surprises with wrong output.
/// The leading space is emitted here (callers bake no space before it), so the
/// attribute slots cleanly after the tag name / prior attributes. Values are
/// HTML-escaped via `render`, matching a normal `name={expr}` attribute.
pub fn attrCond(writer: anytype, comptime name: []const u8, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => if (value) try writer.writeAll(" " ++ name),
        .optional => if (value) |inner| {
            try writer.writeAll(" " ++ name ++ "=\"");
            try render(writer, inner);
            try writer.writeAll("\"");
        },
        else => {
            try writer.writeAll(" " ++ name ++ "=\"");
            try render(writer, value);
            try writer.writeAll("\"");
        },
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

/// Component self-forwarding — the inverse of `renderForwarding`. A component
/// calls this from a thin wrapper so it splices its OWN non-prop "rest" attrs
/// (data-p-* directives, data-*, aria-*, role, tabindex) onto its own root.
/// Call sites then pass every attr plainly and never need to know the
/// component's Props type — eliminating the call-site forwarding + `liftable`
/// analysis entirely. `body` is the component's real render fn `(writer, raw)`.
/// Comptime-gated: with no forwardable rest attrs it renders straight through
/// (no buffer). Conditional roots are handled by splicing the rendered output's
/// first tag (same as renderForwarding).
pub fn forward(comptime Props: type, writer: anytype, raw: anytype, comptime body: anytype) !void {
    const fields = std.meta.fields(@TypeOf(raw));
    comptime var rest = 0;
    inline for (fields) |f| {
        if (comptime (!@hasField(Props, f.name) and isFwdName(f.name))) rest += 1;
    }
    if (rest == 0) return body(writer, raw);

    var parts: [fields.len * 5][]const u8 = undefined;
    var n: usize = 0;
    inline for (fields) |f| {
        if (comptime (!@hasField(Props, f.name) and isFwdName(f.name))) {
            const v: []const u8 = @field(raw, f.name);
            parts[n] = " ";
            parts[n + 1] = f.name;
            parts[n + 2] = "=\"";
            parts[n + 3] = v;
            parts[n + 4] = "\"";
            n += 5;
        }
    }
    const fwd = concatRt(parts[0..n]);
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.heap.page_allocator);
    try body(buf.writer(std.heap.page_allocator), raw);
    try spliceAttrsIntoRoot(writer, buf.items, fwd);
}

/// Attr names a component self-forwards: hyphenated (data-p-* / data-* / aria-*)
/// or the bare a11y attrs role/tabindex. Non-prop fields with other names are
/// ignored (not forwarded, not an error) so stray props can't break the build.
fn isFwdName(comptime name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '-') != null) return true;
    if (std.mem.eql(u8, name, "role")) return true;
    if (std.mem.eql(u8, name, "tabindex")) return true;
    return false;
}

fn isTagStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Byte offset in `html` where extra attributes can be inserted — just before
/// the first opening tag's closing `>` (or the `/` of `/>`). Null if no opening
/// tag is found. Quote-aware so `>` inside an attribute value doesn't fool it.
fn rootAttrInsertPos(html: []const u8) ?usize {
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] == '<' and i + 1 < html.len and isTagStart(html[i + 1])) break;
    }
    if (i >= html.len) return null;
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
    if (j >= html.len) return null;
    return if (j > 0 and html[j - 1] == '/') j - 1 else j;
}

/// Insert `attrs` (` name="value"` run) into the first opening tag of `html`,
/// before its closing `>` (or `/>`). Writes `html` unchanged if none found.
fn spliceAttrsIntoRoot(writer: anytype, html: []const u8, attrs: []const u8) !void {
    const at = rootAttrInsertPos(html) orelse return writer.writeAll(html);
    try writer.writeAll(html[0..at]);
    try writer.writeAll(attrs);
    try writer.writeAll(html[at..]);
}

/// asChild slot: return `child` HTML with `attrs` (a ` name="value"` run)
/// spliced onto its root element's opening tag. Lets a wrapper component (a
/// menu Trigger, tooltip anchor, …) merge its own behavior attributes —
/// `data-p-*` directives, `aria-*` — straight onto the caller's child element,
/// with no wrapper node (the Radix `asChild` pattern). The string form of the
/// splice `forward` already does for self-forwarding; returns a value so it can
/// be used in `{@raw zsx.slot(children, attrs)}` positions. Allocates
/// short-lived from page_allocator like `concatRt` (freed on arena reset).
/// Returns `child` unchanged when there are no attrs or no root tag.
pub fn slot(child: []const u8, attrs: []const u8) []const u8 {
    if (attrs.len == 0) return child;
    const at = rootAttrInsertPos(child) orelse return child;
    const buf = std.heap.page_allocator.alloc(u8, child.len + attrs.len) catch return child;
    @memcpy(buf[0..at], child[0..at]);
    @memcpy(buf[at .. at + attrs.len], attrs);
    @memcpy(buf[at + attrs.len ..], child[at..]);
    return buf;
}

};

pub const icons_data = struct {
// Generated by scripts/build.mjs — do not edit.

pub const view_box = "0 0 24 24";
pub const Name = enum { accordion, alert_hexagon, alert_triangle, arrow_left, audio, bold, bookmark, button, buttons, calendar_check_02, calendar_check, caption, chart, check, chevron_down, chevron_left, chevron_right, chevron_up, clock_check, clock_rewind, close, code, column, columns, components, copy, cover, decorative, details, dot_filled, dot_half, dot_outline, duplicate, edit, external, file, folder_plus, folder, gallery, globe, grid, group_blocks, group, heading_level_1, heading_level_2, heading_level_3, heading_level_4, heading_level_5, heading_level_6, heading, home, html, icon, image, italic, link, list_item, list_ordered, list_unordered, list_view, list, lock, logout, math, media_text, menu_03, moon, more, package, paragraph, pattern, plus_circle, plus, preformatted, pullquote, quote, redo, replace, reset, row, search, separator, settings, share_04, share, spacer, stack, sun, symbol, sync, table, tag, trash, undo, ungroup, upload, user, users, verse, video, x_close };

pub const accordion: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.75" width="17" height="4.25" rx="1"/><rect x="3.5" y="10.5" width="17" height="9.75" rx="1"/><path d="M12 13.25v4.25"/><path d="M9.875 15.375h4.25"/></g>
;

pub const alert_hexagon: []const u8 =
    \\<path d="M12 8.00008V12.0001M12 16.0001H12.01M3 7.94153V16.0586C3 16.4013 3 16.5726 3.05048 16.7254C3.09515 16.8606 3.16816 16.9847 3.26463 17.0893C3.37369 17.2077 3.52345 17.2909 3.82297 17.4573L11.223 21.5684C11.5066 21.726 11.6484 21.8047 11.7985 21.8356C11.9315 21.863 12.0685 21.863 12.2015 21.8356C12.3516 21.8047 12.4934 21.726 12.777 21.5684L20.177 17.4573C20.4766 17.2909 20.6263 17.2077 20.7354 17.0893C20.8318 16.9847 20.9049 16.8606 20.9495 16.7254C21 16.5726 21 16.4013 21 16.0586V7.94153C21 7.59889 21 7.42756 20.9495 7.27477C20.9049 7.13959 20.8318 7.01551 20.7354 6.91082C20.6263 6.79248 20.4766 6.70928 20.177 6.54288L12.777 2.43177C12.4934 2.27421 12.3516 2.19543 12.2015 2.16454C12.0685 2.13721 11.9315 2.13721 11.7985 2.16454C11.6484 2.19543 11.5066 2.27421 11.223 2.43177L3.82297 6.54288C3.52345 6.70928 3.37369 6.79248 3.26463 6.91082C3.16816 7.01551 3.09515 7.13959 3.05048 7.27477C3 7.42756 3 7.59889 3 7.94153Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const alert_triangle: []const u8 =
    \\<path d="M11.9998 8.99999V13M11.9998 17H12.0098M10.6151 3.89171L2.39019 18.0983C1.93398 18.8863 1.70588 19.2803 1.73959 19.6037C1.769 19.8857 1.91677 20.142 2.14613 20.3088C2.40908 20.5 2.86435 20.5 3.77487 20.5H20.2246C21.1352 20.5 21.5904 20.5 21.8534 20.3088C22.0827 20.142 22.2305 19.8857 22.2599 19.6037C22.2936 19.2803 22.0655 18.8863 21.6093 18.0983L13.3844 3.89171C12.9299 3.10654 12.7026 2.71396 12.4061 2.58211C12.1474 2.4671 11.8521 2.4671 11.5935 2.58211C11.2969 2.71396 11.0696 3.10655 10.6151 3.89171Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const arrow_left: []const u8 =
    \\<path d="M19 12H5M5 12L12 19M5 12L12 5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const audio: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.4" cy="17" r="2.3" fill="currentColor" stroke="none"/><path d="M9.7 17V6.5"/><path d="M9.7 6.5c3 .5 4.9 2 5.4 4.5"/></g>
;

pub const bold: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round"><path d="M8 5h5a3.5 3.5 0 0 1 0 7H8z"/><path d="M8 12h6a3.5 3.5 0 0 1 0 7H8z"/></g>
;

pub const bookmark: []const u8 =
    \\<path d="M5 7.8C5 6.11984 5 5.27976 5.32698 4.63803C5.6146 4.07354 6.07354 3.6146 6.63803 3.32698C7.27976 3 8.11984 3 9.8 3H14.2C15.8802 3 16.7202 3 17.362 3.32698C17.9265 3.6146 18.3854 4.07354 18.673 4.63803C19 5.27976 19 6.11984 19 7.8V21L12 17L5 21V7.8Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const button: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="8" width="17" height="8" rx="2.5"/><path d="M8 12h8"/></g>
;

pub const buttons: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="6.5" rx="2"/><rect x="3.5" y="13" width="17" height="6.5" rx="2"/><path d="M8 7.75h8"/><path d="M8 16.25h8"/></g>
;

pub const calendar_check_02: []const u8 =
    \\<path d="M21 10H3M21 12.5V8.8C21 7.11984 21 6.27976 20.673 5.63803C20.3854 5.07354 19.9265 4.6146 19.362 4.32698C18.7202 4 17.8802 4 16.2 4H7.8C6.11984 4 5.27976 4 4.63803 4.32698C4.07354 4.6146 3.6146 5.07354 3.32698 5.63803C3 6.27976 3 7.11984 3 8.8V17.2C3 18.8802 3 19.7202 3.32698 20.362C3.6146 20.9265 4.07354 21.3854 4.63803 21.673C5.27976 22 6.11984 22 7.8 22H12M16 2V6M8 2V6M14.5 19L16.5 21L21 16.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const calendar_check: []const u8 =
    \\<path d="M21 10H3M16 2V6M8 2V6M9 16L11 18L15 14M7.8 22H16.2C17.8802 22 18.7202 22 19.362 21.673C19.9265 21.3854 20.3854 20.9265 20.673 20.362C21 19.7202 21 18.8802 21 17.2V8.8C21 7.11984 21 6.27976 20.673 5.63803C20.3854 5.07354 19.9265 4.6146 19.362 4.32698C18.7202 4 17.8802 4 16.2 4H7.8C6.11984 4 5.27976 4 4.63803 4.32698C4.07354 4.6146 3.6146 5.07354 3.32698 5.63803C3 6.27976 3 7.11984 3 8.8V17.2C3 18.8802 3 19.7202 3.32698 20.362C3.6146 20.9265 4.07354 21.3854 4.63803 21.673C5.27976 22 6.11984 22 7.8 22Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const caption: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="14" rx="2"/><path d="M7 15.5h10"/></g>
;

pub const chart: []const u8 =
    \\<path d="M21 21H4.6C4.03995 21 3.75992 21 3.54601 20.891C3.35785 20.7951 3.20487 20.6422 3.10899 20.454C3 20.2401 3 19.9601 3 19.4V3M21 7L15.5657 12.4343C15.3677 12.6323 15.2687 12.7313 15.1545 12.7684C15.0541 12.8011 14.9459 12.8011 14.8455 12.7684C14.7313 12.7313 14.6323 12.6323 14.4343 12.4343L12.5657 10.5657C12.3677 10.3677 12.2687 10.2687 12.1545 10.2316C12.0541 10.1989 11.9459 10.1989 11.8455 10.2316C11.7313 10.2687 11.6323 10.3677 11.4343 10.5657L7 15M21 7H17M21 7V11" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const check: []const u8 =
    \\<path d="M20 6L9 17L4 12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_down: []const u8 =
    \\<path d="M6 9L12 15L18 9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_left: []const u8 =
    \\<path d="M15 18L9 12L15 6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_right: []const u8 =
    \\<path d="M9 18L15 12L9 6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_up: []const u8 =
    \\<path d="M18 15L12 9L6 15" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const clock_check: []const u8 =
    \\<path d="M14.5 19L16.5 21L21 16.5M21.9851 12.5499C21.995 12.3678 22 12.1845 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.4354 6.33651 21.858 11.7385 21.9966M12 6V12L15.7384 13.8692" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const clock_rewind: []const u8 =
    \\<path d="M22.7 13.5L20.7005 11.5L18.7 13.5M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C15.3019 3 18.1885 4.77814 19.7545 7.42909M12 7V12L15 14" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const close: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12"/><path d="M18 6L6 18"/></g>
;

pub const code: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 8l-4 4 4 4"/><path d="M16 8l4 4-4 4"/><path d="M13.5 5.5l-3 13"/></g>
;

pub const column: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="8.5" y="4.5" width="7" height="15" rx="1.5"/><path d="M4.5 6.5v11"/><path d="M19.5 6.5v11"/></g>
;

pub const columns: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M9.5 4.5v15"/><path d="M14.5 4.5v15"/></g>
;

pub const components: []const u8 =
    \\<path d="M15.0505 9H5.5C4.11929 9 3 7.88071 3 6.5C3 5.11929 4.11929 4 5.5 4H15.0505M8.94949 20H18.5C19.8807 20 21 18.8807 21 17.5C21 16.1193 19.8807 15 18.5 15H8.94949M3 17.5C3 19.433 4.567 21 6.5 21C8.433 21 10 19.433 10 17.5C10 15.567 8.433 14 6.5 14C4.567 14 3 15.567 3 17.5ZM21 6.5C21 8.433 19.433 10 17.5 10C15.567 10 14 8.433 14 6.5C14 4.567 15.567 3 17.5 3C19.433 3 21 4.567 21 6.5Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const copy: []const u8 =
    \\<path d="M7.5 3H14.6C16.8402 3 17.9603 3 18.816 3.43597C19.5686 3.81947 20.1805 4.43139 20.564 5.18404C21 6.03969 21 7.15979 21 9.4V16.5M6.2 21H14.3C15.4201 21 15.9802 21 16.408 20.782C16.7843 20.5903 17.0903 20.2843 17.282 19.908C17.5 19.4802 17.5 18.9201 17.5 17.8V9.7C17.5 8.57989 17.5 8.01984 17.282 7.59202C17.0903 7.21569 16.7843 6.90973 16.408 6.71799C15.9802 6.5 15.4201 6.5 14.3 6.5H6.2C5.0799 6.5 4.51984 6.5 4.09202 6.71799C3.71569 6.90973 3.40973 7.21569 3.21799 7.59202C3 8.01984 3 8.57989 3 9.7V17.8C3 18.9201 3 19.4802 3.21799 19.908C3.40973 20.2843 3.71569 20.5903 4.09202 20.782C4.51984 21 5.0799 21 6.2 21Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const cover: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="17" height="17" rx="2"/><circle cx="8.5" cy="8.25" r="1.4"/><path d="M7 14.75h10"/><path d="M9 17.75h6"/></g>
;

pub const decorative: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12c1.9-3.4 4.6-5.25 8-5.25S18.1 8.6 20 12c-1.9 3.4-4.6 5.25-8 5.25S5.9 15.4 4 12z"/><circle cx="12" cy="12" r="2.25"/><path d="M5.75 18.25L18.25 5.75"/></g>
;

pub const details: []const u8 =
    \\<path d="M5 5l4.25 2.6L5 10.2z" fill="currentColor" stroke="none"/><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12.5 7.5H20"/><path d="M4 13h16"/><path d="M4 17.5h16"/></g>
;

pub const dot_filled: []const u8 =
    \\<circle cx="12" cy="12" r="6" fill="currentColor"/>
;

pub const dot_half: []const u8 =
    \\<circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="1.5"/>
    \\<path d="M12 7a5 5 0 010 10V7z" fill="currentColor"/>
;

pub const dot_outline: []const u8 =
    \\<circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="1.5"/>
;

pub const duplicate: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="8.75" y="8.75" width="11.25" height="11.25" rx="2"/><path d="M15.25 5.25V5a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7.25a2 2 0 0 0 2 2h.25"/></g>
;

pub const edit: []const u8 =
    \\<path d="M2.87601 18.1156C2.92195 17.7021 2.94493 17.4954 3.00748 17.3022C3.06298 17.1307 3.1414 16.9676 3.24061 16.8171C3.35242 16.6475 3.49952 16.5005 3.7937 16.2063L17 3C18.1046 1.89543 19.8954 1.89543 21 3C22.1046 4.10457 22.1046 5.89543 21 7L7.7937 20.2063C7.49951 20.5005 7.35242 20.6475 7.18286 20.7594C7.03242 20.8586 6.86926 20.937 6.69782 20.9925C6.50457 21.055 6.29783 21.078 5.88434 21.124L2.49997 21.5L2.87601 18.1156Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const external: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5H7a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4"/><path d="M13.75 4.5h5.75v5.75"/><path d="M19.5 4.5L11.75 12.25"/></g>
;

pub const file: []const u8 =
    \\<path d="M14 2.26946V6.4C14 6.96005 14 7.24008 14.109 7.45399C14.2049 7.64215 14.3578 7.79513 14.546 7.89101C14.7599 8 15.0399 8 15.6 8H19.7305M20 9.98822V17.2C20 18.8802 20 19.7202 19.673 20.362C19.3854 20.9265 18.9265 21.3854 18.362 21.673C17.7202 22 16.8802 22 15.2 22H8.8C7.11984 22 6.27976 22 5.63803 21.673C5.07354 21.3854 4.6146 20.9265 4.32698 20.362C4 19.7202 4 18.8802 4 17.2V6.8C4 5.11984 4 4.27976 4.32698 3.63803C4.6146 3.07354 5.07354 2.6146 5.63803 2.32698C6.27976 2 7.11984 2 8.8 2H12.0118C12.7455 2 13.1124 2 13.4577 2.08289C13.7638 2.15638 14.0564 2.27759 14.3249 2.44208C14.6276 2.6276 14.887 2.88703 15.4059 3.40589L18.5941 6.59411C19.113 7.11297 19.3724 7.3724 19.5579 7.67515C19.7224 7.94356 19.8436 8.2362 19.9171 8.5423C20 8.88757 20 9.25445 20 9.98822Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const folder_plus: []const u8 =
    \\<path d="M13 7L11.8845 4.76892C11.5634 4.1268 11.4029 3.80573 11.1634 3.57116C10.9516 3.36373 10.6963 3.20597 10.4161 3.10931C10.0992 3 9.74021 3 9.02229 3H5.2C4.0799 3 3.51984 3 3.09202 3.21799C2.71569 3.40973 2.40973 3.71569 2.21799 4.09202C2 4.51984 2 5.0799 2 6.2V7M2 7H17.2C18.8802 7 19.7202 7 20.362 7.32698C20.9265 7.6146 21.3854 8.07354 21.673 8.63803C22 9.27976 22 10.1198 22 11.8V16.2C22 17.8802 22 18.7202 21.673 19.362C21.3854 19.9265 20.9265 20.3854 20.362 20.673C19.7202 21 18.8802 21 17.2 21H6.8C5.11984 21 4.27976 21 3.63803 20.673C3.07354 20.3854 2.6146 19.9265 2.32698 19.362C2 18.7202 2 17.8802 2 16.2V7ZM12 17V11M9 14H15" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const folder: []const u8 =
    \\<path d="M13 7L11.8845 4.76892C11.5634 4.1268 11.4029 3.80573 11.1634 3.57116C10.9516 3.36373 10.6963 3.20597 10.4161 3.10931C10.0992 3 9.74021 3 9.02229 3H5.2C4.0799 3 3.51984 3 3.09202 3.21799C2.71569 3.40973 2.40973 3.71569 2.21799 4.09202C2 4.51984 2 5.0799 2 6.2V7M2 7H17.2C18.8802 7 19.7202 7 20.362 7.32698C20.9265 7.6146 21.3854 8.07354 21.673 8.63803C22 9.27976 22 10.1198 22 11.8V16.2C22 17.8802 22 18.7202 21.673 19.362C21.3854 19.9265 20.9265 20.3854 20.362 20.673C19.7202 21 18.8802 21 17.2 21H6.8C5.11984 21 4.27976 21 3.63803 20.673C3.07354 20.3854 2.6146 19.9265 2.32698 19.362C2 18.7202 2 17.8802 2 16.2V7Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const gallery: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 6V5.5a2 2 0 0 1 2-2h9.5a2 2 0 0 1 2 2V15a2 2 0 0 1-2 2H18"/><rect x="3.5" y="7" width="14" height="13.5" rx="2"/><path d="M3.5 16.75l3.5-3 3 2.5 2.75-2.25 4.75 3.75"/></g>
;

pub const globe: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17"/><path d="M12 3.5c-3 2.4-4.5 5.4-4.5 8.5s1.5 6.1 4.5 8.5c3-2.4 4.5-5.4 4.5-8.5S15 5.9 12 3.5z"/></g>
;

pub const grid: []const u8 =
    \\<path d="M3 3H10V10H3V3ZM14 3H21V10H14V3ZM14 14H21V21H14V14ZM3 14H10V21H3V14Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const group_blocks: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.75" y="3.75" width="16.5" height="16.5" rx="2" stroke-dasharray="3.1 2.6"/><rect x="7.25" y="7.25" width="4.25" height="9.5" rx="1"/><rect x="14" y="7.25" width="2.75" height="9.5" rx="1"/></g>
;

pub const group: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="11" height="11" rx="2"/><path d="M9 20h9a2 2 0 0 0 2-2V9"/></g>
;

pub const heading_level_1: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M15.5 8.25l2.25-1.75v11"/></g>
;

pub const heading_level_2: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M14.5 9.25c.2-1.6 1.5-2.75 3-2.75 1.65 0 2.9 1.2 2.9 2.8 0 1-.5 1.85-1.45 2.8l-4.45 5.4h6"/></g>
;

pub const heading_level_3: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M14.75 8c.6-.95 1.65-1.5 2.9-1.5 1.7 0 2.95 1 2.95 2.5 0 1.35-1 2.25-2.4 2.5 1.5.2 2.7 1.1 2.7 2.7 0 1.7-1.45 2.8-3.25 2.8-1.35 0-2.45-.55-3.1-1.5"/></g>
;

pub const heading_level_4: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M18.75 6.5l-4.25 7.25h6.25"/><path d="M18.75 6.5v11"/></g>
;

pub const heading_level_5: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M20 6.5h-4.75l-.5 5c.6-.55 1.4-.85 2.3-.85 1.9 0 3.2 1.35 3.2 3.25s-1.45 3.35-3.35 3.35c-1.3 0-2.4-.6-3-1.55"/></g>
;

pub const heading_level_6: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M19.9 7.1c-.55-.45-1.25-.7-2.05-.7-2.2 0-3.6 1.85-3.6 4.6v2.9c0 2.05 1.45 3.5 3.3 3.5s3.3-1.45 3.3-3.3-1.45-3.3-3.3-3.3c-1.55 0-2.85 1-3.3 2.4"/></g>
;

pub const heading: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4.5h10V19.5l-5-4.1-5 4.1z"/></g>
;

pub const home: []const u8 =
    \\<path d="M3 10.5651C3 9.9907 3 9.70352 3.07403 9.43905C3.1396 9.20478 3.24737 8.98444 3.39203 8.78886C3.55534 8.56806 3.78202 8.39175 4.23539 8.03912L11.0177 2.764C11.369 2.49075 11.5447 2.35412 11.7387 2.3016C11.9098 2.25526 12.0902 2.25526 12.2613 2.3016C12.4553 2.35412 12.631 2.49075 12.9823 2.764L19.7646 8.03913C20.218 8.39175 20.4447 8.56806 20.608 8.78886C20.7526 8.98444 20.8604 9.20478 20.926 9.43905C21 9.70352 21 9.9907 21 10.5651V17.8C21 18.9201 21 19.4801 20.782 19.908C20.5903 20.2843 20.2843 20.5903 19.908 20.782C19.4802 21 18.9201 21 17.8 21H6.2C5.07989 21 4.51984 21 4.09202 20.782C3.71569 20.5903 3.40973 20.2843 3.21799 19.908C3 19.4801 3 18.9201 3 17.8V10.5651Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const html: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4" width="17" height="16" rx="2"/><path d="M10 9.5L7.5 12l2.5 2.5"/><path d="M14 9.5l2.5 2.5L14 14.5"/></g>
;

pub const icon: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.25" cy="7.25" r="3.75"/><path d="M13.75 4.5l5.75 5.75"/><path d="M19.5 4.5l-5.75 5.75"/><path d="M3.5 19.75l3.75-6.5 3.75 6.5z"/><rect x="13.5" y="13.25" width="6.5" height="6.5" rx="1.5"/></g>
;

pub const image: []const u8 =
    \\<path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const italic: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 5h6.5"/><path d="M7 19h6.5"/><path d="M13.75 5l-4 14"/></g>
;

pub const link: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M13.75 10.25a3.5 3.5 0 0 1 0 4.95l-2.55 2.55a3.5 3.5 0 0 1-4.95-4.95l1.3-1.3"/><path d="M10.25 13.75a3.5 3.5 0 0 1 0-4.95l2.55-2.55a3.5 3.5 0 0 1 4.95 4.95l-1.3 1.3"/></g>
;

pub const list_item: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="12" r="1.4" fill="currentColor" stroke="none"/><path d="M10.5 12h9.5"/></g>
;

pub const list_ordered: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 6.25L6 5.25v5"/><path d="M4.5 14.75c.15-1 .95-1.6 1.85-1.5.85.1 1.5.8 1.4 1.65-.05.55-.45 1-.95 1.5L4.5 18.75h3.6"/><path d="M11 7.75h9"/><path d="M11 16.25h9"/></g>
;

pub const list_unordered: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="5.5" cy="8" r="1.4" fill="currentColor" stroke="none"/><circle cx="5.5" cy="16" r="1.4" fill="currentColor" stroke="none"/><path d="M10.5 8H20"/><path d="M10.5 16H20"/></g>
;

pub const list_view: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5h9.5"/><path d="M10.5 12h9.5"/><path d="M4 17.5h9.5"/></g>
;

pub const list: []const u8 =
    \\<path d="M21 12L9 12M21 6L9 6M21 18L9 18M5 12C5 12.5523 4.55228 13 4 13C3.44772 13 3 12.5523 3 12C3 11.4477 3.44772 11 4 11C4.55228 11 5 11.4477 5 12ZM5 6C5 6.55228 4.55228 7 4 7C3.44772 7 3 6.55228 3 6C3 5.44772 3.44772 5 4 5C4.55228 5 5 5.44772 5 6ZM5 18C5 18.5523 4.55228 19 4 19C3.44772 19 3 18.5523 3 18C3 17.4477 3.44772 17 4 17C4.55228 17 5 17.4477 5 18Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const lock: []const u8 =
    \\<path d="M17 11V8C17 5.23858 14.7614 3 12 3C9.23858 3 7 5.23858 7 8V11M12 14.5V16.5M9.8 21H14.2C15.8802 21 16.7202 21 17.362 20.673C17.9265 20.3854 18.3854 19.9265 18.673 19.362C19 18.7202 19 17.8802 19 16.2V15.8C19 14.1198 19 13.2798 18.673 12.638C18.3854 12.0735 17.9265 11.6146 17.362 11.327C16.7202 11 15.8802 11 14.2 11H9.8C8.11984 11 7.27976 11 6.63803 11.327C6.07354 11.6146 5.6146 12.0735 5.32698 12.638C5 13.2798 5 14.1198 5 15.8V16.2C5 17.8802 5 18.7202 5.32698 19.362C5.6146 19.9265 6.07354 20.3854 6.63803 20.673C7.27976 21 8.11984 21 9.8 21Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const logout: []const u8 =
    \\<path d="M16 17L21 12M21 12L16 7M21 12H9M9 3H7.8C6.11984 3 5.27976 3 4.63803 3.32698C4.07354 3.6146 3.6146 4.07354 3.32698 4.63803C3 5.27976 3 6.11984 3 7.8V16.2C3 17.8802 3 18.7202 3.32698 19.362C3.6146 19.9265 4.07354 20.3854 4.63803 20.673C5.27976 21 6.11984 21 7.8 21H9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const math: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7.25 4.75v5"/><path d="M4.75 7.25h5"/><path d="M14.25 7.25h5"/><path d="M5.5 14.5l3.5 3.5"/><path d="M9 14.5l-3.5 3.5"/><path d="M14.25 16.5h5"/><circle cx="16.75" cy="13.9" r="1" fill="currentColor" stroke="none"/><circle cx="16.75" cy="19.1" r="1" fill="currentColor" stroke="none"/></g>
;

pub const media_text: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="7" width="8" height="10" rx="1.5"/><path d="M14.75 9h5.75"/><path d="M14.75 12h5.75"/><path d="M14.75 15h5.75"/></g>
;

pub const menu_03: []const u8 =
    \\<path d="M3 12H21M3 6H21M3 18H15" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const moon: []const u8 =
    \\<path d="M21.9548 12.9564C20.5779 15.3717 17.9791 17.0001 15 17.0001C10.5817 17.0001 7 13.4184 7 9.00008C7 6.02072 8.62867 3.42175 11.0443 2.04492C5.96975 2.52607 2 6.79936 2 11.9998C2 17.5227 6.47715 21.9998 12 21.9998C17.2002 21.9998 21.4733 18.0305 21.9548 12.9564Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const more: []const u8 =
    \\<path d="M12 13C12.5523 13 13 12.5523 13 12C13 11.4477 12.5523 11 12 11C11.4477 11 11 11.4477 11 12C11 12.5523 11.4477 13 12 13Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M12 6C12.5523 6 13 5.55228 13 5C13 4.44772 12.5523 4 12 4C11.4477 4 11 4.44772 11 5C11 5.55228 11.4477 6 12 6Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M12 20C12.5523 20 13 19.5523 13 19C13 18.4477 12.5523 18 12 18C11.4477 18 11 18.4477 11 19C11 19.5523 11.4477 20 12 20Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const package: []const u8 =
    \\<path d="M16.5 9.4L7.5 4.21M21 16V8C20.9996 7.6493 20.9071 7.30483 20.7315 7.00017C20.556 6.69552 20.3037 6.44136 20 6.264L13 2.264C12.696 2.08669 12.3511 1.99377 12 1.99377C11.6489 1.99377 11.304 2.08669 11 2.264L4 6.264C3.69626 6.44136 3.44398 6.69552 3.26846 7.00017C3.09294 7.30483 3.00036 7.6493 3 8V16C3.00036 16.3507 3.09294 16.6952 3.26846 16.9998C3.44398 17.3045 3.69626 17.5586 4 17.736L11 21.736C11.304 21.9133 11.6489 22.0062 12 22.0062C12.3511 22.0062 12.696 21.9133 13 21.736L20 17.736C20.3037 17.5586 20.556 17.3045 20.7315 16.9998C20.9071 16.6952 20.9996 16.3507 21 16Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M3.27002 6.96L12 12.01L20.73 6.96M12 22.08V12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const paragraph: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11.25 19V5h5.5"/><path d="M14.75 19V5"/><path d="M11.25 12.5a3.75 3.75 0 0 1 0-7.5"/></g>
;

pub const pattern: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="9" height="15" rx="1.5"/><rect x="15" y="4.5" width="5.5" height="6.25" rx="1.5"/><rect x="15" y="13.25" width="5.5" height="6.25" rx="1.5"/></g>
;

pub const plus_circle: []const u8 =
    \\<path d="M12 8V16M8 12H16M22 12C22 17.5228 17.5228 22 12 22C6.47715 22 2 17.5228 2 12C2 6.47715 6.47715 2 12 2C17.5228 2 22 6.47715 22 12Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const plus: []const u8 =
    \\<path d="M12 5V19M5 12H19" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const preformatted: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M7 9h6"/><path d="M7 12.25h9.5"/><path d="M7 15.5h4"/></g>
;

pub const pullquote: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4.5h16"/><path d="M4 19.5h16"/></g><path d="M11.1 8.35c-2.4.4-3.7 2.05-3.7 4.4v2.95h3.5v-3.55H9.25c.2-1.1.85-1.75 1.85-2.1z" fill="currentColor"/><path d="M16.55 8.35c-2.4.4-3.7 2.05-3.7 4.4v2.95h3.5v-3.55h-1.65c.2-1.1.85-1.75 1.85-2.1z" fill="currentColor"/>
;

pub const quote: []const u8 =
    \\<path d="M10.75 6.75c-3.4.6-5.25 2.9-5.25 6.3v4.2h5v-5.1H8.1c.3-1.55 1.2-2.5 2.65-2.95z" fill="currentColor"/><path d="M18.5 6.75c-3.4.6-5.25 2.9-5.25 6.3v4.2h5v-5.1h-2.4c.3-1.55 1.2-2.5 2.65-2.95z" fill="currentColor"/>
;

pub const redo: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M16.25 6.25L20 10l-3.75 3.75"/><path d="M20 10H9.5a5.25 5.25 0 0 0-5.25 5.25v2.25"/></g>
;

pub const replace: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 8h13"/><path d="M14.75 5.25L17.5 8l-2.75 2.75"/><path d="M19.5 16h-13"/><path d="M9.25 13.25L6.5 16l2.75 2.75"/></g>
;

pub const reset: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.75 4.75V9.5h4.75"/><path d="M4.75 9.5a7.5 7.5 0 1 1-.65 4.75"/></g>
;

pub const row: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="7" width="7.75" height="10" rx="1.5"/><rect x="12.75" y="7" width="7.75" height="10" rx="1.5"/></g>
;

pub const search: []const u8 =
    \\<path d="M21 21L17.5001 17.5M20 11.5C20 16.1944 16.1944 20 11.5 20C6.80558 20 3 16.1944 3 11.5C3 6.80558 6.80558 3 11.5 3C16.1944 3 20 6.80558 20 11.5Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const separator: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 12h17"/><path d="M9 7.5h6"/><path d="M9 16.5h6"/></g>
;

pub const settings: []const u8 =
    \\<path d="M9.3951 19.3711L9.97955 20.6856C10.1533 21.0768 10.4368 21.4093 10.7958 21.6426C11.1547 21.8759 11.5737 22.0001 12.0018 22C12.4299 22.0001 12.8488 21.8759 13.2078 21.6426C13.5667 21.4093 13.8503 21.0768 14.024 20.6856L14.6084 19.3711C14.8165 18.9047 15.1664 18.5159 15.6084 18.26C16.0532 18.0034 16.5678 17.8941 17.0784 17.9478L18.5084 18.1C18.9341 18.145 19.3637 18.0656 19.7451 17.8713C20.1265 17.6771 20.4434 17.3763 20.6573 17.0056C20.8715 16.635 20.9735 16.2103 20.9511 15.7829C20.9286 15.3555 20.7825 14.9438 20.5307 14.5978L19.684 13.4344C19.3825 13.0171 19.2214 12.5148 19.224 12C19.2239 11.4866 19.3865 10.9864 19.6884 10.5711L20.5351 9.40778C20.787 9.06175 20.933 8.65007 20.9555 8.22267C20.978 7.79528 20.8759 7.37054 20.6618 7C20.4479 6.62923 20.131 6.32849 19.7496 6.13423C19.3681 5.93997 18.9386 5.86053 18.5129 5.90556L17.0829 6.05778C16.5722 6.11141 16.0577 6.00212 15.6129 5.74556C15.17 5.48825 14.82 5.09736 14.6129 4.62889L14.024 3.31444C13.8503 2.92317 13.5667 2.59072 13.2078 2.3574C12.8488 2.12408 12.4299 1.99993 12.0018 2C11.5737 1.99993 11.1547 2.12408 10.7958 2.3574C10.4368 2.59072 10.1533 2.92317 9.97955 3.31444L9.3951 4.62889C9.18803 5.09736 8.83798 5.48825 8.3951 5.74556C7.95032 6.00212 7.43577 6.11141 6.9251 6.05778L5.49066 5.90556C5.06499 5.86053 4.6354 5.93997 4.25397 6.13423C3.87255 6.32849 3.55567 6.62923 3.34177 7C3.12759 7.37054 3.02555 7.79528 3.04804 8.22267C3.07052 8.65007 3.21656 9.06175 3.46844 9.40778L4.3151 10.5711C4.61704 10.9864 4.77964 11.4866 4.77955 12C4.77964 12.5134 4.61704 13.0137 4.3151 13.4289L3.46844 14.5922C3.21656 14.9382 3.07052 15.3499 3.04804 15.7773C3.02555 16.2047 3.12759 16.6295 3.34177 17C3.55589 17.3706 3.8728 17.6712 4.25417 17.8654C4.63554 18.0596 5.06502 18.1392 5.49066 18.0944L6.92066 17.9422C7.43133 17.8886 7.94587 17.9979 8.39066 18.2544C8.83519 18.511 9.18687 18.902 9.3951 19.3711Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M12 15C13.6568 15 15 13.6569 15 12C15 10.3431 13.6568 9 12 9C10.3431 9 8.99998 10.3431 8.99998 12C8.99998 13.6569 10.3431 15 12 15Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const share_04: []const u8 =
    \\<path d="M15 3H21L21 9M21 3L13 11M10 5H7.8C6.11984 5 5.27976 5 4.63803 5.32698C4.07354 5.6146 3.6146 6.07354 3.32698 6.63803C3 7.27976 3 8.11984 3 9.8V16.2C3 17.8802 3 18.7202 3.32698 19.362C3.6146 19.9265 4.07354 20.3854 4.63803 20.673C5.27976 21 6.11984 21 7.8 21H14.2C15.8802 21 16.7202 21 17.362 20.673C17.9265 20.3854 18.3854 19.9265 18.673 19.362C19 18.7202 19 17.8802 19 16.2V14" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const share: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="6.5" cy="12" r="2.5"/><circle cx="17" cy="5.75" r="2.5"/><circle cx="17" cy="18.25" r="2.5"/><path d="M8.7 10.7l6.1-3.65"/><path d="M8.7 13.3l6.1 3.65"/></g>
;

pub const spacer: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.75v14.5"/><path d="M8.75 8L12 4.75 15.25 8"/><path d="M8.75 16L12 19.25 15.25 16"/></g>
;

pub const stack: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="4" width="15" height="7.25" rx="1.5"/><rect x="4.5" y="12.75" width="15" height="7.25" rx="1.5"/></g>
;

pub const sun: []const u8 =
    \\<path d="M12 2V4M12 20V22M4 12H2M6.31412 6.31412L4.8999 4.8999M17.6859 6.31412L19.1001 4.8999M6.31412 17.69L4.8999 19.1042M17.6859 17.69L19.1001 19.1042M22 12H20M17 12C17 14.7614 14.7614 17 12 17C9.23858 17 7 14.7614 7 12C7 9.23858 9.23858 7 12 7C14.7614 7 17 9.23858 17 12Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const symbol: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4l2.75 2.75L12 9.5 9.25 6.75z"/><path d="M6.75 9.25L9.5 12l-2.75 2.75L4 12z"/><path d="M17.25 9.25L20 12l-2.75 2.75L14.5 12z"/><path d="M12 14.5l2.75 2.75L12 20l-2.75-2.75z"/></g>
;

pub const sync: []const u8 =
    \\<path d="M21 10C21 10 18.995 7.26822 17.3662 5.63824C15.7373 4.00827 13.4864 3 11 3C6.02944 3 2 7.02944 2 12C2 16.9706 6.02944 21 11 21C15.1031 21 18.5649 18.2543 19.6482 14.5M21 10V4M21 10H15" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const table: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="1.5"/><path d="M3.5 10h17"/><path d="M3.5 14.75h17"/><path d="M12 10v9.5"/></g>
;

pub const tag: []const u8 =
    \\<path d="M2 12L11.6422 2.35783C11.8405 2.15953 11.9396 2.06038 12.0558 1.98697C12.1588 1.92191 12.2711 1.87276 12.389 1.84115C12.5221 1.80544 12.6631 1.80078 12.945 1.79148L18.2889 1.61571C19.0558 1.59043 19.4392 1.57779 19.7301 1.72C19.9853 1.84519 20.1927 2.04907 20.3223 2.30189C20.4694 2.58969 20.4632 2.97309 20.4507 3.73989L20.3508 9.0844C20.3457 9.36634 20.3432 9.50731 20.3113 9.64061C20.283 9.75858 20.2371 9.87138 20.1751 9.97537C20.105 10.0929 20.0088 10.1946 19.8165 10.3982L10.5 20M2 12L10.5 20M2 12L5 9M10.5 20L13 17" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const trash: []const u8 =
    \\<path d="M9 3H15M3 6H21M19 6L18.2987 16.5193C18.1935 18.0975 18.1409 18.8867 17.8 19.485C17.4999 20.0118 17.0472 20.4353 16.5017 20.6997C15.882 21 15.0911 21 13.5093 21H10.4907C8.90891 21 8.11803 21 7.49834 20.6997C6.95276 20.4353 6.50009 20.0118 6.19998 19.485C5.85911 18.8867 5.8065 18.0975 5.70129 16.5193L5 6M10 10.5V15.5M14 10.5V15.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const undo: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7.75 6.25L4 10l3.75 3.75"/><path d="M4 10h10.5a5.25 5.25 0 0 1 5.25 5.25v2.25"/></g>
;

pub const ungroup: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="2.75" y="5.25" width="15.5" height="16" rx="2.25" stroke-dasharray="3.25 2.5"/><rect x="11.75" y="2.75" width="9.5" height="9.5" rx="1.75"/></g>
;

pub const upload: []const u8 =
    \\<path d="M21 15V16.2C21 17.8802 21 18.7202 20.673 19.362C20.3854 19.9265 19.9265 20.3854 19.362 20.673C18.7202 21 17.8802 21 16.2 21H7.8C6.11984 21 5.27976 21 4.63803 20.673C4.07354 20.3854 3.6146 19.9265 3.32698 19.362C3 18.7202 3 17.8802 3 16.2V15M17 8L12 3M12 3L7 8M12 3V15" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const user: []const u8 =
    \\<path d="M20 21C20 19.6044 20 18.9067 19.8278 18.3389C19.44 17.0605 18.4395 16.06 17.1611 15.6722C16.5933 15.5 15.8956 15.5 14.5 15.5H9.5C8.10444 15.5 7.40665 15.5 6.83886 15.6722C5.56045 16.06 4.56004 17.0605 4.17224 18.3389C4 18.9067 4 19.6044 4 21M16.5 7.5C16.5 9.98528 14.4853 12 12 12C9.51472 12 7.5 9.98528 7.5 7.5C7.5 5.01472 9.51472 3 12 3C14.4853 3 16.5 5.01472 16.5 7.5Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const users: []const u8 =
    \\<path d="M16 3.46776C17.4817 4.20411 18.5 5.73314 18.5 7.5C18.5 9.26686 17.4817 10.7959 16 11.5322M18 16.7664C19.5115 17.4503 20.8725 18.565 22 20M2 20C3.94649 17.5226 6.58918 16 9.5 16C12.4108 16 15.0535 17.5226 17 20M14 7.5C14 9.98528 11.9853 12 9.5 12C7.01472 12 5 9.98528 5 7.5C5 5.01472 7.01472 3 9.5 3C11.9853 3 14 5.01472 14 7.5Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const verse: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M19.5 4.5c-6 .75-10 4.5-11.25 10.5L6 19.5"/><path d="M8.5 14.5c3.5-.5 7.5-2.5 9.5-6.5"/></g>
;

pub const video: []const u8 =
    \\<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/></g><path d="M10.25 9.25l4.75 2.75-4.75 2.75z" fill="currentColor" stroke="none"/>
;

pub const x_close: []const u8 =
    \\<path d="M18 6L6 18M6 6l12 12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
;

pub fn get(name: Name) []const u8 {
    const values = comptime blk: {
        const fields = @typeInfo(Name).@"enum".fields;
        var result: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, index| result[index] = @field(@This(), field.name);
        break :blk result;
    };
    return values[@intFromEnum(name)];
}
};

pub const alert = struct {

/// Alert — status message box.
///
/// Usage:
///   <Alert variant=.destructive>Something went wrong.</Alert>
///   <Alert variant=.warning>Unsaved changes.</Alert>
pub const Variant = enum { destructive, warning, success, info };
pub const AlertProps = struct {
    variant: Variant = .info,
    class: []const u8 = "",
    children: []const u8 = "",
};
pub fn Alert(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AlertProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AlertProps, _props);
    const base_class = switch (props.variant) {
        .destructive => "rounded-lg border border-destructive/50 bg-destructive/10 p-3 text-sm text-destructive",
        .warning => "rounded-lg border border-warning/50 bg-warning/10 p-3 text-sm text-warning",
        .success => "rounded-lg border border-success/50 bg-success/10 p-3 text-sm text-success",
        .info => "rounded-lg border border-border bg-muted p-3 text-sm text-foreground",
    };
    try writer.writeAll("<div data-publr-component=\"alert\" role=\"alert\" class=\"");
    try writer.writeAll(base_class);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

};

pub const avatar = struct {

/// Avatar — user identity with image, initials fallback, badge, and grouping.
///
/// Sub-components matching shadcn API:
///   - Avatar: outer container (size)
///   - AvatarImage: `<img>` element (absolute, covers fallback)
///   - AvatarFallback: initials shown when no image
///   - AvatarBadge: small status indicator positioned on the avatar
///   - AvatarGroup: container that overlaps children with ring dividers (via CSS)
///   - AvatarGroupCount: "+N" overflow count
///
/// Usage:
///   <Avatar size=.md>
///       <AvatarImage src="/img/olivia.jpg" alt="Olivia" />
///       <AvatarFallback>OM</AvatarFallback>
///   </Avatar>
///
///   <Avatar size=.md>
///       <AvatarFallback>OM</AvatarFallback>
///       <AvatarBadge />
///   </Avatar>
///
///   <AvatarGroup>
///       <Avatar size=.sm><AvatarFallback>OM</AvatarFallback></Avatar>
///       <Avatar size=.sm><AvatarFallback>JL</AvatarFallback></Avatar>
///       <AvatarGroupCount size=.sm count="3" />
///   </AvatarGroup>
pub const Size = enum { xs, sm, default, lg };
pub const FallbackVariant = enum { default, primary, secondary };
// ── Components (shadcn API) ─────────────────────────
pub const AvatarProps = struct {
    size: Size = .default,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Avatar(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AvatarProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarProps, _props);
    const dimensions = if (props.size == .xs) "h-4 w-4 text-3xs"
        else if (props.size == .sm) "h-8 w-8 text-xs"
        else if (props.size == .lg) "h-14 w-14 text-lg"
        else "h-10 w-10 text-sm";
    try writer.writeAll("<span data-publr-component=\"avatar\" data-publr-size=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\" class=\"relative inline-flex items-center justify-center rounded-full shrink-0 ");
    try writer.writeAll(dimensions);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const AvatarImageProps = struct {
    src: []const u8 = "",
    alt: []const u8 = "",
    class: []const u8 = "",
};
pub fn AvatarImage(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AvatarImageProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarImageProps, _props);
    try writer.writeAll("<img data-publr-part=\"image\" src=\"");
    try runtime.render(writer, props.src);
    try writer.writeAll("\" alt=\"");
    try runtime.render(writer, props.alt);
    try writer.writeAll("\" class=\"absolute inset-0 h-full w-full rounded-full object-cover ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">");
        }
    }.b);
}

pub const AvatarFallbackProps = struct {
    variant: FallbackVariant = .default,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn AvatarFallback(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AvatarFallbackProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarFallbackProps, _props);
    const surface = switch (props.variant) {
        .default => "bg-muted text-muted-foreground ring-1 ring-inset ring-border",
        .primary => "bg-primary text-primary-foreground ring-1 ring-inset ring-primary/20",
        .secondary => "bg-review/15 text-review ring-1 ring-inset ring-review/30",
    };
    try writer.writeAll("<span data-publr-part=\"fallback\" data-publr-variant=\"");
    try runtime.render(writer, props.variant);
    try writer.writeAll("\" class=\"flex h-full w-full items-center justify-center rounded-full font-semibold uppercase ");
    try writer.writeAll(surface);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const AvatarBadgeProps = struct {
    class: []const u8 = "",
};
pub fn AvatarBadge(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AvatarBadgeProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarBadgeProps, _props);
    try writer.writeAll("<span data-publr-part=\"badge\" class=\"absolute bottom-0 right-0 h-3 w-3 rounded-full border-2 border-background bg-success ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"></span>");
        }
    }.b);
}

pub const AvatarGroupProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn AvatarGroup(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AvatarGroupProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarGroupProps, _props);
    try writer.writeAll("<div data-publr-component=\"avatar-group\" class=\"flex -space-x-2 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const AvatarGroupCountProps = struct {
    count: []const u8 = "0",
    size: Size = .default,
    class: []const u8 = "",
};
pub fn AvatarGroupCount(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AvatarGroupCountProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarGroupCountProps, _props);
    const dimensions = if (props.size == .sm) "h-8 w-8 text-3xs"
        else if (props.size == .lg) "h-14 w-14 text-sm"
        else "h-10 w-10 text-xs";
    try writer.writeAll("<span data-publr-part=\"count\" class=\"relative inline-flex items-center justify-center rounded-full border-2 border-background bg-muted font-medium text-muted-foreground ");
    try writer.writeAll(dimensions);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n        +");
    try runtime.render(writer, props.count);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

// ── Gallery Demo (separate from component API) ──────
// Props are forwarded to sub-components. The gallery groups them
// by sub-component in the tree panel via manifest.sub_components.
pub const AvatarDemoProps = struct {
    // Demo selector
    demo: enum { fallback, with_image, with_badge, group } = .fallback,
    // Avatar props
    size: Size = .default,
    // AvatarImage props
    src: []const u8 = "",
    alt: []const u8 = "",
    // AvatarFallback props
    fallback: []const u8 = "",
    // Group: per-item props
    src_1: []const u8 = "",
    alt_1: []const u8 = "",
    fallback_1: []const u8 = "",
    src_2: []const u8 = "",
    alt_2: []const u8 = "",
    fallback_2: []const u8 = "",
    src_3: []const u8 = "",
    alt_3: []const u8 = "",
    fallback_3: []const u8 = "",
    // AvatarGroupCount props
    count: []const u8 = "",
};
pub fn AvatarDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(AvatarDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarDemoProps, _props);
    if (props.demo == .fallback) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try runtime.render(_children_w_1, props.fallback);
                try AvatarFallback(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Avatar(writer, .{ .size = props.size, .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_image) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try AvatarImage(_children_w_0, .{ .src = props.src,  .alt = props.alt });
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try runtime.render(_children_w_1, props.fallback);
                try AvatarFallback(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Avatar(writer, .{ .size = props.size, .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_badge) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try runtime.render(_children_w_1, props.fallback);
                try AvatarFallback(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try AvatarBadge(_children_w_0, .{ });
            try _children_w_0.writeAll("\n");
            try Avatar(writer, .{ .size = props.size, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.fallback_1);
                    try AvatarFallback(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try Avatar(_children_w_0, .{ .size = props.size, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.fallback_2);
                    try AvatarFallback(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try Avatar(_children_w_0, .{ .size = props.size, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.fallback_3);
                    try AvatarFallback(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try Avatar(_children_w_0, .{ .size = props.size, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try AvatarGroupCount(_children_w_0, .{ .size = props.size,  .count = props.count });
            try _children_w_0.writeAll("\n");
            try AvatarGroup(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const badge = struct {

/// Badge — status indicator label.
///
/// Renders a `<span>` with semantic-token classes. Used for status tags,
/// labels, counts, and chips.
///
/// Color variants: gray (default), brand, info, error, warning, success.
/// Each maps to a subtle 10%-opacity background, full-strength text,
/// and 30%-opacity ring. `info` uses the blue scale (blue-50/700/200)
/// for muted informational tags ("Beta", "New") — visually distinct from
/// `brand` (which is the saturated primary).
///
/// Type variants:
///   - pill: rounded-full (default)
///   - badge: rounded-md (sm/md), rounded-lg (lg)
///
/// Sizes: sm, md, lg.
///
/// Optional content slots:
///   - `icon` — leading icon (16px)
///   - `icon_trailing` — trailing icon
///   - `show_dot` — leading 8px dot indicator
///   - `closable` — trailing close X (visual only; consumer wires events)
///   - `avatar_src` / `avatar_alt` — leading 16px avatar (composes Avatar)
///   - empty `label` + an icon → icon-only badge
///
/// Example:
///   <Badge label="Published" color=.success />
///   <Badge label="Draft" type=.badge color=.gray show_dot={true} />
///   <Badge label="Filter" closable={true} aria_label="Remove filter" />
///   <Badge label="Olivia" avatar_src="/img/olivia.jpg" avatar_alt="Olivia" />
pub const Icon = root.icon.Icon;
pub const IconName = root.icon.Name;
pub const Avatar = root.avatar.Avatar;
pub const AvatarImage = root.avatar.AvatarImage;
// Color enum — preferred prop name. `Variant` is a legacy alias kept so older
// callers (passing `variant=`) keep compiling. `default`, `outline`, and
// `destructive` are deprecated names mapped to their semantic equivalents.
pub const Color = enum {
    gray, secondary, brand, info, @"error", warning, success, review,
    // Legacy aliases — keep for backward compatibility.
    default, outline, destructive,
};
pub const Variant = Color;
pub const Type = enum { pill, badge };
pub const Size = enum { sm, md, lg };
pub const BadgeProps = struct {
    label: []const u8 = "",
    color: Color = .gray,
    variant: Color = .gray,
    type: Type = .pill,
    size: Size = .md,
    icon: ?IconName = null,
    icon_trailing: ?IconName = null,
    show_dot: bool = false,
    closable: bool = false,
    avatar_src: []const u8 = "",
    avatar_alt: []const u8 = "",
    aria_label: ?[]const u8 = null,
    class: []const u8 = "",
};
pub fn Badge(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BadgeProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BadgeProps, _props);
    const has_label = props.label.len > 0;
    const has_avatar = props.avatar_src.len > 0;
    const has_leading = props.icon != null or props.show_dot or has_avatar;
    const has_trailing = props.icon_trailing != null or props.closable;
    const is_icon_only = !has_label and !has_avatar and !props.show_dot and (props.icon != null or props.icon_trailing != null);

    const base = "inline-flex items-center font-medium ring-1 ring-inset whitespace-nowrap";

    const shape = if (props.type == .pill) "rounded-full" else switch (props.size) {
        .sm, .md => "rounded-md",
        .lg => "rounded-lg",
    };

    const text_size = switch (props.size) {
        .sm => "text-xs",
        .md, .lg => "text-sm",
    };

    const padding = if (is_icon_only) switch (props.size) {
        .sm => "p-1",
        .md => "p-1.5",
        .lg => "p-2",
    } else switch (props.size) {
        .sm => if (has_leading and has_trailing) "gap-1 py-0.5 px-1.5"
            else if (has_leading) "gap-1 py-0.5 pl-1.5 pr-2"
            else if (has_trailing) "gap-1 py-0.5 pl-2 pr-1.5"
            else "py-0.5 px-2",
        .md => if (has_leading and has_trailing) "gap-1 py-0.5 px-2"
            else if (has_leading) "gap-1.5 py-0.5 pl-2 pr-2.5"
            else if (has_trailing) "gap-1 py-0.5 pl-2.5 pr-2"
            else "py-0.5 px-2.5",
        .lg => if (has_leading and has_trailing) "gap-1.5 py-1 px-2.5"
            else if (has_leading) "gap-1.5 py-1 pl-2.5 pr-3"
            else if (has_trailing) "gap-1 py-1 pl-3 pr-2.5"
            else "py-1 px-3",
    };

    // Resolve the effective color: callers may pass `variant=` (legacy) or
    // `color=` (preferred). When both default to .gray, fall through; otherwise
    // an explicit non-gray value on either prop wins.
    const effective: Color = if (props.variant != .gray) props.variant else props.color;

    const color_classes = switch (effective) {
        .gray, .default => "bg-muted text-foreground ring-border",
        .secondary, .outline => "bg-card text-muted-foreground ring-border",
        .brand => "bg-primary/10 text-primary ring-primary/30",
        .info => "bg-blue-50 text-blue-700 ring-blue-200",
        .@"error", .destructive => "bg-error/10 text-error ring-error/30",
        .warning => "bg-warning/10 text-warning ring-warning/30",
        .success => "bg-success/10 text-success ring-success/30",
        .review => "bg-review/10 text-review ring-review/30",
    };

    const accent_class = switch (effective) {
        .gray, .default => "text-muted-foreground",
        .secondary, .outline => "text-muted-foreground",
        .brand => "text-primary",
        .info => "text-blue-700",
        .@"error", .destructive => "text-error",
        .warning => "text-warning",
        .success => "text-success",
        .review => "text-review",
    };

    const dot_size: u16 = 8;
    const icon_size: u16 = if (props.size == .lg) 14 else 12;
    try writer.writeAll("<span data-publr-component=\"badge\" data-publr-color=\"");
    try runtime.render(writer, props.color);
    try writer.writeAll("\" data-publr-size=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\" data-publr-type=\"");
    try runtime.render(writer, props.type);
    try writer.writeAll("\" aria-label=\"");
    try runtime.render(writer, props.aria_label);
    try writer.writeAll("\" class=\"");
    try writer.writeAll(base);
    try writer.writeAll(" ");
    try writer.writeAll(shape);
    try writer.writeAll(" ");
    try writer.writeAll(text_size);
    try writer.writeAll(" ");
    try writer.writeAll(padding);
    try writer.writeAll(" ");
    try writer.writeAll(color_classes);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    if (props.show_dot) {
        try Icon(writer, .{ .name = .dot_filled,  .size = dot_size,  .class = runtime.concatRt(&.{ "shrink-0 ", accent_class }) });
    } else if (has_avatar) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try AvatarImage(_children_w_0, .{ .src = props.avatar_src,  .alt = props.avatar_alt });
            try _children_w_0.writeAll("\n");
            try Avatar(writer, .{ .size = .xs, .children = _children_buf_0.items });
        }
    } else if (props.icon != null and !is_icon_only) {
        try Icon(writer, .{ .name = props.icon.?,  .size = icon_size,  .class = runtime.concatRt(&.{ "shrink-0 ", accent_class }) });
    }
    try writer.writeAll("\n");
    if (has_label) {
        try writer.writeAll("<span class=\"empty:hidden\">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>");
    }
    try writer.writeAll("\n");
    if (props.icon_trailing != null and !is_icon_only) {
        try Icon(writer, .{ .name = props.icon_trailing.?,  .size = icon_size,  .class = runtime.concatRt(&.{ "shrink-0 ", accent_class }) });
    }
    try writer.writeAll("\n");
    if (props.closable) {
        try writer.writeAll("<button type=\"button\" aria-label=\"Remove\" class=\"flex cursor-pointer items-center justify-center rounded-sm p-0.5 transition duration-100 ease-linear hover:bg-foreground/10 ");
        try writer.writeAll(accent_class);
        try writer.writeAll("\">\n");
        try Icon(writer, .{ .name = .x_close,  .size = 12,  .class = "shrink-0" });
        try writer.writeAll("\n</button>");
    }
    try writer.writeAll("\n");
    if (is_icon_only and props.icon != null) {
        try Icon(writer, .{ .name = props.icon.?,  .size = icon_size,  .class = runtime.concatRt(&.{ "shrink-0 ", accent_class }) });
    }
    try writer.writeAll("\n");
    if (is_icon_only and props.icon == null and props.icon_trailing != null) {
        try Icon(writer, .{ .name = props.icon_trailing.?,  .size = icon_size,  .class = runtime.concatRt(&.{ "shrink-0 ", accent_class }) });
    }
    try writer.writeAll("\n</span>");
        }
    }.b);
}

};

pub const breadcrumbs = struct {

/// Breadcrumbs — navigation trail.
///
/// Composable sub-components:
///   - Breadcrumb: outer `<nav>` with aria-label
///   - BreadcrumbList: `<ol>` container
///   - BreadcrumbItem: `<li>` wrapper
///   - BreadcrumbLink: clickable link
///   - BreadcrumbPage: current page (not a link)
///   - BreadcrumbSeparator: separator between items (default: chevron icon)
///   - BreadcrumbEllipsis: "..." for collapsed middle items
///
/// Usage:
///   <Breadcrumb>
///       <BreadcrumbList>
///           <BreadcrumbItem><BreadcrumbLink href="/">Home</BreadcrumbLink></BreadcrumbItem>
///           <BreadcrumbSeparator />
///           <BreadcrumbItem><BreadcrumbPage>Profile</BreadcrumbPage></BreadcrumbItem>
///       </BreadcrumbList>
///   </Breadcrumb>
pub const Icon = root.icon.Icon;
pub const Flex = root.flex.Flex;
// ── Sub-components ──────────────────────────────────
pub const BreadcrumbProps = struct {
    children: []const u8 = "",
};
pub fn Breadcrumb(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbProps, _props);
    try writer.writeAll("<nav data-publr-component=\"breadcrumbs\" aria-label=\"Breadcrumb\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</nav>");
        }
    }.b);
}

pub const BreadcrumbListProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn BreadcrumbList(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbListProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbListProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .as = .ol,  .items = .center,  .gap = .none,  .wrap = .wrap,  .class = runtime.concatRt(&.{ "gap-2 list-none p-0 m-0 text-xs ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const BreadcrumbItemProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn BreadcrumbItem(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbItemProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbItemProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .as = .li,  .display = .inline_flex,  .items = .center,  .gap = .none,  .class = runtime.concatRt(&.{ "gap-2 ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const BreadcrumbLinkProps = struct {
    href: []const u8 = "#",
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn BreadcrumbLink(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbLinkProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbLinkProps, _props);
    try writer.writeAll("<a href=\"");
    try runtime.render(writer, props.href);
    try writer.writeAll("\" class=\"truncate text-xs font-medium text-primary transition-colors hover:text-primary/80 hover:underline focus-visible:rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</a>");
        }
    }.b);
}

pub const BreadcrumbPageProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn BreadcrumbPage(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbPageProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbPageProps, _props);
    try writer.writeAll("<span aria-current=\"page\" class=\"text-xs font-medium text-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const BreadcrumbSeparatorProps = struct {
    class: []const u8 = "",
};
pub fn BreadcrumbSeparator(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbSeparatorProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbSeparatorProps, _props);
    try writer.writeAll("<li role=\"presentation\" aria-hidden=\"true\" class=\"text-border ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">/</li>");
        }
    }.b);
}

pub const BreadcrumbEllipsisProps = struct {
    class: []const u8 = "",
};
pub fn BreadcrumbEllipsis(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbEllipsisProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbEllipsisProps, _props);
    try writer.writeAll("<li class=\"text-xs text-muted-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">...</li>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const BreadcrumbsDemoProps = struct {
    demo: enum { two_level, three_level, four_level, with_ellipsis } = .three_level,
    // BreadcrumbLink props per item
    link_1: []const u8 = "",
    href_1: []const u8 = "",
    link_2: []const u8 = "",
    href_2: []const u8 = "",
    link_3: []const u8 = "",
    href_3: []const u8 = "",
    // BreadcrumbPage
    page: []const u8 = "",
};
pub fn BreadcrumbsDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BreadcrumbsDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbsDemoProps, _props);
    if (props.demo == .two_level) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_1);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.page);
                        try BreadcrumbPage(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbList(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .three_level) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_1);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_2);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_2, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.page);
                        try BreadcrumbPage(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbList(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .four_level) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_1);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_2);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_2, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_3);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_3, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.page);
                        try BreadcrumbPage(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbList(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_1);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try BreadcrumbEllipsis(_children_w_2, .{ });
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.link_2);
                        try BreadcrumbLink(_children_w_2, .{ .href = props.href_2, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.page);
                        try BreadcrumbPage(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try BreadcrumbList(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const bulk_actions = struct {

/// BulkActions — bulk-select action bar for selection-capable lists.
///
/// Sibling composite to `Table` (or any other selection-capable list).
/// Renders a flat-bordered bar above the list with a selected count, action
/// buttons, optional separators, and a trailing clear button. The list
/// directly below should drop its top border-radius (consumer applies
/// `class="rounded-t-none"` on Table) when this is visible — the bar's
/// `border-bottom: 0` and `rounded-t-lg` complete the join.
///
/// Sub-components:
///   - BulkActions: outer container; `count` (usize) + `visible` (bool)
///   - BulkActionsItem: action button with `icon` + `label` + `variant` (default | destructive) + `href`
///   - BulkActionsSeparator: vertical divider between item groups
///   - BulkActionsClear: trailing clear-selection button (`label` defaults to "Clear")
///
/// JS wiring (consumer responsibility): listen to row-checkbox changes, count
/// rows with `data-publr-state="selected"`, set `data-publr-state="visible"`
/// on the bar root + update `count` element. Kept out of the DS for now
/// because the selection lookup is list-specific.
///
/// Usage:
///   <BulkActions count={3} visible={true}>
///       <BulkActionsItem icon=.edit label="Edit" />
///       <BulkActionsItem icon=.copy label="Duplicate" />
///       <BulkActionsSeparator />
///       <BulkActionsItem icon=.trash label="Delete" variant=.destructive />
///       <BulkActionsClear />
///   </BulkActions>
///   <Table class="rounded-t-none">...</Table>
pub const Icon = root.icon.Icon;
pub const IconName = root.icon.Name;
// ── Sub-components ──────────────────────────────────
pub const BulkActionsProps = struct {
    count: usize = 0,
    visible: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn BulkActions(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BulkActionsProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BulkActionsProps, _props);
    const visibility_class = if (props.visible) "flex" else "hidden";
    const state = if (props.visible) "visible" else "hidden";
    try writer.writeAll("<div data-publr-component=\"bulk-actions\" data-publr-state=\"");
    try runtime.render(writer, state);
    try writer.writeAll("\" class=\"");
    try writer.writeAll(visibility_class);
    try writer.writeAll(" h-10 items-center gap-3 border-b border-border bg-primary/10 px-4 text-xs text-primary ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n<span data-publr-part=\"count\" class=\"text-xs font-semibold\">\n");
    try runtime.render(writer, props.count);
    try writer.writeAll("<span class=\"font-normal\">selected</span>\n</span>\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const ItemVariant = enum { default, destructive };
pub const BulkActionsItemProps = struct {
    label: []const u8 = "",
    icon: ?IconName = null,
    variant: ItemVariant = .default,
    href: []const u8 = "",
    disabled: bool = false,
    class: []const u8 = "",
};
pub fn BulkActionsItem(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BulkActionsItemProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BulkActionsItemProps, _props);
    const color = if (props.variant == .destructive) "text-destructive" else "text-primary";
    const item_class = "inline-flex items-center gap-1 rounded-sm text-xs font-semibold hover:underline cursor-pointer disabled:cursor-not-allowed disabled:opacity-50";
    const variant_attr = if (props.variant == .destructive) "destructive" else "default";
    const has_icon = props.icon != null;
    const is_link = props.href.len > 0;
    if (is_link) {
        try writer.writeAll("<a data-publr-part=\"item\" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(color);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = 13,  .class = "shrink-0" });
        }
        try writer.writeAll("\n");
        try runtime.render(writer, props.label);
        try writer.writeAll("\n</a>");
    } else if (props.disabled) {
        try writer.writeAll("<button type=\"button\" data-publr-part=\"item\" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(color);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = 13,  .class = "shrink-0" });
        }
        try writer.writeAll("\n");
        try runtime.render(writer, props.label);
        try writer.writeAll("\n</button>");
    } else {
        try writer.writeAll("<button type=\"button\" data-publr-part=\"item\" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(color);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = 13,  .class = "shrink-0" });
        }
        try writer.writeAll("\n");
        try runtime.render(writer, props.label);
        try writer.writeAll("\n</button>");
    }
        }
    }.b);
}

pub const BulkActionsSeparatorProps = struct {
    class: []const u8 = "",
};
pub fn BulkActionsSeparator(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BulkActionsSeparatorProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BulkActionsSeparatorProps, _props);
    try writer.writeAll("<span data-publr-part=\"separator\" class=\"w-px h-3.5 bg-border ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"></span>");
        }
    }.b);
}

pub const BulkActionsClearProps = struct {
    label: []const u8 = "Clear",
    class: []const u8 = "",
};
pub fn BulkActionsClear(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BulkActionsClearProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BulkActionsClearProps, _props);
    try writer.writeAll("<button type=\"button\" data-publr-part=\"clear\" class=\"ml-auto text-xs font-medium text-primary hover:underline cursor-pointer ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try runtime.render(writer, props.label);
    try writer.writeAll("\n</button>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const BulkActionsDemoProps = struct {
    demo: enum { basic, single, with_separator } = .basic,
};
pub fn BulkActionsDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(BulkActionsDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BulkActionsDemoProps, _props);
    if (props.demo == .single) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .edit,  .label = "Edit" });
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .trash,  .label = "Delete",  .variant = .destructive });
            try _children_w_0.writeAll("\n");
            try BulkActionsClear(_children_w_0, .{ });
            try _children_w_0.writeAll("\n");
            try BulkActions(writer, .{ .count = 1,  .visible = true, .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_separator) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .edit,  .label = "Edit" });
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .copy,  .label = "Duplicate" });
            try _children_w_0.writeAll("\n");
            try BulkActionsSeparator(_children_w_0, .{ });
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .trash,  .label = "Delete",  .variant = .destructive });
            try _children_w_0.writeAll("\n");
            try BulkActionsClear(_children_w_0, .{ });
            try _children_w_0.writeAll("\n");
            try BulkActions(writer, .{ .count = 3,  .visible = true, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .edit,  .label = "Edit" });
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .copy,  .label = "Duplicate" });
            try _children_w_0.writeAll("\n");
            try BulkActionsItem(_children_w_0, .{ .icon = .trash,  .label = "Delete",  .variant = .destructive });
            try _children_w_0.writeAll("\n");
            try BulkActionsClear(_children_w_0, .{ });
            try _children_w_0.writeAll("\n");
            try BulkActions(writer, .{ .count = 3,  .visible = true, .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const button = struct {

/// Button — primary action element.
///
/// Renders a `<button>` (or `<a>` when `href` is set) with semantic-token
/// classes selected by hierarchy, size, and state. Marked with
/// `data-publr-component="button"` for JS binding.
///
/// Hierarchy variants:
///   - primary: brand-action, solid background
///   - secondary: surface with input ring
///   - tertiary: transparent, hover surface
///   - link: brand-color text-only link
///   - link_gray: muted text-only link
///   - destructive: solid destructive (alias for primary destructive)
///   - secondary_destructive: surface with destructive ring
///   - tertiary_destructive: transparent, destructive on hover
///   - unstyled: no visual chrome — keeps button semantics + icon/label
///     slots + disabled behavior, all appearance driven by `class`
///
/// Size variants: xs, sm, md, lg, xl, xxl. Fixed heights (h-8 … h-14) with
/// square icon-only variants; gap and text size scale per size. Icons are
/// size-4 at xs/sm and size-5 from md up.
///
/// State data-attributes:
///   - data-loading="true" while loading (drives `data-[loading=true]:` utilities)
///   - data-icon-only="true" when no label is provided
///   - data-publr-state="loading|idle"
///
/// Example:
///   <Button hierarchy=.primary size=.md label="Save" />
///   <Button hierarchy=.destructive label="Delete" icon=.trash />
///   <Button hierarchy=.secondary icon=.settings aria_label="Settings" />
pub const Icon = root.icon.Icon;
pub const IconName = root.icon.Name;
pub const Hierarchy = enum {
    primary,
    secondary,
    tertiary,
    link,
    link_gray,
    destructive,
    secondary_destructive,
    tertiary_destructive,
    unstyled,
};
pub const Size = enum { xs, sm, md, lg, xl, xxl };
pub const Type = enum { button, submit, reset };
pub const ButtonProps = struct {
    label: []const u8 = "",
    hierarchy: Hierarchy = .primary,
    size: Size = .md,
    disabled: bool = false,
    loading: bool = false,
    button_type: Type = .button,
    icon: ?IconName = null,
    icon_trailing: ?IconName = null,
    href: []const u8 = "",
    id: []const u8 = "",
    full_width: bool = false,
    aria_label: ?[]const u8 = null,
    class: []const u8 = "",
};
pub fn Button(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(ButtonProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(ButtonProps, _props);
    const is_destructive = props.hierarchy == .destructive
        or props.hierarchy == .secondary_destructive
        or props.hierarchy == .tertiary_destructive;
    const is_link = props.hierarchy == .link or props.hierarchy == .link_gray;
    const is_unstyled = props.hierarchy == .unstyled;
    const has_label = props.label.len > 0;
    const is_icon_only = !has_label and (props.icon != null or props.icon_trailing != null);
    const is_disabled = props.disabled or props.loading;
    const is_anchor = props.href.len > 0;
    const has_id = props.id.len > 0;
    const state = if (props.loading) "loading" else "idle";

    const base = if (is_unstyled)
        "group inline-flex items-center cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
    else
        "group relative inline-flex cursor-pointer items-center whitespace-nowrap font-semibold transition duration-150 ease-out active:translate-y-px focus-visible:outline-2 focus-visible:outline-offset-2 disabled:cursor-not-allowed disabled:opacity-50";

    const justify = if (is_unstyled) "" else if (is_link) "justify-normal" else "justify-center";

    const outline = if (is_unstyled) "" else if (is_destructive) "outline-destructive" else "outline-ring";

    // Font size scales monotonically across every size — applied to all
    // variants including `unstyled`, so `size` always changes the type scale.
    const text_size = switch (props.size) {
        .xs => "text-xs",
        .sm => "text-sm",
        .md => "text-base",
        .lg => "text-lg",
        .xl => "text-xl",
        .xxl => "text-2xl",
    };

    // Padding / gap / radius chrome — omitted for `unstyled` (appearance-free).
    const size_classes = if (is_unstyled) "" else if (is_link) switch (props.size) {
        .xs => "gap-1 rounded",
        .sm => "gap-1 rounded",
        .md => "gap-1 rounded",
        .lg => "gap-1.5 rounded",
        .xl => "gap-1.5 rounded",
        .xxl => "gap-2 rounded",
    } else if (is_icon_only) switch (props.size) {
        .xs => "rounded-md size-8",
        .sm => "rounded-md size-9",
        .md => "rounded-lg size-10",
        .lg => "rounded-lg size-11",
        .xl => "rounded-lg size-12",
        .xxl => "rounded-xl size-14",
    } else switch (props.size) {
        .xs => "gap-1.5 rounded-md h-8 px-2.5",
        .sm => "gap-1.5 rounded-md h-9 px-3",
        .md => "gap-2 rounded-lg h-10 px-3.5",
        .lg => "gap-2 rounded-lg h-11 px-4",
        .xl => "gap-2 rounded-lg h-12 px-4.5",
        .xxl => "gap-2.5 rounded-xl h-14 px-5",
    };

    const hierarchy_classes = switch (props.hierarchy) {
        .primary =>
            "bg-primary text-primary-foreground shadow-xs ring-1 ring-transparent ring-inset " ++
            "hover:bg-primary/90 data-[loading=true]:bg-primary/90 " ++
            "before:pointer-events-none before:absolute before:inset-px before:rounded-md before:border before:border-white/10",
        .secondary =>
            "bg-background text-foreground shadow-xs ring-1 ring-input ring-inset " ++
            "hover:bg-accent hover:text-accent-foreground data-[loading=true]:bg-accent",
        .tertiary =>
            "text-muted-foreground hover:bg-accent hover:text-accent-foreground data-[loading=true]:bg-accent",
        .link =>
            "text-primary hover:text-primary/80",
        .link_gray =>
            "text-muted-foreground hover:text-foreground",
        .destructive =>
            "bg-destructive text-primary-foreground shadow-xs ring-1 ring-transparent ring-inset " ++
            "hover:bg-destructive/90 data-[loading=true]:bg-destructive/90 " ++
            "before:pointer-events-none before:absolute before:inset-px before:rounded-md before:border before:border-white/10",
        .secondary_destructive =>
            "bg-background text-destructive shadow-xs ring-1 ring-destructive/30 ring-inset " ++
            "hover:bg-destructive/10 data-[loading=true]:bg-destructive/10",
        .tertiary_destructive =>
            "text-destructive hover:bg-destructive/10 data-[loading=true]:bg-destructive/10",
        .unstyled => "",
    };

    // Icons scale with the button: size-4 at xs/sm, size-5 from md up.
    const small_icon = props.size == .xs or props.size == .sm;
    const icon_px: u16 = if (small_icon) 16 else 20;
    const spinner_class = if (small_icon)
        "size-4 shrink-0 animate-spin"
    else
        "size-5 shrink-0 animate-spin";
    const icon_class = if (small_icon) switch (props.hierarchy) {
        .primary, .destructive =>
            "size-4 shrink-0 group-hover:text-primary-foreground/80",
        .secondary, .tertiary =>
            "size-4 shrink-0 group-hover:text-foreground",
        .secondary_destructive, .tertiary_destructive =>
            "size-4 shrink-0",
        .link =>
            "size-4 shrink-0 group-hover:text-primary/80",
        .link_gray =>
            "size-4 shrink-0 group-hover:text-foreground",
        .unstyled =>
            "size-4 shrink-0",
    } else switch (props.hierarchy) {
        .primary, .destructive =>
            "size-5 shrink-0 group-hover:text-primary-foreground/80",
        .secondary, .tertiary =>
            "size-5 shrink-0 group-hover:text-foreground",
        .secondary_destructive, .tertiary_destructive =>
            "size-5 shrink-0",
        .link =>
            "size-5 shrink-0 group-hover:text-primary/80",
        .link_gray =>
            "size-5 shrink-0 group-hover:text-foreground",
        .unstyled =>
            "size-5 shrink-0",
    };

    const text_class = switch (props.hierarchy) {
        .link =>
            "px-0.5 underline decoration-transparent underline-offset-4 group-hover:decoration-current empty:hidden",
        .link_gray =>
            "px-0.5 underline decoration-transparent underline-offset-4 group-hover:decoration-current empty:hidden",
        .unstyled => "empty:hidden",
        else => "px-0.5 empty:hidden",
    };

    const width = if (props.full_width) "w-full" else "";
    if (is_anchor) {
        try writer.writeAll("<a data-publr-component=\"button\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" data-icon-only=\"");
        try runtime.render(writer, if (is_icon_only) "true" else null);
        try writer.writeAll("\" data-loading=\"");
        try runtime.render(writer, if (props.loading) "true" else null);
        try writer.writeAll("\" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" id=\"");
        try runtime.render(writer, if (has_id) props.id else null);
        try writer.writeAll("\" aria-label=\"");
        try runtime.render(writer, props.aria_label);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(justify);
        try writer.writeAll(" ");
        try writer.writeAll(outline);
        try writer.writeAll(" ");
        try writer.writeAll(size_classes);
        try writer.writeAll(" ");
        try writer.writeAll(text_size);
        try writer.writeAll(" ");
        try writer.writeAll(hierarchy_classes);
        try writer.writeAll(" ");
        try writer.writeAll(width);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        if (props.loading) {
            try Icon(writer, .{ .name = .sync,  .size = icon_px,  .class = spinner_class });
        } else if (props.icon != null) {
            try Icon(writer, .{ .name = props.icon.?,  .size = icon_px,  .class = icon_class });
        }
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<span data-text=\"true\" class=\"");
            try runtime.render(writer, text_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
        }
        try writer.writeAll("\n");
        if (props.icon_trailing != null and !props.loading) {
            try Icon(writer, .{ .name = props.icon_trailing.?,  .size = icon_px,  .class = icon_class });
        }
        try writer.writeAll("\n</a>");
    } else if (is_disabled) {
        try writer.writeAll("<button data-publr-component=\"button\" aria-disabled=\"true\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" data-icon-only=\"");
        try runtime.render(writer, if (is_icon_only) "true" else null);
        try writer.writeAll("\" data-loading=\"");
        try runtime.render(writer, if (props.loading) "true" else null);
        try writer.writeAll("\" type=\"");
        try runtime.render(writer, props.button_type);
        try writer.writeAll("\" id=\"");
        try runtime.render(writer, if (has_id) props.id else null);
        try writer.writeAll("\" aria-label=\"");
        try runtime.render(writer, props.aria_label);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(justify);
        try writer.writeAll(" ");
        try writer.writeAll(outline);
        try writer.writeAll(" ");
        try writer.writeAll(size_classes);
        try writer.writeAll(" ");
        try writer.writeAll(text_size);
        try writer.writeAll(" ");
        try writer.writeAll(hierarchy_classes);
        try writer.writeAll(" ");
        try writer.writeAll(width);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n");
        if (props.loading) {
            try Icon(writer, .{ .name = .sync,  .size = icon_px,  .class = spinner_class });
        } else if (props.icon != null) {
            try Icon(writer, .{ .name = props.icon.?,  .size = icon_px,  .class = icon_class });
        }
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<span data-text=\"true\" class=\"");
            try runtime.render(writer, text_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
        }
        try writer.writeAll("\n");
        if (props.icon_trailing != null and !props.loading) {
            try Icon(writer, .{ .name = props.icon_trailing.?,  .size = icon_px,  .class = icon_class });
        }
        try writer.writeAll("\n</button>");
    } else {
        try writer.writeAll("<button data-publr-component=\"button\" aria-disabled=\"false\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" data-icon-only=\"");
        try runtime.render(writer, if (is_icon_only) "true" else null);
        try writer.writeAll("\" data-loading=\"");
        try runtime.render(writer, if (props.loading) "true" else null);
        try writer.writeAll("\" type=\"");
        try runtime.render(writer, props.button_type);
        try writer.writeAll("\" id=\"");
        try runtime.render(writer, if (has_id) props.id else null);
        try writer.writeAll("\" aria-label=\"");
        try runtime.render(writer, props.aria_label);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(justify);
        try writer.writeAll(" ");
        try writer.writeAll(outline);
        try writer.writeAll(" ");
        try writer.writeAll(size_classes);
        try writer.writeAll(" ");
        try writer.writeAll(text_size);
        try writer.writeAll(" ");
        try writer.writeAll(hierarchy_classes);
        try writer.writeAll(" ");
        try writer.writeAll(width);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        if (props.icon != null) {
            try Icon(writer, .{ .name = props.icon.?,  .size = icon_px,  .class = icon_class });
        }
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<span data-text=\"true\" class=\"");
            try runtime.render(writer, text_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
        }
        try writer.writeAll("\n");
        if (props.icon_trailing != null) {
            try Icon(writer, .{ .name = props.icon_trailing.?,  .size = icon_px,  .class = icon_class });
        }
        try writer.writeAll("\n</button>");
    }
        }
    }.b);
}

};

pub const card = struct {

/// Card — elevated surface container.
///
/// Composable sub-components:
///   - Card: outer container with border, bg, shadow
///   - CardHeader: top section (composes Stack)
///   - CardTitle: heading text (composes Heading; exposes `level` pass-through)
///   - CardDescription: subtitle/helper text (composes Text)
///   - CardAction: top-right action slot (e.g., button, dropdown)
///   - CardContent: main body
///   - CardFooter: bottom section (composes Flex)
///
/// Stat-card composite (dashboard metric tiles):
///   - StatCard: outer container with stat-tuned padding
///   - StatCardLabel: small muted label (composes Text)
///   - StatCardValue: large bold number (composes Heading xxl)
///   - StatCardDelta: change indicator with `direction` prop (up/down/neutral)
///
/// Usage:
///   <Card>
///       <CardHeader>
///           <CardTitle>Account</CardTitle>
///           <CardDescription>Manage your settings.</CardDescription>
///       </CardHeader>
///       <CardContent>
///           <p>Your content here.</p>
///       </CardContent>
///       <CardFooter>
///           <Button label="Save" />
///       </CardFooter>
///   </Card>
///
///   <StatCard>
///       <StatCardLabel>Posts</StatCardLabel>
///       <StatCardValue>127</StatCardValue>
///       <StatCardDelta direction=.up>+8 this week</StatCardDelta>
///   </StatCard>
pub const Heading = root.heading.Heading;
pub const Text = root.text.Text;
pub const Stack = root.stack.Stack;
pub const Flex = root.flex.Flex;
pub const Level = enum { h1, h2, h3, h4, h5, h6 };
// ── Sub-components ──────────────────────────────────
pub const CardProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Card(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardProps, _props);
    try writer.writeAll("<div data-publr-component=\"card\" class=\"rounded-lg border border-border bg-card text-card-foreground shadow-sm ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const CardHeaderProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn CardHeader(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardHeaderProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardHeaderProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Stack(writer, .{ .gap = .none,  .padding = .xl,  .class = runtime.concatRt(&.{ "gap-1.5 pb-0 ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const CardTitleProps = struct {
    level: Level = .h3,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn CardTitle(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardTitleProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardTitleProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Heading(writer, .{ .level = props.level,  .size = .md,  .class = props.class, .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const CardDescriptionProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn CardDescription(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardDescriptionProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardDescriptionProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Text(writer, .{ .size = .sm,  .color = .muted,  .as = .p,  .class = props.class, .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const CardActionProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn CardAction(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardActionProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardActionProps, _props);
    try writer.writeAll("<div data-publr-part=\"action\" class=\"ml-auto ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const CardContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn CardContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" class=\"p-6 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const CardFooterProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn CardFooter(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardFooterProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardFooterProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .padding = .xl,  .class = runtime.concatRt(&.{ "pt-0 ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

// ── StatCard composite ──────────────────────────────
pub const Direction = enum { up, down, neutral };
pub const StatCardProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn StatCard(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(StatCardProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StatCardProps, _props);
    try writer.writeAll("<div data-publr-component=\"stat-card\" class=\"rounded-lg border border-border bg-card text-card-foreground shadow-sm p-4 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const StatCardLabelProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn StatCardLabel(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(StatCardLabelProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StatCardLabelProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Text(writer, .{ .size = .sm,  .color = .muted,  .weight = .medium,  .class = runtime.concatRt(&.{ "mb-1 ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const StatCardValueProps = struct {
    level: Level = .h3,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn StatCardValue(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(StatCardValueProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StatCardValueProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Heading(writer, .{ .level = props.level,  .size = .xxl,  .class = props.class, .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const StatCardDeltaProps = struct {
    direction: Direction = .neutral,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn StatCardDelta(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(StatCardDeltaProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StatCardDeltaProps, _props);
    if (props.direction == .up) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll(props.children);
            try Text(writer, .{ .size = .xs,  .color = .success,  .weight = .medium,  .class = runtime.concatRt(&.{ "mt-1 ", props.class }), .children = _children_buf_0.items });
        }
    } else if (props.direction == .down) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll(props.children);
            try Text(writer, .{ .size = .xs,  .color = .destructive,  .weight = .medium,  .class = runtime.concatRt(&.{ "mt-1 ", props.class }), .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll(props.children);
            try Text(writer, .{ .size = .xs,  .color = .muted,  .class = runtime.concatRt(&.{ "mt-1 ", props.class }), .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const CardDemoProps = struct {
    demo: enum { basic, with_description, with_footer, stats } = .basic,
    // CardTitle
    title: []const u8 = "",
    // CardDescription
    description: []const u8 = "",
    // CardContent
    content: []const u8 = "",
    // CardFooter
    footer: []const u8 = "",
};
pub fn CardDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CardDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.title);
                    try CardTitle(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try CardHeader(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("<p class=\"text-sm text-foreground\">");
                try runtime.render(_children_w_1, props.content);
                try _children_w_1.writeAll("</p>");
                try CardContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Card(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_description) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.title);
                    try CardTitle(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.description);
                    try CardDescription(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try CardHeader(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("<p class=\"text-sm text-foreground\">");
                try runtime.render(_children_w_1, props.content);
                try _children_w_1.writeAll("</p>");
                try CardContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Card(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_footer) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.title);
                    try CardTitle(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.description);
                    try CardDescription(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try CardHeader(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("<p class=\"text-sm text-foreground\">");
                try runtime.render(_children_w_1, props.content);
                try _children_w_1.writeAll("</p>");
                try CardContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(_children_w_1, props.footer);
                try _children_w_1.writeAll("</span>");
                try CardFooter(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Card(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("Posts");
                try StatCardLabel(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("127");
                try StatCardValue(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("+8 this week");
                try StatCardDelta(_children_w_0, .{ .direction = .up, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try StatCard(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const checkbox = struct {

/// Checkbox — toggle control for checked/unchecked state.
///
/// Renders a native `<input type="checkbox">` with styled indicator.
/// Compose with Field/FieldLabel for labeling, or use the built-in label prop.
///
/// No custom JS — native checkbox handles state.
///
/// Usage:
///   <Checkbox label="Accept terms" />
///   <Checkbox label="Subscribe" description="Get weekly updates" />
///   <Checkbox label="Disabled" disabled={true} />
///   <Checkbox label="Invalid" invalid={true} />
///   <Checkbox label="Checked" checked=.checked />
pub const CheckedState = enum { unchecked, checked, indeterminate };
pub const CheckboxProps = struct {
    label: []const u8 = "",
    description: []const u8 = "",
    name: []const u8 = "",
    id: []const u8 = "",
    value: []const u8 = "",
    checked: CheckedState = .unchecked,
    disabled: bool = false,
    invalid: bool = false,
    class: []const u8 = "",
};
pub fn Checkbox(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(CheckboxProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CheckboxProps, _props);
    const has_label = props.label.len > 0;
    const has_description = props.description.len > 0;
    const invalid_ring = if (props.invalid) "ring-1 ring-error" else "";
    const checkbox_class_base = "h-4 w-4 shrink-0 rounded border border-input bg-background text-primary accent-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50";
    const state = switch (props.checked) {
        .checked => "checked",
        .unchecked => "unchecked",
        .indeterminate => "indeterminate",
    };
    const is_checked = props.checked == .checked;
    const is_indeterminate = props.checked == .indeterminate;
    if (props.disabled and is_checked) {
        try writer.writeAll("<label data-p-store=\"local:checkbox\" data-publr-component=\"checkbox\" data-p-on=\"change:sync\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<input type=\"checkbox\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5\" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">\n<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>");
        }
        try writer.writeAll("\n</label>");
    } else if (props.disabled and is_indeterminate) {
        try writer.writeAll("<label data-p-store=\"local:checkbox\" data-publr-component=\"checkbox\" data-p-on=\"change:sync\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<input type=\"checkbox\" data-publr-indeterminate=\"true\" aria-checked=\"mixed\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">\n<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>");
        }
        try writer.writeAll("\n</label>");
    } else if (props.disabled) {
        try writer.writeAll("<label data-p-store=\"local:checkbox\" data-publr-component=\"checkbox\" data-p-on=\"change:sync\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<input type=\"checkbox\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">\n<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>");
        }
        try writer.writeAll("\n</label>");
    } else if (is_checked) {
        try writer.writeAll("<label data-p-store=\"local:checkbox\" data-publr-component=\"checkbox\" data-p-on=\"change:sync\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"flex items-start gap-2 cursor-pointer ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<input type=\"checkbox\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5\" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">\n<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>");
        }
        try writer.writeAll("\n</label>");
    } else if (is_indeterminate) {
        try writer.writeAll("<label data-p-store=\"local:checkbox\" data-publr-component=\"checkbox\" data-p-on=\"change:sync\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"flex items-start gap-2 cursor-pointer ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<input type=\"checkbox\" data-publr-indeterminate=\"true\" aria-checked=\"mixed\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">\n<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>");
        }
        try writer.writeAll("\n</label>");
    } else {
        try writer.writeAll("<label data-p-store=\"local:checkbox\" data-publr-component=\"checkbox\" data-p-on=\"change:sync\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"flex items-start gap-2 cursor-pointer ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<input type=\"checkbox\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">\n<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>");
        }
        try writer.writeAll("\n</label>");
    }
        }
    }.b);
}

};

pub const container = struct {

/// Container — max-width wrapper with padding.
///
/// Usage:
///   <Container size=.md>content</Container>
pub const ContainerSize = enum { sm, md, lg, xl, full };
pub const Padding = enum { none, sm, md, lg, xl };
pub const ContainerProps = struct {
    size: ContainerSize = .lg,
    padding: Padding = .lg,
    class: []const u8 = "",
    children: []const u8 = "",
};
pub fn Container(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(ContainerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(ContainerProps, _props);
    const base = "w-full mx-auto";

    const size_class = switch (props.size) {
        .sm => "max-w-lg",
        .md => "max-w-3xl",
        .lg => "max-w-5xl",
        .xl => "max-w-7xl",
        .full => "max-w-full",
    };

    const pad = switch (props.padding) {
        .none => "",
        .sm => "px-3 py-2",
        .md => "px-4 py-3",
        .lg => "px-6 py-4",
        .xl => "px-8 py-6",
    };
    try writer.writeAll("<div data-publr-component=\"container\" class=\"");
    try writer.writeAll(base);
    try writer.writeAll(" ");
    try writer.writeAll(size_class);
    try writer.writeAll(" ");
    try writer.writeAll(pad);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

};

pub const dialog = struct {

/// Dialog — modal overlay with focus trap.
///
/// Sub-components matching Radix Dialog API:
///   - Dialog: root container with state
///   - DialogTrigger: button that opens the dialog
///   - DialogOverlay: backdrop layer
///   - DialogContent: centered content panel
///   - DialogClose: button that closes the dialog
///   - DialogTitle: accessible heading (composes Heading; level pass-through)
///   - DialogDescription: accessible body text (composes Text)
///
/// Usage:
///   <Dialog>
///       <DialogTrigger><Button label="Open" /></DialogTrigger>
///       <DialogOverlay>
///           <DialogContent>
///               <DialogTitle>Are you sure?</DialogTitle>
///               <DialogDescription>This action cannot be undone.</DialogDescription>
///               <div class="flex justify-end gap-3 mt-6">
///                   <DialogClose><Button hierarchy=.secondary label="Cancel" /></DialogClose>
///                   <Button hierarchy=.destructive label="Delete" />
///               </div>
///           </DialogContent>
///       </DialogOverlay>
///   </Dialog>
pub const Button = root.button.Button;
pub const Heading = root.heading.Heading;
pub const Text = root.text.Text;
pub const Level = enum { h1, h2, h3, h4, h5, h6 };
// ── Sub-components ──────────────────────────────────
pub const DialogProps = struct {
    id: []const u8 = "",
    dismissable: bool = true,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Dialog(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogProps, _props);
    try writer.writeAll("<div data-p-store=\"local:dialog\" data-publr-component=\"dialog\" data-publr-state=\"closed\" data-publr-id=\"");
    try runtime.render(writer, props.id);
    try writer.writeAll("\" data-publr-dismissable=\"");
    try runtime.render(writer, if (props.dismissable) "true" else "false");
    try writer.writeAll("\" class=\"group inline-block ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

// Trigger is a non-button wrapper (a `<button>` here would nest inside the
// composed `<Button>` — invalid HTML the browser reparents, orphaning the real
// control). The click bubbles from the child Button to this span's handler; the
// span carries aria-expanded (mirrors the Popover trigger pattern).
pub const DialogTriggerProps = struct {
    children: []const u8 = "",
};
pub fn DialogTrigger(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogTriggerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogTriggerProps, _props);
    try writer.writeAll("<span class=\"inline-block\" data-publr-part=\"trigger\" aria-expanded=\"false\" aria-haspopup=\"dialog\" data-p-on=\"click:open\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const DialogOverlayProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DialogOverlay(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogOverlayProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogOverlayProps, _props);
    try writer.writeAll("<div data-publr-part=\"overlay\" data-p-on=\"click:overlayClick\" class=\"fixed inset-0 z-50 flex items-center justify-center bg-black/50 opacity-0 pointer-events-none transition-opacity group-data-[publr-state=open]:opacity-100 group-data-[publr-state=open]:pointer-events-auto ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const DialogContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DialogContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"publr-dialog-title\" aria-describedby=\"publr-dialog-description\" class=\"bg-popover text-popover-foreground rounded-lg p-6 max-w-md w-full mx-4 shadow-lg border border-border ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const DialogCloseProps = struct {
    children: []const u8 = "",
};
pub fn DialogClose(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogCloseProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogCloseProps, _props);
    try writer.writeAll("<span data-publr-part=\"close\" data-p-on=\"click:close\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

// DialogTitle and DialogDescription wrap the composed primitive in a thin
// element holding `data-publr-part` (queried by dialog.js) and the static
// `id` (overwritten at runtime by JS to a per-dialog unique id, but kept
// here so pre-JS-load AT references work).
pub const DialogTitleProps = struct {
    level: Level = .h3,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DialogTitle(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogTitleProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogTitleProps, _props);
    try writer.writeAll("<div data-publr-part=\"title\" id=\"publr-dialog-title\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Heading(writer, .{ .level = props.level,  .size = .md,  .class = props.class, .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const DialogDescriptionProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DialogDescription(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogDescriptionProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogDescriptionProps, _props);
    try writer.writeAll("<div data-publr-part=\"description\" id=\"publr-dialog-description\" class=\"mt-2\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Text(writer, .{ .size = .sm,  .color = .muted,  .as = .p,  .class = props.class, .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const DialogDemoProps = struct {
    demo: enum { confirm, destructive, info } = .confirm,
};
pub fn DialogDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DialogDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogDemoProps, _props);
    if (props.demo == .confirm) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = "Open dialog" });
                try DialogTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Save changes?");
                        try DialogTitle(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Your unsaved changes will be lost if you don't save them.");
                        try DialogDescription(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n<div class=\"flex justify-end gap-3 mt-6\">\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Button(_children_w_3, .{ .hierarchy = .secondary,  .label = "Cancel" });
                        try DialogClose(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n<span data-publr-part=\"confirm\" data-p-on=\"click:close\">");
                    try Button(_children_w_2, .{ .hierarchy = .primary,  .label = "Save" });
                    try _children_w_2.writeAll("</span>\n</div>\n");
                    try DialogContent(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DialogOverlay(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Dialog(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .destructive) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try Button(_children_w_1, .{ .hierarchy = .destructive,  .label = "Delete" });
                try DialogTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Delete item?");
                        try DialogTitle(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("This action cannot be undone. This will permanently delete the item.");
                        try DialogDescription(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n<div class=\"flex justify-end gap-3 mt-6\">\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Button(_children_w_3, .{ .hierarchy = .secondary,  .label = "Cancel" });
                        try DialogClose(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n<span data-publr-part=\"confirm\" data-p-on=\"click:close\">");
                    try Button(_children_w_2, .{ .hierarchy = .destructive,  .label = "Delete" });
                    try _children_w_2.writeAll("</span>\n</div>\n");
                    try DialogContent(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DialogOverlay(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Dialog(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = "Info" });
                try DialogTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Notice");
                        try DialogTitle(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Please read the terms and conditions before continuing.");
                        try DialogDescription(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n<div class=\"flex justify-end gap-3 mt-6\">\n<span data-publr-part=\"confirm\" data-p-on=\"click:close\">");
                    try Button(_children_w_2, .{ .hierarchy = .primary,  .label = "I understand" });
                    try _children_w_2.writeAll("</span>\n</div>\n");
                    try DialogContent(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DialogOverlay(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Dialog(writer, .{ .dismissable = false, .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const dropdown = struct {

/// DropdownMenu — action menu triggered by a button.
///
/// Sub-components matching shadcn API:
///   - DropdownMenu: root container with state
///   - DropdownMenuTrigger: element that opens the menu
///   - DropdownMenuContent: floating panel
///   - DropdownMenuGroup: logical grouping
///   - DropdownMenuLabel: non-interactive heading
///   - DropdownMenuItem: clickable action (variant: destructive)
///   - DropdownMenuSeparator: visual divider
///
/// Usage:
///   <DropdownMenu>
///       <DropdownMenuTrigger>
///           <Button label="Actions" icon=.chevron_down />
///       </DropdownMenuTrigger>
///       <DropdownMenuContent>
///           <DropdownMenuLabel>Actions</DropdownMenuLabel>
///           <DropdownMenuItem>Edit</DropdownMenuItem>
///           <DropdownMenuItem>Duplicate</DropdownMenuItem>
///           <DropdownMenuSeparator />
///           <DropdownMenuItem variant=.destructive>Delete</DropdownMenuItem>
///       </DropdownMenuContent>
///   </DropdownMenu>
pub const Button = root.button.Button;
pub const Icon = root.icon.Icon;
pub const IconName = root.icon.Name;
// ── Sub-components ──────────────────────────────────
pub const DropdownMenuProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DropdownMenu(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuProps, _props);
    try writer.writeAll("<div data-p-store=\"local:dropdown\" data-publr-component=\"dropdown\" class=\"relative inline-block ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

// PublrJS wire form of the trigger directives used in the default branch below
// (`onClick`→data-p-on, `:aria-expanded`→data-p-bind). In asChild mode these are
// spliced straight onto the caller's child via `runtime.slot`. Kept honest by the
// dropdown spec: if the transpiler's wire format ever drifts from this literal,
// the asChild demo stops opening and the behavior test fails.
//
// NOTE: the data-p-on handler separator is written `\x3b` (an escaped ';') on
// purpose — the ZSX transpiler's const passthrough splits statements on a raw
// ';' even inside a string literal, so a literal ';' here would truncate the
// value. Zig decodes `\x3b` back to ';' at compile time.
pub const trigger_fwd_attrs = " data-p-on=\"click:toggle\x3bkeydown.down:openMenu\" data-p-bind=\"aria-expanded:state.open\" aria-haspopup=\"menu\"";
pub const DropdownMenuTriggerProps = struct {
    as_child: bool = false,
    children: []const u8 = "",
};
pub fn DropdownMenuTrigger(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuTriggerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuTriggerProps, _props);
    // Radix `asChild`: when set, merge the trigger's behavior attributes straight
    // onto the caller's child element (a <Button>, an avatar button, …) with no
    // wrapper of our own — the child stays the real, focusable control. Otherwise
    // render a default `<div class="inline-block">` element carrying the handlers
    // (a <div> holds any child with no button-in-button parse break). Either way
    // the store anchors the menu to the root element and click/keydown bubble to
    // the handler-bearing node.
    if (props.as_child) {
        try writer.writeAll(runtime.slot(props.children, trigger_fwd_attrs));
    } else {
        try writer.writeAll("<div class=\"inline-block\" aria-haspopup=\"menu\" data-p-bind=\"aria-expanded:state.open\" data-p-on=\"click:toggle;keydown.down:openMenu\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</div>");
    }
        }
    }.b);
}

pub const DropdownMenuContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DropdownMenuContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" data-p-show=\"state.open\" role=\"menu\" data-p-on=\"keydown:navKeys;click:itemClick\" data-p-portal=\"");
    try runtime.render(writer, true);
    try writer.writeAll("\" class=\"hidden min-w-48 rounded-lg border border-border bg-popover p-1 text-popover-foreground shadow-lg ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const DropdownMenuGroupProps = struct {
    children: []const u8 = "",
};
pub fn DropdownMenuGroup(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuGroupProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuGroupProps, _props);
    try writer.writeAll("<div role=\"group\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
        }
    }.b);
}

pub const DropdownMenuLabelProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DropdownMenuLabel(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuLabelProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuLabelProps, _props);
    try writer.writeAll("<span data-publr-part=\"label\" class=\"block px-2 py-1.5 text-xs font-semibold text-muted-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const ItemVariant = enum { default, destructive };
pub const DropdownMenuShortcutProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DropdownMenuShortcut(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuShortcutProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuShortcutProps, _props);
    try writer.writeAll("<span data-publr-part=\"shortcut\" class=\"ml-auto font-mono text-[10px] text-muted-foreground tracking-wider px-1 py-px border border-border rounded-sm ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const DropdownMenuItemProps = struct {
    variant: ItemVariant = .default,
    disabled: bool = false,
    href: []const u8 = "",
    shortcut: []const u8 = "",
    icon: ?IconName = null,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn DropdownMenuItem(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuItemProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuItemProps, _props);
    const item_class = if (props.variant == .destructive)
        "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm text-destructive outline-none hover:bg-destructive/10 focus-visible:bg-destructive/10 disabled:pointer-events-none disabled:text-muted-foreground disabled:opacity-50"
    else
        "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm outline-none hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent focus-visible:text-accent-foreground disabled:pointer-events-none disabled:text-muted-foreground disabled:opacity-50";

    const variant_attr = if (props.variant == .destructive) "destructive" else "default";
    const state = if (props.disabled) "disabled" else "default";
    const is_link = props.href.len > 0;
    const has_shortcut = props.shortcut.len > 0;
    const has_icon = props.icon != null;
    // Icon color follows variant: destructive items get destructive-colored
    // icons; default items get muted icons (matches preview's `.item .ic`).
    const icon_color = if (props.variant == .destructive) "text-destructive" else "text-muted-foreground";
    if (is_link) {
        try writer.writeAll("<a data-publr-part=\"item\" role=\"menuitem\" tabindex=\"-1\" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = 14,  .class = runtime.concatRt(&.{ "shrink-0 ", icon_color }) });
        }
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        if (has_shortcut) {
            {
                var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_0 = @import("std").heap.page_allocator;
                defer _children_buf_0.deinit(_children_alloc_0);
                const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
                _ = &_children_w_0;
                try runtime.render(_children_w_0, props.shortcut);
                try DropdownMenuShortcut(writer, .{ .children = _children_buf_0.items });
            }
        }
        try writer.writeAll("\n</a>");
    } else if (props.disabled) {
        try writer.writeAll("<button data-publr-part=\"item\" role=\"menuitem\" tabindex=\"-1\" aria-disabled=\"true\" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = 14,  .class = runtime.concatRt(&.{ "shrink-0 ", icon_color }) });
        }
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        if (has_shortcut) {
            {
                var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_0 = @import("std").heap.page_allocator;
                defer _children_buf_0.deinit(_children_alloc_0);
                const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
                _ = &_children_w_0;
                try runtime.render(_children_w_0, props.shortcut);
                try DropdownMenuShortcut(writer, .{ .children = _children_buf_0.items });
            }
        }
        try writer.writeAll("\n</button>");
    } else {
        try writer.writeAll("<button data-publr-part=\"item\" role=\"menuitem\" tabindex=\"-1\" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = 14,  .class = runtime.concatRt(&.{ "shrink-0 ", icon_color }) });
        }
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        if (has_shortcut) {
            {
                var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_0 = @import("std").heap.page_allocator;
                defer _children_buf_0.deinit(_children_alloc_0);
                const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
                _ = &_children_w_0;
                try runtime.render(_children_w_0, props.shortcut);
                try DropdownMenuShortcut(writer, .{ .children = _children_buf_0.items });
            }
        }
        try writer.writeAll("\n</button>");
    }
        }
    }.b);
}

pub const DropdownMenuSeparatorProps = struct {
    class: []const u8 = "",
};
pub fn DropdownMenuSeparator(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownMenuSeparatorProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuSeparatorProps, _props);
    try writer.writeAll("<div data-publr-part=\"separator\" role=\"separator\" class=\"my-1 h-px bg-border ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"></div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const DropdownDemoProps = struct {
    demo: enum { basic, with_icons, destructive, as_child } = .basic,
};
pub fn DropdownDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(DropdownDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = "Actions",  .icon = .chevron_down,  .size = .sm });
                try _children_w_1.writeAll("\n");
                try DropdownMenuTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Actions");
                    try DropdownMenuLabel(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Edit");
                    try DropdownMenuItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Duplicate");
                    try DropdownMenuItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Archive");
                    try DropdownMenuItem(_children_w_1, .{ .disabled = true, .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DropdownMenuContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try DropdownMenu(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_icons) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = "Actions",  .icon = .chevron_down,  .size = .sm });
                try _children_w_1.writeAll("\n");
                try DropdownMenuTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Actions");
                    try DropdownMenuLabel(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try Icon(_children_w_2, .{ .name = .edit,  .size = 16,  .class = "" });
                    try _children_w_2.writeAll(" Edit");
                    try DropdownMenuItem(_children_w_1, .{ .shortcut = "⌘E", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try Icon(_children_w_2, .{ .name = .copy,  .size = 16,  .class = "" });
                    try _children_w_2.writeAll(" Duplicate");
                    try DropdownMenuItem(_children_w_1, .{ .shortcut = "⌘D",  .disabled = true, .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try Icon(_children_w_2, .{ .name = .bookmark,  .size = 16,  .class = "" });
                    try _children_w_2.writeAll(" Archive");
                    try DropdownMenuItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DropdownMenuContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try DropdownMenu(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .destructive) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = "Actions",  .icon = .chevron_down,  .size = .sm });
                try _children_w_1.writeAll("\n");
                try DropdownMenuTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Actions");
                    try DropdownMenuLabel(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try Icon(_children_w_2, .{ .name = .edit,  .size = 16,  .class = "" });
                    try _children_w_2.writeAll(" Edit");
                    try DropdownMenuItem(_children_w_1, .{ .shortcut = "⌘E", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try Icon(_children_w_2, .{ .name = .copy,  .size = 16,  .class = "" });
                    try _children_w_2.writeAll(" Duplicate");
                    try DropdownMenuItem(_children_w_1, .{ .shortcut = "⌘D", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DropdownMenuSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try Icon(_children_w_2, .{ .name = .trash,  .size = 16,  .class = "" });
                    try _children_w_2.writeAll(" Delete");
                    try DropdownMenuItem(_children_w_1, .{ .variant = .destructive,  .shortcut = "⌫", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DropdownMenuContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try DropdownMenu(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        // asChild: the Button IS the trigger — the handlers merge onto it, no
        // wrapper element of our own.
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = "Actions",  .icon = .chevron_down,  .size = .sm });
                try _children_w_1.writeAll("\n");
                try DropdownMenuTrigger(_children_w_0, .{ .as_child = true, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Actions");
                    try DropdownMenuLabel(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Edit");
                    try DropdownMenuItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Duplicate");
                    try DropdownMenuItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Archive");
                    try DropdownMenuItem(_children_w_1, .{ .disabled = true, .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try DropdownMenuContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try DropdownMenu(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const empty = struct {

/// Empty — zero-data placeholder.
///
/// Sub-components matching shadcn API:
///   - Empty: outer container
///   - EmptyMedia: icon/illustration area (variant: default or icon)
///   - EmptyTitle: heading
///   - EmptyDescription: body text
///   - EmptyContent: action area (buttons, links)
///
/// Usage:
///   <Empty>
///       <EmptyMedia variant=.icon>
///           <Icon name=.folder size={24} class="text-muted-foreground" />
///       </EmptyMedia>
///       <EmptyTitle>No posts yet</EmptyTitle>
///       <EmptyDescription>Create your first post to get started.</EmptyDescription>
///       <EmptyContent><Button label="Create Post" /></EmptyContent>
///   </Empty>
pub const Icon = root.icon.Icon;
pub const Button = root.button.Button;
pub const Heading = root.heading.Heading;
pub const Text = root.text.Text;
pub const Stack = root.stack.Stack;
pub const Level = enum { h1, h2, h3, h4, h5, h6 };
// ── Sub-components ──────────────────────────────────
// Empty wraps a <Stack> inside a thin <div> that holds `data-publr-component`.
// gap=.none preserves original behavior (children rely on their own mb-4/mt-1
// margins for spacing rather than parent gap).
pub const EmptyProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Empty(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(EmptyProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyProps, _props);
    try writer.writeAll("<div data-publr-component=\"empty\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Stack(writer, .{ .items = .center,  .justify = .center,  .gap = .none,  .class = runtime.concatRt(&.{ "py-12 px-4 text-center ", props.class }), .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const EmptyMediaProps = struct {
    variant: enum { default, icon } = .default,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn EmptyMedia(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(EmptyMediaProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyMediaProps, _props);
    const wrapper_class = if (props.variant == .icon) "rounded-full bg-muted p-3 mb-4" else "mb-4";
    try writer.writeAll("<div data-publr-part=\"media\" class=\"");
    try writer.writeAll(wrapper_class);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const EmptyTitleProps = struct {
    level: Level = .h3,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn EmptyTitle(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(EmptyTitleProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyTitleProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Heading(writer, .{ .level = props.level,  .size = .xs,  .class = props.class, .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const EmptyDescriptionProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn EmptyDescription(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(EmptyDescriptionProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyDescriptionProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Text(writer, .{ .size = .xs,  .color = .muted,  .as = .p,  .class = runtime.concatRt(&.{ "mt-1 max-w-sm leading-5 ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const EmptyContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn EmptyContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(EmptyContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" class=\"mt-4 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const EmptyDemoProps = struct {
    demo: enum { with_action, without_action } = .with_action,
    // EmptyTitle
    title: []const u8 = "",
    // EmptyDescription
    description: []const u8 = "",
    // Button label in EmptyContent
    action_label: []const u8 = "",
};
pub fn EmptyDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(EmptyDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyDemoProps, _props);
    if (props.demo == .with_action) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Icon(_children_w_1, .{ .name = .folder,  .size = 24,  .class = "text-muted-foreground" });
                try _children_w_1.writeAll("\n");
                try EmptyMedia(_children_w_0, .{ .variant = .icon, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try runtime.render(_children_w_1, props.title);
                try EmptyTitle(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try runtime.render(_children_w_1, props.description);
                try EmptyDescription(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Button(_children_w_1, .{ .hierarchy = .primary,  .label = props.action_label });
                try _children_w_1.writeAll("\n");
                try EmptyContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Empty(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Icon(_children_w_1, .{ .name = .search,  .size = 24,  .class = "text-muted-foreground" });
                try _children_w_1.writeAll("\n");
                try EmptyMedia(_children_w_0, .{ .variant = .icon, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try runtime.render(_children_w_1, props.title);
                try EmptyTitle(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try runtime.render(_children_w_1, props.description);
                try EmptyDescription(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Empty(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const form_field = struct {

/// Field — accessible form field layout system.
///
/// Sub-components matching shadcn API:
///   - FieldSet: semantic fieldset wrapper
///   - FieldLegend: legend for fieldset (variant: legend/label)
///   - FieldGroup: stacks Field components
///   - Field: core wrapper for a single field (orientation: vertical/horizontal)
///   - FieldContent: flex column for label + description beside control
///   - FieldLabel: styled label element
///   - FieldDescription: helper text
///   - FieldSeparator: visual divider
///   - FieldError: error message container
///
/// Usage:
///   <Field>
///       <FieldLabel>Email</FieldLabel>
///       <Input type=.email placeholder="you@example.com" />
///       <FieldDescription>We'll never share your email.</FieldDescription>
///   </Field>
pub const Text = root.text.Text;
pub const Label = root.label.Label;
pub const Stack = root.stack.Stack;
pub const Separator = root.separator.Separator;
// ── Sub-components ──────────────────────────────────
pub const FieldSetProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldSet(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldSetProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldSetProps, _props);
    try writer.writeAll("<fieldset data-publr-component=\"field-set\" class=\"space-y-6 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</fieldset>");
        }
    }.b);
}

pub const LegendVariant = enum { legend, label };
pub const FieldLegendProps = struct {
    variant: LegendVariant = .legend,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldLegend(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldLegendProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldLegendProps, _props);
    if (props.variant == .label) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try _children_w_0.writeAll(props.children);
            try _children_w_0.writeAll("\n");
            try Text(writer, .{ .as = .legend,  .size = .sm,  .weight = .medium,  .class = props.class, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try _children_w_0.writeAll(props.children);
            try _children_w_0.writeAll("\n");
            try Text(writer, .{ .as = .legend,  .size = .lg,  .weight = .semibold,  .class = runtime.concatRt(&.{ "tracking-tight ", props.class }), .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

pub const FieldGroupProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldGroup(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldGroupProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldGroupProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Stack(writer, .{ .gap = .lg,  .class = props.class, .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const Orientation = enum { vertical, horizontal };
// Field wraps a <Stack> inside a thin <div> that holds `data-publr-component`
// and `data-invalid`. The vertical orientation uses gap-1.5 (sub-`xs`) via
// class override on Stack — too small to justify a new `xxs` Gap value.
pub const FieldProps = struct {
    orientation: Orientation = .vertical,
    invalid: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Field(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldProps, _props);
    const invalid_attr = if (props.invalid) "true" else "false";
    if (props.orientation == .horizontal) {
        try writer.writeAll("<div data-publr-component=\"field\" data-invalid=\"");
        try runtime.render(writer, invalid_attr);
        try writer.writeAll("\">\n");
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try _children_w_0.writeAll(props.children);
            try _children_w_0.writeAll("\n");
            try Stack(writer, .{ .direction = .horizontal,  .items = .start,  .gap = .md,  .class = props.class, .children = _children_buf_0.items });
        }
        try writer.writeAll("\n</div>");
    } else {
        try writer.writeAll("<div data-publr-component=\"field\" data-invalid=\"");
        try runtime.render(writer, invalid_attr);
        try writer.writeAll("\">\n");
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try _children_w_0.writeAll(props.children);
            try _children_w_0.writeAll("\n");
            try Stack(writer, .{ .gap = .none,  .class = runtime.concatRt(&.{ "gap-1.5 ", props.class }), .children = _children_buf_0.items });
        }
        try writer.writeAll("\n</div>");
    }
        }
    }.b);
}

pub const FieldContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldContentProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Stack(writer, .{ .gap = .none,  .class = runtime.concatRt(&.{ "gap-0.5 ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const FieldLabelProps = struct {
    html_for: []const u8 = "",
    required: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldLabel(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldLabelProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldLabelProps, _props);
    if (props.required) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try _children_w_1.writeAll(props.children);
                try _children_w_1.writeAll("\n<span class=\"text-error ml-0.5\">*</span>\n");
                try Text(_children_w_0, .{ .as = .span,  .size = .sm,  .weight = .medium, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Label(writer, .{ .html_for = props.html_for,  .class = props.class, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll(props.children);
                try Text(_children_w_0, .{ .as = .span,  .size = .sm,  .weight = .medium, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Label(writer, .{ .html_for = props.html_for,  .class = props.class, .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

/// FieldLabelRow — dense-admin baseline row: semibold micro label with an
/// optional right-aligned hint. Sits above the field control (mb-2).
pub const FieldLabelRowProps = struct {
    label: []const u8 = "",
    hint: []const u8 = "",
    html_for: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldLabelRow(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldLabelRowProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldLabelRowProps, _props);
    try writer.writeAll("<div data-publr-part=\"label-row\" class=\"mb-2 flex items-baseline ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try runtime.render(_children_w_0, props.label);
        try _children_w_0.writeAll("\n");
        try Label(writer, .{ .html_for = props.html_for,  .class = "text-xs font-semibold text-foreground", .children = _children_buf_0.items });
    }
    try writer.writeAll("\n");
    if (props.hint.len > 0) {
        try writer.writeAll("<span data-publr-part=\"description\" class=\"ml-auto text-2xs text-muted-foreground\">");
        try runtime.render(writer, props.hint);
        try writer.writeAll("</span>");
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const FieldDescriptionProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldDescription(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldDescriptionProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldDescriptionProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Text(writer, .{ .size = .xs,  .color = .muted,  .as = .p,  .class = props.class, .children = _children_buf_0.items });
    }
        }
    }.b);
}

// FieldSeparator(no children) composes <Separator>. The "OR" labeled-divider
// variant (with children) stays raw — Separator has no label slot and adding
// one for one consumer isn't justified.
pub const FieldSeparatorProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldSeparator(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldSeparatorProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldSeparatorProps, _props);
    const has_children = props.children.len > 0;
    if (has_children) {
        try writer.writeAll("<div class=\"relative my-4 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<div class=\"absolute inset-0 flex items-center\"><span class=\"w-full border-t border-border\"></span></div>\n<div class=\"relative flex justify-center text-xs uppercase\">\n<span class=\"bg-background px-2 text-muted-foreground\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>\n</div>\n</div>");
    } else {
        try Separator(writer, .{ .spacing = .lg,  .class = props.class });
    }
        }
    }.b);
}

// FieldError keeps raw <p> with role="alert" — Text primitive doesn't expose
// arbitrary `role`, and adding it for one consumer isn't worth the API
// bloat. Uses `text-error` (semantic token, distinct from destructive) per
// existing convention.
pub const FieldErrorProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn FieldError(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldErrorProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldErrorProps, _props);
    try writer.writeAll("<p role=\"alert\" class=\"text-xs text-error ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const Input = root.text_input.Input;
pub const Checkbox = root.checkbox.Checkbox;
pub const FieldDemoProps = struct {
    demo: enum { basic, with_error, horizontal, fieldset } = .basic,
};
pub fn FieldDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FieldDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("Email");
                try FieldLabel(_children_w_0, .{ .html_for = "basic-email", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Input(_children_w_0, .{ .id = "basic-email",  .name = "email",  .placeholder = "you@example.com" });
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("We'll never share your email.");
                try FieldDescription(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Field(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_error) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("Email");
                try FieldLabel(_children_w_0, .{ .html_for = "error-email", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Input(_children_w_0, .{ .id = "error-email",  .name = "email",  .placeholder = "you@example.com",  .invalid = true });
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("Please enter a valid email address.");
                try FieldError(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Field(writer, .{ .invalid = true, .children = _children_buf_0.items });
        }
    } else if (props.demo == .horizontal) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("Remember me");
                try FieldLabel(_children_w_0, .{ .html_for = "horizontal-remember", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Checkbox(_children_w_0, .{ .id = "horizontal-remember",  .name = "remember" });
            try _children_w_0.writeAll("\n");
            try Field(writer, .{ .orientation = .horizontal, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("Profile");
                try FieldLegend(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Full name");
                        try FieldLabel(_children_w_2, .{ .html_for = "fieldset-name", .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try Input(_children_w_2, .{ .id = "fieldset-name",  .name = "name",  .placeholder = "John Doe" });
                    try _children_w_2.writeAll("\n");
                    try Field(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Email");
                        try FieldLabel(_children_w_2, .{ .html_for = "fieldset-email",  .required = true, .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try Input(_children_w_2, .{ .id = "fieldset-email",  .name = "email",  .placeholder = "you@example.com" });
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("We'll never share your email.");
                        try FieldDescription(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try Field(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try FieldGroup(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try FieldSet(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const flex = struct {

/// Flex — horizontal layout shorthand.
///
/// Usage:
///   <Flex justify=.between items=.center gap=.md>left right</Flex>
///   <Flex gap=.sm border=.bottom padding=.lg>toolbar items</Flex>
///   <Flex as=.ul gap=.xs class="list-none p-0 m-0">list items</Flex>
///   <Flex as=.li display=.inline_flex items=.center gap=.xs>inline list item</Flex>
pub const Gap = enum { none, xs, sm, md, lg, xl, @"2xl" };
pub const Align = enum { start, center, end, stretch, baseline };
pub const Justify = enum { start, center, end, between };
pub const Wrap = enum { nowrap, wrap };
pub const Border = enum { none, bottom, top, left, right, all };
pub const Background = enum { none, default, muted, card };
pub const Element = enum { div, ul, ol, li, nav };
pub const Display = enum { flex, inline_flex };
pub const FlexProps = struct {
    gap: Gap = .none,
    items: Align = .center,
    justify: Justify = .start,
    wrap: Wrap = .nowrap,
    padding: Gap = .none,
    border: Border = .none,
    background: Background = .none,
    grow: bool = false,
    as: Element = .div,
    display: Display = .flex,
    class: []const u8 = "",
    children: []const u8 = "",
};
pub fn Flex(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(FlexProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FlexProps, _props);
    const display_c = if (props.display == .inline_flex) "inline-flex" else "flex";
    const gap_c = if (props.gap == .none) "" else if (props.gap == .xs) "gap-1" else if (props.gap == .sm) "gap-2" else if (props.gap == .md) "gap-3" else if (props.gap == .lg) "gap-4" else if (props.gap == .xl) "gap-6" else "gap-8";
    const items_c = if (props.items == .start) "items-start" else if (props.items == .center) "items-center" else if (props.items == .end) "items-end" else if (props.items == .baseline) "items-baseline" else "items-stretch";
    const justify_c = if (props.justify == .center) "justify-center" else if (props.justify == .end) "justify-end" else if (props.justify == .between) "justify-between" else "";
    const wrap_c = if (props.wrap == .wrap) "flex-wrap" else "";
    const pad_c = if (props.padding == .none) "" else if (props.padding == .xs) "p-1" else if (props.padding == .sm) "p-2" else if (props.padding == .md) "p-3" else if (props.padding == .lg) "p-4" else if (props.padding == .xl) "p-6" else "p-8";
    const border_c = if (props.border == .bottom) "border-b border-border" else if (props.border == .top) "border-t border-border" else if (props.border == .left) "border-l border-border" else if (props.border == .right) "border-r border-border" else if (props.border == .all) "border border-border" else "";
    const bg_c = if (props.background == .default) "bg-background" else if (props.background == .muted) "bg-muted" else if (props.background == .card) "bg-card" else "";
    const grow_c = if (props.grow) "flex-1 min-w-0" else "";
    if (props.as == .ul) {
        try writer.writeAll("<ul data-publr-component=\"flex\" class=\"");
        try writer.writeAll(display_c);
        try writer.writeAll(" flex-row ");
        try writer.writeAll(gap_c);
        try writer.writeAll(" ");
        try writer.writeAll(items_c);
        try writer.writeAll(" ");
        try writer.writeAll(justify_c);
        try writer.writeAll(" ");
        try writer.writeAll(wrap_c);
        try writer.writeAll(" ");
        try writer.writeAll(pad_c);
        try writer.writeAll(" ");
        try writer.writeAll(border_c);
        try writer.writeAll(" ");
        try writer.writeAll(bg_c);
        try writer.writeAll(" ");
        try writer.writeAll(grow_c);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</ul>");
    } else if (props.as == .ol) {
        try writer.writeAll("<ol data-publr-component=\"flex\" class=\"");
        try writer.writeAll(display_c);
        try writer.writeAll(" flex-row ");
        try writer.writeAll(gap_c);
        try writer.writeAll(" ");
        try writer.writeAll(items_c);
        try writer.writeAll(" ");
        try writer.writeAll(justify_c);
        try writer.writeAll(" ");
        try writer.writeAll(wrap_c);
        try writer.writeAll(" ");
        try writer.writeAll(pad_c);
        try writer.writeAll(" ");
        try writer.writeAll(border_c);
        try writer.writeAll(" ");
        try writer.writeAll(bg_c);
        try writer.writeAll(" ");
        try writer.writeAll(grow_c);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</ol>");
    } else if (props.as == .li) {
        try writer.writeAll("<li data-publr-component=\"flex\" class=\"");
        try writer.writeAll(display_c);
        try writer.writeAll(" flex-row ");
        try writer.writeAll(gap_c);
        try writer.writeAll(" ");
        try writer.writeAll(items_c);
        try writer.writeAll(" ");
        try writer.writeAll(justify_c);
        try writer.writeAll(" ");
        try writer.writeAll(wrap_c);
        try writer.writeAll(" ");
        try writer.writeAll(pad_c);
        try writer.writeAll(" ");
        try writer.writeAll(border_c);
        try writer.writeAll(" ");
        try writer.writeAll(bg_c);
        try writer.writeAll(" ");
        try writer.writeAll(grow_c);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</li>");
    } else if (props.as == .nav) {
        try writer.writeAll("<nav data-publr-component=\"flex\" class=\"");
        try writer.writeAll(display_c);
        try writer.writeAll(" flex-row ");
        try writer.writeAll(gap_c);
        try writer.writeAll(" ");
        try writer.writeAll(items_c);
        try writer.writeAll(" ");
        try writer.writeAll(justify_c);
        try writer.writeAll(" ");
        try writer.writeAll(wrap_c);
        try writer.writeAll(" ");
        try writer.writeAll(pad_c);
        try writer.writeAll(" ");
        try writer.writeAll(border_c);
        try writer.writeAll(" ");
        try writer.writeAll(bg_c);
        try writer.writeAll(" ");
        try writer.writeAll(grow_c);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</nav>");
    } else {
        try writer.writeAll("<div data-publr-component=\"flex\" class=\"");
        try writer.writeAll(display_c);
        try writer.writeAll(" flex-row ");
        try writer.writeAll(gap_c);
        try writer.writeAll(" ");
        try writer.writeAll(items_c);
        try writer.writeAll(" ");
        try writer.writeAll(justify_c);
        try writer.writeAll(" ");
        try writer.writeAll(wrap_c);
        try writer.writeAll(" ");
        try writer.writeAll(pad_c);
        try writer.writeAll(" ");
        try writer.writeAll(border_c);
        try writer.writeAll(" ");
        try writer.writeAll(bg_c);
        try writer.writeAll(" ");
        try writer.writeAll(grow_c);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</div>");
    }
        }
    }.b);
}

};

pub const grid = struct {

/// Grid — CSS grid with column presets.
///
/// Usage:
///   <Grid columns=.three gap=.lg>items</Grid>
pub const Columns = enum { one, two, three, four, auto_fill };
pub const Gap = enum { none, xs, sm, md, lg, xl, @"2xl" };
pub const GridProps = struct {
    columns: Columns = .three,
    gap: Gap = .lg,
    class: []const u8 = "",
    children: []const u8 = "",
};
pub fn Grid(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(GridProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(GridProps, _props);
    const cols = if (props.columns == .one) "grid-cols-1" else if (props.columns == .two) "grid-cols-2" else if (props.columns == .three) "grid-cols-3" else if (props.columns == .four) "grid-cols-4" else "grid-cols-[repeat(auto-fill,minmax(200px,1fr))]";
    const gap_class = if (props.gap == .none) "" else if (props.gap == .xs) "gap-1" else if (props.gap == .sm) "gap-2" else if (props.gap == .md) "gap-3" else if (props.gap == .lg) "gap-4" else if (props.gap == .xl) "gap-6" else "gap-8";
    try writer.writeAll("<div data-publr-component=\"grid\" class=\"grid ");
    try writer.writeAll(cols);
    try writer.writeAll(" ");
    try writer.writeAll(gap_class);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

};

pub const heading = struct {

/// Heading — semantic heading with constrained sizes.
///
/// Usage:
///   <Heading level=.h1 size=.xl>Page Title</Heading>
///   <Heading level=.h2 size=.md>Section</Heading>
pub const Level = enum { h1, h2, h3, h4, h5, h6 };
pub const HeadingSize = enum { xs, sm, md, lg, xl, xxl, xxxl };
pub const HeadingProps = struct {
    level: Level = .h2,
    size: HeadingSize = .md,
    class: []const u8 = "",
    children: []const u8 = "",
};
pub fn Heading(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(HeadingProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(HeadingProps, _props);
    const base_class = if (props.size == .xs) "text-sm font-semibold tracking-tight text-foreground" else if (props.size == .sm) "text-md font-semibold tracking-tight text-foreground" else if (props.size == .md) "text-lg font-semibold tracking-tight text-foreground" else if (props.size == .lg) "text-xl font-semibold tracking-tight text-foreground" else if (props.size == .xl) "text-2xl font-bold tracking-tight text-foreground" else if (props.size == .xxl) "text-3xl font-semibold tracking-tight text-foreground" else "text-4xl font-semibold tracking-tight text-foreground";
    if (props.level == .h1) {
        try writer.writeAll("<h1 data-publr-component=\"heading\" class=\"");
        try writer.writeAll(base_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h1>");
    } else if (props.level == .h2) {
        try writer.writeAll("<h2 data-publr-component=\"heading\" class=\"");
        try writer.writeAll(base_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h2>");
    } else if (props.level == .h3) {
        try writer.writeAll("<h3 data-publr-component=\"heading\" class=\"");
        try writer.writeAll(base_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h3>");
    } else if (props.level == .h4) {
        try writer.writeAll("<h4 data-publr-component=\"heading\" class=\"");
        try writer.writeAll(base_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h4>");
    } else if (props.level == .h5) {
        try writer.writeAll("<h5 data-publr-component=\"heading\" class=\"");
        try writer.writeAll(base_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h5>");
    } else {
        try writer.writeAll("<h6 data-publr-component=\"heading\" class=\"");
        try writer.writeAll(base_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h6>");
    }
        }
    }.b);
}

};

pub const icon = struct {

/// Icon — SVG icon from the design system icon set.
///
/// Renders an `<svg>` element with the inner paths for the specified icon.
/// Icons come from the pinned `publr-icons` Zig artifact. Update it explicitly
/// with `scripts/update-icons.sh`; normal builds never fetch dependencies.
///
/// Size constants:
///   - Size.sm = 16
///   - Size.md = 20
///   - Size.lg = 24 (default)
///   - Size.xl = 32
///
/// Example:
///   <Icon name=.home />
///   <Icon name=.settings size={Size.sm} />
///   <Icon name=.edit size={Size.xl} class="text-brand-600" />
pub const icons = root.icons_data;
pub const Name = icons.Name;
pub const Size = struct {
    pub const sm: u16 = 16;
    pub const md: u16 = 20;
    pub const lg: u16 = 24;
    pub const xl: u16 = 32;
};
pub const IconProps = struct {
    name: Name,
    size: u16 = 24,
    class: []const u8 = "icon",
};
pub fn Icon(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(IconProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(IconProps, _props);
    try writer.writeAll("<svg viewBox=\"0 0 24 24\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\" class=\"");
    try runtime.render(writer, props.class);
    try writer.writeAll("\" width=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\" height=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\">\n");
    try writer.writeAll(icons.get(props.name));
    try writer.writeAll("\n</svg>");
        }
    }.b);
}

};

pub const input_group = struct {

/// InputGroup — input with addons (icons, buttons, text).
///
/// Sub-components matching shadcn API:
///   - InputGroup: wrapper that combines input + addons
///   - InputGroupInput: styled input for use inside group
///   - InputGroupTextarea: styled textarea for use inside group
///   - InputGroupAddon: container for icons/buttons/text (align: inline_start/inline_end)
///   - InputGroupButton: button inside addon
///   - InputGroupText: static text inside addon
///
/// Usage:
///   <InputGroup>
///       <InputGroupInput placeholder="Search..." />
///       <InputGroupAddon align_to=.inline_end>
///           <Icon name=.search size={16} class="text-muted-foreground" />
///       </InputGroupAddon>
///   </InputGroup>
pub const Icon = root.icon.Icon;
pub const Flex = root.flex.Flex;
// ── Sub-components ──────────────────────────────────
// InputGroup wraps a <Flex items=.center> inside a thin <div> that holds
// `data-publr-component="input-group"` and the `relative` positioning context
// for absolutely-positioned addons.
pub const InputGroupProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn InputGroup(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputGroupProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupProps, _props);
    try writer.writeAll("<div data-publr-component=\"input-group\" class=\"relative ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .items = .center, .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const AddonAlign = enum { inline_start, inline_end };
// InputGroupAddon composes <Flex items=.center> with absolute positioning
// applied via class override. The flex layout still benefits from the
// primitive; positioning rides as decoration since `absolute` isn't a
// layout-primitive concern.
pub const InputGroupAddonProps = struct {
    align_to: AddonAlign = .inline_start,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn InputGroupAddon(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputGroupAddonProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupAddonProps, _props);
    const cls = if (props.align_to == .inline_end)
        "absolute right-0 inset-y-0 pr-3 pointer-events-none"
    else
        "absolute left-0 inset-y-0 pl-3 pointer-events-none";
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .items = .center,  .class = runtime.concatRt(&.{ cls, " ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const InputGroupInputProps = struct {
    placeholder: []const u8 = "",
    name: []const u8 = "",
    has_start_addon: bool = false,
    has_end_addon: bool = false,
    disabled: bool = false,
    class: []const u8 = "",
};
pub fn InputGroupInput(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputGroupInputProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupInputProps, _props);
    // Apply exactly one padding-left and one padding-right utility — never both
    // `px-3` and `pl-10`/`pr-10`, because the JIT emits utilities in an order
    // where smaller numbers come later in the CSS and would override `pl-10`.
    const pad_l = if (props.has_start_addon) "pl-10" else "pl-3";
    const pad_r = if (props.has_end_addon) "pr-10" else "pr-3";
    if (props.disabled) {
        try writer.writeAll("<input data-publr-part=\"input\" type=\"text\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" class=\"flex w-full rounded-md border border-input bg-card ");
        try writer.writeAll(pad_l);
        try writer.writeAll(" ");
        try writer.writeAll(pad_r);
        try writer.writeAll(" py-2 text-sm text-foreground shadow-xs transition duration-150 placeholder:text-muted-foreground hover:border-gray-400 focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">");
    } else {
        try writer.writeAll("<input data-publr-part=\"input\" type=\"text\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" class=\"flex w-full rounded-md border border-input bg-card ");
        try writer.writeAll(pad_l);
        try writer.writeAll(" ");
        try writer.writeAll(pad_r);
        try writer.writeAll(" py-2 text-sm text-foreground shadow-xs transition duration-150 placeholder:text-muted-foreground hover:border-gray-400 focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
    }
        }
    }.b);
}

pub const InputGroupTextareaProps = struct {
    placeholder: []const u8 = "",
    name: []const u8 = "",
    disabled: bool = false,
    class: []const u8 = "",
};
pub fn InputGroupTextarea(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputGroupTextareaProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupTextareaProps, _props);
    if (props.disabled) {
        try writer.writeAll("<textarea data-publr-part=\"textarea\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" class=\"flex w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground shadow-xs transition duration-150 placeholder:text-muted-foreground hover:border-gray-400 focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"></textarea>");
    } else {
        try writer.writeAll("<textarea data-publr-part=\"textarea\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" class=\"flex w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground shadow-xs transition duration-150 placeholder:text-muted-foreground hover:border-gray-400 focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y ");
        try writer.writeAll(props.class);
        try writer.writeAll("\"></textarea>");
    }
        }
    }.b);
}

pub const InputGroupButtonProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn InputGroupButton(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputGroupButtonProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupButtonProps, _props);
    try writer.writeAll("<button data-publr-part=\"button\" class=\"inline-flex items-center justify-center text-xs font-medium text-muted-foreground hover:text-foreground transition-colors pointer-events-auto ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</button>");
        }
    }.b);
}

pub const InputGroupTextProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn InputGroupText(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputGroupTextProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupTextProps, _props);
    try writer.writeAll("<span class=\"inline-flex items-center justify-center w-4 h-4 text-sm text-muted-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</span>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const InputGroupDemoProps = struct {
    demo: enum { with_icon, with_text, with_button } = .with_icon,
};
pub fn InputGroupDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputGroupDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupDemoProps, _props);
    if (props.demo == .with_icon) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try InputGroupInput(_children_w_0, .{ .placeholder = "Search...",  .has_start_addon = true });
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Icon(_children_w_1, .{ .name = .search,  .size = 16,  .class = "text-muted-foreground" });
                try _children_w_1.writeAll("\n");
                try InputGroupAddon(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try InputGroup(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_text) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try InputGroupInput(_children_w_0, .{ .placeholder = "0.00",  .has_start_addon = true });
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("$");
                    try InputGroupText(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try InputGroupAddon(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try InputGroup(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try InputGroupInput(_children_w_0, .{ .placeholder = "Enter URL...",  .has_end_addon = true });
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    try Icon(_children_w_2, .{ .name = .copy,  .size = 16,  .class = "" });
                    try _children_w_2.writeAll("\n");
                    try InputGroupButton(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try InputGroupAddon(_children_w_0, .{ .align_to = .inline_end, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try InputGroup(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const text_input = struct {

/// Input — text input and textarea for forms.
///
/// Sub-components:
///   - Input: styled `<input>` element
///   - Textarea: styled `<textarea>` element
///
/// Usage:
///   <Input name="email" placeholder="you@example.com" />
///   <Input input_type=.password name="password" />
///   <Textarea name="bio" placeholder="Tell us about yourself" />
pub const InputType = enum { text, email, password, search, tel, url, number, file };
pub const InputProps = struct {
    input_type: InputType = .text,
    name: []const u8 = "",
    id: []const u8 = "",
    placeholder: []const u8 = "",
    value: []const u8 = "",
    disabled: bool = false,
    invalid: bool = false,
    required: bool = false,
    class: []const u8 = "",
};
pub fn Input(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(InputProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputProps, _props);
    const base = "flex rounded-md border bg-card px-3 py-2 text-base sm:text-sm text-foreground shadow-xs transition duration-150 placeholder:text-muted-foreground hover:border-gray-400 focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50";

    const border = if (props.invalid) "border-error" else "border-input";
    if (props.disabled and props.required) {
        try writer.writeAll("<input data-publr-component=\"input\" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\" required=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">");
    } else if (props.disabled) {
        try writer.writeAll("<input data-publr-component=\"input\" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">");
    } else if (props.required) {
        try writer.writeAll("<input data-publr-component=\"input\" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\" required=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">");
    } else {
        try writer.writeAll("<input data-publr-component=\"input\" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">");
    }
        }
    }.b);
}

pub const TextareaProps = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    placeholder: []const u8 = "",
    value: []const u8 = "",
    disabled: bool = false,
    invalid: bool = false,
    required: bool = false,
    class: []const u8 = "",
};
pub fn Textarea(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TextareaProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TextareaProps, _props);
    const border = if (props.invalid) "border-error" else "border-input";
    if (props.disabled) {
        try writer.writeAll("<textarea data-publr-component=\"textarea\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" class=\"flex w-full rounded-md border bg-card px-3 py-2 text-base sm:text-sm text-foreground shadow-xs transition duration-150 placeholder:text-muted-foreground hover:border-gray-400 focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y ");
        try writer.writeAll(border);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">");
        try runtime.render(writer, props.value);
        try writer.writeAll("</textarea>");
    } else {
        try writer.writeAll("<textarea data-publr-component=\"textarea\" id=\"");
        try runtime.render(writer, if (props.id.len > 0) props.id else null);
        try writer.writeAll("\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\" class=\"flex w-full rounded-md border bg-card px-3 py-2 text-base sm:text-sm text-foreground shadow-xs transition duration-150 placeholder:text-muted-foreground hover:border-gray-400 focus-visible:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y ");
        try writer.writeAll(border);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\">");
        try runtime.render(writer, props.value);
        try writer.writeAll("</textarea>");
    }
        }
    }.b);
}

};

pub const label = struct {

/// Label — semantic <label> wrapper for form controls.
///
/// Renders a `<label>` with optional `for` attribute. Applies no typography
/// styling itself — wrap content in `<Text>` for sizing/weight/color.
/// Pattern matches the Field/FieldLabel composition.
///
/// Usage:
///   <Label html_for="email">
///       <Text size=.sm weight=.medium>Email</Text>
///   </Label>
///
///   <Label>
///       <Text size=.sm>Inline label without for-binding</Text>
///   </Label>
pub const LabelProps = struct {
    html_for: []const u8 = "",
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Label(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(LabelProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(LabelProps, _props);
    if (props.html_for.len > 0) {
        try writer.writeAll("<label data-publr-component=\"label\" for=\"");
        try runtime.render(writer, props.html_for);
        try writer.writeAll("\" class=\"");
        try runtime.render(writer, props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</label>");
    } else {
        try writer.writeAll("<label data-publr-component=\"label\" class=\"");
        try runtime.render(writer, props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</label>");
    }
        }
    }.b);
}

};

pub const pagination = struct {

/// Pagination — page navigation.
///
/// Sub-components matching shadcn API:
///   - Pagination: outer `<nav>` container
///   - PaginationContent: `<ul>` list
///   - PaginationItem: `<li>` wrapper
///   - PaginationLink: page number (is_active for current page)
///   - PaginationPrevious: previous button with chevron
///   - PaginationNext: next button with chevron
///   - PaginationEllipsis: "..." truncation
///
/// Usage:
///   <Pagination>
///       <PaginationContent>
///           <PaginationItem><PaginationPrevious /></PaginationItem>
///           <PaginationItem><PaginationLink is_active={true}>1</PaginationLink></PaginationItem>
///           <PaginationItem><PaginationLink>2</PaginationLink></PaginationItem>
///           <PaginationItem><PaginationEllipsis /></PaginationItem>
///           <PaginationItem><PaginationLink>10</PaginationLink></PaginationItem>
///           <PaginationItem><PaginationNext /></PaginationItem>
///       </PaginationContent>
///   </Pagination>
pub const Icon = root.icon.Icon;
pub const Flex = root.flex.Flex;
// ── Sub-components ──────────────────────────────────
pub const PaginationProps = struct {
    children: []const u8 = "",
};
pub fn Pagination(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationProps, _props);
    try writer.writeAll("<nav data-publr-component=\"pagination\" aria-label=\"Pagination\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</nav>");
        }
    }.b);
}

pub const PaginationContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn PaginationContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationContentProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try _children_w_0.writeAll(props.children);
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .as = .ul,  .gap = .xs,  .class = runtime.concatRt(&.{ "list-none p-0 m-0 ", props.class }), .children = _children_buf_0.items });
    }
        }
    }.b);
}

pub const PaginationItemProps = struct {
    children: []const u8 = "",
};
pub fn PaginationItem(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationItemProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationItemProps, _props);
    try writer.writeAll("<li>");
    try writer.writeAll(props.children);
    try writer.writeAll("</li>");
        }
    }.b);
}

pub const PaginationLinkProps = struct {
    href: []const u8 = "#",
    is_active: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn PaginationLink(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationLinkProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationLinkProps, _props);
    const base = "inline-flex items-center justify-center h-8 w-8 rounded-md text-sm font-medium transition-colors";
    if (props.is_active) {
        try writer.writeAll("<span aria-current=\"page\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" bg-accent text-accent-foreground ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</span>");
    } else {
        try writer.writeAll("<a href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground hover:bg-accent/50 hover:text-foreground ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</a>");
    }
        }
    }.b);
}

pub const PaginationPreviousProps = struct {
    href: []const u8 = "#",
    disabled: bool = false,
    class: []const u8 = "",
};
pub fn PaginationPrevious(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationPreviousProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationPreviousProps, _props);
    const base = "inline-flex items-center justify-center h-8 w-8 rounded-md text-sm font-medium transition-colors";
    if (props.disabled) {
        try writer.writeAll("<span class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground opacity-50 cursor-not-allowed ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try Icon(writer, .{ .name = .chevron_left,  .size = 16,  .class = "" });
        try writer.writeAll("\n</span>");
    } else {
        try writer.writeAll("<a href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground hover:bg-accent/50 hover:text-foreground ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try Icon(writer, .{ .name = .chevron_left,  .size = 16,  .class = "" });
        try writer.writeAll("\n</a>");
    }
        }
    }.b);
}

pub const PaginationNextProps = struct {
    href: []const u8 = "#",
    disabled: bool = false,
    class: []const u8 = "",
};
pub fn PaginationNext(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationNextProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationNextProps, _props);
    const base = "inline-flex items-center justify-center h-8 w-8 rounded-md text-sm font-medium transition-colors";
    if (props.disabled) {
        try writer.writeAll("<span class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground opacity-50 cursor-not-allowed ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try Icon(writer, .{ .name = .chevron_right,  .size = 16,  .class = "" });
        try writer.writeAll("\n</span>");
    } else {
        try writer.writeAll("<a href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground hover:bg-accent/50 hover:text-foreground ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try Icon(writer, .{ .name = .chevron_right,  .size = 16,  .class = "" });
        try writer.writeAll("\n</a>");
    }
        }
    }.b);
}

pub const PaginationEllipsisProps = struct {
    class: []const u8 = "",
};
pub fn PaginationEllipsis(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationEllipsisProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationEllipsisProps, _props);
    try writer.writeAll("<span class=\"inline-flex items-center justify-center h-8 w-8 text-sm text-muted-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">...</span>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const PaginationDemoProps = struct {
    demo: enum { few_pages, many_pages, last_page } = .few_pages,
};
pub fn PaginationDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PaginationDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationDemoProps, _props);
    if (props.demo == .few_pages) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationPrevious(_children_w_2, .{ .disabled = true });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("1");
                        try PaginationLink(_children_w_2, .{ .is_active = true, .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("2");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("3");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationNext(_children_w_2, .{ });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try PaginationContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Pagination(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .many_pages) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationPrevious(_children_w_2, .{ });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("1");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationEllipsis(_children_w_2, .{ });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("4");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("5");
                        try PaginationLink(_children_w_2, .{ .is_active = true, .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("6");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationEllipsis(_children_w_2, .{ });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("20");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationNext(_children_w_2, .{ });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try PaginationContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Pagination(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationPrevious(_children_w_2, .{ });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("1");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationEllipsis(_children_w_2, .{ });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("8");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("9");
                        try PaginationLink(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("10");
                        try PaginationLink(_children_w_2, .{ .is_active = true, .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try PaginationNext(_children_w_2, .{ .disabled = true });
                    try PaginationItem(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try PaginationContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Pagination(writer, .{ .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const popover = struct {

/// Popover — floating content panel.
///
/// Sub-components matching Radix Popover API:
///   - Popover: outer container with state
///   - PopoverTrigger: element that opens the popover
///   - PopoverContent: floating panel (side, align_to, side_offset, align_offset)
///   - PopoverHeader: header section
///   - PopoverTitle: title text
///   - PopoverDescription: body text
///   - PopoverClose: close button (optional)
///   - PopoverArrow: pointing arrow (optional)
///
/// Usage:
///   <Popover>
///       <PopoverTrigger><Button label="Settings" /></PopoverTrigger>
///       <PopoverContent side=.bottom align_to=.center side_offset={8}>
///           <PopoverTitle>Settings</PopoverTitle>
///           <PopoverDescription>Customize your preferences.</PopoverDescription>
///       </PopoverContent>
///   </Popover>
pub const Button = root.button.Button;
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const PopoverProps = struct {
    modal: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Popover(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverProps, _props);
    try writer.writeAll("<div data-p-store=\"local:popover\" data-publr-component=\"popover\" data-publr-modal=\"");
    try runtime.render(writer, props.modal);
    try writer.writeAll("\" class=\"relative inline-block ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const PopoverTriggerProps = struct {
    children: []const u8 = "",
};
pub fn PopoverTrigger(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverTriggerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverTriggerProps, _props);
    try writer.writeAll("<span data-publr-part=\"trigger\" aria-haspopup=\"dialog\" data-p-bind=\"aria-expanded:state.open\" data-p-on=\"click:toggle\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const Side = enum { top, right, bottom, left };
pub const Alignment = enum { start, center, end };
pub const PopoverContentProps = struct {
    side: Side = .bottom,
    align_to: Alignment = .center,
    side_offset: u16 = 0,
    align_offset: u16 = 0,
    avoid_collisions: bool = true,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn PopoverContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" data-p-show=\"state.open\" role=\"dialog\" data-p-portal=\"");
    try runtime.render(writer, true);
    try writer.writeAll("\" data-publr-side=\"");
    try runtime.render(writer, props.side);
    try writer.writeAll("\" data-publr-align=\"");
    try runtime.render(writer, props.align_to);
    try writer.writeAll("\" data-publr-side-offset=\"");
    try runtime.render(writer, props.side_offset);
    try writer.writeAll("\" data-publr-align-offset=\"");
    try runtime.render(writer, props.align_offset);
    try writer.writeAll("\" data-publr-avoid-collisions=\"");
    try runtime.render(writer, props.avoid_collisions);
    try writer.writeAll("\" class=\"hidden w-72 rounded-lg border border-border bg-popover p-4 text-popover-foreground shadow-md ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const PopoverHeaderProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn PopoverHeader(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverHeaderProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverHeaderProps, _props);
    try writer.writeAll("<div data-publr-part=\"header\" class=\"mb-3 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const PopoverTitleProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn PopoverTitle(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverTitleProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverTitleProps, _props);
    try writer.writeAll("<h4 data-publr-part=\"title\" class=\"text-sm font-semibold text-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</h4>");
        }
    }.b);
}

pub const PopoverDescriptionProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn PopoverDescription(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverDescriptionProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverDescriptionProps, _props);
    try writer.writeAll("<p data-publr-part=\"description\" class=\"text-sm text-muted-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
        }
    }.b);
}

pub const PopoverCloseProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn PopoverClose(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverCloseProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverCloseProps, _props);
    try writer.writeAll("<button data-publr-part=\"close\" type=\"button\" aria-label=\"Close\" data-p-on=\"click:close\" class=\"text-muted-foreground hover:text-foreground transition-colors ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</button>");
        }
    }.b);
}

pub const PopoverArrowProps = struct {
    class: []const u8 = "",
};
pub fn PopoverArrow(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverArrowProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverArrowProps, _props);
    try writer.writeAll("<div data-publr-part=\"arrow\" class=\"absolute w-2.5 h-2.5 bg-popover border border-border rotate-45 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"></div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const PopoverDemoProps = struct {
    demo: enum { basic, with_form } = .basic,
    // Popover
    modal: bool = false,
    // PopoverContent
    side: Side = .bottom,
    align_to: Alignment = .center,
    side_offset: u16 = 0,
    align_offset: u16 = 0,
    avoid_collisions: bool = true,
    // PopoverTitle
    title: []const u8 = "",
    // PopoverDescription
    description: []const u8 = "",
    // Trigger label
    trigger_label: []const u8 = "",
};
pub fn PopoverDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(PopoverDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = props.trigger_label,  .size = .sm });
                try _children_w_1.writeAll("\n");
                try PopoverTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.title);
                        try PopoverTitle(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try PopoverHeader(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.description);
                    try PopoverDescription(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try PopoverContent(_children_w_0, .{ .side = props.side,  .align_to = props.align_to,  .side_offset = props.side_offset,  .align_offset = props.align_offset,  .avoid_collisions = props.avoid_collisions, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Popover(writer, .{ .modal = props.modal, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                try Button(_children_w_1, .{ .hierarchy = .secondary,  .label = props.trigger_label,  .size = .sm });
                try _children_w_1.writeAll("\n");
                try PopoverTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try runtime.render(_children_w_3, props.title);
                        try PopoverTitle(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Icon(_children_w_3, .{ .name = .x_close,  .size = 16,  .class = "" });
                        try PopoverClose(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try PopoverHeader(_children_w_1, .{ .class = "flex items-center justify-between", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.description);
                    try PopoverDescription(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n<div class=\"mt-3 grid gap-2\">\n<label class=\"grid gap-1\">\n<span class=\"text-xs font-medium text-foreground\">Width</span>\n<input type=\"text\" value=\"100%\" class=\"rounded-md border border-input bg-background px-2.5 py-1.5 text-sm\">\n</label>\n<label class=\"grid gap-1\">\n<span class=\"text-xs font-medium text-foreground\">Height</span>\n<input type=\"text\" value=\"auto\" class=\"rounded-md border border-input bg-background px-2.5 py-1.5 text-sm\">\n</label>\n</div>\n");
                try PopoverContent(_children_w_0, .{ .side = props.side,  .align_to = props.align_to,  .side_offset = props.side_offset,  .align_offset = props.align_offset,  .avoid_collisions = props.avoid_collisions, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Popover(writer, .{ .modal = true, .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const radio_group = struct {

/// RadioGroup — set of radio buttons where only one can be selected.
///
/// Sub-components matching shadcn API:
///   - RadioGroup: outer container (fieldset + legend)
///   - RadioGroupItem: individual radio option with label + description
///
/// Usage:
///   <RadioGroup name="plan" legend="Choose a plan">
///       <RadioGroupItem value="free" label="Free" description="Up to 5 pages" />
///       <RadioGroupItem value="pro" label="Pro" description="Unlimited pages" />
///       <RadioGroupItem value="enterprise" label="Enterprise" description="Custom SLA" />
///   </RadioGroup>
pub const Orientation = enum { vertical, horizontal };
// ── Sub-components ──────────────────────────────────
pub const RadioGroupProps = struct {
    name: []const u8 = "",
    legend: []const u8 = "",
    orientation: Orientation = .vertical,
    disabled: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn RadioGroup(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(RadioGroupProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(RadioGroupProps, _props);
    const layout = if (props.orientation == .horizontal)
        "flex flex-row flex-wrap gap-4"
    else
        "flex flex-col gap-3";

    const has_legend = props.legend.len > 0;
    if (props.disabled) {
        try writer.writeAll("<fieldset data-p-store=\"local:radio-group\" data-publr-component=\"radio-group\" data-p-on=\"change:sync\" data-publr-name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" class=\"space-y-3 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n");
        if (has_legend) {
            try writer.writeAll("<legend class=\"text-sm font-medium text-foreground\">");
            try runtime.render(writer, props.legend);
            try writer.writeAll("</legend>");
        }
        try writer.writeAll("\n<div role=\"radiogroup\" class=\"");
        try runtime.render(writer, layout);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</div>\n</fieldset>");
    } else {
        try writer.writeAll("<fieldset data-p-store=\"local:radio-group\" data-publr-component=\"radio-group\" data-p-on=\"change:sync\" data-publr-name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" class=\"space-y-3 ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        if (has_legend) {
            try writer.writeAll("<legend class=\"text-sm font-medium text-foreground\">");
            try runtime.render(writer, props.legend);
            try writer.writeAll("</legend>");
        }
        try writer.writeAll("\n<div role=\"radiogroup\" class=\"");
        try runtime.render(writer, layout);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</div>\n</fieldset>");
    }
        }
    }.b);
}

pub const ItemVariant = enum { default, card };
pub const RadioGroupItemProps = struct {
    value: []const u8 = "",
    label: []const u8 = "",
    description: []const u8 = "",
    name: []const u8 = "",
    disabled: bool = false,
    // card: bordered option card with dense label + description (admin forms).
    variant: ItemVariant = .default,
    class: []const u8 = "",
};
pub fn RadioGroupItem(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(RadioGroupItemProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(RadioGroupItemProps, _props);
    const has_description = props.description.len > 0;
    const radio_class = "mt-0.5 h-4 w-4 shrink-0 rounded-full border border-input bg-background text-primary accent-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50";
    const wrapper_base = if (props.variant == .card)
        "flex items-start gap-3 rounded-md border border-border bg-background px-3 py-3 transition-colors hover:border-gray-300 hover:bg-muted/20"
    else
        "flex items-start gap-2";
    const label_class = if (props.variant == .card)
        "text-xs font-medium text-foreground"
    else
        "text-sm text-foreground";
    const desc_class = if (props.variant == .card)
        "mt-0.5 text-2xs leading-4 text-muted-foreground"
    else
        "text-xs text-muted-foreground";
    if (props.disabled) {
        if (props.name.len > 0) {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"");
            try writer.writeAll(wrapper_base);
            try writer.writeAll(" cursor-not-allowed opacity-50 ");
            try writer.writeAll(props.class);
            try writer.writeAll("\">\n<input type=\"radio\" name=\"");
            try runtime.render(writer, props.name);
            try writer.writeAll("\" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\" disabled=\"");
            try runtime.render(writer, true);
            try writer.writeAll("\">\n<div class=\"grid gap-0.5\">\n<span class=\"");
            try runtime.render(writer, label_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"");
                try runtime.render(writer, desc_class);
                try writer.writeAll("\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>\n</label>");
        } else {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"");
            try writer.writeAll(wrapper_base);
            try writer.writeAll(" cursor-not-allowed opacity-50 ");
            try writer.writeAll(props.class);
            try writer.writeAll("\">\n<input type=\"radio\" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\" disabled=\"");
            try runtime.render(writer, true);
            try writer.writeAll("\">\n<div class=\"grid gap-0.5\">\n<span class=\"");
            try runtime.render(writer, label_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"");
                try runtime.render(writer, desc_class);
                try writer.writeAll("\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>\n</label>");
        }
    } else {
        if (props.name.len > 0) {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"");
            try writer.writeAll(wrapper_base);
            try writer.writeAll(" cursor-pointer ");
            try writer.writeAll(props.class);
            try writer.writeAll("\">\n<input type=\"radio\" name=\"");
            try runtime.render(writer, props.name);
            try writer.writeAll("\" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\">\n<div class=\"grid gap-0.5\">\n<span class=\"");
            try runtime.render(writer, label_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"");
                try runtime.render(writer, desc_class);
                try writer.writeAll("\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>\n</label>");
        } else {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"");
            try writer.writeAll(wrapper_base);
            try writer.writeAll(" cursor-pointer ");
            try writer.writeAll(props.class);
            try writer.writeAll("\">\n<input type=\"radio\" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\">\n<div class=\"grid gap-0.5\">\n<span class=\"");
            try runtime.render(writer, label_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>\n");
            if (has_description) {
                try writer.writeAll("<span class=\"");
                try runtime.render(writer, desc_class);
                try writer.writeAll("\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n</div>\n</label>");
        }
    }
        }
    }.b);
}

// ── Gallery preview ─────────────────────────────────
pub const Demo = enum { default };
pub const RadioGroupPreviewProps = struct {
    demo: Demo = .default,
    // RadioGroup
    name: []const u8 = "",
    legend: []const u8 = "",
    orientation: Orientation = .vertical,
    disabled: bool = false,
    // RadioGroupItem @1
    value_1: []const u8 = "",
    label_1: []const u8 = "",
    description_1: []const u8 = "",
    // RadioGroupItem @2
    value_2: []const u8 = "",
    label_2: []const u8 = "",
    description_2: []const u8 = "",
    // RadioGroupItem @3
    value_3: []const u8 = "",
    label_3: []const u8 = "",
    description_3: []const u8 = "",
};
pub fn RadioGroupPreview(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(RadioGroupPreviewProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(RadioGroupPreviewProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try RadioGroupItem(_children_w_0, .{ .value = props.value_1,  .label = props.label_1,  .description = props.description_1 });
        try _children_w_0.writeAll("\n");
        try RadioGroupItem(_children_w_0, .{ .value = props.value_2,  .label = props.label_2,  .description = props.description_2 });
        try _children_w_0.writeAll("\n");
        try RadioGroupItem(_children_w_0, .{ .value = props.value_3,  .label = props.label_3,  .description = props.description_3 });
        try _children_w_0.writeAll("\n");
        try RadioGroup(writer, .{ .name = props.name,  .legend = props.legend,  .orientation = props.orientation,  .disabled = props.disabled, .children = _children_buf_0.items });
    }
        }
    }.b);
}

};

pub const section_title = struct {

/// SectionTitle — dense admin section header row.
///
/// h-12 bordered row with an uppercase micro-type eyebrow title and an
/// optional trailing action slot (children, right-aligned).
///
/// Example:
///   <SectionTitle title="Review queue" />
///   <SectionTitle title="Recent activity">
///       <Button hierarchy=.tertiary size=.xs label="View all" />
///   </SectionTitle>
pub const SectionTitleProps = struct {
    title: []const u8 = "",
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SectionTitle(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SectionTitleProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SectionTitleProps, _props);
    try writer.writeAll("<div data-publr-component=\"section-title\" class=\"flex h-12 items-center border-b border-border px-5 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n<h2 data-publr-part=\"title\" class=\"text-xs font-semibold uppercase tracking-[0.08em] text-muted-foreground\">");
    try runtime.render(writer, props.title);
    try writer.writeAll("</h2>\n");
    if (props.children.len > 0) {
        try writer.writeAll("<div data-publr-part=\"action\" class=\"ml-auto flex items-center gap-2\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</div>");
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const Button = root.button.Button;
pub const SectionTitleDemoProps = struct {
    demo: enum { plain, with_action } = .plain,
    title: []const u8 = "Review queue",
};
pub fn SectionTitleDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SectionTitleDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SectionTitleDemoProps, _props);
    if (props.demo == .with_action) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try Button(_children_w_0, .{ .hierarchy = .tertiary,  .size = .xs,  .label = "View all" });
            try _children_w_0.writeAll("\n");
            try SectionTitle(writer, .{ .title = props.title, .children = _children_buf_0.items });
        }
    } else {
        try SectionTitle(writer, .{ .title = props.title });
    }
        }
    }.b);
}

};

pub const select = struct {

/// Select — custom select with composable parts.
///
/// Sub-components matching shadcn API:
///   - Select: outer container with state + hidden input
///   - SelectTrigger: the button that opens the listbox
///   - SelectValue: displayed value/placeholder inside trigger
///   - SelectContent: floating listbox panel
///   - SelectGroup: group of options
///   - SelectLabel: non-interactive group heading
///   - SelectItem: individual option
///   - SelectSeparator: divider between groups
///
/// Usage:
///   <Select name="fruit">
///       <SelectTrigger>
///           <SelectValue>Select a fruit</SelectValue>
///       </SelectTrigger>
///       <SelectContent>
///           <SelectGroup>
///               <SelectLabel>Fruits</SelectLabel>
///               <SelectItem value="apple">Apple</SelectItem>
///               <SelectItem value="banana">Banana</SelectItem>
///           </SelectGroup>
///       </SelectContent>
///   </Select>
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const SelectProps = struct {
    name: []const u8 = "",
    default_value: []const u8 = "",
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Select(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectProps, _props);
    try writer.writeAll("<div data-p-store=\"local:select\" data-publr-component=\"select\" data-publr-default-value=\"");
    try runtime.render(writer, props.default_value);
    try writer.writeAll("\" class=\"relative inline-block ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n<input type=\"hidden\" data-publr-part=\"value\" name=\"");
    try runtime.render(writer, props.name);
    try writer.writeAll("\" value=\"");
    try runtime.render(writer, props.default_value);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const TriggerSize = enum { sm, md };
pub const SelectTriggerProps = struct {
    children: []const u8 = "",
    disabled: bool = false,
    // sm: dense filter-row trigger (h-7, text-xs); md: default form control.
    size: TriggerSize = .md,
    class: []const u8 = "",
};
pub fn SelectTrigger(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectTriggerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectTriggerProps, _props);
    const size_class = if (props.size == .sm) "h-7 gap-1.5 px-2 text-xs" else "px-3 py-2 text-sm";
    const base = "inline-flex items-center justify-between w-48 rounded-md border border-input bg-card shadow-xs transition duration-150 hover:border-gray-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-50";
    if (props.disabled) {
        try writer.writeAll("<button data-publr-part=\"trigger\" type=\"button\" aria-haspopup=\"listbox\" aria-expanded=\"false\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_down,  .size = 14,  .class = "text-muted-foreground shrink-0" });
        try writer.writeAll("\n</button>");
    } else {
        try writer.writeAll("<button data-publr-part=\"trigger\" type=\"button\" aria-haspopup=\"listbox\" data-p-bind=\"aria-expanded:state.open\" data-p-on=\"click:toggle;keydown.down:openList\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_down,  .size = 14,  .class = "text-muted-foreground shrink-0" });
        try writer.writeAll("\n</button>");
    }
        }
    }.b);
}

pub const SelectValueProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SelectValue(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectValueProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectValueProps, _props);
    try writer.writeAll("<span data-publr-part=\"label\" class=\"text-muted-foreground truncate ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const SelectContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SelectContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" data-p-show=\"state.open\" role=\"listbox\" data-p-on=\"keydown:navKeys;click:optionClick\" data-p-portal=\"");
    try runtime.render(writer, true);
    try writer.writeAll("\" class=\"hidden min-w-48 rounded-lg border border-border bg-popover p-1 text-popover-foreground shadow-lg ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const SelectGroupProps = struct {
    children: []const u8 = "",
};
pub fn SelectGroup(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectGroupProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectGroupProps, _props);
    try writer.writeAll("<div role=\"group\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
        }
    }.b);
}

pub const SelectLabelProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SelectLabel(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectLabelProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectLabelProps, _props);
    try writer.writeAll("<div class=\"px-2 py-1.5 text-xs font-semibold text-muted-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
        }
    }.b);
}

pub const SelectItemProps = struct {
    value: []const u8 = "",
    disabled: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SelectItem(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectItemProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectItemProps, _props);
    const state = if (props.disabled) "disabled" else "unselected";
    const item_class = if (props.disabled)
        "group flex items-center justify-between gap-2 rounded-md px-2 py-1.5 text-sm text-muted-foreground opacity-50 outline-none pointer-events-none cursor-default"
    else
        "group flex items-center justify-between gap-2 rounded-md px-2 py-1.5 text-sm outline-none hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent cursor-pointer";
    if (props.disabled) {
        try writer.writeAll("<div data-publr-part=\"option\" role=\"option\" tabindex=\"-1\" aria-disabled=\"true\" aria-selected=\"false\" data-value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<span data-publr-part=\"option-label\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>\n<span data-publr-part=\"indicator\" class=\"ml-2 shrink-0 opacity-0 transition-opacity\">\n");
        try Icon(writer, .{ .name = .check,  .size = 16,  .class = "" });
        try writer.writeAll("\n</span>\n</div>");
    } else {
        try writer.writeAll("<div data-publr-part=\"option\" role=\"option\" tabindex=\"-1\" aria-selected=\"false\" data-value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(item_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<span data-publr-part=\"option-label\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>\n<span data-publr-part=\"indicator\" class=\"ml-2 shrink-0 opacity-0 transition-opacity group-data-[publr-state=selected]:opacity-100\">\n");
        try Icon(writer, .{ .name = .check,  .size = 16,  .class = "" });
        try writer.writeAll("\n</span>\n</div>");
    }
        }
    }.b);
}

pub const SelectSeparatorProps = struct {
    class: []const u8 = "",
};
pub fn SelectSeparator(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectSeparatorProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectSeparatorProps, _props);
    try writer.writeAll("<div role=\"separator\" class=\"my-1 h-px bg-border ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"></div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const SelectDemoProps = struct {
    demo: enum { basic, with_groups, disabled } = .basic,
    // Select
    name: []const u8 = "",
    default_value: []const u8 = "banana",
    // SelectValue
    placeholder: []const u8 = "",
};
pub fn SelectDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SelectDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.placeholder);
                    try SelectValue(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try SelectTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Apple");
                    try SelectItem(_children_w_1, .{ .value = "apple", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Banana");
                    try SelectItem(_children_w_1, .{ .value = "banana", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Cherry");
                    try SelectItem(_children_w_1, .{ .value = "cherry",  .disabled = true, .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Grape");
                    try SelectItem(_children_w_1, .{ .value = "grape", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Orange");
                    try SelectItem(_children_w_1, .{ .value = "orange", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try SelectContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Select(writer, .{ .name = props.name,  .default_value = props.default_value, .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_groups) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.placeholder);
                    try SelectValue(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try SelectTrigger(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Fruits");
                        try SelectLabel(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Apple");
                        try SelectItem(_children_w_2, .{ .value = "apple", .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Banana");
                        try SelectItem(_children_w_2, .{ .value = "banana", .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Cherry");
                        try SelectItem(_children_w_2, .{ .value = "cherry", .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try SelectGroup(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try SelectSeparator(_children_w_1, .{ });
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Vegetables");
                        try SelectLabel(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Carrot");
                        try SelectItem(_children_w_2, .{ .value = "carrot", .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Potato");
                        try SelectItem(_children_w_2, .{ .value = "potato",  .disabled = true, .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try SelectGroup(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try SelectContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Select(writer, .{ .name = props.name,  .default_value = props.default_value, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.placeholder);
                    try SelectValue(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try SelectTrigger(_children_w_0, .{ .disabled = true, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Apple");
                    try SelectItem(_children_w_1, .{ .value = "apple", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("Banana");
                    try SelectItem(_children_w_1, .{ .value = "banana", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try SelectContent(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Select(writer, .{ .name = props.name,  .default_value = props.default_value, .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const separator = struct {

/// Separator — visual divider.
///
/// Usage:
///   <Separator />
///   <Separator spacing=.lg />
pub const Direction = enum { horizontal, vertical };
pub const Spacing = enum { none, sm, md, lg, xl };
pub const SeparatorProps = struct {
    direction: Direction = .horizontal,
    spacing: Spacing = .none,
    class: []const u8 = "",
};
pub fn Separator(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SeparatorProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SeparatorProps, _props);
    const base = if (props.direction == .vertical) "border-l border-border self-stretch min-h-4" else "w-full border-t border-border";
    const margin = if (props.spacing == .none) "" else if (props.spacing == .sm) (if (props.direction == .horizontal) "my-2" else "mx-2") else if (props.spacing == .md) (if (props.direction == .horizontal) "my-3" else "mx-3") else if (props.spacing == .lg) (if (props.direction == .horizontal) "my-4" else "mx-4") else (if (props.direction == .horizontal) "my-6" else "mx-6");
    try writer.writeAll("<div data-publr-component=\"separator\" role=\"separator\" class=\"");
    try writer.writeAll(base);
    try writer.writeAll(" ");
    try writer.writeAll(margin);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"></div>");
        }
    }.b);
}

};

pub const sidebar = struct {

/// Sidebar — navigation sidebar with composable parts.
///
/// Sub-components matching shadcn API:
///   - Sidebar: outer container
///   - SidebarHeader: sticky top section
///   - SidebarContent: scrollable middle section
///   - SidebarFooter: sticky bottom section
///   - SidebarGroup: section within content
///   - SidebarGroupLabel: section heading (collapsible option)
///   - SidebarGroupContent: section body
///   - SidebarMenu: list container
///   - SidebarMenuItem: list item wrapper
///   - SidebarMenuButton: clickable nav item (is_active)
///   - SidebarMenuBadge: count badge on an item
///
/// Usage:
///   <Sidebar>
///       <SidebarHeader>
///           <span>Publr CMS</span>
///       </SidebarHeader>
///       <SidebarContent>
///           <SidebarGroup>
///               <SidebarGroupLabel>Content</SidebarGroupLabel>
///               <SidebarGroupContent>
///                   <SidebarMenu>
///                       <SidebarMenuItem>
///                           <SidebarMenuButton is_active={true}>
///                               <Icon name=.file size={16} class="" /> Pages
///                           </SidebarMenuButton>
///                       </SidebarMenuItem>
///                   </SidebarMenu>
///               </SidebarGroupContent>
///           </SidebarGroup>
///       </SidebarContent>
///   </Sidebar>
pub const Icon = root.icon.Icon;
pub const Variant = enum { default, transparent };
// ── Sub-components ──────────────────────────────────
pub const SidebarContainerProps = struct {
    children: []const u8 = "",
    variant: Variant = .default,
    class: []const u8 = "",
};
pub fn SidebarContainer(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarContainerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarContainerProps, _props);
    const surface_classes = switch (props.variant) {
        .default => "bg-sidebar border-r border-sidebar-border",
        .transparent => "bg-transparent",
    };
    try writer.writeAll("<nav data-publr-component=\"sidebar\" data-publr-variant=\"");
    try runtime.render(writer, props.variant);
    try writer.writeAll("\" class=\"flex h-full w-56 flex-col text-sidebar-foreground ");
    try writer.writeAll(surface_classes);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</nav>");
        }
    }.b);
}

pub const SidebarHeaderProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarHeader(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarHeaderProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarHeaderProps, _props);
    try writer.writeAll("<div data-publr-part=\"header\" class=\"flex items-center gap-2 px-3 py-4 border-b border-sidebar-border ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const SidebarContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" class=\"flex-1 overflow-y-auto px-2 py-2 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const SidebarFooterProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarFooter(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarFooterProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarFooterProps, _props);
    try writer.writeAll("<div data-publr-part=\"footer\" class=\"border-t border-sidebar-border px-2 py-2 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const SidebarGroupProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarGroup(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarGroupProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarGroupProps, _props);
    try writer.writeAll("<div data-publr-part=\"section\" data-publr-state=\"open\" class=\"mb-2 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const SidebarGroupLabelProps = struct {
    children: []const u8 = "",
    collapsible: bool = false,
    class: []const u8 = "",
};
pub fn SidebarGroupLabel(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarGroupLabelProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarGroupLabelProps, _props);
    if (props.collapsible) {
        try writer.writeAll("<button data-publr-part=\"section-trigger\" class=\"flex w-full items-center justify-between px-2 py-1 text-xs font-semibold text-muted-foreground uppercase tracking-wider hover:text-sidebar-foreground ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_down,  .size = 14,  .class = "" });
        try writer.writeAll("\n</button>");
    } else {
        try writer.writeAll("<span class=\"block px-2 py-1 text-xs font-semibold text-muted-foreground uppercase tracking-wider ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</span>");
    }
        }
    }.b);
}

pub const SidebarGroupContentProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarGroupContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarGroupContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarGroupContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"section-content\" class=\"mt-0.5 space-y-0.5 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const SidebarMenuProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarMenu(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarMenuProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuProps, _props);
    try writer.writeAll("<div class=\"space-y-0.5 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const SidebarMenuItemProps = struct {
    children: []const u8 = "",
};
pub fn SidebarMenuItem(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarMenuItemProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuItemProps, _props);
    try writer.writeAll("<div>");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
        }
    }.b);
}

pub const SidebarMenuButtonProps = struct {
    href: []const u8 = "#",
    is_active: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarMenuButton(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarMenuButtonProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuButtonProps, _props);
    const base = "flex items-center gap-2 rounded-md px-2 py-1.5 text-sm transition-colors";
    if (props.is_active) {
        try writer.writeAll("<a data-publr-part=\"item\" aria-current=\"page\" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" bg-sidebar-primary text-sidebar-primary-foreground ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</a>");
    } else {
        try writer.writeAll("<a data-publr-part=\"item\" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-sidebar-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n</a>");
    }
        }
    }.b);
}

pub const SidebarMenuBadgeProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn SidebarMenuBadge(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarMenuBadgeProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuBadgeProps, _props);
    try writer.writeAll("<span class=\"ml-auto inline-flex items-center rounded-full bg-sidebar-accent px-1.5 py-0.5 text-[10px] font-medium text-sidebar-accent-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

// ── Gallery preview (matches filename, no gallery_entry) ──
pub const SidebarProps = struct {
    collapsible: bool = false,
    variant: Variant = .default,
};
pub fn Sidebar(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SidebarProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            try _children_w_1.writeAll("\n<span class=\"text-sm font-semibold text-sidebar-foreground\">Publr CMS</span>\n");
            try SidebarHeader(_children_w_0, .{ .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("Content");
                    try SidebarGroupLabel(_children_w_2, .{ .collapsible = props.collapsible, .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("\n");
                    {
                        var _children_buf_4: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_4 = @import("std").heap.page_allocator;
                        defer _children_buf_4.deinit(_children_alloc_4);
                        const _children_w_4 = _children_buf_4.writer(_children_alloc_4);
                        _ = &_children_w_4;
                        try _children_w_4.writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            const _children_w_5 = _children_buf_5.writer(_children_alloc_5);
                            _ = &_children_w_5;
                            try _children_w_5.writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                const _children_w_6 = _children_buf_6.writer(_children_alloc_6);
                                _ = &_children_w_6;
                                try _children_w_6.writeAll("\n");
                                try Icon(_children_w_6, .{ .name = .file,  .size = 16,  .class = "" });
                                try _children_w_6.writeAll(" Pages\n                            ");
                                try SidebarMenuButton(_children_w_5, .{ .is_active = true, .children = _children_buf_6.items });
                            }
                            try _children_w_5.writeAll("\n");
                            try SidebarMenuItem(_children_w_4, .{ .children = _children_buf_5.items });
                        }
                        try _children_w_4.writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            const _children_w_5 = _children_buf_5.writer(_children_alloc_5);
                            _ = &_children_w_5;
                            try _children_w_5.writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                const _children_w_6 = _children_buf_6.writer(_children_alloc_6);
                                _ = &_children_w_6;
                                try _children_w_6.writeAll("\n");
                                try Icon(_children_w_6, .{ .name = .edit,  .size = 16,  .class = "" });
                                try _children_w_6.writeAll(" Posts\n                                ");
                                {
                                    var _children_buf_7: @import("std").ArrayListUnmanaged(u8) = .{};
                                    const _children_alloc_7 = @import("std").heap.page_allocator;
                                    defer _children_buf_7.deinit(_children_alloc_7);
                                    const _children_w_7 = _children_buf_7.writer(_children_alloc_7);
                                    _ = &_children_w_7;
                                    try _children_w_7.writeAll("12");
                                    try SidebarMenuBadge(_children_w_6, .{ .children = _children_buf_7.items });
                                }
                                try _children_w_6.writeAll("\n");
                                try SidebarMenuButton(_children_w_5, .{ .children = _children_buf_6.items });
                            }
                            try _children_w_5.writeAll("\n");
                            try SidebarMenuItem(_children_w_4, .{ .children = _children_buf_5.items });
                        }
                        try _children_w_4.writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            const _children_w_5 = _children_buf_5.writer(_children_alloc_5);
                            _ = &_children_w_5;
                            try _children_w_5.writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                const _children_w_6 = _children_buf_6.writer(_children_alloc_6);
                                _ = &_children_w_6;
                                try _children_w_6.writeAll("\n");
                                try Icon(_children_w_6, .{ .name = .image,  .size = 16,  .class = "" });
                                try _children_w_6.writeAll(" Media\n                            ");
                                try SidebarMenuButton(_children_w_5, .{ .children = _children_buf_6.items });
                            }
                            try _children_w_5.writeAll("\n");
                            try SidebarMenuItem(_children_w_4, .{ .children = _children_buf_5.items });
                        }
                        try _children_w_4.writeAll("\n");
                        try SidebarMenu(_children_w_3, .{ .children = _children_buf_4.items });
                    }
                    try _children_w_3.writeAll("\n");
                    try SidebarGroupContent(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                try SidebarGroup(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("System");
                    try SidebarGroupLabel(_children_w_2, .{ .collapsible = props.collapsible, .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("\n");
                    {
                        var _children_buf_4: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_4 = @import("std").heap.page_allocator;
                        defer _children_buf_4.deinit(_children_alloc_4);
                        const _children_w_4 = _children_buf_4.writer(_children_alloc_4);
                        _ = &_children_w_4;
                        try _children_w_4.writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            const _children_w_5 = _children_buf_5.writer(_children_alloc_5);
                            _ = &_children_w_5;
                            try _children_w_5.writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                const _children_w_6 = _children_buf_6.writer(_children_alloc_6);
                                _ = &_children_w_6;
                                try _children_w_6.writeAll("\n");
                                try Icon(_children_w_6, .{ .name = .settings,  .size = 16,  .class = "" });
                                try _children_w_6.writeAll(" Settings\n                            ");
                                try SidebarMenuButton(_children_w_5, .{ .children = _children_buf_6.items });
                            }
                            try _children_w_5.writeAll("\n");
                            try SidebarMenuItem(_children_w_4, .{ .children = _children_buf_5.items });
                        }
                        try _children_w_4.writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            const _children_w_5 = _children_buf_5.writer(_children_alloc_5);
                            _ = &_children_w_5;
                            try _children_w_5.writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                const _children_w_6 = _children_buf_6.writer(_children_alloc_6);
                                _ = &_children_w_6;
                                try _children_w_6.writeAll("\n");
                                try Icon(_children_w_6, .{ .name = .users,  .size = 16,  .class = "" });
                                try _children_w_6.writeAll(" Users\n                            ");
                                try SidebarMenuButton(_children_w_5, .{ .children = _children_buf_6.items });
                            }
                            try _children_w_5.writeAll("\n");
                            try SidebarMenuItem(_children_w_4, .{ .children = _children_buf_5.items });
                        }
                        try _children_w_4.writeAll("\n");
                        try SidebarMenu(_children_w_3, .{ .children = _children_buf_4.items });
                    }
                    try _children_w_3.writeAll("\n");
                    try SidebarGroupContent(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                try SidebarGroup(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            try SidebarContent(_children_w_0, .{ .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                try Icon(_children_w_2, .{ .name = .user,  .size = 16,  .class = "" });
                try _children_w_2.writeAll(" Account\n            ");
                try SidebarMenuButton(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            try SidebarFooter(_children_w_0, .{ .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        try SidebarContainer(writer, .{ .variant = props.variant, .children = _children_buf_0.items });
    }
        }
    }.b);
}

};

pub const stack = struct {

/// Stack — universal layout container.
///
/// Usage:
///   <Stack gap=.lg padding=.xl>content</Stack>
///   <Stack direction=.horizontal gap=.md items=.center>items</Stack>
///   <Stack border=.bottom background=.muted padding=.lg>header</Stack>
///   <Stack width=.panel border=.left overflow=.scroll grow={true}>sidebar</Stack>
pub const Direction = enum { vertical, horizontal };
pub const Gap = enum { none, xs, sm, md, lg, xl, @"2xl" };
pub const Align = enum { start, center, end, stretch, baseline };
pub const Justify = enum { start, center, end, between };
pub const Border = enum { none, bottom, top, left, right, all };
pub const Background = enum { none, default, muted, card };
pub const Overflow = enum { visible, scroll };
pub const Width = enum { auto, full, sidebar, panel };
pub const MinHeight = enum { auto, screen };
pub const StackProps = struct {
    direction: Direction = .vertical,
    gap: Gap = .md,
    items: Align = .stretch,
    justify: Justify = .start,
    padding: Gap = .none,
    border: Border = .none,
    background: Background = .none,
    overflow: Overflow = .visible,
    width: Width = .auto,
    grow: bool = false,
    push: bool = false,
    min_height: MinHeight = .auto,
    class: []const u8 = "",
    children: []const u8 = "",
};
pub fn Stack(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(StackProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StackProps, _props);
    const dir = if (props.direction == .horizontal) "flex-row" else "flex-col";
    const gap_c = if (props.gap == .none) "" else if (props.gap == .xs) "gap-1" else if (props.gap == .sm) "gap-2" else if (props.gap == .md) "gap-3" else if (props.gap == .lg) "gap-4" else if (props.gap == .xl) "gap-6" else "gap-8";
    const items_c = if (props.items == .start) "items-start" else if (props.items == .center) "items-center" else if (props.items == .end) "items-end" else if (props.items == .baseline) "items-baseline" else "items-stretch";
    const justify_c = if (props.justify == .center) "justify-center" else if (props.justify == .end) "justify-end" else if (props.justify == .between) "justify-between" else "";
    const pad_c = if (props.padding == .none) "" else if (props.padding == .xs) "p-1" else if (props.padding == .sm) "p-2" else if (props.padding == .md) "p-3" else if (props.padding == .lg) "p-4" else if (props.padding == .xl) "p-6" else "p-8";
    const border_c = if (props.border == .bottom) "border-b border-border" else if (props.border == .top) "border-t border-border" else if (props.border == .left) "border-l border-border" else if (props.border == .right) "border-r border-border" else if (props.border == .all) "border border-border" else "";
    const bg_c = if (props.background == .default) "bg-background" else if (props.background == .muted) "bg-muted" else if (props.background == .card) "bg-card" else "";
    const overflow_c = if (props.overflow == .scroll) "overflow-y-auto" else "";
    const width_c = if (props.width == .full) "w-full" else if (props.width == .sidebar) "w-56 shrink-0" else if (props.width == .panel) "w-80 shrink-0" else "";
    const grow_c = if (props.grow) "flex-1 min-w-0" else "";
    const push_c = if (props.push) (if (props.direction == .horizontal) "ml-auto" else "mt-auto") else "";
    const mh_c = if (props.min_height == .screen) "min-h-screen" else "";
    try writer.writeAll("<div data-publr-component=\"stack\" class=\"flex ");
    try writer.writeAll(dir);
    try writer.writeAll(" ");
    try writer.writeAll(gap_c);
    try writer.writeAll(" ");
    try writer.writeAll(items_c);
    try writer.writeAll(" ");
    try writer.writeAll(justify_c);
    try writer.writeAll(" ");
    try writer.writeAll(pad_c);
    try writer.writeAll(" ");
    try writer.writeAll(border_c);
    try writer.writeAll(" ");
    try writer.writeAll(bg_c);
    try writer.writeAll(" ");
    try writer.writeAll(overflow_c);
    try writer.writeAll(" ");
    try writer.writeAll(width_c);
    try writer.writeAll(" ");
    try writer.writeAll(grow_c);
    try writer.writeAll(" ");
    try writer.writeAll(push_c);
    try writer.writeAll(" ");
    try writer.writeAll(mh_c);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

};

pub const status = struct {

/// Status — dot-prefixed workflow status text.
///
/// Compact inline indicator for entry workflow states: a small tone-colored
/// dot followed by the state label in matching text. Tones map to semantic
/// tokens (never raw palette scales) so they track light/dark themes:
///
///   - published → success
///   - review    → review (violet)
///   - draft     → muted
///   - scheduled → warning
///   - changed   → primary
///
/// The label defaults to the capitalized tone name; pass `label` to override
/// (e.g. localized or custom copy).
///
/// Emits the badge data-contract (`data-publr-color="status"`) plus
/// `data-publr-tone` for styling hooks — matches the POC reference markup.
///
/// Example:
///   <Status tone=.published />
///   <Status tone=.review label="In review" />
pub const Tone = enum { published, review, draft, scheduled, changed };
pub const StatusProps = struct {
    tone: Tone = .draft,
    label: []const u8 = "",
    class: []const u8 = "",
};
pub fn Status(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(StatusProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StatusProps, _props);
    const text_class = switch (props.tone) {
        .published => "text-success",
        .review => "text-review",
        .draft => "text-muted-foreground",
        .scheduled => "text-warning",
        .changed => "text-primary",
    };
    const dot_class = switch (props.tone) {
        .published => "bg-success",
        .review => "bg-review",
        .draft => "bg-gray-400",
        .scheduled => "bg-warning",
        .changed => "bg-primary",
    };
    const derived_label = switch (props.tone) {
        .published => "Published",
        .review => "Review",
        .draft => "Draft",
        .scheduled => "Scheduled",
        .changed => "Changed",
    };
    const resolved_label = if (props.label.len > 0) props.label else derived_label;
    try writer.writeAll("<span data-publr-component=\"badge\" data-publr-color=\"status\" data-publr-type=\"badge\" data-publr-size=\"sm\" data-publr-tone=\"");
    try runtime.render(writer, props.tone);
    try writer.writeAll("\" class=\"inline-flex items-center gap-1.5 whitespace-nowrap text-xs font-medium ");
    try writer.writeAll(text_class);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n<span aria-hidden=\"true\" class=\"size-1.5 shrink-0 rounded-full ");
    try writer.writeAll(dot_class);
    try writer.writeAll("\"></span>\n");
    try runtime.render(writer, resolved_label);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const StatusDemoProps = struct {
    tone: Tone = .published,
};
pub fn StatusDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(StatusDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StatusDemoProps, _props);
    try Status(writer, .{ .tone = props.tone });
        }
    }.b);
}

};

pub const @"switch" = struct {

/// Switch — toggle control with label.
///
/// Renders a `<label>` wrapping a hidden native checkbox and a styled track/thumb.
/// The thumb position and track color are driven by `:checked` CSS state.
///
/// No custom JS needed — native checkbox handles state. Minimal JS syncs `aria-checked`.
///
/// Example:
///   <Switch label="Enable notifications" />
///   <Switch label="Dark mode" checked={true} />
///   <Switch label="Maintenance" disabled={true} />
pub const Size = enum { sm, md, lg };
pub const SwitchProps = struct {
    label: []const u8 = "Toggle",
    name: []const u8 = "",
    size: Size = .md,
    checked: bool = false,
    disabled: bool = false,
    class: []const u8 = "",
};
pub fn Switch(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(SwitchProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SwitchProps, _props);
    const track_size = switch (props.size) {
        .sm => "w-8 h-4",
        .md => "w-10 h-5",
        .lg => "w-12 h-6",
    };

    const thumb_size = switch (props.size) {
        .sm => "h-3 w-3",
        .md => "h-4 w-4",
        .lg => "h-5 w-5",
    };

    const thumb_translate = switch (props.size) {
        .sm => "peer-checked:translate-x-4",
        .md => "peer-checked:translate-x-5",
        .lg => "peer-checked:translate-x-6",
    };

    const label_size = switch (props.size) {
        .sm => "text-xs",
        .md => "text-sm",
        .lg => "text-md",
    };
    const state = if (props.checked) "checked" else "unchecked";
    const container_class = if (props.disabled)
        "inline-flex items-center gap-2 cursor-not-allowed opacity-50"
    else
        "inline-flex items-center gap-2 cursor-pointer";
    if (props.disabled and props.checked) {
        try writer.writeAll("<label data-p-store=\"local:switch\" data-publr-component=\"switch\" data-p-on=\"change:sync\" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(container_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<span class=\"relative inline-flex items-center shrink-0\">\n<input type=\"checkbox\" class=\"peer sr-only\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n<span class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary\"></span>\n<span class=\"absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"></span>\n</span>\n<span class=\"text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>\n</label>");
    } else if (props.disabled) {
        try writer.writeAll("<label data-p-store=\"local:switch\" data-publr-component=\"switch\" data-p-on=\"change:sync\" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(container_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<span class=\"relative inline-flex items-center shrink-0\">\n<input type=\"checkbox\" class=\"peer sr-only\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n<span class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary\"></span>\n<span class=\"absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"></span>\n</span>\n<span class=\"text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>\n</label>");
    } else if (props.checked) {
        try writer.writeAll("<label data-p-store=\"local:switch\" data-publr-component=\"switch\" data-p-on=\"change:sync\" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(container_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<span class=\"relative inline-flex items-center shrink-0\">\n<input type=\"checkbox\" class=\"peer sr-only\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n<span class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary\"></span>\n<span class=\"absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"></span>\n</span>\n<span class=\"text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>\n</label>");
    } else {
        try writer.writeAll("<label data-p-store=\"local:switch\" data-publr-component=\"switch\" data-p-on=\"change:sync\" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(container_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n<span class=\"relative inline-flex items-center shrink-0\">\n<input type=\"checkbox\" class=\"peer sr-only\" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\">\n<span class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary\"></span>\n<span class=\"absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"></span>\n</span>\n<span class=\"text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>\n</label>");
    }
        }
    }.b);
}

};

pub const table = struct {

/// Table — data table with composable parts.
///
/// Sub-components:
///   - Table: `<table>` element (wrapped in overflow container)
///   - TableCaption: caption text
///   - TableHeader: `<thead>` element
///   - TableBody: `<tbody>` element
///   - TableFooter: `<tfoot>` element
///   - TableRow: `<tr>` element. `selected` prop drives `data-publr-state`.
///   - TableHead: `<th>` element. `sortable` + `sort_direction` add a sort
///     indicator (chevron up/down/stacked) and `data-publr-part="sort-trigger"`.
///   - TableCell: `<td>` element
///
/// Usage:
///   <Table>
///       <TableHeader>
///           <TableRow>
///               <TableHead sortable={true} sort_direction=.ascending href="?sort=name">Name</TableHead>
///               <TableHead>Email</TableHead>
///           </TableRow>
///       </TableHeader>
///       <TableBody>
///           <TableRow>
///               <TableCell>Olivia</TableCell>
///               <TableCell>olivia@example.com</TableCell>
///           </TableRow>
///       </TableBody>
///   </Table>
pub const Icon = root.icon.Icon;
pub const Badge = root.badge.Badge;
pub const Checkbox = root.checkbox.Checkbox;
pub const Avatar = root.avatar.Avatar;
pub const AvatarFallback = root.avatar.AvatarFallback;
pub const Button = root.button.Button;
pub const Flex = root.flex.Flex;
pub const Text = root.text.Text;
pub const Separator = root.separator.Separator;
pub const SortDirection = enum { none, ascending, descending };
// ── Sub-components ──────────────────────────────────
pub const TableProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Table(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableProps, _props);
    try writer.writeAll("<div data-publr-component=\"table\" class=\"w-full overflow-auto ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n<table class=\"w-full caption-bottom border-collapse\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</table>\n</div>");
        }
    }.b);
}

/// TableBulkBar — surfaces above a Table when rows are selected.
/// Shows a master checkbox (with indeterminate state for partial selection),
/// a "N selected of M" count, an action slot for edit/tag/export/delete buttons,
/// and a clear-selection link. Wire master <-> row checkboxes in consumer JS.
pub const TableBulkBarProps = struct {
    selected: u32 = 0,
    total: u32 = 0,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TableBulkBar(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableBulkBarProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableBulkBarProps, _props);
    const hidden_class = if (props.selected == 0) "hidden" else "";
    try writer.writeAll("<div data-publr-component=\"table-bulk-bar\" data-publr-state=\"");
    try runtime.render(writer, if (props.selected == 0) "empty" else "active");
    try writer.writeAll("\" class=\"");
    try writer.writeAll(hidden_class);
    try writer.writeAll(" flex h-10 items-center gap-3 border-b border-border bg-primary/10 px-4 text-xs text-primary ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n<span class=\"font-semibold\"><span data-publr-part=\"count\">");
    try runtime.render(writer, props.selected);
    try writer.writeAll("</span> selected</span>\n<span data-publr-part=\"actions\" class=\"contents\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</span>\n<span data-publr-part=\"clear\" class=\"ml-auto cursor-pointer font-medium hover:underline\">Clear selection</span>\n</div>");
        }
    }.b);
}

pub const TableCaptionProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TableCaption(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableCaptionProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableCaptionProps, _props);
    try writer.writeAll("<caption class=\"mt-4 text-sm text-muted-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</caption>");
        }
    }.b);
}

pub const TableHeaderProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TableHeader(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableHeaderProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableHeaderProps, _props);
    try writer.writeAll("<thead data-publr-part=\"header\" class=\"bg-muted/30 border-b border-border ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</thead>");
        }
    }.b);
}

pub const TableBodyProps = struct {
    children: []const u8 = "",
};
pub fn TableBody(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableBodyProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableBodyProps, _props);
    try writer.writeAll("<tbody data-publr-part=\"body\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</tbody>");
        }
    }.b);
}

pub const TableFooterProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TableFooter(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableFooterProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableFooterProps, _props);
    try writer.writeAll("<tfoot data-publr-part=\"footer\" class=\"border-t border-border bg-muted/30 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</tfoot>");
        }
    }.b);
}

pub const TableRowProps = struct {
    children: []const u8 = "",
    selected: bool = false,
    class: []const u8 = "",
};
pub fn TableRow(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableRowProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableRowProps, _props);
    try writer.writeAll("<tr data-publr-state=\"");
    try runtime.render(writer, if (props.selected) "selected" else "unselected");
    try writer.writeAll("\" class=\"border-b border-border last:border-b-0 hover:bg-muted/30 transition-colors ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</tr>");
        }
    }.b);
}

pub const TableHeadProps = struct {
    children: []const u8 = "",
    sortable: bool = false,
    sort_direction: SortDirection = .none,
    href: []const u8 = "#",
    // Dense admin-list treatment: h-12 uppercase micro-type header.
    dense: bool = false,
    class: []const u8 = "",
};
pub fn TableHead(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableHeadProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableHeadProps, _props);
    const aria_sort: []const u8 = switch (props.sort_direction) {
        .ascending => "ascending",
        .descending => "descending",
        .none => "none",
    };

    const head_class = if (props.dense)
        "h-12 text-left align-middle text-3xs font-semibold uppercase tracking-[0.08em] text-muted-foreground px-4 whitespace-nowrap"
    else
        "text-left text-xs font-medium text-muted-foreground px-6 py-3 whitespace-nowrap";
    try writer.writeAll("<th aria-sort=\"");
    try runtime.render(writer, aria_sort);
    try writer.writeAll("\" class=\"");
    try writer.writeAll(head_class);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    if (props.sortable) {
        try writer.writeAll("<a data-publr-part=\"sort-trigger\" class=\"inline-flex items-center gap-1.5 cursor-pointer hover:text-foreground transition-colors\" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        if (props.sort_direction == .ascending) {
            try Icon(writer, .{ .name = .chevron_up,  .size = 12,  .class = "shrink-0" });
        } else if (props.sort_direction == .descending) {
            try Icon(writer, .{ .name = .chevron_down,  .size = 12,  .class = "shrink-0" });
        } else {
            try writer.writeAll("<span class=\"inline-flex flex-col -space-y-1 opacity-50 shrink-0\">\n");
            try Icon(writer, .{ .name = .chevron_up,  .size = 10,  .class = "" });
            try writer.writeAll("\n");
            try Icon(writer, .{ .name = .chevron_down,  .size = 10,  .class = "" });
            try writer.writeAll("\n</span>");
        }
        try writer.writeAll("\n</a>");
    } else {
        try writer.writeAll(props.children);
    }
    try writer.writeAll("\n</th>");
        }
    }.b);
}

pub const TableCellProps = struct {
    children: []const u8 = "",
    // Dense admin-list treatment: tighter padding, middle alignment.
    dense: bool = false,
    class: []const u8 = "",
};
pub fn TableCell(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableCellProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableCellProps, _props);
    const cell_class = if (props.dense)
        "px-4 py-3 align-middle text-sm text-foreground"
    else
        "px-6 py-4 text-sm text-foreground";
    try writer.writeAll("<td class=\"");
    try writer.writeAll(cell_class);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</td>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
const NameCellProps = struct { initials: []const u8, full: []const u8, handle: []const u8 };
fn NameCell(writer: anytype, props: anytype) !void {
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try runtime.render(_children_w_2, props.initials);
                try AvatarFallback(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try Avatar(_children_w_0, .{ .size = .sm, .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try runtime.render(_children_w_2, props.full);
                try Text(_children_w_1, .{ .as = .span,  .size = .sm,  .weight = .medium, .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try runtime.render(_children_w_2, props.handle);
                try Text(_children_w_1, .{ .as = .span,  .size = .xs,  .color = .muted,  .class = "font-mono", .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            try Flex(_children_w_0, .{ .class = "flex-col items-start",  .gap = .none, .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .items = .center,  .gap = .sm, .children = _children_buf_0.items });
    }
}

const RowActionsProps = struct {};
fn RowActions(writer: anytype, _: anytype) !void {
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try Button(_children_w_0, .{ .hierarchy = .tertiary,  .size = .sm,  .icon = .trash,  .aria_label = "Delete row" });
        try _children_w_0.writeAll("\n");
        try Button(_children_w_0, .{ .hierarchy = .tertiary,  .size = .sm,  .icon = .edit,  .aria_label = "Edit row" });
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .items = .center,  .gap = .xs,  .justify = .end, .children = _children_buf_0.items });
    }
}

pub const TableDemoProps = struct {
    selectable: bool = false,
    sortable: bool = false,
    show_footer: bool = false,
    show_bulk_bar: bool = false,
};
pub fn TableDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TableDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableDemoProps, _props);
    try writer.writeAll("<div>\n");
    if (props.show_bulk_bar and props.selectable) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            try Button(_children_w_0, .{ .hierarchy = .tertiary,  .size = .sm,  .icon = .edit,  .label = "Edit" });
            try _children_w_0.writeAll("\n");
            try Button(_children_w_0, .{ .hierarchy = .tertiary,  .size = .sm,  .icon = .tag,  .label = "Tag" });
            try _children_w_0.writeAll("\n");
            try Button(_children_w_0, .{ .hierarchy = .tertiary,  .size = .sm,  .icon = .upload,  .label = "Export" });
            try _children_w_0.writeAll("\n");
            try Button(_children_w_0, .{ .hierarchy = .tertiary,  .size = .sm,  .icon = .trash,  .label = "Delete",  .class = "text-destructive" });
            try _children_w_0.writeAll("\n");
            try TableBulkBar(writer, .{ .selected = 2,  .total = 3, .children = _children_buf_0.items });
        }
    }
    try writer.writeAll("\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                if (props.selectable) {
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Checkbox(_children_w_3, .{ .checked = .indeterminate });
                        try TableHead(_children_w_2, .{ .class = "w-10", .children = _children_buf_3.items });
                    }
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("Name");
                    try TableHead(_children_w_2, .{ .sortable = props.sortable,  .sort_direction = if (props.sortable) SortDirection.ascending else SortDirection.none,  .href = "?sort=name", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("Status");
                    try TableHead(_children_w_2, .{ .sortable = props.sortable, .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("Email");
                    try TableHead(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("Actions");
                    try TableHead(_children_w_2, .{ .class = "text-right w-px", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                try TableRow(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            try TableHeader(_children_w_0, .{ .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                if (props.selectable and props.show_bulk_bar) {
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Checkbox(_children_w_3, .{ .checked = .checked });
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                } else if (props.selectable) {
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Checkbox(_children_w_3, .{ });
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try NameCell(_children_w_3, .{ .initials = "OR",  .full = "Olivia Rhye",  .handle = "@olivia" });
                    try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try Badge(_children_w_3, .{ .label = "Active",  .color = .success,  .size = .sm,  .show_dot = true });
                    try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("olivia@publr.dev");
                    try TableCell(_children_w_2, .{ .class = "font-mono text-muted-foreground", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try RowActions(_children_w_3, .{ });
                    try TableCell(_children_w_2, .{ .class = "text-right", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                try TableRow(_children_w_1, .{ .selected = props.show_bulk_bar and props.selectable, .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                if (props.selectable and props.show_bulk_bar) {
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Checkbox(_children_w_3, .{ .checked = .checked });
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                } else if (props.selectable) {
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Checkbox(_children_w_3, .{ });
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try NameCell(_children_w_3, .{ .initials = "PB",  .full = "Phoenix Baker",  .handle = "@phoenix" });
                    try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try Badge(_children_w_3, .{ .label = "Draft",  .color = .warning,  .size = .sm,  .show_dot = true });
                    try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("phoenix@publr.dev");
                    try TableCell(_children_w_2, .{ .class = "font-mono text-muted-foreground", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try RowActions(_children_w_3, .{ });
                    try TableCell(_children_w_2, .{ .class = "text-right", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                try TableRow(_children_w_1, .{ .selected = props.show_bulk_bar and props.selectable, .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                if (props.selectable) {
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try Checkbox(_children_w_3, .{ });
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try NameCell(_children_w_3, .{ .initials = "LS",  .full = "Lana Steiner",  .handle = "@lana" });
                    try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try Badge(_children_w_3, .{ .label = "Inactive",  .color = .secondary,  .size = .sm });
                    try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try _children_w_3.writeAll("lana@publr.dev");
                    try TableCell(_children_w_2, .{ .class = "font-mono text-muted-foreground", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try RowActions(_children_w_3, .{ });
                    try TableCell(_children_w_2, .{ .class = "text-right", .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                try TableRow(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            try TableBody(_children_w_0, .{ .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        if (props.show_footer) {
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try _children_w_2.writeAll("\n");
                    if (props.selectable) {
                        {
                            var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_3 = @import("std").heap.page_allocator;
                            defer _children_buf_3.deinit(_children_alloc_3);
                            const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                            _ = &_children_w_3;
                            try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                        }
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("Total");
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try TableCell(_children_w_2, .{ .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                        _ = &_children_w_3;
                        try _children_w_3.writeAll("3 entries");
                        try TableCell(_children_w_2, .{ .class = "text-right", .children = _children_buf_3.items });
                    }
                    try _children_w_2.writeAll("\n");
                    try TableRow(_children_w_1, .{ .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try TableFooter(_children_w_0, .{ .children = _children_buf_1.items });
            }
        }
        try _children_w_0.writeAll("\n");
        try Table(writer, .{ .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

};

pub const tabs = struct {

/// Tabs — tabbed content panels.
///
/// Sub-components matching shadcn API:
///   - Tabs: root container (default_value)
///   - TabsList: tab trigger container (variant: default/line)
///   - TabsTrigger: individual tab button (value, disabled)
///   - TabsContent: individual tab panel (value)
///
/// Link triggers to panels via matching `value` prop.
///
/// Usage:
///   <Tabs default_value="account">
///       <TabsList>
///           <TabsTrigger value="account">Account</TabsTrigger>
///           <TabsTrigger value="password">Password</TabsTrigger>
///       </TabsList>
///       <TabsContent value="account">Account settings.</TabsContent>
///       <TabsContent value="password">Password settings.</TabsContent>
///   </Tabs>
// ── Sub-components ──────────────────────────────────
pub const TabsProps = struct {
    default_value: []const u8 = "",
    children: []const u8 = "",
};
pub fn Tabs(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TabsProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsProps, _props);
    try writer.writeAll("<div data-p-store=\"local:tabs\" data-publr-component=\"tabs\" data-publr-default-value=\"");
    try runtime.render(writer, props.default_value);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const Variant = enum { default, line };
pub const TabsListProps = struct {
    variant: Variant = .default,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TabsList(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TabsListProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsListProps, _props);
    const list_class = if (props.variant == .line)
        "inline-flex items-center gap-5 border-b border-border"
    else
        "inline-flex items-center gap-1 rounded-lg bg-muted p-1";
    try writer.writeAll("<div data-publr-part=\"list\" role=\"tablist\" data-p-on=\"click:tabClick;keydown:navKeys\" data-publr-variant=\"");
    try runtime.render(writer, props.variant);
    try writer.writeAll("\" class=\"");
    try writer.writeAll(list_class);
    try writer.writeAll(" ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const TabsTriggerProps = struct {
    value: []const u8 = "",
    variant: Variant = .default,
    disabled: bool = false,
    // Optional trailing count (e.g. entry totals on list tabs).
    count: []const u8 = "",
    count_class: []const u8 = "text-muted-foreground",
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TabsTrigger(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TabsTriggerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsTriggerProps, _props);
    const trigger_class = if (props.variant == .line)
        "h-12 shrink-0 border-b-2 border-transparent px-0.5 text-xs font-medium transition-colors data-[publr-state=active]:border-foreground data-[publr-state=active]:text-foreground data-[publr-state=inactive]:text-muted-foreground data-[publr-state=inactive]:hover:text-foreground disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:text-muted-foreground"
    else
        "px-3 py-1.5 text-sm font-medium rounded-md transition-colors data-[publr-state=active]:bg-background data-[publr-state=active]:text-foreground data-[publr-state=active]:shadow-xs data-[publr-state=inactive]:text-muted-foreground data-[publr-state=inactive]:hover:text-foreground disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:text-muted-foreground";
    if (props.disabled) {
        try writer.writeAll("<button data-publr-part=\"trigger\" data-publr-state=\"inactive\" role=\"tab\" aria-selected=\"false\" aria-disabled=\"true\" tabindex=\"-1\" data-publr-tab=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" id=\"publr-tab-trigger-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\" aria-controls=\"publr-tab-content-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(trigger_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        if (props.count.len > 0) {
            try writer.writeAll("<span data-publr-part=\"count\" class=\"ml-1 ");
            try writer.writeAll(props.count_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.count);
            try writer.writeAll("</span>");
        }
        try writer.writeAll("\n</button>");
    } else {
        try writer.writeAll("<button data-publr-part=\"trigger\" data-publr-state=\"inactive\" role=\"tab\" aria-selected=\"false\" tabindex=\"-1\" data-publr-tab=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\" id=\"publr-tab-trigger-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\" aria-controls=\"publr-tab-content-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\" class=\"");
        try writer.writeAll(trigger_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        if (props.count.len > 0) {
            try writer.writeAll("<span data-publr-part=\"count\" class=\"ml-1 ");
            try writer.writeAll(props.count_class);
            try writer.writeAll("\">");
            try runtime.render(writer, props.count);
            try writer.writeAll("</span>");
        }
        try writer.writeAll("\n</button>");
    }
        }
    }.b);
}

pub const TabsContentProps = struct {
    value: []const u8 = "",
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TabsContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TabsContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" data-publr-state=\"inactive\" role=\"tabpanel\" data-publr-tab=\"");
    try runtime.render(writer, props.value);
    try writer.writeAll("\" id=\"publr-tab-content-");
    try runtime.escape(writer, props.value);
    try writer.writeAll("\" aria-labelledby=\"publr-tab-trigger-");
    try runtime.escape(writer, props.value);
    try writer.writeAll("\" class=\"mt-4 text-sm text-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\" hidden=\"");
    try runtime.render(writer, true);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const TabsDemoProps = struct {
    demo: enum { default, line } = .default,
    default_value: []const u8 = "tab1",
    // TabsTrigger labels (suffix _N for instance matching)
    label_1: []const u8 = "",
    label_2: []const u8 = "",
    label_3: []const u8 = "",
    // TabsContent text
    content_1: []const u8 = "",
    content_2: []const u8 = "",
    content_3: []const u8 = "",
};
pub fn TabsDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TabsDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsDemoProps, _props);
    if (props.demo == .line) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.label_1);
                    try TabsTrigger(_children_w_1, .{ .value = "tab1",  .variant = .line,  .count = "12", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.label_2);
                    try TabsTrigger(_children_w_1, .{ .value = "tab2",  .variant = .line, .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.label_3);
                    try TabsTrigger(_children_w_1, .{ .value = "tab3",  .variant = .line,  .disabled = true, .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try TabsList(_children_w_0, .{ .variant = .line, .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n<p>");
                try runtime.render(_children_w_1, props.content_1);
                try _children_w_1.writeAll("</p>\n");
                try TabsContent(_children_w_0, .{ .value = "tab1", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n<p>");
                try runtime.render(_children_w_1, props.content_2);
                try _children_w_1.writeAll("</p>\n");
                try TabsContent(_children_w_0, .{ .value = "tab2", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n<p>");
                try runtime.render(_children_w_1, props.content_3);
                try _children_w_1.writeAll("</p>\n");
                try TabsContent(_children_w_0, .{ .value = "tab3", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Tabs(writer, .{ .default_value = props.default_value, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
            _ = &_children_w_0;
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.label_1);
                    try TabsTrigger(_children_w_1, .{ .value = "tab1", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.label_2);
                    try TabsTrigger(_children_w_1, .{ .value = "tab2", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                    _ = &_children_w_2;
                    try runtime.render(_children_w_2, props.label_3);
                    try TabsTrigger(_children_w_1, .{ .value = "tab3", .children = _children_buf_2.items });
                }
                try _children_w_1.writeAll("\n");
                try TabsList(_children_w_0, .{ .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n<p>");
                try runtime.render(_children_w_1, props.content_1);
                try _children_w_1.writeAll("</p>\n");
                try TabsContent(_children_w_0, .{ .value = "tab1", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n<p>");
                try runtime.render(_children_w_1, props.content_2);
                try _children_w_1.writeAll("</p>\n");
                try TabsContent(_children_w_0, .{ .value = "tab2", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
                _ = &_children_w_1;
                try _children_w_1.writeAll("\n<p>");
                try runtime.render(_children_w_1, props.content_3);
                try _children_w_1.writeAll("</p>\n");
                try TabsContent(_children_w_0, .{ .value = "tab3", .children = _children_buf_1.items });
            }
            try _children_w_0.writeAll("\n");
            try Tabs(writer, .{ .default_value = props.default_value, .children = _children_buf_0.items });
        }
    }
        }
    }.b);
}

};

pub const text = struct {

/// Text — body text with constrained size, color, weight, and semantic variant.
///
/// Usage:
///   <Text size=.sm color=.muted>5 entries found</Text>
///   <Text size=.xs color=.destructive>Required</Text>
///   <Text variant=.eyebrow size=.xs color=.muted>Settings · account</Text>
///   <Text variant=.micro size=.xxs>UPDATED · 2H AGO</Text>
///   <Text variant=.code size=.sm>post_8f4a9c2e1b</Text>
///
/// Variants are pure modifiers — they layer on top of the size + weight
/// chosen via props, never overriding them:
///   - body (default): no extra classes.
///   - eyebrow: adds `uppercase tracking-wider`.
///   - micro: adds `uppercase tracking-wider`. Use with `size=.xxs` for the
///     traditional 10px micro look.
///   - code: adds `font-mono`.
///
/// For form labels, use `<Label html_for="email"><Text size=.sm weight=.medium>Email</Text></Label>`.
pub const TextSize = enum { xxs, xs, sm, md, lg };
pub const TextColor = enum { default, muted, primary, destructive, success, warning };
pub const TextWeight = enum { normal, medium, semibold, bold };
pub const TextElement = enum { p, span, div, legend };
pub const Variant = enum { body, eyebrow, micro, code };
pub const TextProps = struct {
    size: TextSize = .md,
    color: TextColor = .default,
    weight: TextWeight = .normal,
    variant: Variant = .body,
    as: TextElement = .p,
    class: []const u8 = "",
    children: []const u8 = "",
};
pub fn Text(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TextProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TextProps, _props);
    const size_class = if (props.size == .xxs) "text-3xs" else if (props.size == .xs) "text-xs" else if (props.size == .sm) "text-sm" else if (props.size == .lg) "text-lg" else "text-md";
    const color_class = if (props.color == .muted) "text-muted-foreground" else if (props.color == .primary) "text-primary" else if (props.color == .destructive) "text-destructive" else if (props.color == .success) "text-success" else if (props.color == .warning) "text-warning" else "text-foreground";
    const weight_class = if (props.weight == .medium) "font-medium" else if (props.weight == .semibold) "font-semibold" else if (props.weight == .bold) "font-bold" else "";
    const variant_class = if (props.variant == .eyebrow) "uppercase tracking-wider" else if (props.variant == .micro) "uppercase tracking-wider" else if (props.variant == .code) "font-mono" else "";
    if (props.as == .span) {
        try writer.writeAll("<span data-publr-component=\"text\" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll(" ");
        try writer.writeAll(variant_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>");
    } else if (props.as == .div) {
        try writer.writeAll("<div data-publr-component=\"text\" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll(" ");
        try writer.writeAll(variant_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</div>");
    } else if (props.as == .legend) {
        try writer.writeAll("<legend data-publr-component=\"text\" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll(" ");
        try writer.writeAll(variant_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</legend>");
    } else {
        try writer.writeAll("<p data-publr-component=\"text\" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll(" ");
        try writer.writeAll(variant_class);
        try writer.writeAll(" ");
        try writer.writeAll(props.class);
        try writer.writeAll("\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</p>");
    }
        }
    }.b);
}

};

pub const toast = struct {

/// Toast — notification feedback.
///
/// Renders a toast element with variant icon (from Icon component) and close button.
/// For the gallery, renders a single visible toast preview.
///
/// In production, a ToastRegion renders hidden templates (one per variant).
/// JS `publr.toast()` clones a template, sets the message, and shows it.
///
/// Data attributes:
///   - `data-publr-component="toast"` — individual toast element
///   - `data-publr-variant="<variant>"` — variant type
///   - `data-publr-part="message"` — text content (JS sets this on clone)
///   - `data-publr-part="close"` — dismiss button
///
/// Example (JS):
///   publr.toast('Changes saved')
///   publr.toast('File uploaded', { variant: 'success' })
///   publr.toast('Something went wrong', { variant: 'error' })
pub const Icon = root.icon.Icon;
pub const Flex = root.flex.Flex;
pub const Variant = enum { default, success, @"error", warning };
pub const ToastProps = struct {
    message: []const u8 = "Changes saved successfully",
    variant: Variant = .default,
    show_close: bool = true,
    class: []const u8 = "",
};
pub fn Toast(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(ToastProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(ToastProps, _props);
    const border_class = switch (props.variant) {
        .default => "border-border",
        .success => "border-success/30",
        .@"error" => "border-error/30",
        .warning => "border-warning/30",
    };
    try writer.writeAll("<div data-p-store=\"local:toast\" data-publr-component=\"toast\" data-publr-variant=\"");
    try runtime.render(writer, props.variant);
    try writer.writeAll("\" class=\"pointer-events-auto ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        if (props.variant == .success) {
            try Icon(_children_w_0, .{ .name = .check,  .size = 16,  .class = "text-success shrink-0" });
        } else if (props.variant == .@"error") {
            try Icon(_children_w_0, .{ .name = .alert_hexagon,  .size = 16,  .class = "text-error shrink-0" });
        } else if (props.variant == .warning) {
            try Icon(_children_w_0, .{ .name = .alert_triangle,  .size = 16,  .class = "text-warning shrink-0" });
        }
        try _children_w_0.writeAll("\n<p data-publr-part=\"message\" class=\"text-xs text-popover-foreground\">");
        try runtime.render(_children_w_0, props.message);
        try _children_w_0.writeAll("</p>\n");
        if (props.show_close) {
            try _children_w_0.writeAll("<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\" data-p-on=\"click:dismiss\">\n");
            try Icon(_children_w_0, .{ .name = .x_close,  .size = 14,  .class = "" });
            try _children_w_0.writeAll("\n</button>");
        }
        try _children_w_0.writeAll("\n");
        try Flex(writer, .{ .items = .center,  .gap = .md,  .class = runtime.concatRt(&.{ "rounded-md border bg-popover px-3 py-2 shadow-lg ", border_class }), .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>");
        }
    }.b);
}

/// ToastRegion — hidden container holding toast templates per variant.
///
/// Render once in your layout. JS reads templates from here to create toasts.
/// Each template is a complete toast with proper icons, ready to be cloned.
///
/// Example:
///   <!-- In your layout, once -->
///   <ToastRegion />
pub const ToastRegionProps = struct {};
pub fn ToastRegion(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<div id=\"publr-toast-region\" aria-live=\"polite\" role=\"status\" style=\"position:fixed;bottom:16px;right:16px;z-index:9999;display:flex;flex-direction:column-reverse;gap:8px;pointer-events:none;max-width:420px;\">\n<template data-publr-toast-template=\"default\">\n<div data-publr-component=\"toast\" data-publr-variant=\"default\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n<p data-publr-part=\"message\" class=\"text-xs text-popover-foreground\"></p>\n<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">\n");
        try Icon(_children_w_0, .{ .name = .x_close,  .size = 14,  .class = "" });
        try _children_w_0.writeAll("\n</button>\n");
        try Flex(writer, .{ .items = .center,  .gap = .md,  .class = "rounded-md border border-border bg-popover px-3 py-2 shadow-lg", .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>\n</template>\n<template data-publr-toast-template=\"success\">\n<div data-publr-component=\"toast\" data-publr-variant=\"success\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try Icon(_children_w_0, .{ .name = .check,  .size = 16,  .class = "text-success shrink-0" });
        try _children_w_0.writeAll("\n<p data-publr-part=\"message\" class=\"text-xs text-popover-foreground\"></p>\n<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">\n");
        try Icon(_children_w_0, .{ .name = .x_close,  .size = 14,  .class = "" });
        try _children_w_0.writeAll("\n</button>\n");
        try Flex(writer, .{ .items = .center,  .gap = .md,  .class = "rounded-md border border-success/30 bg-popover px-3 py-2 shadow-lg", .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>\n</template>\n<template data-publr-toast-template=\"error\">\n<div data-publr-component=\"toast\" data-publr-variant=\"error\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try Icon(_children_w_0, .{ .name = .alert_hexagon,  .size = 16,  .class = "text-error shrink-0" });
        try _children_w_0.writeAll("\n<p data-publr-part=\"message\" class=\"text-xs text-popover-foreground\"></p>\n<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">\n");
        try Icon(_children_w_0, .{ .name = .x_close,  .size = 14,  .class = "" });
        try _children_w_0.writeAll("\n</button>\n");
        try Flex(writer, .{ .items = .center,  .gap = .md,  .class = "rounded-md border border-error/30 bg-popover px-3 py-2 shadow-lg", .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>\n</template>\n<template data-publr-toast-template=\"warning\">\n<div data-publr-component=\"toast\" data-publr-variant=\"warning\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">\n");
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        try Icon(_children_w_0, .{ .name = .alert_triangle,  .size = 16,  .class = "text-warning shrink-0" });
        try _children_w_0.writeAll("\n<p data-publr-part=\"message\" class=\"text-xs text-popover-foreground\"></p>\n<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">\n");
        try Icon(_children_w_0, .{ .name = .x_close,  .size = 14,  .class = "" });
        try _children_w_0.writeAll("\n</button>\n");
        try Flex(writer, .{ .items = .center,  .gap = .md,  .class = "rounded-md border border-warning/30 bg-popover px-3 py-2 shadow-lg", .children = _children_buf_0.items });
    }
    try writer.writeAll("\n</div>\n</template>\n</div>");
}

};

pub const tooltip = struct {

/// Tooltip — hover/focus-triggered floating label.
///
/// Sub-components matching Radix Tooltip API:
///   - TooltipProvider: global config (delay_duration, skip_delay_duration)
///   - Tooltip: root container (default_open, delay_duration, disable_hoverable_content)
///   - TooltipTrigger: element that triggers the tooltip
///   - TooltipPortal: portals content into document.body
///   - TooltipContent: floating label (side, alignment, side_offset, avoid_collisions, ...)
///   - TooltipArrow: optional pointing arrow (width, height)
///
/// Usage:
///   <TooltipProvider>
///       <Tooltip>
///           <TooltipTrigger><Button label="Hover me" /></TooltipTrigger>
///           <TooltipPortal>
///               <TooltipContent side=.top>
///                   Edit this item
///                   <TooltipArrow />
///               </TooltipContent>
///           </TooltipPortal>
///       </Tooltip>
///   </TooltipProvider>
pub const Button = root.button.Button;
// ── Sub-components ──────────────────────────────────
pub const DelayDuration = enum { instant, fast, default, slow };
pub const Side = enum { top, right, bottom, left };
pub const Alignment = enum { start, center, end };
pub const TooltipProviderProps = struct {
    delay_duration: DelayDuration = .default,
    skip_delay_duration: u16 = 300,
    disable_hoverable_content: bool = false,
    children: []const u8 = "",
};
pub fn TooltipProvider(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TooltipProviderProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipProviderProps, _props);
    try writer.writeAll("<div data-publr-component=\"tooltip-provider\" data-publr-delay=\"");
    try runtime.render(writer, props.delay_duration);
    try writer.writeAll("\" data-publr-skip-delay=\"");
    try runtime.render(writer, props.skip_delay_duration);
    try writer.writeAll("\" data-publr-disable-hoverable-content=\"");
    try runtime.render(writer, props.disable_hoverable_content);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const TooltipProps = struct {
    default_open: bool = false,
    delay_duration: DelayDuration = .default,
    disable_hoverable_content: bool = false,
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn Tooltip(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TooltipProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipProps, _props);
    try writer.writeAll("<div data-p-store=\"local:tooltip\" data-publr-component=\"tooltip\" data-publr-state=\"");
    try runtime.render(writer, if (props.default_open) "open" else "closed");
    try writer.writeAll("\" data-publr-delay=\"");
    try runtime.render(writer, props.delay_duration);
    try writer.writeAll("\" data-publr-disable-hoverable-content=\"");
    try runtime.render(writer, props.disable_hoverable_content);
    try writer.writeAll("\" class=\"inline-block ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const TooltipTriggerProps = struct {
    children: []const u8 = "",
};
pub fn TooltipTrigger(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TooltipTriggerProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipTriggerProps, _props);
    try writer.writeAll("<span data-publr-part=\"trigger\" data-state=\"closed\" data-p-on=\"mouseenter:show;mouseleave:hide;focusin:show;focusout:hide;keydown.escape:dismiss\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</span>");
        }
    }.b);
}

pub const TooltipPortalProps = struct {
    children: []const u8 = "",
};
pub fn TooltipPortal(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TooltipPortalProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipPortalProps, _props);
    try writer.writeAll("<div data-publr-part=\"portal\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const TooltipContentProps = struct {
    side: Side = .top,
    alignment: Alignment = .center,
    side_offset: u16 = 12,
    align_offset: u16 = 0,
    avoid_collisions: bool = true,
    collision_padding: u16 = 0,
    arrow_padding: u16 = 0,
    sticky: enum { partial, always } = .partial,
    hide_when_detached: bool = false,
    aria_label: []const u8 = "",
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TooltipContent(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TooltipContentProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" data-p-show=\"state.open\" data-state=\"closed\" role=\"tooltip\" data-p-on=\"mouseenter:keepOpen;mouseleave:hide\" data-p-portal=\"");
    try runtime.render(writer, true);
    try writer.writeAll("\" data-publr-side=\"");
    try runtime.render(writer, props.side);
    try writer.writeAll("\" data-publr-align=\"");
    try runtime.render(writer, props.alignment);
    try writer.writeAll("\" data-publr-side-offset=\"");
    try runtime.render(writer, props.side_offset);
    try writer.writeAll("\" data-publr-align-offset=\"");
    try runtime.render(writer, props.align_offset);
    try writer.writeAll("\" data-publr-avoid-collisions=\"");
    try runtime.render(writer, props.avoid_collisions);
    try writer.writeAll("\" data-publr-collision-padding=\"");
    try runtime.render(writer, props.collision_padding);
    try writer.writeAll("\" data-publr-arrow-padding=\"");
    try runtime.render(writer, props.arrow_padding);
    try writer.writeAll("\" data-publr-sticky=\"");
    try runtime.render(writer, props.sticky);
    try writer.writeAll("\" data-publr-hide-when-detached=\"");
    try runtime.render(writer, props.hide_when_detached);
    try writer.writeAll("\" aria-label=\"");
    try runtime.render(writer, props.aria_label);
    try writer.writeAll("\" class=\"hidden px-2.5 py-1.5 rounded-md bg-background text-foreground text-xs font-medium shadow-md border border-border whitespace-nowrap ");
    try writer.writeAll(props.class);
    try writer.writeAll("\">\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n</div>");
        }
    }.b);
}

pub const TooltipArrowProps = struct {
    width: u16 = 10,
    height: u16 = 5,
    class: []const u8 = "",
};
pub fn TooltipArrow(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TooltipArrowProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipArrowProps, _props);
    try writer.writeAll("<div data-publr-part=\"arrow\" data-publr-arrow-width=\"");
    try runtime.render(writer, props.width);
    try writer.writeAll("\" data-publr-arrow-height=\"");
    try runtime.render(writer, props.height);
    try writer.writeAll("\" class=\"absolute w-2.5 h-1.5 bg-background border border-border rotate-45 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"></div>");
        }
    }.b);
}

// ── Gallery Demo ────────────────────────────────────
pub const Demo = enum { default };
pub const TooltipDemoProps = struct {
    demo: Demo = .default,
    // TooltipContent
    side: Side = .top,
    alignment: Alignment = .center,
    // Tooltip
    delay_duration: DelayDuration = .default,
    // Content text
    text: []const u8 = "",
    // Trigger label
    trigger_label: []const u8 = "",
};
pub fn TooltipDemo(__fw: anytype, __fp: anytype) !void {
    return runtime.forward(TooltipDemoProps, __fw, __fp, struct {
        fn b(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipDemoProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        const _children_w_0 = _children_buf_0.writer(_children_alloc_0);
        _ = &_children_w_0;
        try _children_w_0.writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            const _children_w_1 = _children_buf_1.writer(_children_alloc_1);
            _ = &_children_w_1;
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                try Button(_children_w_2, .{ .hierarchy = .secondary,  .label = props.trigger_label,  .size = .sm });
                try _children_w_2.writeAll("\n");
                try TooltipTrigger(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                const _children_w_2 = _children_buf_2.writer(_children_alloc_2);
                _ = &_children_w_2;
                try _children_w_2.writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    const _children_w_3 = _children_buf_3.writer(_children_alloc_3);
                    _ = &_children_w_3;
                    try runtime.render(_children_w_3, props.text);
                    try TooltipContent(_children_w_2, .{ .side = props.side,  .alignment = props.alignment, .children = _children_buf_3.items });
                }
                try _children_w_2.writeAll("\n");
                try TooltipPortal(_children_w_1, .{ .children = _children_buf_2.items });
            }
            try _children_w_1.writeAll("\n");
            try Tooltip(_children_w_0, .{ .delay_duration = props.delay_duration, .children = _children_buf_1.items });
        }
        try _children_w_0.writeAll("\n");
        try TooltipProvider(writer, .{ .children = _children_buf_0.items });
    }
        }
    }.b);
}

};

pub const css =
    \\
;

pub const checkbox_js =
    \\import{Publr as a}from"/static/scripts/publr.js";a.store("checkbox",()=>{let r=null,e=null;const n=()=>{if(!r||!e)return;const t=e.indeterminate?"indeterminate":e.checked?"checked":"unchecked";r.dataset.publrState=t,e.dataset.publrIndeterminate=t==="indeterminate"?"true":"false",e.setAttribute("aria-checked",t==="indeterminate"?"mixed":e.checked?"true":"false")};return{actions:{sync:n},setup:({el:t})=>{r=t,e=t.querySelector('input[type="checkbox"]'),(e==null?void 0:e.dataset.publrIndeterminate)==="true"&&(e.indeterminate=!0),n()}}});
    \\
;

pub const core_js =
    \\const a=new Map;function i(t,e){a.set(t,e)}function r(t=document){t.querySelectorAll("[data-publr-component]").forEach(e=>{const o=e.dataset.publrComponent,n=a.get(o);n&&!e._publrInit&&(e._publrInit=!0,n(e))})}document.addEventListener("publr:init",t=>r(t.target));function u(t){return t.dataset.publrState==="open"}function d(t){t.dataset.publrState="open";const e=t.querySelector('[data-publr-part="trigger"]');e&&e.setAttribute("aria-expanded","true")}function s(t){t.dataset.publrState="closed";const e=t.querySelector('[data-publr-part="trigger"]');e&&e.setAttribute("aria-expanded","false"),t._publrOnClose&&(t._publrOnClose(),delete t._publrOnClose)}function p(t){u(t)?s(t):d(t)}i("toggle",t=>{const e=t.querySelector('[data-publr-part="trigger"]');e&&e.addEventListener("click",()=>p(t))});document.readyState==="loading"?document.addEventListener("DOMContentLoaded",()=>r()):r();export{r as i,i as r};
    \\
;

pub const dialog_js =
    \\import{Publr as b}from"/static/scripts/publr.js";import{trapFocus as v}from"/static/scripts/publr-focus.js";let S=0;b.store("dialog",()=>{const a=b.reactive({open:!1});let f=null,o=null,s=null,n=null,t=null,u=!0,r=null,l=null;return{state:a,actions:{open:()=>{a.open=!0},close:()=>{a.open=!1},overlayClick:(e,i)=>{i.event.target===n&&u&&(a.open=!1)}},setup:({el:e})=>{if(f=e,o=e.querySelector('[data-publr-part="trigger"]'),n=e.querySelector('[data-publr-part="overlay"]'),t=e.querySelector('[data-publr-part="content"]'),!o||!n||!t)return;s=o.querySelector("button")||o,u=e.dataset.publrDismissable!=="false";const i=e.querySelector('[data-publr-part="title"]'),d=e.querySelector('[data-publr-part="description"]'),p=e.dataset.publrId||`publr-dialog-${++S}`;return e.dataset.publrId=p,i?(i.id=`${p}-title`,t.setAttribute("aria-labelledby",i.id)):t.removeAttribute("aria-labelledby"),d?(d.id=`${p}-description`,t.setAttribute("aria-describedby",d.id)):t.removeAttribute("aria-describedby"),b.effect(()=>{const c=a.open;if(f.dataset.publrState=c?"open":"closed",o.setAttribute("aria-expanded",c?"true":"false"),c){if(r||(r=v(t)),u&&!l){const y=m=>{m.key==="Escape"&&(m.preventDefault(),a.open=!1)};document.addEventListener("keydown",y,!0),l=()=>{document.removeEventListener("keydown",y,!0),l=null}}}else l&&l(),r&&(r(),r=null,s==null||s.focus())}),()=>{l&&l(),r&&r()}}}});
    \\
;

pub const dismiss_js =
    \\
    \\
;

pub const dropdown_js =
    \\import{Publr as u}from"/static/scripts/publr.js";import{position as v}from"/static/scripts/publr-position.js";u.store("dropdown",()=>{const o=u.reactive({open:!1});let c=null,a=null,l=null;const f=()=>a?[...a.querySelectorAll('[data-publr-part="item"]')].filter(r=>!r.disabled&&r.getAttribute("aria-disabled")!=="true"):[],i=(r,n)=>{var e;r.forEach((t,s)=>{t.tabIndex=s===n?0:-1}),(e=r[n])==null||e.focus()},d=()=>{a&&a.contains(document.activeElement)&&(c.querySelector("button")||c).focus()};return{state:o,actions:{toggle:()=>{o.open=!o.open},openMenu:(r,n)=>{n.event.preventDefault(),o.open=!0},close:()=>{o.open=!1},navKeys:(r,n)=>{const e=n.event,t=f();if(!t.length)return;const s=t.indexOf(document.activeElement);switch(e.key){case"ArrowDown":e.preventDefault(),i(t,s<t.length-1?s+1:0);break;case"ArrowUp":e.preventDefault(),i(t,s>0?s-1:t.length-1);break;case"Home":e.preventDefault(),i(t,0);break;case"End":e.preventDefault(),i(t,t.length-1);break;case"Enter":case" ":e.preventDefault(),s>=0&&(t[s].click(),o.open=!1);break;case"Escape":case"Tab":e.preventDefault(),o.open=!1;break;default:if(e.key.length===1&&!e.ctrlKey&&!e.metaKey&&!e.altKey){const m=e.key.toLowerCase(),p=t.find(b=>b.textContent.trim().toLowerCase().startsWith(m));p&&i(t,t.indexOf(p))}}},itemClick:(r,n)=>{const e=n.event.target.closest('[data-publr-part="item"]');e&&!e.disabled&&e.getAttribute("aria-disabled")!=="true"&&(o.open=!1)}},setup:({el:r})=>(c=r,a=r.querySelector('[data-publr-part="content"]'),u.effect(()=>{if(o.open){if(requestAnimationFrame(()=>{if(!o.open||!a||!c)return;v(a,c,{placement:"bottom-start",offset:8});const n=f();n.length&&i(n,0)}),!l){const n=e=>{!c.contains(e.target)&&!(a&&a.contains(e.target))&&(o.open=!1)};document.addEventListener("mousedown",n,!0),l=()=>{document.removeEventListener("mousedown",n,!0),l=null}}}else d(),l&&l()}),()=>{l&&l()})}});
    \\
;

pub const focus_js =
    \\
    \\
;

pub const keyboard_js =
    \\
    \\
;

pub const popover_js =
    \\import{Publr as d}from"/static/scripts/publr.js";import{position as b}from"/static/scripts/publr-position.js";import{trapFocus as v}from"/static/scripts/publr-focus.js";d.store("popover",()=>{const t=d.reactive({open:!1});let u=null,o=null,e=null,n=null,l=null;const f=()=>{const s=(o==null?void 0:o.querySelector("button"))||o;s==null||s.focus()};return{state:t,actions:{toggle:()=>{t.open=!t.open},close:()=>{t.open=!1}},setup:({el:s})=>{if(u=s,o=s.querySelector('[data-publr-part="trigger"]'),e=s.querySelector('[data-publr-part="content"]'),!(!o||!e))return d.effect(()=>{if(t.open){if(requestAnimationFrame(()=>{if(!t.open||!e||!o)return;const a=e.dataset.publrSide||"bottom",i=e.dataset.publrAlign||"center",r=parseInt(e.dataset.publrSideOffset||"0",10),p=e.dataset.publrAvoidCollisions!=="false",m=i==="center"?a:`${a}-${i}`;if(b(e,o,{placement:m,offset:r||12,flip:p}),u.dataset.publrModal==="true")l=v(e);else{const c=e.querySelector('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])');c==null||c.focus()}}),!n){const a=r=>{!u.contains(r.target)&&!(e&&e.contains(r.target))&&(t.open=!1)},i=r=>{r.key==="Escape"&&(r.preventDefault(),t.open=!1)};document.addEventListener("mousedown",a,!0),document.addEventListener("keydown",i,!0),n=()=>{document.removeEventListener("mousedown",a,!0),document.removeEventListener("keydown",i,!0),n=null}}}else l&&(l(),l=null),n&&(n(),f())}),()=>{l&&l(),n&&n()}}}});
    \\
;

pub const portal_js =
    \\
    \\
;

pub const position_js =
    \\
    \\
;

pub const radio_group_js =
    \\import{Publr as u}from"/static/scripts/publr.js";u.store("radio-group",()=>{let r=null;const a=()=>r?[...r.querySelectorAll('[data-publr-part="item"]')]:[],c=()=>{a().forEach(t=>{const e=t.querySelector('input[type="radio"]');e&&(t.dataset.publrState=e.checked?"checked":"unchecked")})};return{actions:{sync:c},setup:({el:t})=>{r=t;const e=t.dataset.publrName||"";e&&a().forEach(n=>{const o=n.querySelector('input[type="radio"]');o&&!o.name&&(o.name=e)}),c()}}});
    \\
;

pub const select_js =
    \\import{Publr as g}from"/static/scripts/publr.js";import{position as w}from"/static/scripts/publr-position.js";g.store("select",()=>{const s=g.reactive({open:!1});let h=null,i=null,l=null,d=null,o=null,x="",c=null;const f=e=>e.hasAttribute("aria-disabled")||e.dataset.publrState==="disabled",m=()=>l?[...l.querySelectorAll('[data-publr-part="option"]')]:[],b=()=>m().filter(e=>!f(e)),y=e=>{var a,t;return((t=(a=e.querySelector('[data-publr-part="option-label"]'))==null?void 0:a.textContent)==null?void 0:t.trim())||e.textContent.trim()},u=(e,a)=>{var t;e.forEach((n,r)=>{n.tabIndex=r===a?0:-1}),(t=e[a])==null||t.focus()},k=()=>m().find(e=>e.getAttribute("aria-selected")==="true")||null,v=e=>{!e||f(e)||(d&&(d.value=e.dataset.value),o&&(o.textContent=y(e),o.classList.remove("text-muted-foreground"),o.classList.add("text-foreground")),m().forEach(a=>{const t=a===e;a.setAttribute("aria-selected",t?"true":"false"),a.dataset.publrState=t?"selected":f(a)?"disabled":"unselected"}))};return{state:s,actions:{toggle:()=>{s.open=!s.open},openList:(e,a)=>{a.event.preventDefault(),s.open=!0},close:()=>{s.open=!1},navKeys:(e,a)=>{const t=a.event,n=b();if(!n.length)return;const r=n.indexOf(document.activeElement);switch(t.key){case"ArrowDown":t.preventDefault(),u(n,r<n.length-1?r+1:0);break;case"ArrowUp":t.preventDefault(),u(n,r>0?r-1:n.length-1);break;case"Home":t.preventDefault(),u(n,0);break;case"End":t.preventDefault(),u(n,n.length-1);break;case"Enter":case" ":t.preventDefault(),r>=0&&(v(n[r]),s.open=!1);break;case"Escape":case"Tab":t.preventDefault(),s.open=!1;break;default:if(t.key.length===1&&!t.ctrlKey&&!t.metaKey&&!t.altKey){const p=t.key.toLowerCase(),D=n.find(L=>y(L).toLowerCase().startsWith(p));D&&u(n,n.indexOf(D))}}},optionClick:(e,a)=>{const t=a.event.target.closest('[data-publr-part="option"]');t&&!f(t)&&(v(t),s.open=!1)}},setup:({el:e})=>{var t;h=e,i=e.querySelector('[data-publr-part="trigger"]'),l=e.querySelector('[data-publr-part="content"]'),d=e.querySelector('[data-publr-part="value"]'),o=e.querySelector('[data-publr-part="label"]'),x=((t=o==null?void 0:o.textContent)==null?void 0:t.trim())||"";const a=b().find(n=>n.dataset.value===e.dataset.publrDefaultValue);return a?v(a):o&&(d&&(d.value=""),o.textContent=x,o.classList.add("text-muted-foreground"),o.classList.remove("text-foreground")),g.effect(()=>{if(s.open){if(requestAnimationFrame(()=>{if(!s.open||!l||!i)return;w(l,i,{placement:"bottom-start",offset:4});const n=b();if(!n.length)return;const r=k(),p=r?n.indexOf(r):-1;u(n,p>=0?p:0)}),!c){const n=r=>{!h.contains(r.target)&&!(l&&l.contains(r.target))&&(s.open=!1)};document.addEventListener("mousedown",n,!0),c=()=>{document.removeEventListener("mousedown",n,!0),c=null}}}else l&&l.contains(document.activeElement)&&(i==null||i.focus()),c&&c()}),()=>{c&&c()}}}});
    \\
;

pub const sidebar_js =
    \\import{r as n,i as c}from"./publr-core.js";n("sidebar",s=>{s.querySelectorAll('[data-publr-part="section-trigger"]').forEach(e=>{e.addEventListener("click",()=>{const t=e.closest('[data-publr-part="section"]');if(!t)return;const r=t.dataset.publrState==="open";t.dataset.publrState=r?"closed":"open";const a=t.querySelector('[data-publr-part="section-content"]');a&&(a.hidden=!!r);const o=e.querySelector("svg");o&&(o.style.transform=r?"rotate(-90deg)":"")})})});c();
    \\
;

pub const switch_js =
    \\import{Publr as u}from"/static/scripts/publr.js";u.store("switch",()=>{let t=null,e=null;const c=()=>{t&&e&&(t.dataset.publrState=e.checked?"checked":"unchecked")};return{actions:{sync:c},setup:({el:r})=>{t=r,e=r.querySelector('input[type="checkbox"]'),c()}}});
    \\
;

pub const tabs_js =
    \\import{Publr as i}from"/static/scripts/publr.js";i.store("tabs",()=>{let s=null,u=null;const d=()=>u?[...u.querySelectorAll('[data-publr-part="trigger"]')].filter(a=>!a.disabled):[],c=a=>{if(!a||a.disabled)return;const r=a.dataset.publrTab;s.querySelectorAll('[data-publr-part="trigger"]').forEach(e=>{e.dataset.publrState="inactive",e.setAttribute("aria-selected","false"),e.tabIndex=-1}),s.querySelectorAll('[data-publr-part="content"]').forEach(e=>{e.dataset.publrState="inactive",e.hidden=!0}),a.dataset.publrState="active",a.setAttribute("aria-selected","true"),a.tabIndex=0;const t=s.querySelector(`[data-publr-part="content"][data-publr-tab="${r}"]`);t&&(t.dataset.publrState="active",t.hidden=!1)};return{actions:{tabClick:(a,r)=>{const t=r.event.target.closest('[data-publr-part="trigger"]');t&&!t.disabled&&c(t)},navKeys:(a,r)=>{const t=r.event,e=d(),l=e.indexOf(document.activeElement);if(l===-1)return;let n=l;switch(t.key){case"ArrowRight":t.preventDefault(),n=l<e.length-1?l+1:0;break;case"ArrowLeft":t.preventDefault(),n=l>0?l-1:e.length-1;break;case"Home":t.preventDefault(),n=0;break;case"End":t.preventDefault(),n=e.length-1;break;default:return}e[n].focus(),c(e[n])}},setup:({el:a})=>{if(s=a,u=a.querySelector('[data-publr-part="list"]'),!u)return;const r=d(),t=r.find(e=>e.dataset.publrTab===a.dataset.publrDefaultValue)||r[0];t&&c(t)}}});
    \\
;

pub const toast_js =
    \\import{Publr as c}from"/static/scripts/publr.js";let p=0;function f(){return document.getElementById("publr-toast-region")}function r(t,{remove:o=!0}={}){t.style.transition="opacity 0.2s, transform 0.2s",t.style.opacity="0",t.style.transform="translateY(8px)",setTimeout(()=>{o?t.remove():t.style.display="none"},200)}function m(t,o={}){const n=o.variant||"default",s=o.duration??4e3,i=++p,a=f();if(!a)return console.warn("publr.toast: no #publr-toast-region found. Add <ToastRegion /> to your layout."),null;const l=a.querySelector(`template[data-publr-toast-template="${n}"]`);if(!l)return console.warn(`publr.toast: no template for variant "${n}"`),null;const e=l.content.firstElementChild.cloneNode(!0);e.dataset.toastId=i;const u=e.querySelector('[data-publr-part="message"]');u&&(u.textContent=t);const d=e.querySelector('[data-publr-part="close"]');return d&&d.addEventListener("click",()=>r(e)),a.appendChild(e),requestAnimationFrame(()=>{e.style.opacity="1",e.style.transform="translateY(0)"}),s>0&&s!==1/0&&setTimeout(()=>r(e),s),i}typeof window<"u"&&(window.publr=window.publr||{},window.publr.toast=m);c.store("toast",()=>({actions:{dismiss:(t,o)=>{const n=o.el.closest('[data-publr-component="toast"]');n&&r(n,{remove:!1})}}}));
    \\
;

pub const tooltip_js =
    \\import{Publr as u}from"/static/scripts/publr.js";import{position as w}from"/static/scripts/publr-position.js";const p={instant:0,fast:200,default:700,slow:1e3};let d=0;u.store("tooltip",()=>{const l=u.reactive({open:!1});let i=null,o=null,a=null,c=p.default,f=300,b=!1,n=null,s=null;const r=e=>{o&&(o.dataset.state=e),a&&(a.dataset.state=e),i&&(i.dataset.publrState=e==="closed"?"closed":"open")};return{state:l,actions:{show:()=>{clearTimeout(s);const t=Date.now()-d<f?0:c;r(t>0?"delayed-open":"instant-open"),n=setTimeout(()=>{l.open=!0,r("instant-open")},t)},hide:()=>{clearTimeout(n),s=setTimeout(()=>{l.open=!1,r("closed"),d=Date.now()},100)},keepOpen:()=>{b||clearTimeout(s)},dismiss:(e,t)=>{t.event.key==="Escape"&&(clearTimeout(n),clearTimeout(s),l.open=!1,r("closed"),d=Date.now())}},setup:({el:e})=>{if(i=e,o=e.querySelector('[data-publr-part="trigger"]'),a=e.querySelector('[data-publr-part="content"]'),!o||!a)return;const t=e.closest('[data-publr-component="tooltip-provider"]'),T=e.dataset.publrDelay||(t==null?void 0:t.dataset.publrDelay)||"default";return c=p[T]??p.default,f=t?parseInt(t.dataset.publrSkipDelay||"300",10):300,b=(e.dataset.publrDisableHoverableContent||(t==null?void 0:t.dataset.publrDisableHoverableContent))==="true",e.dataset.publrState==="open"&&(l.open=!0),u.effect(()=>{l.open&&requestAnimationFrame(()=>{if(!l.open||!a||!o)return;const m=a.dataset.publrSide||"top",y=a.dataset.publrAlign||"center",D=parseInt(a.dataset.publrSideOffset||"0",10),S=a.dataset.publrAvoidCollisions!=="false",g=y==="center"?m:`${m}-${y}`;w(a,o,{placement:g,offset:D||6,flip:S})})}),()=>{clearTimeout(n),clearTimeout(s)}}}});
    \\
;

