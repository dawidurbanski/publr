const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../app/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const types = @import("content_type.zig");
const access = @import("record/access.zig");
const document_module = @import("record/document.zig");
pub const fixture = @import("record/fixture.zig");
const lifecycle = @import("record/lifecycle.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const records = store.records;
const values = store.values;
const Def = store.content_types.Def;

const load = access.load;
const parse_document = document_module.parse_document;
const title_of = model.document.title_of;
const unique_slug = document_module.unique_slug;
const slug_of = model.document.slug_of;
const document_of = document_module.document_of;
const check_status = access.check_status;
const allowed_statuses = access.allowed_statuses;
const filter_of = document_module.filter_of;
const copy_problems = document_module.copy_problems;

pub const namespace: sdk.operation.Namespace = .{
    .name = "record",
    .summary = "The content itself: one document per record, in one status",
    .details =
    \\A record is one document of one content type in one status. Documents are JSON
    \\objects shaped by the type's fields and validated on every write. Each write bumps
    \\the record's `version`; pass `expected_version` to refuse overwriting someone
    \\else's change.
    \\
    \\Status is the publication axis (`draft`, `published`, `archived`, `deleted`,
    \\moved by `record transition`); `changed` is the editing axis: saving a live record
    \\parks the edit in a pending copy and sets `changed`, the live document stays as
    \\it is until `record publish` applies the copy, or `record discard_changes` drops
    \\it. Unpublishing, archiving and deleting keep pending edits as they are.
    \\
    \\Anyone may read live records of public types; signed-in users read and write
    \\everything their role allows.
    ,
};

pub const Purpose = enum { delivery, edit };
pub const Order = records.Order;
pub const list_max = records.list_max;
pub const Problem = document_module.Problem;
pub const Record = records.Record;
pub const Transition = lifecycle.Transition;
pub const Publish = lifecycle.Publish;
pub const DiscardChanges = lifecycle.DiscardChanges;
pub const Delete = lifecycle.Delete;
pub const Purge = lifecycle.Purge;

pub const example_id = "a1b2c3d4e5f60718293a4b5c";
pub const example_changed_id = "b2c3d4e5f60718293a4b5c6d";
pub const example_draft_id = "c3d4e5f60718293a4b5c6d7e";
pub const example_document = "{\"title\":\"Hello, world\",\"body\":\"<p>First post.</p>\"}";
const example_record: Record = .{
    .id = example_id,
    .type_id = "7c2d9e4f1a8b3c5d6e7f8a9b",
    .type = "post",
    .status = "published",
    .changed = false,
    .version = 3,
    .title = "Hello, world",
    .slug = "hello-world",
    .created_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .updated_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .created_at = 1789650000000,
    .updated_at = 1789653600000,
};

pub const Create = struct {
    pub const name = "record.create";
    pub const description = "Create a record of a type from a JSON document";
    pub const details =
        \\The document is validated against the type's fields; the title comes from
        \\the type's `title_field`. When the type has a `slug` field it is filled from
        \\its source (or the title) when the document leaves it empty, and made unique
        \\per type. The status defaults to the initial status (`draft`); a type may
        \\restrict which statuses it accepts.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { type: []const u8, document: []const u8, status: ?[]const u8 = null };
    pub const Out = struct { id: []const u8, status: []const u8, slug: ?[]const u8, version: i64 };
    pub const example: In = .{ .type = "post", .document = example_document };
    pub const example_out: Out = .{
        .id = example_id,
        .status = "draft",
        .slug = "hello-world",
        .version = 1,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The content type, by handle or id",
        .document = "The document as a JSON object",
        .status = "Initial status; the registry's initial status when omitted",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(in.type.len <= 64 << 10);

        const row = try types.find(ctx, in.type) orelse return error.NotFound;

        if (!granted.allows_type(row.def.handle)) {
            return error.Denied;
        }

        const status = in.status orelse registry.Statuses.initial().id;
        try check_status(row.def, status, granted);

        var document = try parse_document(ctx, row.def, in.document);
        const title = try title_of(row.def, document);
        const slug = try unique_slug(ctx, row.id, row.def, &document, title, null);
        const id = try records.insert(ctx.db, ctx.io, ctx.arena, .{
            .type_id = row.id,
            .created_by = ctx.caller.user_id(),
            .status = status,
        }, ctx.now_ms);

        try values.write(ctx.db, id, values.live, row.id, row.def.fields, document);
        ctx.notice("record.created", id);

        if (registry.Statuses.is_live(status)) {
            ctx.notice("record.published", id);
        }

        return .{ .id = id, .status = status, .slug = slug, .version = 1 };
    }
};

pub const Get = struct {
    pub const name = "record.get";
    pub const description = "Read one record with its document";
    pub const details =
        \\`purpose` says why: `delivery` (default) is the live document, what a site or
        \\API consumer wants; `edit` is what the admin editor wants: the pending copy
        \\when the record has unpublished changes, else the live document. `slot` names a
        \\copy explicitly (`live`, `pending`, or a plugin's own) for previews. Anonymous
        \\callers only see live records of public types; anything else answers not found.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        purpose: Purpose = .delivery,
        slot: ?[]const u8 = null,
    };
    pub const Out = struct { record: Record, slot: []const u8, document: []const u8 };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{
        .record = example_record,
        .slot = "live",
        .document = example_document,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .purpose = "`delivery` or `edit`",
        .slot = "Read this copy instead (`live`, `pending`, ...); signed-in callers only",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const record = try load(ctx, in.id, granted) orelse return error.NotFound;
        const type_row = try types.find(ctx, record.type_id) orelse return error.NotFound;
        const slot = try slot_for(ctx, record, in);

        std.debug.assert(slot.len > 0);
        const document = try document_of(ctx, record.id, slot, type_row.def);
        const text = try std.json.Stringify.valueAlloc(ctx.arena, document, .{});
        var shown = record;

        if (!std.mem.eql(u8, slot, values.live)) {
            shown.title = title_of(type_row.def, document) catch "";
            shown.slug = slug_of(type_row.def, document);
        }

        return .{ .record = shown, .slot = slot, .document = text };
    }

    fn slot_for(ctx: *Ctx, row: records.Record, in: In) Error![]const u8 {
        std.debug.assert(row.id.len > 0);
        std.debug.assert(ctx.now_ms >= 0);

        if (in.slot) |wanted| {
            if (ctx.caller == .anonymous and !std.mem.eql(u8, wanted, values.live)) {
                return error.NotFound;
            }

            const present = try values.has_slot(ctx.db, row.id, wanted);

            return if (present) wanted else error.NotFound;
        }

        if (in.purpose == .edit and row.changed and ctx.caller != .anonymous) {
            return values.pending;
        }

        return values.live;
    }
};

pub const Save = struct {
    pub const name = "record.save";
    pub const description = "Write a record's document: straight in for drafts, parked when live";
    pub const details =
        \\Validates the document, keeps the slug unless the document sets one, bumps
        \\`version`. Pass the `version` you last read as `expected_version` and the save is
        \\refused (`conflict`) if someone saved in between. On a live record (or one that
        \\already has pending edits) the document is parked as the pending copy and the
        \\record is marked `changed`; the live document is untouched until `record publish`.
        \\Otherwise the document replaces the record's own, and the old one is kept as a
        \\revision snapshot.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, document: []const u8, expected_version: ?i64 = null };
    pub const Out = struct { version: i64, slug: ?[]const u8, changed: bool };
    pub const example: In = .{ .id = example_id, .document = example_document };
    pub const example_out: Out = .{ .version = 3, .slug = "hello-world", .changed = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .document = "The full new document as a JSON object",
        .expected_version = "The `version` you read; refuse if it changed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try load(ctx, in.id, granted) orelse return error.NotFound;
        const type_row = try types.find(ctx, row.type_id) orelse return error.NotFound;
        var document = try parse_document(ctx, type_row.def, in.document);
        const title = try title_of(type_row.def, document);
        const slug = try unique_slug(ctx, row.type_id, type_row.def, &document, title, row.id);
        const park = row.changed or registry.Statuses.is_live(row.status);
        const actor = ctx.caller.user_id();
        const expected = in.expected_version;
        const now = ctx.now_ms;
        const version = try records.save(ctx.db, row.id, actor, expected, now, park);
        const slot = if (park) values.pending else values.live;

        if (!park) {
            try document_module.snapshot_live(ctx, row, type_row.def);
        }

        try values.write(ctx.db, row.id, slot, row.type_id, type_row.def.fields, document);

        if (!park) {
            ctx.notice("record.saved", row.id);
        } else if (!row.changed) {
            ctx.notice("record.changed", row.id);
        } else {
            ctx.notice("record.changes_saved", row.id);
        }

        return .{ .version = version, .slug = slug, .changed = park };
    }
};

