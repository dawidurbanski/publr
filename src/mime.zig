const std = @import("std");

const mime_map = .{
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".png", "image/png" },
    .{ ".gif", "image/gif" },
    .{ ".webp", "image/webp" },
    .{ ".avif", "image/avif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".bmp", "image/bmp" },
    .{ ".ico", "image/x-icon" },
    .{ ".pdf", "application/pdf" },
    .{ ".mp4", "video/mp4" },
    .{ ".webm", "video/webm" },
    .{ ".mp3", "audio/mpeg" },
    .{ ".ogg", "audio/ogg" },
    .{ ".wav", "audio/wav" },
    .{ ".txt", "text/plain" },
    .{ ".css", "text/css" },
    .{ ".js", "application/javascript" },
    .{ ".json", "application/json" },
    .{ ".xml", "application/xml" },
    .{ ".html", "text/html" },
};

/// Get MIME type from file path or filename by extension.
/// Uses case-insensitive matching. Returns "application/octet-stream" for unknown extensions.
pub fn fromPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return fromExtension(ext);
}

/// Get MIME type from a file extension (e.g. ".jpg").
/// Uses case-insensitive matching. Returns "application/octet-stream" for unknown extensions.
pub fn fromExtension(ext: []const u8) []const u8 {
    if (ext.len == 0) return "application/octet-stream";

    inline for (mime_map) |entry| {
        if (eqlIgnoreCase(ext, entry[0])) return entry[1];
    }

    return "application/octet-stream";
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

test "fromPath returns correct MIME for known extensions" {
    try std.testing.expectEqualStrings("image/jpeg", fromPath("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", fromPath("photo.jpeg"));
    try std.testing.expectEqualStrings("image/png", fromPath("image.png"));
    try std.testing.expectEqualStrings("image/gif", fromPath("anim.gif"));
    try std.testing.expectEqualStrings("image/webp", fromPath("photo.webp"));
    try std.testing.expectEqualStrings("image/svg+xml", fromPath("icon.svg"));
    try std.testing.expectEqualStrings("application/pdf", fromPath("doc.pdf"));
    try std.testing.expectEqualStrings("video/mp4", fromPath("clip.mp4"));
    try std.testing.expectEqualStrings("text/html", fromPath("page.html"));
}

test "fromPath is case insensitive" {
    try std.testing.expectEqualStrings("image/jpeg", fromPath("PHOTO.JPG"));
    try std.testing.expectEqualStrings("image/png", fromPath("image.PNG"));
    try std.testing.expectEqualStrings("image/svg+xml", fromPath("icon.SVG"));
}

test "fromPath returns octet-stream for unknown" {
    try std.testing.expectEqualStrings("application/octet-stream", fromPath("file.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", fromPath("noext"));
}

test "fromExtension works directly" {
    try std.testing.expectEqualStrings("image/jpeg", fromExtension(".jpg"));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension(""));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension(".unknown"));
}
