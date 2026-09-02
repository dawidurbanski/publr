const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../app/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const content_type = model.content_type;
const content_types = store.content_types;
const evolution = model.evolution;
const Def = content_type.Def;

pub const namespace: sdk.operation.Namespace = .{
    .name = "content_type",
    .summary = "Content types: the shapes records are made of",
    .details =
    \\A content type is data, not code: a handle, names, whether it is public, and a
    \\list of fields (string, text, richtext, slug, email, url, boolean, integer,
    \\number, datetime, select, image, reference, group, repeater). Definitions are
    \\passed as JSON. Editors may read types; changing them needs an admin. Public
    \\types are readable by anyone; private types only by signed-in users.
    ,
};

pub const Summary = struct {
    id: []const u8,
    handle: []const u8,
    name: []const u8,
    name_plural: []const u8,
    public: bool,
    system: bool,
    owner: []const u8,
    editor: []const u8,
    fields: u32,
};

pub const Problem = model.field.Problem;

const new_definition =
    \\{"handle":"note","name":"Note","name_plural":"Notes","public":false,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","required":true}]}
;
pub const example_definition =
    \\{"handle":"post","name":"Post","name_plural":"Posts","public":true,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","required":true},
    \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"title"}},
    \\ {"name":"body","label":"Body","kind":"richtext","searchable":true},
    \\ {"name":"related","label":"Related","kind":"reference","many":true,
    \\ "options":{"to":"post"}}]}
;

pub const Create = struct {
    pub const name = "content_type.create";
    pub const description = "Create a content type from a JSON definition";
    pub const details =
        \\Admins only. The definition is a JSON object: `handle` (`[a-z][a-z0-9_]*`,
        \\unique), `name`, `name_plural`, optional `icon`, `public` (default false),
        \\`editor` (default `form`), `editor_config`, `title_field` (default `title`),
        \\`statuses` (restrict to some of the registered statuses), and `fields`. Each
        \\field: `name`, `label`, `kind`, and optionally `required`, `filterable`,
        \\`searchable`, `many` (reference/repeater), `position` (`main`/`side`),
        \\`options` (`min`, `max`, `min_len`, `max_len`, `choices`, `source`, `to`,
        \\`rows`) and `fields` for group/repeater. Use `content_type validate` to see problems.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { definition: []const u8 };
    pub const Out = struct { id: []const u8, handle: []const u8 };
    pub const example: In = .{ .definition = new_definition };
    pub const example_out: Out = .{ .id = "7c2d9e4f1a8b3c5d6e7f8a9b", .handle = "note" };
    pub const field_docs: sdk.operation.Docs(In) = .{ .definition = "The type definition as JSON" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The new type's id",
        .handle = "Its handle",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const def = try parse_and_validate(ctx, in.definition);
        const id = try content_types.insert(ctx.db, ctx.arena, def, ctx.now_ms);

        ctx.notice("content_type.created", def.handle);

        return .{ .id = id, .handle = def.handle };
    }
};