pub const List = struct {
    pub const name = "record.list";
    pub const description = "List records of a type, with status, filter, search, order and paging";
    pub const details =
        \\Filter on any field by its path (`filter_field` + `filter_value`; `seo.title`,
        \\`faq.question` for nested ones; numbers and booleans compare as numbers, `true`
        \\= 1; references and images by the target id); search uses fields marked
        \\`searchable` (full text). Filters, search and order look at live values only.
        \\Anonymous callers get live records of public types only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
        status: ?[]const u8 = null,
        changed: ?bool = null,
        search: ?[]const u8 = null,
        filter_field: ?[]const u8 = null,
        filter_value: ?[]const u8 = null,
        order: Order = .updated_desc,
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct { records: []const Record };
    pub const example: In = .{ .type = "post", .status = "published", .limit = 20 };
    pub const example_out: Out = .{ .records = &.{example_record} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The content type, by handle or id",
        .status = "Only this status; without it, listed statuses only (no archived, no deleted)",
        .changed = "Only records with (`true`) or without (`false`) pending edits",
        .search = "Full-text query over searchable fields",
        .filter_field = "A field path (`views`, `seo.title`, `tags`)",
        .filter_value = "The value to match (text, number, true/false, or an id for references)",
        .order = "`updated_desc` (default), `created_desc` or `title_asc`",
        .limit = "Page size, up to 200",
        .offset = "Rows to skip",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(in.type.len <= 64 << 10);
        std.debug.assert(granted.allows());

        const row = try types.find(ctx, in.type) orelse return error.NotFound;

        if (!types.visible(granted, row.def)) {
            return error.NotFound;
        }

        if (in.limit == 0 or in.limit > records.list_max) {
            return error.Invalid;
        }

        var statuses_buffer: [model.status.statuses_max][]const u8 = undefined;
        const query: records.Query = .{
            .type_id = row.id,
            .statuses = allowed_statuses(granted, in.status, &statuses_buffer),
            .changed = in.changed,
            .search = in.search,
            .filter = try filter_of(row.def, in.filter_field, in.filter_value),
            .order = in.order,
            .limit = in.limit,
            .offset = in.offset,
        };
        const rows = try records.list(ctx.db, ctx.arena, query);
        var visible: std.ArrayList(Record) = .empty;

        for (rows) |record| {
            const grant_row: sdk.grant.Row = .{
                .record_id = record.id,
                .type_id = record.type_id,
                .status = record.status,
                .owner_id = record.created_by,
            };

            if (!granted.record_filter.accepts(ctx, grant_row)) {
                continue;
            }

            try visible.append(ctx.arena, record);
        }

        return .{ .records = visible.items };
    }
};

