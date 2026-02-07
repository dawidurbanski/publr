//! SVG Sanitizer
//!
//! Whitelist-based SVG sanitizer that strips dangerous elements, attributes,
//! and URL schemes. Inspired by the enshrined/svg-sanitize library used by
//! WordPress Safe SVG.
//!
//! Security model:
//! - Elements not in the allow list are removed (content preserved)
//! - Elements in the deny list are removed WITH their content
//! - Attributes not in the allow list are stripped
//! - Event handler attributes (on*) are always stripped
//! - javascript:/data: URLs are blocked in href attributes

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sanitize SVG content, returning a new allocation with dangerous content removed.
pub fn sanitize(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, input, pos, '<') orelse {
            try out.appendSlice(allocator, input[pos..]);
            break;
        };

        // Copy text before tag
        try out.appendSlice(allocator, input[pos..tag_start]);
        pos = tag_start;

        // Comment <!-- ... -->
        if (pos + 4 <= input.len and std.mem.eql(u8, input[pos..][0..4], "<!--")) {
            if (std.mem.indexOf(u8, input[pos + 4 ..], "-->")) |end| {
                pos = pos + 4 + end + 3;
            } else pos = input.len;
            continue;
        }

        // Processing instruction <? ... ?>
        if (pos + 1 < input.len and input[pos + 1] == '?') {
            if (std.mem.indexOf(u8, input[pos + 2 ..], "?>")) |end| {
                // Keep XML declaration, strip everything else (PHP etc.)
                if (pos + 5 <= input.len and std.mem.eql(u8, input[pos..][0..5], "<?xml")) {
                    try out.appendSlice(allocator, input[pos .. pos + 2 + end + 2]);
                }
                pos = pos + 2 + end + 2;
            } else pos = input.len;
            continue;
        }

        // CDATA <![CDATA[ ... ]]>
        if (pos + 9 <= input.len and std.mem.eql(u8, input[pos..][0..9], "<![CDATA[")) {
            if (std.mem.indexOf(u8, input[pos + 9 ..], "]]>")) |end| {
                try out.appendSlice(allocator, input[pos .. pos + 9 + end + 3]);
                pos = pos + 9 + end + 3;
            } else pos = input.len;
            continue;
        }

        // Find end of tag (respecting quoted attributes)
        const tag_end = findTagEnd(input, pos + 1) orelse {
            pos = input.len;
            continue;
        };

        const inner = input[pos + 1 .. tag_end]; // between < and >
        const is_closing = inner.len > 0 and inner[0] == '/';
        const tag_body = if (is_closing) trimLeft(inner[1..]) else inner;
        const is_self_closing = inner.len > 0 and inner[inner.len - 1] == '/';

        // Extract tag name
        const name_end = findNameEnd(tag_body);
        if (name_end == 0) {
            pos = tag_end + 1;
            continue;
        }
        const raw_name = tag_body[0..name_end];

        var name_buf: [64]u8 = undefined;
        const tag_name = toLowerBuf(raw_name, &name_buf) orelse {
            pos = tag_end + 1;
            continue;
        };

        // Denied elements: remove tag AND content
        if (isDenied(tag_name)) {
            pos = tag_end + 1;
            if (!is_closing and !is_self_closing) {
                pos = skipToClose(input, pos, tag_name);
            }
            continue;
        }

        // Unknown elements: remove tag, keep content
        if (!isAllowed(tag_name)) {
            pos = tag_end + 1;
            continue;
        }

        // Allowed element: output with filtered attributes
        if (is_closing) {
            try out.appendSlice(allocator, input[pos .. tag_end + 1]);
        } else {
            try out.append(allocator, '<');
            try out.appendSlice(allocator, raw_name);
            const attrs_start = name_end;
            const attrs_end = if (is_self_closing) tag_body.len - 1 else tag_body.len;
            if (attrs_start < attrs_end) {
                try filterAttributes(allocator, &out, tag_body[attrs_start..attrs_end]);
            }
            if (is_self_closing) {
                try out.appendSlice(allocator, "/>");
            } else {
                try out.append(allocator, '>');
            }
        }

        pos = tag_end + 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Find the closing '>' of a tag, respecting quoted attribute values.
