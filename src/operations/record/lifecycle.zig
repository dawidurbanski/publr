const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../app/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const types = @import("../content_type.zig");
const access = @import("access.zig");
const document_module = @import("document.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const records = store.records;
const values = store.values;
const load = access.load;
const check_status = access.check_status;

const example_id = "a1b2c3d4e5f60718293a4b5c";
const record_operations = @import("../record.zig");

/// Make the pending copy the live document (if there is one) and drop the mark.
fn apply_pending(ctx: *Ctx, row: records.Record) Error!bool {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (!row.changed) {
        return false;
    }

    const type_row = try types.find(ctx, row.type_id) orelse return error.NotFound;
    const slug_field = model.document.slug_field_of(type_row.def);

    if (slug_field) |found| {
        try refuse_taken_slug(ctx, row, found.name);
    }

    try document_module.snapshot_live(ctx, row, type_row.def);

    const promoted = try values.promote(ctx.db, row.id, values.pending, values.live);

    if (promoted) {
        ctx.notice("record.saved", row.id);
    }

    return true;
}

/// A parked slug was checked against live values when it was typed; check again now.
fn refuse_taken_slug(ctx: *Ctx, row: records.Record, slug_field: []const u8) Error!void {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(slug_field.len > 0);

    const slot = values.pending;
    const slug = try values.read_text(ctx.db, ctx.arena, row.id, slot, slug_field);
    const wanted = slug orelse return;
    const type_id = row.type_id;
    const holder = try values.find_by_text(ctx.db, ctx.arena, type_id, slug_field, wanted);

    if (holder != null and !std.mem.eql(u8, holder.?, row.id)) {
        return error.Conflict;
    }
}

/// The outcome notice of a status move, if the move has a name of its own.
fn notify_transition(ctx: *Ctx, id: []const u8, from: []const u8, to: []const u8) void {
    std.debug.assert(id.len > 0);
    std.debug.assert(!std.mem.eql(u8, from, to) or from.len > 0);

    ctx.notice("record.transitioned", id);

    const from_live = registry.Statuses.is_live(from);
    const to_live = registry.Statuses.is_live(to);

    if (to_live and !from_live) {
        ctx.notice("record.published", id);
    } else if (from_live and !to_live) {
        ctx.notice("record.unpublished", id);
    }

    if (std.mem.eql(u8, to, "archived")) {
        ctx.notice("record.archived", id);
    } else if (std.mem.eql(u8, to, "deleted")) {
        ctx.notice("record.deleted", id);
    } else if (std.mem.eql(u8, from, "archived") or std.mem.eql(u8, from, "deleted")) {
        ctx.notice("record.restored", id);
    }
}

pub const Transition = struct {
    pub const name = "record.transition";
    pub const description = "Move a record to another status (publish, unpublish, archive, ...)";
    pub const details =
        \\The move must be a registered transition (see `status list`) and the type
        \\must accept the target status. Moving into a live status applies pending
        \\edits first, like `record publish`; moving out of one keeps them parked.
        \\Bumps `version`; `expected_version` works as in save.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, to: []const u8, expected_version: ?i64 = null };
    pub const Out = struct { status: []const u8, changed: bool, version: i64 };
    pub const example: In = .{ .id = record_operations.example_draft_id, .to = "published" };
    pub const example_out: Out = .{ .status = "published", .changed = false, .version = 2 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .to = "The target status id",
        .expected_version = "The `version` you read; refuse if it changed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try load(ctx, in.id, granted) orelse return error.NotFound;

        return move(ctx, row, in.to, in.expected_version, granted);
    }
};

fn move(
    ctx: *Ctx,
    row: records.Record,
    to: []const u8,
    expected: ?i64,
    granted: *const Grant,
) Error!Transition.Out {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(to.len > 0);

    const type_row = try types.find(ctx, row.type_id) orelse return error.NotFound;

    if (!registry.Statuses.allows(row.status, to)) {
        return error.Invalid;
    }

    try check_status(type_row.def, to, granted);

    if (!granted.allows_transition(row.status, to)) {
        return error.Denied;
    }

    const applied = if (registry.Statuses.is_live(to)) try apply_pending(ctx, row) else false;
    const changed = row.changed and !applied;
    const actor = ctx.caller.user_id();
    const version = try records.set_status(
        ctx.db,
        row.id,
        to,
        expected,
        ctx.now_ms,
        actor,
        changed,
    );

    notify_transition(ctx, row.id, row.status, to);

    return .{ .status = to, .changed = changed, .version = version };
}

pub const Publish = struct {
    pub const name = "record.publish";
    pub const description = "Make the record's latest document live";
    pub const details =
        \\From a draft: the document goes live (`draft -> published`). From a live
        \\record with pending edits: the pending copy becomes the live document, the
        \\old one is kept as a revision snapshot, `changed` clears. Either way one
        \\`record.published` notice. Refused when there is nothing to publish.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = Transition.Out;
    pub const example: In = .{ .id = record_operations.example_changed_id };
    pub const example_out: Out = .{ .status = "published", .changed = false, .version = 2 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .expected_version = "The `version` you read; refuse if it changed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try load(ctx, in.id, granted) orelse return error.NotFound;

        if (!registry.Statuses.is_live(row.status)) {
            return move(ctx, row, "published", in.expected_version, granted);
        }

        if (!row.changed) {
            return error.Invalid;
        }

        if (!granted.allows_transition(row.status, row.status)) {
            return error.Denied;
        }

        _ = try apply_pending(ctx, row);

        const actor = ctx.caller.user_id();
        const expected = in.expected_version;
        const now = ctx.now_ms;
        const version = try records.save(ctx.db, row.id, actor, expected, now, false);

        ctx.notice("record.published", row.id);

        return .{ .status = row.status, .changed = false, .version = version };
    }
};

