const std = @import("std");
const field = @import("field.zig");
const convert = @import("convert.zig");
const document_module = @import("document.zig");

const Def = field.Def;
const Value = std.json.Value;

pub const paths_max: u32 = 1024;

pub const ConvertError = convert.Error || error{ NotConvertible, DataDoesNotFit };

pub const Plan = struct {
    allowed: bool,
    needs_rewrite: bool,
    removed: []const []const u8,
};

const Leaf = struct { path: []const u8, def: Def };

pub fn plan(arena: std.mem.Allocator, old: []const Def, new: []const Def) !Plan {
    std.debug.assert(old.len <= field.fields_max);
    std.debug.assert(new.len <= field.fields_max);

    var old_leaves: std.ArrayList(Leaf) = .empty;
    var new_leaves: std.ArrayList(Leaf) = .empty;

    try flatten(arena, old, "", &old_leaves);
    try flatten(arena, new, "", &new_leaves);

    var removed: std.ArrayList([]const u8) = .empty;
    var allowed = true;
    var needs_rewrite = false;

    for (old_leaves.items) |before| {
        const after = find_leaf(new_leaves.items, before.path) orelse {
            try removed.append(arena, before.path);

            continue;
        };
        const same_kind = before.def.kind == after.def.kind;
        const same_many = before.def.many == after.def.many;
        const same_search = before.def.searchable == after.def.searchable;

        if (!same_kind and !convert.allowed(before.def.kind, after.def.kind)) {
            allowed = false;
        }

        if (!same_kind or !same_many or !same_search) {
            needs_rewrite = true;
        }
    }

    return .{ .allowed = allowed, .needs_rewrite = needs_rewrite, .removed = removed.items };
}

fn flatten(
    arena: std.mem.Allocator,
    defs: []const Def,
    prefix: []const u8,
    out: *std.ArrayList(Leaf),
) !void {
    std.debug.assert(prefix.len <= document_module.path_len_max);
    std.debug.assert(out.items.len <= paths_max);

    for (defs) |def| {
        var buffer: [document_module.path_len_max]u8 = undefined;
        const path = try document_module.join(&buffer, prefix, def.name);
        const owned = try arena.dupe(u8, path);

        if (field.is_leaf(def.kind)) {
            try out.append(arena, .{ .path = owned, .def = def });
        } else {
            try flatten(arena, def.fields, owned, out);
        }
    }
}

fn find_leaf(leaves: []const Leaf, path: []const u8) ?Leaf {
    std.debug.assert(path.len > 0);
    std.debug.assert(leaves.len <= paths_max);

    for (leaves) |leaf| {
        if (std.mem.eql(u8, leaf.path, path)) {
            return leaf;
        }
    }

    return null;
}

pub fn convert_document(
    arena: std.mem.Allocator,
    old: []const Def,
    new: []const Def,
    document: Value,
) ConvertError!Value {
    std.debug.assert(document == .object);
    std.debug.assert(new.len <= field.fields_max);

    var object: std.json.ObjectMap = .empty;

    for (new) |after| {
        const before = find_def(old, after.name) orelse continue;
        const value = document.object.get(after.name) orelse continue;

        if (value == .null) {
            continue;
        }

        const converted = try convert_value(arena, before, after, value);
        try object.put(arena, try arena.dupe(u8, after.name), converted);
    }

    return .{ .object = object };
}

fn convert_value(
    arena: std.mem.Allocator,
    before: Def,
    after: Def,
    value: Value,
) ConvertError!Value {
    std.debug.assert(std.mem.eql(u8, before.name, after.name));
    std.debug.assert(value != .null);

    if (field.is_leaf(after.kind) and field.is_leaf(before.kind)) {
        if (!convert.allowed(before.kind, after.kind)) {
            return error.NotConvertible;
        }

        return convert.convert(arena, before, after, value);
    }

    if (after.kind == .group and before.kind == .group) {
        return convert_document(arena, before.fields, after.fields, value);
    }

    if (after.kind == .repeater and before.kind == .repeater) {
        if (value != .array) {
            return error.DataDoesNotFit;
        }

        var array = std.json.Array.init(arena);

        for (value.array.items) |item| {
            try array.append(try convert_document(arena, before.fields, after.fields, item));
        }

        return .{ .array = array };
    }

    return error.NotConvertible;
}

fn find_def(defs: []const Def, name: []const u8) ?Def {
    std.debug.assert(name.len > 0);
    std.debug.assert(defs.len <= field.fields_max);

    for (defs) |def| {
        if (std.mem.eql(u8, def.name, name)) {
            return def;
        }
    }

    return null;
}

test "plan: removed leaves, allowed and refused kind changes, rewrite when needed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const old = [_]Def{
        .{ .name = "title", .label = "T", .kind = .string },
        .{ .name = "views", .label = "V", .kind = .integer },
        .{ .name = "seo", .label = "S", .kind = .group, .fields = &.{
            .{ .name = "description", .label = "D", .kind = .text },
        } },
    };
    const same = try plan(arena, &old, &old);
    try std.testing.expect(same.allowed and !same.needs_rewrite and same.removed.len == 0);

    const widened = [_]Def{
        .{ .name = "title", .label = "T", .kind = .text },
        .{ .name = "views", .label = "V", .kind = .number },
    };
    const widen = try plan(arena, &old, &widened);
    try std.testing.expect(widen.allowed and widen.needs_rewrite);
    try std.testing.expectEqual(@as(usize, 1), widen.removed.len);
    try std.testing.expectEqualStrings("seo.description", widen.removed[0]);

    const shape = [_]Def{.{
        .name = "title",
        .label = "T",
        .kind = .reference,
        .options = .{ .to = "x" },
    }};
    try std.testing.expect(!(try plan(arena, &old, &shape)).allowed);
}