fn findTagEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    while (i < input.len) {
        switch (input[i]) {
            '"', '\'' => {
                const quote = input[i];
                i += 1;
                while (i < input.len and input[i] != quote) : (i += 1) {}
                if (i < input.len) i += 1;
            },
            '>' => return i,
            else => i += 1,
        }
    }
    return null;
}

/// Find end of tag name (first whitespace, '/', or end of string).
fn findNameEnd(s: []const u8) usize {
    for (s, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '/' or c == '>') return i;
    }
    return s.len;
}

/// Skip forward past the matching close tag for a denied element.
fn skipToClose(input: []const u8, start: usize, tag_name: []const u8) usize {
    var depth: u32 = 1;
    var i = start;
    while (i < input.len and depth > 0) {
        const next_lt = std.mem.indexOfScalarPos(u8, input, i, '<') orelse return input.len;
        i = next_lt + 1;
        if (i >= input.len) return input.len;

        const is_close = input[i] == '/';
        const body_start = if (is_close) i + 1 else i;

        const gt = std.mem.indexOfScalarPos(u8, input, body_start, '>') orelse return input.len;
        const name_end = findNameEnd(input[body_start..gt]);
        if (name_end == 0) {
            i = gt + 1;
            continue;
        }

        var buf: [64]u8 = undefined;
        const name = toLowerBuf(input[body_start .. body_start + name_end], &buf) orelse {
            i = gt + 1;
            continue;
        };

        if (std.mem.eql(u8, name, tag_name)) {
            if (is_close) {
                depth -= 1;
            } else {
                // Check for self-closing
                const inner = std.mem.trimRight(u8, input[body_start..gt], " \t\n\r");
                if (inner.len == 0 or inner[inner.len - 1] != '/') {
                    depth += 1;
                }
            }
        }
        i = gt + 1;
    }
    return i;
}

/// Parse attributes from a tag body and write only allowed ones to output.
fn filterAttributes(allocator: Allocator, out: *std.ArrayList(u8), attrs: []const u8) !void {
    var i: usize = 0;
    while (i < attrs.len) {
        // Skip whitespace
        while (i < attrs.len and isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;

        // Parse attribute name
        const name_start = i;
        while (i < attrs.len and attrs[i] != '=' and !isWhitespace(attrs[i])) : (i += 1) {}
        if (i == name_start) break;
        const attr_name = attrs[name_start..i];

        // Skip whitespace around '='
        while (i < attrs.len and isWhitespace(attrs[i])) : (i += 1) {}

        var attr_value: ?[]const u8 = null;
        if (i < attrs.len and attrs[i] == '=') {
            i += 1;
            while (i < attrs.len and isWhitespace(attrs[i])) : (i += 1) {}

            if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
                const quote = attrs[i];
                i += 1;
                const val_start = i;
                while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
                attr_value = attrs[val_start..i];
                if (i < attrs.len) i += 1; // skip closing quote
            } else {
                // Unquoted value
                const val_start = i;
                while (i < attrs.len and !isWhitespace(attrs[i])) : (i += 1) {}
                attr_value = attrs[val_start..i];
            }
        }

        // Check if attribute is allowed
        var name_buf: [64]u8 = undefined;
        const lower_name = toLowerBuf(attr_name, &name_buf) orelse continue;

        // Block all event handlers
        if (lower_name.len > 2 and std.mem.eql(u8, lower_name[0..2], "on")) continue;

        // Allow data-* and aria-* attributes
        const is_data = lower_name.len > 5 and std.mem.eql(u8, lower_name[0..5], "data-");
        const is_aria = lower_name.len > 5 and std.mem.eql(u8, lower_name[0..5], "aria-");

        if (!is_data and !is_aria and !isAllowedAttribute(lower_name)) continue;

        // For href-like attributes, validate URL
        if (attr_value) |val| {
            if (isHrefAttr(lower_name) and !isSafeUrl(val)) continue;
        }

        // Write attribute
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, attr_name);
        if (attr_value) |val| {
            try out.appendSlice(allocator, "=\"");
            try out.appendSlice(allocator, val);
            try out.append(allocator, '"');
        }
    }
}

