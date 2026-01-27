const std = @import("std");

/// Layout options for wrapping content
pub const LayoutOptions = struct {
    title: []const u8 = "Minizen",
    css: []const []const u8 = &[_][]const u8{},
    js: []const []const u8 = &[_][]const u8{},
};

/// Default admin layout options
pub const admin_layout = LayoutOptions{
    .title = "Minizen Admin",
    .css = &[_][]const u8{"/static/admin.css"},
    .js = &[_][]const u8{"/static/admin.js"},
};

/// Default public layout options
pub const public_layout = LayoutOptions{
    .title = "Minizen",
    .css = &[_][]const u8{},
    .js = &[_][]const u8{},
};

/// Wrap content in a full HTML layout
/// Returns a static buffer - content must be consumed before next call
pub fn wrapLayout(content: []const u8, options: LayoutOptions) []const u8 {
    // Use a static buffer for the assembled HTML
    // This avoids allocation and works since we consume the response immediately
    const S = struct {
        var buf: [65536]u8 = undefined; // 64KB buffer
    };

    var offset: usize = 0;

    // DOCTYPE and html start
    offset += copyTo(S.buf[offset..], "<!DOCTYPE html>\n<html>\n<head>\n    <meta charset=\"utf-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n    <title>");

    // Title
    offset += copyTo(S.buf[offset..], options.title);

    offset += copyTo(S.buf[offset..], "</title>\n");

    // CSS links
    for (options.css) |href| {
        offset += copyTo(S.buf[offset..], "    <link rel=\"stylesheet\" href=\"");
        offset += copyTo(S.buf[offset..], href);
        offset += copyTo(S.buf[offset..], "\">\n");
    }

    offset += copyTo(S.buf[offset..], "</head>\n<body>\n    <main>\n");

    // Main content
    offset += copyTo(S.buf[offset..], content);

    offset += copyTo(S.buf[offset..], "\n    </main>\n");

    // JS scripts
    for (options.js) |src| {
        offset += copyTo(S.buf[offset..], "    <script src=\"");
        offset += copyTo(S.buf[offset..], src);
        offset += copyTo(S.buf[offset..], "\"></script>\n");
    }

    offset += copyTo(S.buf[offset..], "</body>\n</html>\n");

    return S.buf[0..offset];
}

fn copyTo(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}

// Tests
test "wrapLayout basic" {
    const content = "<h1>Hello</h1>";
    const result = wrapLayout(content, .{ .title = "Test" });

    try std.testing.expect(std.mem.indexOf(u8, result, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<title>Test</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<main>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1>Hello</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</main>") != null);
}

test "wrapLayout with CSS and JS" {
    const content = "<p>Content</p>";
    const result = wrapLayout(content, .{
        .title = "Admin",
        .css = &[_][]const u8{"/static/admin.css"},
        .js = &[_][]const u8{"/static/admin.js"},
    });

    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"/static/admin.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src=\"/static/admin.js\"") != null);
}

test "wrapLayout default options" {
    const content = "<p>Test</p>";
    const result = wrapLayout(content, .{});

    try std.testing.expect(std.mem.indexOf(u8, result, "<title>Minizen</title>") != null);
}

test "admin_layout preset" {
    const content = "<div>Admin panel</div>";
    const result = wrapLayout(content, admin_layout);

    try std.testing.expect(std.mem.indexOf(u8, result, "<title>Minizen Admin</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"/static/admin.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src=\"/static/admin.js\"") != null);
}
