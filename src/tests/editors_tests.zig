//! Editor registry tests.
//!
//! Lives here rather than inline in `src/editors.zig` because editors.zig
//! depends on `plugin_registry`, which depends on every plugin, which in
//! turn import `editors` back. Using editors.zig as a test root creates a
//! "file exists in modules 'root' and 'editors'" conflict. A wrapper file
//! sidesteps the cycle: editors.zig is reached only as the `editors`
//! module, never as the test root.

const std = @import("std");
const editors = @import("editors");
const content_type = @import("content_type");
const mw = @import("middleware");

test "registry: form built-in is registered" {
    const ed = editors.get("form") orelse return error.FormEditorMissing;
    try std.testing.expectEqualStrings("form", ed.id);
}

test "registry: unknown id returns null" {
    try std.testing.expectEqual(@as(?*const editors.Editor, null), editors.get("does-not-exist"));
}

test "registry: empty id returns null" {
    try std.testing.expectEqual(@as(?*const editors.Editor, null), editors.get(""));
}

test "registry: gutenberg plugin is aggregated" {
    // Plugin auto-discovery should have picked up cms/plugins/gutenberg/main.zig
    // and added its `editor` decl to `builtin_editors`.
    const ed = editors.get("gutenberg") orelse return error.GutenbergMissing;
    try std.testing.expectEqualStrings("gutenberg", ed.id);
    try std.testing.expectEqual(@as(usize, 5), ed.assets.len);
    try std.testing.expect(ed.render != null);
}

test "Editor: assets default to empty, render defaults to null" {
    // Sanity check: a fresh Editor value has sensible defaults.
    const noop_fn = struct {
        fn impl(args: editors.BootstrapArgs, w: std.io.AnyWriter) anyerror!void {
            _ = args;
            _ = w;
        }
    }.impl;
    const ed: editors.Editor = .{ .id = "noop", .bootstrap = noop_fn };
    try std.testing.expectEqual(@as(usize, 0), ed.assets.len);
    try std.testing.expectEqual(@as(?editors.RenderFn, null), ed.render);
}

// =============================================================================
// gutenberg plugin behavior — accessed via the public registry interface
// =============================================================================

fn renderGutenberg(input: []const u8, buf: *std.ArrayListUnmanaged(u8)) !void {
    const ed = editors.get("gutenberg") orelse return error.NoGutenberg;
    const render = ed.render orelse return error.NoRender;
    try render(input, buf.writer(std.testing.allocator).any());
}

test "gutenberg.render: strips open + close markers around core blocks" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try renderGutenberg("<!-- wp:paragraph --><p>Hello</p><!-- /wp:paragraph -->", &buf);
    try std.testing.expectEqualStrings("<p>Hello</p>", buf.items);
}

test "gutenberg.render: leaves non-wp HTML comments intact" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try renderGutenberg("<p>A</p><!-- regular note --><p>B</p>", &buf);
    try std.testing.expectEqualStrings("<p>A</p><!-- regular note --><p>B</p>", buf.items);
}

test "gutenberg.render: handles multiple blocks" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try renderGutenberg(
        \\<!-- wp:paragraph --><p>A</p><!-- /wp:paragraph -->
        \\<!-- wp:heading --><h2>B</h2><!-- /wp:heading -->
    , &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<!--") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<p>A</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h2>B</h2>") != null);
}

test "gutenberg.render: unterminated comment emits rest verbatim" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try renderGutenberg("<p>OK</p><!-- wp:broken", &buf);
    try std.testing.expectEqualStrings("<p>OK</p><!-- wp:broken", buf.items);
}

test "gutenberg.render: content without comments passes through" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try renderGutenberg("<p>just html</p>", &buf);
    try std.testing.expectEqualStrings("<p>just html</p>", buf.items);
}
