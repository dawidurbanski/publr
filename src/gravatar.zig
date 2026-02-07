const std = @import("std");

/// Gravatar URL with fixed buffer size.
/// Format: https://gravatar.com/avatar/{32-char-hash}?d=mp&s={1-4 digits}
/// Max length: 47 + 32 + 4 = 83 bytes
pub const GravatarUrl = struct {
    buffer: [83]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const GravatarUrl) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Build Gravatar URL for an email address.
/// Email is lowercased and trimmed before hashing.
/// Default fallback is "mp" (mystery person silhouette).
pub fn url(email: []const u8, size: u16) GravatarUrl {
    var result = GravatarUrl{};
    const prefix = "https://gravatar.com/avatar/";
    @memcpy(result.buffer[0..prefix.len], prefix);
    result.len = prefix.len;

    // MD5 hash the normalized email
    var hasher = std.crypto.hash.Md5.init(.{});
    for (email) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            hasher.update(&[_]u8{std.ascii.toLower(c)});
        }
    }
    var hash: [16]u8 = undefined;
    hasher.final(&hash);

    // Write hex-encoded hash
    const hex = std.fmt.bytesToHex(hash, .lower);
    @memcpy(result.buffer[result.len..][0..32], &hex);
    result.len += 32;

    // Append query params
    const suffix = std.fmt.bufPrint(result.buffer[result.len..], "?d=mp&s={d}", .{size}) catch unreachable;
    result.len += suffix.len;

    return result;
}

/// Build Gravatar URL with default size (40px).
pub fn urlDefault(email: []const u8) GravatarUrl {
    return url(email, 40);
}

test "gravatar url basic" {
    const result = url("test@example.com", 80);
    try std.testing.expectEqualStrings(
        "https://gravatar.com/avatar/55502f40dc8b7c769880b10874abc9d0?d=mp&s=80",
        result.slice(),
    );
}

test "gravatar url normalizes email" {
    // Uppercase should produce same hash as lowercase
    const lower = url("test@example.com", 40);
    const upper = url("TEST@EXAMPLE.COM", 40);
    try std.testing.expectEqualStrings(lower.slice(), upper.slice());
}

test "gravatar url trims whitespace" {
    const clean = url("test@example.com", 40);
    const padded = url("  test@example.com  ", 40);
    try std.testing.expectEqualStrings(clean.slice(), padded.slice());
}

test "gravatar url default size" {
    const result = urlDefault("test@example.com");
    try std.testing.expect(std.mem.endsWith(u8, result.slice(), "?d=mp&s=40"));
}
