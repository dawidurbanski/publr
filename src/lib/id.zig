//! Identifiers as Publr writes them: 24 lowercase hex characters, either random (records,
//! users) or derived from a name (content types), so a declared type has the same id in
//! every database.

const std = @import("std");

pub const len: u32 = 24;

pub fn random(io: std.Io, out: *[len]u8) []const u8 {
    std.debug.assert(len % 2 == 0);

    var raw: [len / 2]u8 = undefined;
    io.random(&raw);
    out.* = std.fmt.bytesToHex(raw, .lower);

    std.debug.assert(out[0] != 0);

    return out;
}

pub fn derived(name: []const u8, out: *[len]u8) []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(len % 2 == 0);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    out.* = std.fmt.bytesToHex(digest[0 .. len / 2].*, .lower);

    return out;
}

test "random ids are hex and differ; derived ids are stable" {
    var first: [len]u8 = undefined;
    var second: [len]u8 = undefined;
    _ = random(std.testing.io, &first);
    _ = random(std.testing.io, &second);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));

    for (first) |char| {
        try std.testing.expect(std.ascii.isHex(char) and !std.ascii.isUpper(char));
    }

    var one: [len]u8 = undefined;
    var two: [len]u8 = undefined;
    try std.testing.expectEqualStrings(derived("post", &one), derived("post", &two));
    try std.testing.expect(!std.mem.eql(u8, derived("post", &one), derived("page", &two)));
}