pub const Referrers = struct {
    pub const name = "record.referrers";
    pub const description = "List the records whose references point at a record or media item";
    pub const details =
        \\Every reference and image value is a pointer to another record, and Publr keeps
        \\a reverse index of them. Give a record id (or a media id) and get back who
        \\points at it and through which field. Only records the caller may read are
        \\listed.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { referrers: []const Referrer };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .referrers = &.{
        .{ .record_id = "9b1e7c3d5a2f4e6b8d0c1a3f", .field = "related" },
    } };
    pub const field_docs: sdk.operation.Docs(In) = .{ .id = "The target record or media id" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .referrers = "Record id and field path (`related`, `faq.link`) that points at the target",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len == 0 or in.id.len > 128) {
            return error.Invalid;
        }

        const found = try values.referrers(
            ctx.db,
            ctx.arena,
            in.id,
        );
        var visible: std.ArrayList(Referrer) = .empty;

        for (found) |item| {
            if (try load(ctx, item.record_id, granted) != null) {
                const referrer: Referrer = .{ .record_id = item.record_id, .field = item.field };
                try visible.append(ctx.arena, referrer);
            }
        }

        std.debug.assert(visible.items.len <= found.len);

        return .{ .referrers = visible.items };
    }
};

pub const Referrer = struct { record_id: []const u8, field: []const u8 };