/// Check if a URL value is safe for href attributes.
fn isSafeUrl(value: []const u8) bool {
    const trimmed = trimLeft(value);
    if (trimmed.len == 0) return true;
    if (trimmed[0] == '#') return true; // fragment
    if (trimmed[0] == '/') return true; // relative

    // Check for dangerous schemes
    var scheme_buf: [32]u8 = undefined;
    const check_len = @min(trimmed.len, scheme_buf.len);
    const lower = toLowerBuf(trimmed[0..check_len], &scheme_buf) orelse return false;

    if (std.mem.startsWith(u8, lower, "javascript:")) return false;
    if (std.mem.startsWith(u8, lower, "vbscript:")) return false;

    // data: URIs — only allow safe image types
    if (std.mem.startsWith(u8, lower, "data:")) {
        const safe_data = [_][]const u8{
            "data:image/png",  "data:image/gif",
            "data:image/jpg",  "data:image/jpeg",
            "data:image/webp", "data:image/svg+xml",
        };
        for (safe_data) |prefix| {
            if (std.mem.startsWith(u8, lower, prefix)) return true;
        }
        return false;
    }

    return true; // http:, https:, relative paths
}

fn isHrefAttr(name: []const u8) bool {
    return std.mem.eql(u8, name, "href") or
        std.mem.eql(u8, name, "xlink:href") or
        std.mem.eql(u8, name, "src");
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isWhitespace(s[i])) : (i += 1) {}
    return s[i..];
}

fn toLowerBuf(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..s.len];
}

fn isDenied(name: []const u8) bool {
    for (denied_elements) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    return false;
}

fn isAllowed(name: []const u8) bool {
    for (allowed_elements) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    return false;
}

fn isAllowedAttribute(name: []const u8) bool {
    for (allowed_attributes) |a| {
        if (std.mem.eql(u8, name, a)) return true;
    }
    return false;
}

// =============================================================================
// Whitelists
// =============================================================================

/// Elements removed INCLUDING their content.
const denied_elements = [_][]const u8{
    "script", "foreignobject", "iframe",   "embed",
    "object", "applet",        "meta",     "link",
    "base",   "form",          "input",    "button",
    "select", "textarea",      "noscript",
};

/// Elements allowed to pass through (with attribute filtering).
const allowed_elements = [_][]const u8{
    // Structure
    "svg",                 "g",              "defs",               "symbol",
    "use",                 "desc",           "title",              "metadata",
    // Shapes
    "path",                "rect",           "circle",             "ellipse",
    "line",                "polyline",       "polygon",
    // Text
               "text",
    "tspan",               "textpath",
    // Gradients & patterns
          "lineargradient",     "radialgradient",
    "stop",                "pattern",
    // Clipping & masking
           "clippath",           "mask",
    "marker",
    // Filters
                 "filter",         "feblend",            "fecolormatrix",
    "fecomponenttransfer", "fecomposite",    "feconvolvematrix",   "fediffuselighting",
    "fedisplacementmap",   "fedistantlight", "feflood",            "fefunca",
    "fefuncb",             "fefuncg",        "fefuncr",            "fegaussianblur",
    "feimage",             "femerge",        "femergenode",        "femorphology",
    "feoffset",            "fepointlight",   "fespecularlighting", "fespotlight",
    "fetile",              "feturbulence",
    // Style
      "style",
    // Animation
                 "animate",
    "animatecolor",        "animatemotion",  "animatetransform",
    // Image & anchor
      "image",
    "a",
    // Switch
                      "switch",
};

