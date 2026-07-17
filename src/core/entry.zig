//! Generic content entry value.
//!
//! Every data-layer read returns this `Entry` shape — same struct regardless
//! of whether the content type is compile-in, WASM-loaded, or DB-defined.
//! Promoted columns (title/slug/status/timestamps) live on the top-level
//! struct; everything else is in `data: FieldMap`.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Tagged runtime field value. Each variant corresponds to one of the
/// `MetaValueType` cases plus a few JSON-friendly extras for fields that
/// don't fit a single column (booleans, nested JSON for group/repeater).
///
/// Construction parses once (out of `entries.data` JSON); accessors are
/// direct switches so consumers don't pay per-access parse costs.
pub const FieldValue = union(enum) {
    text: []const u8,
    int: i64,
    real: f64,
    bool_: bool,
    datetime: i64,
    /// Heterogeneous payload — used for `group` / `repeater` fields whose
    /// in-memory shape varies per descriptor. Caller is responsible for
    /// freeing the value through the owning `FieldMap`.
    json: std.json.Value,
    null_: void,
};

/// Runtime-keyed field bag. Caller owns the backing memory; pass through
/// `deinit` when the entry's allocator-bound lifetime ends.
pub const FieldMap = struct {
    inner: std.StringHashMapUnmanaged(FieldValue) = .{},
    arena: ?*std.heap.ArenaAllocator = null,

    pub const empty: FieldMap = .{};

    /// Free the underlying hash map. Values that own memory (the
    /// `.json` variant) are released when the entry's allocator/arena is
    /// torn down — `FieldMap` itself doesn't reach into the values.
    pub fn deinit(self: *FieldMap, allocator: Allocator) void {
        self.inner.deinit(allocator);
        if (self.arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
            self.arena = null;
        }
    }

    pub fn put(self: *FieldMap, allocator: Allocator, name: []const u8, value: FieldValue) !void {
        try self.inner.put(allocator, name, value);
    }

    pub fn get(self: FieldMap, name: []const u8) ?FieldValue {
        return self.inner.get(name);
    }

    /// Return the value as `[]const u8` when stored as text. Returns null
    /// for missing keys or non-text values.
    pub fn getText(self: FieldMap, name: []const u8) ?[]const u8 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .text => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: FieldMap, name: []const u8) ?i64 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .int => |n| n,
            .datetime => |t| t,
            else => null,
        };
    }

    pub fn getReal(self: FieldMap, name: []const u8) ?f64 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .real => |n| n,
            else => null,
        };
    }

    pub fn getBool(self: FieldMap, name: []const u8) ?bool {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .bool_ => |b| b,
            else => null,
        };
    }

    pub fn getDatetime(self: FieldMap, name: []const u8) ?i64 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .datetime => |t| t,
            else => null,
        };
    }

    pub fn getJson(self: FieldMap, name: []const u8) ?std.json.Value {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .json => |j| j,
            else => null,
        };
    }

    /// True when the key exists with a `.null_` value or is missing.
    pub fn isNull(self: FieldMap, name: []const u8) bool {
        const v = self.get(name) orelse return true;
        return v == .null_;
    }

    /// Custom JSON serializer — emits the map as a JSON object keyed by
    /// field name. The internal arena pointer and any non-serializable
    /// `.json` payloads are flattened back to their natural JSON shape.
    pub fn jsonStringify(self: FieldMap, jw: anytype) !void {
        try jw.beginObject();
        var it = self.inner.iterator();
        while (it.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .text => |s| try jw.write(s),
                .int => |n| try jw.write(n),
                .real => |n| try jw.write(n),
                .bool_ => |b| try jw.write(b),
                .datetime => |t| try jw.write(t),
                .json => |v| try jw.write(v),
                .null_ => try jw.write(null),
            }
        }
        try jw.endObject();
    }

    /// Construct from a typed `Data` struct produced by the compile-in
    /// fast path's `parseFromSlice`. The descriptor steers per-field
    /// variant selection so the resulting map's shape matches what
    /// `fromJson` would produce for the same data — consumers see one
    /// uniform `Entry.data` regardless of which path created it.
    ///
    /// Caller passes a `data_struct` whose fields correspond 1:1 to
    /// `def.fields`. String/text → `.text`; bool → `.bool_`; required
    /// integer → `.int`; optional integer → `.int` or `.null_`; required
    /// number → `.real`; optional number → `.real` or `.null_`; required
    /// datetime → `.datetime`; optional datetime → `.datetime` or `.null_`;
    /// container fields (`group`, `repeater`) → `.json` (serialized to
    /// `std.json.Value`).
    pub fn fromTypedStruct(
        allocator: Allocator,
        comptime def: anytype, // *const content_type.ContentTypeDef — kept anytype to avoid import cycle
        data_struct: anytype,
    ) !FieldMap {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena_ptr.deinit();
            allocator.destroy(arena_ptr);
        }
        const arena_alloc = arena_ptr.allocator();

        var map: FieldMap = .{ .arena = arena_ptr };
        inline for (def.fields) |f| {
            const raw = @field(data_struct, f.name);
            const value: FieldValue = comptime_value: {
                const id = f.field_type_id;
                if (comptime (std.mem.eql(u8, id, "string") or
                    std.mem.eql(u8, id, "text") or
                    std.mem.eql(u8, id, "slug") or
                    std.mem.eql(u8, id, "select") or
                    std.mem.eql(u8, id, "richtext") or
                    std.mem.eql(u8, id, "email") or
                    std.mem.eql(u8, id, "url") or
                    std.mem.eql(u8, id, "image")))
                {
                    // Dupe into the FieldMap's arena — `raw` borrows the
                    // caller's parse buffer, which is typically freed before
                    // the map is read (parseEntryRowSpecialized deinits the
                    // typed parse right after this returns).
                    if (comptime @typeInfo(@TypeOf(raw)) == .optional) {
                        break :comptime_value if (raw) |s|
                            FieldValue{ .text = try arena_alloc.dupe(u8, s) }
                        else
                            FieldValue.null_;
                    } else {
                        break :comptime_value FieldValue{ .text = try arena_alloc.dupe(u8, raw) };
                    }
                } else if (comptime std.mem.eql(u8, id, "boolean")) {
                    if (comptime @typeInfo(@TypeOf(raw)) == .optional) {
                        break :comptime_value if (raw) |b| FieldValue{ .bool_ = b } else FieldValue.null_;
                    } else {
                        break :comptime_value FieldValue{ .bool_ = raw };
                    }
                } else if (comptime std.mem.eql(u8, id, "integer")) {
                    if (comptime @typeInfo(@TypeOf(raw)) == .optional) {
                        break :comptime_value if (raw) |n| FieldValue{ .int = n } else FieldValue.null_;
                    } else {
                        break :comptime_value FieldValue{ .int = raw };
                    }
                } else if (comptime std.mem.eql(u8, id, "number")) {
                    if (comptime @typeInfo(@TypeOf(raw)) == .optional) {
                        break :comptime_value if (raw) |n| FieldValue{ .real = n } else FieldValue.null_;
                    } else {
                        break :comptime_value FieldValue{ .real = raw };
                    }
                } else if (comptime std.mem.eql(u8, id, "datetime")) {
                    if (comptime @typeInfo(@TypeOf(raw)) == .optional) {
                        break :comptime_value if (raw) |n| FieldValue{ .datetime = n } else FieldValue.null_;
                    } else {
                        break :comptime_value FieldValue{ .datetime = raw };
                    }
                } else {
                    // reference, taxonomy, group, repeater — serialize through
                    // std.json into a Value kept on the arena.
                    var buf: std.ArrayList(u8) = .{};
                    buf.writer(arena_alloc).print("{f}", .{std.json.fmt(raw, .{})}) catch {
                        break :comptime_value FieldValue.null_;
                    };
                    const slice = buf.toOwnedSlice(arena_alloc) catch {
                        break :comptime_value FieldValue.null_;
                    };
                    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_alloc, slice, .{}) catch {
                        break :comptime_value FieldValue.null_;
                    };
                    break :comptime_value FieldValue{ .json = parsed };
                }
            };
            try map.inner.put(allocator, f.name, value);
        }
        return map;
    }

    /// Construct from a JSON object string. Values are coerced by JSON shape:
    /// strings → `.text`, integers → `.int`, floats → `.real`, booleans →
    /// `.bool_`, nulls → `.null_`, nested objects / arrays → `.json`.
    /// `json_text` may be freed as soon as this returns: parsing uses
    /// `.alloc_always` so every string is copied into the FieldMap's arena
    /// (the default `.alloc_if_needed` would keep escape-free strings as
    /// borrowed slices of `json_text` — dangling once the caller frees it,
    /// e.g. SQLite row buffers freed at statement finalize).
    pub fn fromJson(allocator: Allocator, json_text: []const u8) !FieldMap {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena_ptr.allocator();
        errdefer {
            arena_ptr.deinit();
            allocator.destroy(arena_ptr);
        }

        var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_alloc, json_text, .{
            .allocate = .alloc_always,
        });
        if (parsed != .object) {
            return .{ .arena = arena_ptr };
        }

        var map: FieldMap = .{ .arena = arena_ptr };
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            const value: FieldValue = switch (entry.value_ptr.*) {
                .string => |s| .{ .text = s },
                .integer => |i| .{ .int = i },
                .float => |f| .{ .real = f },
                .bool => |b| .{ .bool_ = b },
                .null => .null_,
                else => |v| .{ .json = v },
                .number_string => |s| .{ .text = s },
            };
            try map.inner.put(allocator, entry.key_ptr.*, value);
        }
        return map;
    }
};