pub const Update = struct {
    pub const name = "content_type.update";
    pub const description = "Change a content type's definition; existing records follow";
    pub const details =
        \\Admins only. Takes the type by handle or id and the full new definition (see
        \\`content_type create`). What happens to existing records follows from the
        \\change: added fields need nothing; a removed field is refused while records
        \\hold values for it unless `drop_content` is true, which deletes those values;
        \\a field whose kind changes is converted row by row when the change is
        \\allowed (string to text, integer to number, single to many, ...) and every
        \\value fits, otherwise the update is refused as `conflict`; shape changes
        \\(reference/image/group/repeater to something else) are never conversions,
        \\remove and re-add instead. Toggling `searchable` re-indexes the field.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { type: []const u8, definition: []const u8, drop_content: bool = false };
    pub const Out = struct {
        id: []const u8,
        handle: []const u8,
        records_rewritten: u32,
        values_dropped: u32,
    };
    pub const example: In = .{ .type = "post", .definition = example_definition };
    pub const example_out: Out = .{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .handle = "post",
        .records_rewritten = 0,
        .values_dropped = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "Handle or id",
        .definition = "The complete new definition as JSON",
        .drop_content = "Delete the values of fields that the new definition removes",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The type's id",
        .handle = "Its handle",
        .records_rewritten = "Records whose values were converted or re-indexed",
        .values_dropped = "Values deleted for removed fields",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(in.type.len <= 64 << 10);

        const row = try find(ctx, in.type) orelse return error.NotFound;
        const def = if (row.def.system and ctx.caller != .system)
            try parse_addition(ctx, row.def, in.definition)
        else
            try parse_and_validate(ctx, in.definition);
        const plan = try evolution.plan(ctx.arena, row.def.fields, def.fields);

        if (!plan.allowed) {
            return error.Invalid;
        }

        var dropped: u32 = 0;

        for (plan.removed) |path| {
            const held = try store.values.count_field(ctx.db, row.id, path);

            if (held > 0 and !in.drop_content) {
                return error.Conflict;
            }

            dropped += try store.values.delete_field(ctx.db, row.id, path);
        }

        const rewritten = if (plan.needs_rewrite) try rewrite_all(ctx, row.id, row.def, def) else 0;
        const filled = try backfill_slugs(ctx, row.id, row.def, def);
        const updated = try content_types.update(ctx.db, ctx.arena, row.id, def, ctx.now_ms);

        std.debug.assert(updated);
        ctx.notice("content_type.updated", def.handle);

        return .{
            .id = row.id,
            .handle = def.handle,
            .records_rewritten = rewritten + filled,
            .values_dropped = dropped,
        };
    }
};

pub const Get = struct {
    pub const name = "content_type.get";
    pub const description = "Read a content type's full definition";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { type: []const u8 };
    pub const Out = struct { id: []const u8, definition: Def, created_at: i64, updated_at: i64 };
    pub const example: In = .{ .type = "post" };
    pub const example_out: Out = .{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .definition = content_type.test_post,
        .created_at = 1789650000000,
        .updated_at = 1789650000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{ .type = "Handle or id" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(in.type.len <= 64 << 10);

        const row = try find(ctx, in.type) orelse return error.NotFound;

        if (!visible(granted, row.def)) {
            return error.NotFound;
        }

        std.debug.assert(row.id.len > 0);

        return .{
            .id = row.id,
            .definition = row.def,
            .created_at = row.created_at,
            .updated_at = row.updated_at,
        };
    }
};

pub const List = struct {
    pub const name = "content_type.list";
    pub const description = "List content types";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { types: []const Summary };
    pub const example: In = .{};
    pub const example_out: Out = .{ .types = &.{.{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .handle = "post",
        .name = "Post",
        .name_plural = "Posts",
        .public = true,
        .system = false,
        .owner = "",
        .editor = "form",
        .fields = 2,
    }} };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .types = "Sorted by name; anonymous callers see public types only",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        const rows = try content_types.list(ctx.db, ctx.arena);
        var summaries: std.ArrayList(Summary) = .empty;

        for (rows) |row| {
            if (!visible(granted, row.def)) {
                continue;
            }

            try summaries.append(ctx.arena, .{
                .id = row.id,
                .handle = row.def.handle,
                .name = row.def.name,
                .name_plural = row.def.name_plural,
                .public = row.def.public,
                .system = row.def.system,
                .owner = row.def.owner,
                .editor = row.def.editor,
                .fields = @intCast(row.def.fields.len),
            });
        }

        std.debug.assert(summaries.items.len <= rows.len);

        return .{ .types = summaries.items };
    }
};

