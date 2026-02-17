const std = @import("std");
const Allocator = std.mem.Allocator;

const charset = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Generate a prefixed ID with random alphanumeric suffix.
/// Returns a fixed-size array: [prefix.len + rand_len]u8
pub fn generatePrefixedId(comptime prefix: []const u8, comptime rand_len: usize) [prefix.len + rand_len]u8 {
    var id_buf: [prefix.len + rand_len]u8 = undefined;
    @memcpy(id_buf[0..prefix.len], prefix);

    var rand_buf: [rand_len]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    for (rand_buf, 0..) |byte, i| {
        id_buf[prefix.len + i] = charset[byte % charset.len];
    }

    return id_buf;
}

/// Generate a prefixed ID and return as heap-allocated slice.
pub fn generatePrefixedIdAlloc(allocator: Allocator, comptime prefix: []const u8, comptime rand_len: usize) ![]u8 {
    const id = generatePrefixedId(prefix, rand_len);
    return try allocator.dupe(u8, &id);
}

// Convenience aliases matching existing API signatures
pub fn generateEntryId(allocator: Allocator) ![]u8 {
    return generatePrefixedIdAlloc(allocator, "e_", 16);
}

pub fn generateVersionId() [18]u8 {
    return generatePrefixedId("v_", 16);
}

pub fn generateReleaseId() [20]u8 {
    return generatePrefixedId("rel_", 16);
}

pub fn generateMediaId(allocator: Allocator) ![]u8 {
    return generatePrefixedIdAlloc(allocator, "m_", 16);
}

pub fn generateTermId(allocator: Allocator) ![]u8 {
    return generatePrefixedIdAlloc(allocator, "t_", 12);
}

test "generatePrefixedId produces correct prefix and length" {
    const id = generatePrefixedId("e_", 16);
    try std.testing.expectEqualStrings("e_", id[0..2]);
    try std.testing.expectEqual(@as(usize, 18), id.len);

    // All chars should be from the charset
    for (id[2..]) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, charset, c) != null);
    }
}

test "generatePrefixedId with longer prefix" {
    const id = generatePrefixedId("rel_", 16);
    try std.testing.expectEqualStrings("rel_", id[0..4]);
    try std.testing.expectEqual(@as(usize, 20), id.len);
}

test "generatePrefixedId produces unique IDs" {
    const id1 = generatePrefixedId("e_", 16);
    const id2 = generatePrefixedId("e_", 16);
    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "generatePrefixedIdAlloc returns heap-allocated slice" {
    const allocator = std.testing.allocator;
    const id = try generatePrefixedIdAlloc(allocator, "m_", 16);
    defer allocator.free(id);

    try std.testing.expectEqualStrings("m_", id[0..2]);
    try std.testing.expectEqual(@as(usize, 18), id.len);
}

test "convenience aliases have correct lengths" {
    const allocator = std.testing.allocator;

    const entry_id = try generateEntryId(allocator);
    defer allocator.free(entry_id);
    try std.testing.expectEqual(@as(usize, 18), entry_id.len);
    try std.testing.expectEqualStrings("e_", entry_id[0..2]);

    const version_id = generateVersionId();
    try std.testing.expectEqual(@as(usize, 18), version_id.len);
    try std.testing.expectEqualStrings("v_", version_id[0..2]);

    const release_id = generateReleaseId();
    try std.testing.expectEqual(@as(usize, 20), release_id.len);
    try std.testing.expectEqualStrings("rel_", release_id[0..4]);

    const media_id = try generateMediaId(allocator);
    defer allocator.free(media_id);
    try std.testing.expectEqual(@as(usize, 18), media_id.len);
    try std.testing.expectEqualStrings("m_", media_id[0..2]);

    const term_id = try generateTermId(allocator);
    defer allocator.free(term_id);
    try std.testing.expectEqual(@as(usize, 14), term_id.len);
    try std.testing.expectEqualStrings("t_", term_id[0..2]);
}

test "id_gen: public API coverage" {
    _ = generatePrefixedId;
    _ = generatePrefixedIdAlloc;
    _ = generateEntryId;
    _ = generateVersionId;
    _ = generateReleaseId;
    _ = generateMediaId;
    _ = generateTermId;
}
