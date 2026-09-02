//! Text utilities: slugs (URL-safe names) and their numeric suffixes.

const std = @import("std");

pub const slug_len_max: u32 = 200;
pub const attempts_max: u32 = 50;

pub fn slugify(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(slug_len_max > 0);
    std.debug.assert(text.len <= 1 << 20);

    var out: std.ArrayList(u8) = .empty;
    var pending_hyphen = false;

    for (text) |char| {
        const lower = std.ascii.toLower(char);
        const keep = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');

        if (keep) {
            if (pending_hyphen and out.items.len > 0) {
                try out.append(arena, '-');
            }

            pending_hyphen = false;
            try out.append(arena, lower);

            if (out.items.len == slug_len_max) {
                break;
            }
        } else {
            pending_hyphen = true;
        }
    }

    if (out.items.len == 0) {
        try out.appendSlice(arena, "record");
    }

    return out.items;
}

pub fn with_suffix(arena: std.mem.Allocator, base: []const u8, attempt: u32) ![]const u8 {
    std.debug.assert(base.len > 0);
    std.debug.assert(attempt >= 2 and attempt <= attempts_max);

    return std.fmt.allocPrint(arena, "{s}-{d}", .{ base, attempt });
}

test "slugify lowers, collapses separators, trims, and never returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("hello-world", try slugify(arena, "  Hello,   World! "));
    try std.testing.expectEqualStrings("caf-2024", try slugify(arena, "Café 2024"));
    try std.testing.expectEqualStrings("record", try slugify(arena, "!!!"));
    try std.testing.expectEqualStrings("hello-world-2", try with_suffix(arena, "hello-world", 2));
}