pub const Validate = struct {
    pub const name = "record.validate";
    pub const description = "Check a document against a type and list every problem without saving";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { type: []const u8, document: []const u8 };
    pub const Out = struct { valid: bool, problems: []const Problem };
    pub const example: In = .{ .type = "post", .document = "{\"body\":\"no title\",\"extra\":1}" };
    pub const example_out: Out = .{ .valid = false, .problems = &.{
        .{ .path = "title", .message = "required" },
        .{ .path = "extra", .message = "unknown field" },
    } };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(in.type.len <= 64 << 10);
        std.debug.assert(granted.allows());

        const row = try types.find(ctx, in.type) orelse return error.NotFound;

        if (!types.visible(granted, row.def)) {
            return error.NotFound;
        }

        var problems: model.field.Problems = .{};
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            ctx.arena,
            in.document,
            .{},
        ) catch {
            problems.add("", "document is not valid JSON");

            return .{ .valid = false, .problems = try copy_problems(ctx, &problems) };
        };

        model.validate.validate_document(row.def.fields, parsed, &problems);

        return .{ .valid = problems.is_empty(), .problems = try copy_problems(ctx, &problems) };
    }
};

pub const operations = [_]type{
    Create,    Get,    Save,           Transition, Publish,  List,
    Referrers, Delete, DiscardChanges, Purge,      Validate,
};

const SDK = registry.SDK;

fn seed_admin_type(harness: *sdk.testing.Harness) !void {
    var system = harness.ctx(.system);

    std.debug.assert(system.caller == .system);
    std.debug.assert(harness.buffer.len > 0);

    try SDK.bootstrap(&system);
    try fixture.post_type(&system);
}

test "create, get, save with expected_version, transition, list; slugs are unique per type" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .role = .editor } });
    const first = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = example_document },
    );
    try std.testing.expectEqualStrings("draft", first.status);
    try std.testing.expectEqualStrings("hello-world", first.slug.?);

    const second = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = example_document },
    );
    try std.testing.expectEqualStrings("hello-world-2", second.slug.?);

    const got = try SDK.dispatch(&editor, Get, .{ .id = first.id });
    try std.testing.expectEqualStrings("Hello, world", got.record.title);
    try std.testing.expectEqualStrings("u_ed", got.record.created_by.?);
    try std.testing.expectEqual(@as(i64, 1), got.record.version);

    const saved = try SDK.dispatch(&editor, Save, .{
        .id = first.id,
        .document = "{\"title\":\"Hello again\",\"body\":\"x\"}",
        .expected_version = 1,
    });
    try std.testing.expectEqual(@as(i64, 2), saved.version);
    try std.testing.expectEqualStrings("hello-world", saved.slug.?);

    const stale = SDK.dispatch(
        &editor,
        Save,
        .{ .id = first.id, .document = example_document, .expected_version = 1 },
    );
    try std.testing.expectError(error.Conflict, stale);

    const invalid = SDK.dispatch(
        &editor,
        Save,
        .{ .id = first.id, .document = "{\"body\":\"no title\"}" },
    );
    try std.testing.expectError(error.Invalid, invalid);

    const published = try SDK.dispatch(&editor, Transition, .{ .id = first.id, .to = "published" });
    try std.testing.expectEqualStrings("published", published.status);
    try std.testing.expectEqual(@as(i64, 3), published.version);
    const bad_move = SDK.dispatch(&editor, Transition, .{ .id = first.id, .to = "nope" });
    try std.testing.expectError(error.Invalid, bad_move);

    const drafts = try SDK.dispatch(&editor, List, .{ .type = "post", .status = "draft" });
    try std.testing.expectEqual(@as(usize, 1), drafts.records.len);
    const everything = try SDK.dispatch(&editor, List, .{ .type = "post", .order = .title_asc });
    try std.testing.expectEqual(@as(usize, 2), everything.records.len);
    try std.testing.expectEqualStrings("Hello again", everything.records[0].title);
}