pub const Delete = struct {
    pub const name = "content_type.delete";
    pub const description = "Delete a content type; refuses while it has records unless forced";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { type: []const u8, force: bool = false };
    pub const Out = struct { deleted: bool, records_removed: u32 };
    pub const example: In = .{ .type = "page" };
    pub const example_out: Out = .{ .deleted = true, .records_removed = 0 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "Handle or id",
        .force = "Also delete every record of the type",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(in.type.len <= 64 << 10);

        const row = try find(ctx, in.type) orelse return error.NotFound;

        if (row.def.system and ctx.caller != .system) {
            return error.Denied;
        }

        const records = try store.records.count_by_type(ctx.db, row.id);

        if (records > 0 and !in.force) {
            return error.Conflict;
        }

        const deleted = try content_types.delete(ctx.db, row.id);
        ctx.notice("content_type.deleted", row.def.handle);

        return .{ .deleted = deleted, .records_removed = records };
    }
};

pub const Validate = struct {
    pub const name = "content_type.validate";
    pub const description = "Check a JSON definition and list every problem without saving";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { definition: []const u8 };
    pub const Out = struct { valid: bool, problems: []const Problem };
    pub const example: In = .{
        .definition = "{\"handle\":\"Post\",\"name\":\"\",\"name_plural\":\"Posts\",\"fields\":[]}",
    };
    pub const example_out: Out = .{ .valid = false, .problems = &.{
        .{ .path = "handle", .message = "handle must be [a-z][a-z0-9_]*, up to 64 characters" },
        .{ .path = "name", .message = "name must be 1 to 128 characters" },
        .{ .path = "fields", .message = "a content type needs at least one field" },
        .{ .path = "title_field", .message = "title_field must name a top-level field" },
    } };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        var problems: model.field.Problems = .{};
        const def = content_type.decode(ctx.arena, in.definition) catch {
            problems.add("", "definition is not valid JSON for a content type");

            return .{ .valid = false, .problems = try copy_problems(ctx, &problems) };
        };

        content_type.validate_def(def, &problems);
        check_statuses(def, &problems);

        return .{ .valid = problems.is_empty(), .problems = try copy_problems(ctx, &problems) };
    }
};

/// A slug field that just appeared: existing records get theirs from its source (or the
/// title), unique per type, in every slot they have.
fn backfill_slugs(ctx: *Ctx, type_id: []const u8, old: Def, new: Def) Error!u32 {
    std.debug.assert(ctx.db.transaction_depth >= 1);
    std.debug.assert(type_id.len > 0);

    const document_module = @import("record/document.zig");
    const slug_field = model.document.slug_field_of(new) orelse return 0;

    if (model.document.slug_field_of(old) != null) {
        return 0;
    }

    var offset: u32 = 0;
    var filled: u32 = 0;

    while (true) {
        const rows = try store.records.list(ctx.db, ctx.arena, .{
            .type_id = type_id,
            .order = .created_desc,
            .limit = store.records.list_max,
            .offset = offset,
        });

        for (rows) |record| {
            const slots = try store.values.slots_of(ctx.db, ctx.arena, record.id);

            for (slots) |slot| {
                var document = try document_module.document_of(ctx, record.id, slot, new);
                const title = model.document.title_of(new, document) catch continue;
                _ = try document_module.unique_slug(ctx, type_id, new, &document, title, record.id);

                const record_id = record.id;

                try store.values.write(ctx.db, record_id, slot, type_id, new.fields, document);
            }

            filled += 1;
        }

        if (rows.len < store.records.list_max) {
            break;
        }

        offset += store.records.list_max;
    }

    std.debug.assert(slug_field.kind == .slug);

    return filled;
}

fn rewrite_all(ctx: *Ctx, type_id: []const u8, old: Def, new: Def) Error!u32 {
    std.debug.assert(ctx.db.transaction_depth >= 1);
    std.debug.assert(type_id.len > 0);

    var offset: u32 = 0;
    var rewritten: u32 = 0;

    while (true) {
        const rows = try store.records.list(ctx.db, ctx.arena, .{
            .type_id = type_id,
            .order = .created_desc,
            .limit = store.records.list_max,
            .offset = offset,
        });

        for (rows) |row| {
            const slots = try store.values.slots_of(ctx.db, ctx.arena, row.id);

            for (slots) |slot| {
                try rewrite_slot(ctx, type_id, row.id, slot, old, new);
            }

            rewritten += 1;
        }

        if (rows.len < store.records.list_max) {
            return rewritten;
        }

        offset += store.records.list_max;
    }
}

