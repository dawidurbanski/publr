//! Schema Registry
//!
//! Runtime registry of `ContentTypeDef` values. Compile-in core schemas,
//! plugin schemas, and DB-defined types all register through the same API.
//!
//! Boot order:
//!   1. `init(allocator)` — start the runtime registry
//!   2. `register(def)` for each compile-in entry (core + plugins) and each
//!      DB-defined / WASM-loaded descriptor
//!   3. Data-layer functions (`saveEntry`, `getEntry`, …) look types up via
//!      `findById` — the registry is the single source of truth.
//!
//! Public surface: `init`, `deinit`, `register`, `unregister`, `findById`,
//! `findByHandle`, `all`, `compiled_in_types`, `all_taxonomy_ids`, `isReserved`.

const std = @import("std");
const field_mod = @import("field");
const content_type_mod = @import("content_type");

const FieldDef = field_mod.FieldDef;
const ContentTypeDef = content_type_mod.ContentTypeDef;

// Import core schemas — needed for `content_types_for_seed` and reserved-id
// helpers.
const core_schemas = @import("schemas");

/// Compile-in content type descriptors known at build time. Concatenates
/// the core schemas (`schemas.content_type_defs`) with any plugin
/// descriptors discovered by `build/content_types.zig`. The data layer's
/// fast path (`inline for (compiled_in_types)`) specializes hot functions
/// over this slice.
pub const compiled_in_types: []const ContentTypeDef = blk: {
    const discovered = @import("compiled_in_content_types").all;
    var out: [core_schemas.content_type_defs.len + discovered.len]ContentTypeDef = undefined;
    var i: usize = 0;
    for (core_schemas.content_type_defs) |def| {
        out[i] = def;
        i += 1;
    }
    for (discovered) |def| {
        out[i] = def;
        i += 1;
    }
    const final = out;
    break :blk &final;
};

/// Comptime slice of core compile-in content types as `ContentTypeDef` values.
/// Used by `seed.zig` to generate the `content_types` table seed SQL.
pub const content_types: []const ContentTypeDef = core_schemas.content_type_defs;

/// Check if a content type ID is a reserved type-id prefix. Reserved
/// prefixes are framework-controlled (currently none — the runtime
/// registry collision check via `register` handles duplicate names).
pub fn isReserved(_: []const u8) bool {
    return false;
}

/// All taxonomy IDs used across compile-in content types (computed at
/// comptime). Used by `seed.zig` to generate the `taxonomies` table seed SQL.
pub const all_taxonomy_ids: []const []const u8 = computeTaxonomyIds();

