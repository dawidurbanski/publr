//! A record's document: parsing and validating it, assembling it from rows, titles and
//! slugs, filters, and keeping the old live copy as a revision.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const slugs = @import("../../lib/text.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const records = store.records;
const values = store.values;
const Def = store.content_types.Def;
const document_rules = model.document;
pub const Problem = model.field.Problem;

pub fn parse_document(ctx: *Ctx, def: Def, text: []const u8) Error!std.json.Value {
    std.debug.assert(def.fields.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (text.len == 0 or text.len > records.document_bytes_max) {
        return error.Invalid;
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, text, .{}) catch {
        return error.Invalid;
    };
    var problems: model.field.Problems = .{};

    model.validate.validate_document(def.fields, parsed, &problems);

    if (!problems.is_empty()) {
        return error.Invalid;
    }

    return parsed;
}

pub fn document_of(
    ctx: *Ctx,
    record_id: []const u8,
    slot: []const u8,
    def: Def,
) Error!std.json.Value {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(def.fields.len > 0);

    const rows = try values.read(ctx.db, ctx.arena, record_id, slot);

    return try document_rules.assemble(ctx.arena, def.fields, rows);
}

/// The slug for a write: the document's own when set, else the current one on save,
/// else derived from the slug field's source or the title; suffixed until unique per
/// type. Null when the type has no slug field. Sets it into the document.
pub fn unique_slug(
    ctx: *Ctx,
    type_id: []const u8,
    def: Def,
    document: *std.json.Value,
    title: []const u8,
    own_id: ?[]const u8,
) Error!?[]const u8 {
    std.debug.assert(document.* == .object);
    std.debug.assert(title.len > 0);

    const slug_field = document_rules.slug_field_of(def) orelse return null;
    const given = document.object.get(slug_field.name);
    var base: []const u8 = undefined;

    if (given != null and given.? == .string and given.?.string.len > 0) {
        base = given.?.string;
    } else if (try current_slug(ctx, own_id, slug_field.name)) |kept| {
        try put_slug(ctx, document, slug_field.name, kept);

        return kept;
    } else {
        const source = document_rules.slug_source(def, slug_field, document.*, title);
        base = try slugs.slugify(ctx.arena, source);
    }

    var candidate = base;
    var attempt: u32 = 1;

    while (attempt <= slugs.attempts_max) : (attempt += 1) {
        const holder = try store.values.find_by_text(
            ctx.db,
            ctx.arena,
            type_id,
            slug_field.name,
            candidate,
        );
        const taken_by_other = holder != null and
            (own_id == null or !std.mem.eql(u8, holder.?, own_id.?));

        if (!taken_by_other) {
            try put_slug(ctx, document, slug_field.name, candidate);

            return candidate;
        }

        candidate = try slugs.with_suffix(
            ctx.arena,
            base,
            attempt + 1,
        );
    }

    return error.Conflict;
}

fn current_slug(ctx: *Ctx, own_id: ?[]const u8, path: []const u8) Error!?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const id = own_id orelse return null;
    const slot = slot_in_use(ctx, id);

    return try values.read_text(ctx.db, ctx.arena, id, slot, path);
}

fn put_slug(
    ctx: *Ctx,
    document: *std.json.Value,
    name: []const u8,
    slug: []const u8,
) Error!void {
    std.debug.assert(document.* == .object);
    std.debug.assert(slug.len > 0);

    const key = try ctx.arena.dupe(u8, name);

    try document.object.put(ctx.arena, key, .{ .string = slug });
}

/// Where a record's edits currently live: its pending copy when one exists, else live.
pub fn slot_in_use(ctx: *Ctx, id: []const u8) []const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const parked = values.has_slot(ctx.db, id, values.pending) catch false;

    return if (parked) values.pending else values.live;
}

/// Keep the live document as a revision before it is replaced.
pub fn snapshot_live(ctx: *Ctx, row: records.Record, def: Def) Error!void {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const has_live = try values.has_slot(ctx.db, row.id, values.live);

    if (!has_live) {
        return;
    }

    const document = try document_of(ctx, row.id, values.live, def);
    const text = try std.json.Stringify.valueAlloc(ctx.arena, document, .{});

    _ = try store.snapshots.take(
        ctx.db,
        row.id,
        store.snapshots.revision,
        ctx.now_ms,
        ctx.caller.user_id(),
        text,
    );
}

pub fn filter_of(def: Def, field_name: ?[]const u8, value: ?[]const u8) Error!?records.Filter {
    std.debug.assert(def.fields.len > 0);
    std.debug.assert(def.handle.len > 0);

    const name = field_name orelse return null;
    const text = value orelse return error.Invalid;
    const found = document_rules.find_path(def.fields, name) orelse return error.Invalid;

    return switch (model.field.column_of(found.kind)) {
        .text => .{ .field = name, .text = text },
        .ref => .{ .field = name, .ref = text },
        .int => .{
            .field = name,
            .int = document_rules.parse_int_like(text) orelse return error.Invalid,
        },
        .real => .{
            .field = name,
            .real = std.fmt.parseFloat(f64, text) catch return error.Invalid,
        },
        .long => error.Invalid,
    };
}

pub fn copy_problems(ctx: *Ctx, problems: *const model.field.Problems) Error![]const Problem {
    std.debug.assert(problems.len <= model.field.problems_max);
    std.debug.assert(ctx.now_ms >= 0);

    const copy = try ctx.arena.alloc(Problem, problems.len);

    for (problems.slice(), 0..) |problem, index| {
        copy[index] = .{
            .path = ctx.arena.dupe(u8, problem.path) catch return error.OutOfMemory,
            .message = problem.message,
        };
    }

    return copy;
}