/// Attributes allowed on any element.
const allowed_attributes = [_][]const u8{
    // Core
    "id",                          "class",               "style",
    "lang",                        "tabindex",            "role",
    // Geometry
    "x",                           "y",                   "x1",
    "x2",                          "y1",                  "y2",
    "cx",                          "cy",                  "r",
    "rx",                          "ry",                  "width",
    "height",                      "d",                   "points",
    "viewbox",                     "preserveaspectratio", "transform",
    // Presentation
    "fill",                        "stroke",              "fill-opacity",
    "stroke-opacity",              "stroke-width",        "stroke-dasharray",
    "stroke-dashoffset",           "stroke-linecap",      "stroke-linejoin",
    "stroke-miterlimit",           "opacity",             "color",
    "display",                     "visibility",          "overflow",
    "clip",                        "clip-path",           "clip-rule",
    "mask",                        "filter",              "fill-rule",
    "paint-order",                 "vector-effect",       "shape-rendering",
    "image-rendering",             "text-rendering",      "color-interpolation",
    "color-interpolation-filters", "enable-background",
    // Font & text
      "font-family",
    "font-size",                   "font-style",          "font-weight",
    "font-variant",                "text-anchor",         "text-decoration",
    "letter-spacing",              "word-spacing",        "dominant-baseline",
    "alignment-baseline",          "baseline-shift",      "direction",
    "writing-mode",                "unicode-bidi",        "textlength",
    "lengthadjust",                "dx",                  "dy",
    "rotate",                      "startoffset",         "method",
    "spacing",
    // Linking
                        "href",                "xlink:href",
    "xlink:title",                 "target",
    // Namespace
                 "xmlns",
    "xmlns:xlink",                 "xmlns:svg",           "xml:space",
    "xml:lang",                    "version",             "baseprofile",
    // Gradient
    "gradientunits",               "gradienttransform",   "spreadmethod",
    "fx",                          "fy",                  "fr",
    "offset",
    // Pattern
                         "patternunits",        "patterncontentunits",
    "patterntransform",
    // Marker
               "markerwidth",         "markerheight",
    "markerunits",                 "refx",                "refy",
    "orient",                      "marker-start",        "marker-mid",
    "marker-end",
    // Filter attributes
                     "filterunits",         "primitiveunits",
    "in",                          "in2",                 "result",
    "mode",                        "operator",            "k1",
    "k2",                          "k3",                  "k4",
    "stddeviation",                "radius",              "edgemode",
    "scale",                       "diffuseconstant",     "specularconstant",
    "specularexponent",            "surfacescale",        "kernelmatrix",
    "kernelunitlength",            "order",               "bias",
    "divisor",                     "targetx",             "targety",
    "type",                        "values",              "tablevalues",
    "slope",                       "intercept",           "amplitude",
    "exponent",                    "azimuth",             "elevation",
    "limitingconeangle",           "pointsatx",           "pointsaty",
    "pointsatz",                   "flood-color",         "flood-opacity",
    "lighting-color",              "stop-color",          "stop-opacity",
    "color-profile",
    // Symbol/use
                  "viewbox",
    // Animation
                "attributename",
    "attributetype",               "begin",               "dur",
    "end",                         "repeatcount",         "repeatdur",
    "restart",                     "from",                "to",
    "by",                          "calcmode",            "keysplines",
    "keytimes",                    "additive",            "accumulate",
    // Image
    "crossorigin",                 "decoding",
    // Misc
               "requiredfeatures",
    "requiredextensions",          "systemlanguage",      "space",
};

// =============================================================================
// Tests
// =============================================================================

test "strips script tags and content" {
    const input = "<svg><script>alert('xss')</script><rect/></svg>";
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<svg><rect/></svg>", result);
}

test "strips event handlers" {
    const input =
        \\<svg><rect onclick="alert(1)" width="10" onload="hack()"/></svg>
    ;
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<svg><rect width=\"10\"/></svg>", result);
}

test "strips javascript: URLs" {
    const input =
        \\<svg><a href="javascript:alert(1)"><text>click</text></a></svg>
    ;
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<svg><a><text>click</text></a></svg>", result);
}

test "strips foreignObject with content" {
    const input = "<svg><foreignObject><body><script>alert(1)</script></body></foreignObject><rect/></svg>";
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<svg><rect/></svg>", result);
}

test "preserves safe SVG content" {
    const input =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 2L2 22h20Z" fill="#333" stroke-width="2"/></svg>
    ;
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "strips processing instructions" {
    const input = "<?php echo 'pwned'; ?><svg><rect/></svg>";
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<svg><rect/></svg>", result);
}

test "keeps XML declaration" {
    const input =
        \\<?xml version="1.0"?><svg><rect/></svg>
    ;
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "removes unknown elements but keeps content" {
    const input = "<svg><custom>text</custom><rect/></svg>";
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<svg>text<rect/></svg>", result);
}

test "allows data-* and aria-* attributes" {
    const input =
        \\<svg><rect data-id="1" aria-label="box" width="10"/></svg>
    ;
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "blocks unsafe data: URIs" {
    const input =
        \\<svg><image href="data:text/html,<script>alert(1)</script>"/></svg>
    ;
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<svg><image/></svg>", result);
}

test "allows safe data: image URIs" {
    const input =
        \\<svg><image href="data:image/png;base64,abc"/></svg>
    ;
    const result = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}
