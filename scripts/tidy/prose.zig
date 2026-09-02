const std = @import("std");
const limits = @import("limits.zig");

const file_bytes_max = limits.file_bytes_max;
const line_len_max = limits.line_len_max;

pub fn check_prose(
    init: std.process.Init,
    dir: std.Io.Dir,
    basename: []const u8,
    path: []const u8,
    hint: []const u8,
) !u32 {
    const text = try dir.readFileAlloc(init.io, basename, init.gpa, .limited(file_bytes_max));
    defer init.gpa.free(text);

    std.debug.assert(basename.len > 0);
    std.debug.assert(path.len >= basename.len);

    return check_text(text, path, hint, true);
}

pub fn check_text(text: []const u8, path: []const u8, hint: []const u8, report: bool) u32 {
    std.debug.assert(path.len > 0);
    std.debug.assert(text.len <= file_bytes_max);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 1;
    var violations: u32 = 0;

    while (lines.next()) |line| : (line_no += 1) {
        const em_dash = std.mem.indexOf(u8, line, "\u{2014}") != null;
        const en_dash = std.mem.indexOf(u8, line, "\u{2013}") != null;

        if (em_dash or en_dash) {
            violations += 1;

            if (report) {
                const message = "em/en dash in prose: use a comma, colon or a new sentence";
                std.debug.print("{s}:{d}: {s}{s}\n", .{ path, line_no, message, hint });
            }
        }
    }

    return violations;
}

test "em and en dashes are reported per line, plain hyphens are fine" {
    const clean = "Plain prose, with commas and colons: fine.\nA hyphen-ated word - and a dash.\n";
    const dirty = "One \u{2014} em dash\nTwo \u{2013} en dash\nclean\n";

    try std.testing.expectEqual(@as(u32, 0), check_text(clean, "clean.md", "", false));
    try std.testing.expectEqual(@as(u32, 2), check_text(dirty, "dirty.md", "", false));
}