test "anonymous callers see live records of public types only; private types are invisible" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .role = .admin } });
    var anon = harness.ctx(.anonymous);
    var private = model.content_type.test_post;
    private.handle = "note";
    private.name = "Note";
    private.name_plural = "Notes";
    private.public = false;
    const private_definition = try model.content_type.encode(harness.fixed.allocator(), private);
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = private_definition });

    const draft = try SDK.dispatch(
        &admin,
        Create,
        .{ .type = "post", .document = example_document },
    );
    const live = try SDK.dispatch(&admin, Create, .{
        .type = "post",
        .document = "{\"title\":\"Live one\",\"body\":\"y\"}",
        .status = "published",
    });
    const secret = try SDK.dispatch(&admin, Create, .{
        .type = "note",
        .document = "{\"title\":\"Secret\",\"body\":\"z\"}",
        .status = "published",
    });

    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, Get, .{ .id = draft.id }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, Get, .{ .id = secret.id }));
    try std.testing.expectEqualStrings(
        "Live one",
        (try SDK.dispatch(&anon, Get, .{ .id = live.id })).record.title,
    );

    const listed = try SDK.dispatch(&anon, List, .{ .type = "post" });
    try std.testing.expectEqual(@as(usize, 1), listed.records.len);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, List, .{ .type = "note" }));
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&anon, Create, .{ .type = "post", .document = example_document }),
    );

    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, types.List, .{}));
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&anon, types.Create, .{ .definition = private_definition }),
    );

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .role = .editor } });
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&editor, types.Create, .{ .definition = private_definition }),
    );

    const visible_types = (try SDK.dispatch(&editor, types.List, .{})).types;
    var seen_post = false;
    var seen_note = false;

    for (visible_types) |summary| {
        seen_post = seen_post or std.mem.eql(u8, summary.handle, "post");
        seen_note = seen_note or std.mem.eql(u8, summary.handle, "note");
    }

    try std.testing.expect(seen_post and seen_note);
}

test "validate reports problems; filters and search go through the projection" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .role = .editor } });
    const report = try SDK.dispatch(
        &editor,
        Validate,
        .{ .type = "post", .document = "{\"body\":1,\"extra\":true}" },
    );
    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(usize, 3), report.problems.len);

    _ = try SDK.dispatch(
        &editor,
        Create,
        .{
            .type = "post",
            .document = "{\"title\":\"Ten\",\"body\":\"about apples\",\"views\":10}",
        },
    );
    _ = try SDK.dispatch(
        &editor,
        Create,
        .{
            .type = "post",
            .document = "{\"title\":\"Twenty\",\"body\":\"about pears\",\"views\":20}",
        },
    );

    const tens = try SDK.dispatch(
        &editor,
        List,
        .{ .type = "post", .filter_field = "views", .filter_value = "10" },
    );
    try std.testing.expectEqual(@as(usize, 1), tens.records.len);
    try std.testing.expectEqualStrings("Ten", tens.records[0].title);

    const pears = try SDK.dispatch(&editor, List, .{ .type = "post", .search = "pears" });
    try std.testing.expectEqual(@as(usize, 1), pears.records.len);
    try std.testing.expectEqualStrings("Twenty", pears.records[0].title);

    const not_filterable = SDK.dispatch(
        &editor,
        List,
        .{ .type = "post", .filter_field = "body", .filter_value = "x" },
    );
    try std.testing.expectError(error.Invalid, not_filterable);
}