fn rewrite_slot(
    ctx: *Ctx,
    type_id: []const u8,
    record_id: []const u8,
    slot: []const u8,
    old: Def,
    new: Def,
) Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(slot.len > 0);

    const values = try store.values.read(ctx.db, ctx.arena, record_id, slot);
    const document = try model.document.assemble(ctx.arena, old.fields, values);
    const converted = evolution.convert_document(
        ctx.arena,
        old.fields,
        new.fields,
        document,
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Conflict,
        };
    };

    try store.values.write(ctx.db, record_id, slot, type_id, new.fields, converted);
}

pub fn find(ctx: *Ctx, handle_or_id: []const u8) Error!?content_types.Row {
    std.debug.assert(handle_or_id.len <= 64 << 10);
    std.debug.assert(ctx.now_ms >= 0);

    if (handle_or_id.len == 0) {
        return null;
    }

    const by_handle = try content_types.get_by_handle(ctx.db, ctx.arena, handle_or_id);

    if (by_handle) |row| {
        return row;
    }

    return content_types.get_by_id(ctx.db, ctx.arena, handle_or_id);
}

pub fn visible(granted: *const Grant, def: Def) bool {
    std.debug.assert(granted.allows());
    std.debug.assert(def.handle.len > 0);

    if (granted.record_filter.flags.public_types_only and !def.public) {
        return false;
    }

    return granted.allows_type(def.handle);
}

fn parse_and_validate(ctx: *Ctx, definition: []const u8) Error!Def {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(content_type.definition_bytes_max > 0);

    if (definition.len == 0 or definition.len > content_type.definition_bytes_max) {
        return error.Invalid;
    }

    const def = try content_type.decode(ctx.arena, definition);
    var problems: model.field.Problems = .{};

    content_type.validate_def(def, &problems);
    check_statuses(def, &problems);

    if (ctx.caller != .system) {
        if (def.system or def.owner.len > 0) {
            problems.add("system", "system types are declared in code, not created by hand");
        }

        for (def.fields) |candidate| {
            if (candidate.locked) {
                problems.add(candidate.name, "locked fields are declared in code");
            }
        }
    }

    if (!problems.is_empty()) {
        return error.Invalid;
    }

    return def;
}

/// A system type edited by hand: everything declared stays as declared; only fields
/// added by hand (after the locked ones) may change.
fn parse_addition(ctx: *Ctx, current: Def, definition: []const u8) Error!Def {
    std.debug.assert(current.system);
    std.debug.assert(ctx.caller != .system);

    if (definition.len == 0 or definition.len > content_type.definition_bytes_max) {
        return error.Invalid;
    }

    const given = try content_type.decode(ctx.arena, definition);
    const locked = current.fields.len - @import("../sdk/plugin/types.zig").unlocked_of(current).len;

    if (given.fields.len < locked) {
        return error.Invalid;
    }

    for (given.fields[locked..]) |candidate| {
        if (candidate.locked) {
            return error.Invalid;
        }
    }

    var def = current;
    const fields = try ctx.arena.alloc(model.field.Def, given.fields.len);

    @memcpy(fields[0..locked], current.fields[0..locked]);
    @memcpy(fields[locked..], given.fields[locked..]);
    def.fields = fields;

    var problems: model.field.Problems = .{};

    content_type.validate_def(def, &problems);

    if (!problems.is_empty()) {
        return error.Invalid;
    }

    return def;
}

fn check_statuses(def: Def, problems: *model.field.Problems) void {
    std.debug.assert(registry.Statuses.all.len > 0);

    for (def.statuses) |id| {
        if (registry.Statuses.find(id) == null) {
            problems.add("statuses", "unknown status");
        }
    }
}

fn copy_problems(ctx: *Ctx, problems: *const model.field.Problems) Error![]const Problem {
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

pub const operations = [_]type{ Create, Update, Get, List, Delete, Validate };