/// Generic content entry — same shape across compile-in / WASM / DB types.
pub const Entry = struct {
    id: []const u8,
    content_type: []const u8,
    slug: ?[]const u8,
    title: []const u8,
    status: []const u8,
    created_at: i64,
    updated_at: i64,
    published_at: ?i64,
    author_id: ?[]const u8 = null,
    /// Schema version of the underlying entries row; the descriptor version
    /// (for plugin upgrades) is separate.
    version: u32 = 1,
    data: FieldMap = .{},

    pub fn isPublished(self: Entry) bool {
        return std.mem.eql(u8, self.status, "published");
    }

    pub fn isDraft(self: Entry) bool {
        return std.mem.eql(u8, self.status, "draft");
    }

    pub fn isChanged(self: Entry) bool {
        return std.mem.eql(u8, self.status, "changed");
    }

    /// Frees the heap-owned slices on the entry — call this when an
    /// allocator owned the row's string columns directly (default for the
    /// runtime data layer). Callers using their own arena can skip this
    /// and free the arena instead.
    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.id);
        if (self.slug) |s| allocator.free(s);
        allocator.free(self.title);
        allocator.free(self.status);
        allocator.free(self.content_type);
        if (self.author_id) |a| allocator.free(a);
        self.data.deinit(allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "FieldMap.fromJson parses scalars into typed variants" {
    const json =
        \\{"title": "Hello", "year": 2026, "price": 9.99, "featured": true, "missing": null}
    ;
    var map = try FieldMap.fromJson(std.testing.allocator, json);
    defer map.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Hello", map.getText("title").?);
    try std.testing.expectEqual(@as(i64, 2026), map.getInt("year").?);
    try std.testing.expectApproxEqAbs(@as(f64, 9.99), map.getReal("price").?, 0.001);
    try std.testing.expectEqual(true, map.getBool("featured").?);
    try std.testing.expect(map.isNull("missing"));
    try std.testing.expect(map.getText("not-there") == null);
}

test "FieldMap.fromJson values survive freeing the input JSON" {
    // Regression: escape-free strings used to be borrowed slices of
    // `json_text` (std.json `.alloc_if_needed`), dangling once the caller
    // freed it — e.g. SQLite row buffers freed at statement finalize.
    // The testing allocator poisons freed memory, so a borrow fails here.
    const json_text = try std.testing.allocator.dupe(u8,
        \\{"title": "Hello", "content": "data:image/jpeg;base64,AAAA"}
    );
    var map = try FieldMap.fromJson(std.testing.allocator, json_text);
    defer map.deinit(std.testing.allocator);
    std.testing.allocator.free(json_text);

    try std.testing.expectEqualStrings("Hello", map.getText("title").?);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,AAAA", map.getText("content").?);
}

test "FieldMap.fromJson keeps nested objects as .json" {
    const json =
        \\{"seo": {"meta_title": "X"}}
    ;
    var map = try FieldMap.fromJson(std.testing.allocator, json);
    defer map.deinit(std.testing.allocator);

    const seo = map.getJson("seo") orelse return error.TestUnexpectedNull;
    try std.testing.expect(seo == .object);
    try std.testing.expectEqualStrings("X", seo.object.get("meta_title").?.string);
}

test "FieldMap.fromJson on non-object input returns empty map" {
    var map = try FieldMap.fromJson(std.testing.allocator, "[]");
    defer map.deinit(std.testing.allocator);
    try std.testing.expect(map.get("anything") == null);
}

test "Entry status helpers" {
    var entry: Entry = .{
        .id = "",
        .content_type = "",
        .slug = null,
        .title = "",
        .status = "published",
        .created_at = 0,
        .updated_at = 0,
        .published_at = null,
    };
    try std.testing.expect(entry.isPublished());
    try std.testing.expect(!entry.isDraft());

    entry.status = "draft";
    try std.testing.expect(entry.isDraft());

    entry.status = "changed";
    try std.testing.expect(entry.isChanged());
}