test "slug comes from the slug field's source; type update re-indexes existing records" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .role = .admin } });
    const definition =
        \\{"handle":"person","name":"Person","name_plural":"People","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}},
        \\ {"name":"age","label":"Age","kind":"integer"}]}
    ;
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = definition });

    const ada_document = "{\"name\":\"Ada L.\",\"age\":36}";
    const ada = try SDK.dispatch(&admin, Create, .{ .type = "person", .document = ada_document });
    try std.testing.expectEqualStrings("ada-l", ada.slug.?);

    const explicit = try SDK.dispatch(&admin, Create, .{
        .type = "person",
        .document = "{\"name\":\"Grace\",\"handle\":\"amazing-grace\",\"age\":45}",
    });
    try std.testing.expectEqualStrings("amazing-grace", explicit.slug.?);

    const by_age: List.In = .{ .type = "person", .filter_field = "age", .filter_value = "36" };
    const thirty_six = try SDK.dispatch(&admin, List, by_age);
    try std.testing.expectEqual(@as(usize, 1), thirty_six.records.len);
    try std.testing.expectEqualStrings("Ada L.", thirty_six.records[0].title);

    const widened =
        \\{"handle":"person","name":"Person","name_plural":"People","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}},
        \\ {"name":"age","label":"Age","kind":"number"}]}
    ;
    const evolved = try SDK.dispatch(
        &admin,
        types.Update,
        .{ .type = "person", .definition = widened },
    );
    try std.testing.expectEqual(@as(u32, 2), evolved.records_rewritten);

    const as_number: List.In = .{ .type = "person", .filter_field = "age", .filter_value = "36" };
    try std.testing.expectEqual(
        @as(usize, 1),
        (try SDK.dispatch(&admin, List, as_number)).records.len,
    );

    const narrowed =
        \\{"handle":"person","name":"Person","name_plural":"People","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}}]}
    ;
    const refused = SDK.dispatch(
        &admin,
        types.Update,
        .{ .type = "person", .definition = narrowed },
    );
    try std.testing.expectError(error.Conflict, refused);

    const dropped = try SDK.dispatch(&admin, types.Update, .{
        .type = "person",
        .definition = narrowed,
        .drop_content = true,
    });
    try std.testing.expectEqual(@as(u32, 2), dropped.values_dropped);

    const shape =
        \\{"handle":"person","name":"Person","name_plural":"People","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"reference","options":{"to":"x"}},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}}]}
    ;
    const invalid = SDK.dispatch(&admin, types.Update, .{ .type = "person", .definition = shape });
    try std.testing.expectError(error.Invalid, invalid);
}

test "referrers: reverse index of reference values, filtered by what the caller may read" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .role = .editor } });
    const target = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = example_document },
    );
    const pointing_document = try std.fmt.allocPrint(
        harness.fixed.allocator(),
        "{{\"title\":\"Pointing\",\"body\":\"x\",\"tags\":[\"{s}\"]}}",
        .{target.id},
    );
    const pointing = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = pointing_document },
    );

    const found = try SDK.dispatch(&editor, Referrers, .{ .id = target.id });
    try std.testing.expectEqual(@as(usize, 1), found.referrers.len);
    try std.testing.expectEqualStrings(pointing.id, found.referrers[0].record_id);
    try std.testing.expectEqualStrings("tags", found.referrers[0].field);

    var anon = harness.ctx(.anonymous);
    const hidden = try SDK.dispatch(&anon, Referrers, .{ .id = target.id });
    try std.testing.expectEqual(@as(usize, 0), hidden.referrers.len);
}

test "adding a slug field to a type backfills existing records, duplicates get suffixes" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .role = .admin } });
    const without =
        \\{"handle":"hotel","name":"Hotel","name_plural":"Hotels","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true}]}
    ;
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = without });
    const abc: Create.In = .{ .type = "hotel", .document = "{\"name\":\"ABC\"}" };
    const first = try SDK.dispatch(&admin, Create, abc);
    const second = try SDK.dispatch(&admin, Create, abc);
    try std.testing.expect(first.slug == null);

    const with_slug =
        \\{"handle":"hotel","name":"Hotel","name_plural":"Hotels","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
    ;
    const updated = try SDK.dispatch(&admin, types.Update, .{
        .type = "hotel",
        .definition = with_slug,
    });
    try std.testing.expectEqual(@as(u32, 2), updated.records_rewritten);

    const one = try SDK.dispatch(&admin, Get, .{ .id = first.id });
    const two = try SDK.dispatch(&admin, Get, .{ .id = second.id });
    const slugs = [_][]const u8{ one.record.slug.?, two.record.slug.? };
    const has_plain = std.mem.eql(u8, slugs[0], "abc") or std.mem.eql(u8, slugs[1], "abc");
    const has_suffixed = std.mem.eql(u8, slugs[0], "abc-2") or std.mem.eql(u8, slugs[1], "abc-2");
    try std.testing.expect(has_plain and has_suffixed);
}