pub const DiscardChanges = struct {
    pub const name = "record.discard_changes";
    pub const description = "Drop a record's pending edits; the document stays as it is";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = struct { version: i64 };
    pub const example: In = .{ .id = record_operations.example_changed_id };
    pub const example_out: Out = .{ .version = 4 };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try load(ctx, in.id, granted) orelse return error.NotFound;

        if (!row.changed) {
            return error.Invalid;
        }

        try values.clear(ctx.db, row.id, values.pending);

        const actor = ctx.caller.user_id();
        const expected = in.expected_version;
        const now = ctx.now_ms;
        const version = try records.save(ctx.db, row.id, actor, expected, now, false);

        ctx.notice("record.changes_discarded", row.id);

        return .{ .version = version };
    }
};

pub const Delete = struct {
    pub const name = "record.delete";
    pub const description = "Move a record to `deleted` (reversible: transition back to draft)";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = Transition.Out;
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .status = "deleted", .changed = false, .version = 2 };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try load(ctx, in.id, granted) orelse return error.NotFound;

        return move(ctx, row, "deleted", in.expected_version, granted);
    }
};

pub const Purge = struct {
    pub const name = "record.purge";
    pub const description = "Remove a record for good: document, pending edits and snapshots";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { purged: bool };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .purged = true };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try load(ctx, in.id, granted) orelse return error.NotFound;

        _ = try store.snapshots.delete_all(ctx.db, row.id);

        const purged = try records.delete(ctx.db, row.id);

        ctx.notice("record.purged", row.id);

        return .{ .purged = purged };
    }
};

const SDK = registry.SDK;

test "pending edits: save on a live record parks, publish applies, discard drops, moves keep" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .role = .editor } });
    var anon = harness.ctx(.anonymous);
    const created = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"One\",\"body\":\"first\"}",
    });
    _ = try SDK.dispatch(&editor, Publish, .{ .id = created.id });

    const parked = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Two\",\"body\":\"second\"}",
    });
    try std.testing.expect(parked.changed);
    const public_view = try SDK.dispatch(&anon, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("One", public_view.record.title);
    const editing = try SDK.dispatch(&editor, record_operations.Get, .{
        .id = created.id,
        .purpose = .edit,
    });
    try std.testing.expectEqualStrings("Two", editing.record.title);
    try std.testing.expectEqualStrings("pending", editing.slot);
    try std.testing.expect(editing.record.changed);

    const live_only = try SDK.dispatch(&anon, record_operations.List, .{
        .type = "post",
        .search = "second",
    });
    try std.testing.expectEqual(@as(usize, 0), live_only.records.len);
    const flagged = try SDK.dispatch(&editor, record_operations.List, .{
        .type = "post",
        .changed = true,
    });
    try std.testing.expectEqual(@as(usize, 1), flagged.records.len);

    const unpublished = try SDK.dispatch(&editor, Transition, .{ .id = created.id, .to = "draft" });
    try std.testing.expect(unpublished.changed);
    const still_parked = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Three\",\"body\":\"third\"}",
    });
    try std.testing.expect(still_parked.changed);
    const own_view = try SDK.dispatch(&editor, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("One", own_view.record.title);

    const published = try SDK.dispatch(&editor, Publish, .{ .id = created.id });
    try std.testing.expect(!published.changed);
    try std.testing.expectEqualStrings("published", published.status);
    const public_again = try SDK.dispatch(&anon, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("Three", public_again.record.title);
    const nothing_to_publish = SDK.dispatch(&editor, Publish, .{ .id = created.id });
    try std.testing.expectError(error.Invalid, nothing_to_publish);

    _ = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Four\",\"body\":\"x\"}",
    });
    _ = try SDK.dispatch(&editor, DiscardChanges, .{ .id = created.id });
    const after = try SDK.dispatch(&editor, record_operations.Get, .{
        .id = created.id,
        .purpose = .edit,
    });
    try std.testing.expectEqualStrings("Three", after.record.title);
    try std.testing.expect(!after.record.changed);
    const nothing_to_discard = SDK.dispatch(&editor, DiscardChanges, .{ .id = created.id });
    try std.testing.expectError(error.Invalid, nothing_to_discard);

    const revisions = try store.snapshots.list(
        &harness.fixture.connection,
        harness.fixed.allocator(),
        created.id,
        "revision",
        10,
    );
    try std.testing.expectEqual(@as(usize, 1), revisions.len);
    try std.testing.expect(std.mem.indexOf(u8, revisions[0].document, "\"One\"") != null);

    const deleted = try SDK.dispatch(&editor, Delete, .{ .id = created.id });
    try std.testing.expectEqualStrings("deleted", deleted.status);
    const gone_for_anon = SDK.dispatch(&anon, record_operations.Get, .{ .id = created.id });
    try std.testing.expectError(error.NotFound, gone_for_anon);
    const restored = try SDK.dispatch(&editor, Transition, .{ .id = created.id, .to = "draft" });
    try std.testing.expectEqualStrings("draft", restored.status);
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, Purge, .{ .id = created.id }));

    var admin = harness.ctx(.{ .user = .{ .id = "u_ad", .role = .admin } });
    try std.testing.expect((try SDK.dispatch(&admin, Purge, .{ .id = created.id })).purged);
    const gone_for_good = SDK.dispatch(&admin, record_operations.Get, .{ .id = created.id });
    try std.testing.expectError(error.NotFound, gone_for_good);
}