fn computeTaxonomyIds() []const []const u8 {
    comptime {
        var seen: [64][]const u8 = undefined;
        var seen_count: usize = 0;

        for (content_types) |ct| {
            for (ct.fields) |f| {
                if (f.storage == .taxonomy) {
                    if (f.taxonomy_id) |tax_id| {
                        var found = false;
                        for (seen[0..seen_count]) |s| {
                            if (std.mem.eql(u8, s, tax_id)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            seen[seen_count] = tax_id;
                            seen_count += 1;
                        }
                    }
                }
            }
        }

        const result = seen[0..seen_count].*;
        return &result;
    }
}

// =============================================================================
// Runtime registry (ContentTypeDef-based)
// =============================================================================
//
// Boot order:
//   1. `init(allocator)`
//   2. `register(def)` once per `compiled_in_types` entry and each entry from
//      `schemas.content_type_defs` (the core compile-in tuple)
//   3. `register(def)` for any DB-defined or WASM-loaded descriptors
//
// Data-layer functions (`saveEntry`, `getEntry`, …) look types
// up via `findById` — the registry is the single source of truth.

var runtime_state: ?RuntimeState = null;

const RuntimeState = struct {
    allocator: std.mem.Allocator,
    by_id: std.StringHashMapUnmanaged(*const ContentTypeDef),
    order: std.ArrayListUnmanaged(*const ContentTypeDef),
};

pub const RegisterError = error{
    DuplicateContentType,
    NotInitialized,
    OutOfMemory,
};

/// Initialize the runtime registry. Safe to call multiple times — repeat
/// calls reset the registry (intended for tests). In production, call once
/// during boot.
pub fn init(allocator: std.mem.Allocator) void {
    if (runtime_state) |*s| {
        for (s.order.items) |def| s.allocator.destroy(def);
        s.by_id.deinit(s.allocator);
        s.order.deinit(s.allocator);
    }
    runtime_state = .{
        .allocator = allocator,
        .by_id = .{},
        .order = .{},
    };
}

/// Tear the registry down. Frees the per-entry `ContentTypeDef` copies
/// allocated by `register`, plus the hashmap/array index storage. The
/// descriptor *fields* (strings, etc.) are not owned by the registry.
pub fn deinit() void {
    if (runtime_state) |*s| {
        for (s.order.items) |def| s.allocator.destroy(def);
        s.by_id.deinit(s.allocator);
        s.order.deinit(s.allocator);
        runtime_state = null;
    }
}

/// Register a content type descriptor. Returns `DuplicateContentType` when
/// the `type_id` collides with an already-registered entry — registration
/// is fail-loud, never silent-override.
pub fn register(def: ContentTypeDef) RegisterError!void {
    var s = if (runtime_state) |*st| st else return error.NotInitialized;
    if (s.by_id.contains(def.type_id)) return error.DuplicateContentType;

    const heap_def = s.allocator.create(ContentTypeDef) catch return error.OutOfMemory;
    heap_def.* = def;

    s.by_id.put(s.allocator, def.type_id, heap_def) catch |e| {
        s.allocator.destroy(heap_def);
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    s.order.append(s.allocator, heap_def) catch |e| {
        _ = s.by_id.remove(def.type_id);
        s.allocator.destroy(heap_def);
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
        };
    };
}

/// Remove a content type. No-op when the id is not registered.
pub fn unregister(type_id: []const u8) void {
    var s = if (runtime_state) |*st| st else return;
    const entry = s.by_id.fetchRemove(type_id) orelse return;
    var i: usize = 0;
    while (i < s.order.items.len) : (i += 1) {
        if (s.order.items[i] == entry.value) {
            _ = s.order.orderedRemove(i);
            break;
        }
    }
    s.allocator.destroy(entry.value);
}

/// Look up a registered content type by `type_id`. Returns null for unknown.
pub fn findById(type_id: []const u8) ?*const ContentTypeDef {
    const s = if (runtime_state) |*st| st else return null;
    return s.by_id.get(type_id);
}

/// Look up a registered content type by URL handle. Returns null for unknown.
pub fn findByHandle(handle: []const u8) ?*const ContentTypeDef {
    const s = if (runtime_state) |*st| st else return null;
    for (s.order.items) |def| {
        if (std.mem.eql(u8, def.handle, handle)) return def;
    }
    return null;
}

/// Snapshot of every registered content type in registration order.
pub fn all() []const *const ContentTypeDef {
    const s = if (runtime_state) |*st| st else return &.{};
    return s.order.items;
}

// =============================================================================
// Tests
// =============================================================================

test "content_types is empty when no compile-in starters are bundled" {
    try std.testing.expectEqual(@as(usize, 0), content_types.len);
}

test "isReserved is empty by default" {
    try std.testing.expect(!isReserved("post"));
    try std.testing.expect(!isReserved("page"));
    try std.testing.expect(!isReserved("recipe"));
}

test "all_taxonomy_ids is empty when no compile-in starters declare taxonomies" {
    try std.testing.expectEqual(@as(usize, 0), all_taxonomy_ids.len);
}

test "registry: public API coverage" {
    _ = isReserved;
    _ = init;
    _ = deinit;
    _ = register;
    _ = unregister;
    _ = findById;
    _ = findByHandle;
    _ = all;
    _ = compiled_in_types;
}

// =============================================================================
// Runtime registry tests
// =============================================================================

const field_for_tests = field_mod;

fn sampleDef(comptime type_id: []const u8, comptime handle: []const u8) ContentTypeDef {
    return content_type_mod.contentType(.{
        .type_id = type_id,
        .display_name = "Sample",
        .handle = handle,
        .fields = &.{
            field_for_tests.String("title", .{ .required = true }),
        },
    });
}

test "runtime registry: register, findById, findByHandle, all" {
    init(std.testing.allocator);
    defer deinit();

    const book = sampleDef("book", "books");
    const movie = sampleDef("movie", "movies");

    try register(book);
    try register(movie);

    const found = findById("book") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("book", found.type_id);

    const by_handle = findByHandle("movies") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("movie", by_handle.type_id);

    const snapshot = all();
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expectEqualStrings("book", snapshot[0].type_id);
    try std.testing.expectEqualStrings("movie", snapshot[1].type_id);
}

test "runtime registry: register rejects duplicate type_id" {
    init(std.testing.allocator);
    defer deinit();

    try register(sampleDef("book", "books"));
    try std.testing.expectError(error.DuplicateContentType, register(sampleDef("book", "books_alt")));
}

test "runtime registry: findById returns null for unknown id" {
    init(std.testing.allocator);
    defer deinit();

    try std.testing.expect(findById("does-not-exist") == null);
}

test "runtime registry: unregister removes the entry" {
    init(std.testing.allocator);
    defer deinit();

    try register(sampleDef("book", "books"));
    try std.testing.expect(findById("book") != null);
    unregister("book");
    try std.testing.expect(findById("book") == null);
    try std.testing.expectEqual(@as(usize, 0), all().len);
}

test "runtime registry: register requires init" {
    deinit();
    try std.testing.expectError(error.NotInitialized, register(sampleDef("book", "books")));
}

test "runtime registry: compiled_in_types is an empty slice when no plugin exposes one" {
    try std.testing.expectEqual(@as(usize, 0), compiled_in_types.len);
}
