const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const store = publr.store;
const content_types = publr.operations.content_type;
const records = publr.operations.record;
const sites = publr.operations.site;
const users = publr.operations.user;
const SDK = publr.registry.SDK;

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const admin_email = "ada@example.com";
pub const shared_password = "correct horse battery";

const page_definition =
    \\{"handle":"page","name":"Page","name_plural":"Pages","public":true,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","required":true}]}
;
const second_document = "{\"title\":\"Hello, world\",\"body\":\"<p>Second.</p>\"}";
const edited_document = "{\"title\":\"Hello, world\",\"body\":\"<p>Edited.</p>\"}";
const referring_document = "{\"title\":\"See also\",\"related\":[\"" ++
    records.example_id ++ "\"]}";

/// Everything the printed examples name: Ada, the admin every `--as` points at; an editor
/// who can sign in; an invited account holding the documented token; the `post` and `page`
/// types; a live record that anyone may read and that has a revision behind it, a second
/// live record with edits parked in `pending`, and a draft still waiting to be published.
pub fn fill(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.db.transaction_depth == 0);

    const admin_id = try fill_site(ctx);

    try fill_users(ctx);

    ctx.caller = .{ .user = .{ .id = admin_id, .role = .admin } };

    try fill_types(ctx);
    try fill_records(ctx);
}

fn fill_site(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(admin_email.len > 0);

    const created = try SDK.dispatch(ctx, sites.Init, .{
        .email = admin_email,
        .display_name = "Ada",
        .password = shared_password,
    });

    std.debug.assert(created.user_id.len > 0);

    return created.user_id;
}

fn fill_users(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(users.SetPassword.example.token.len == users.password_token_len);

    _ = try SDK.dispatch(ctx, users.Create, .{
        .email = "editor@example.com",
        .display_name = "Editor",
        .password = shared_password,
    });

    const invited = try SDK.dispatch(ctx, users.Create, .{
        .email = "invited@example.com",
        .display_name = "Invited",
        .password_link = true,
    });

    const token_hash = users.hash_token(users.SetPassword.example.token) orelse unreachable;
    const expires_at = ctx.now_ms + users.password_link_lifetime_ms;

    try store.users.set_password_token(ctx.db, invited.user_id, token_hash, expires_at);
}

fn fill_types(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(content_types.example_definition.len > 0);

    _ = try SDK.dispatch(ctx, content_types.Create, .{
        .definition = content_types.example_definition,
    });
    _ = try SDK.dispatch(ctx, content_types.Create, .{ .definition = page_definition });
}

fn fill_records(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(records.example_changed_id.len == store.records.id_len);

    try record_with_id(ctx, records.example_id);
    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = records.example_id });
    _ = try SDK.dispatch(ctx, records.Save, .{
        .id = records.example_id,
        .document = second_document,
    });
    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = records.example_id });

    try record_with_id(ctx, records.example_changed_id);
    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = records.example_changed_id });
    _ = try SDK.dispatch(ctx, records.Save, .{
        .id = records.example_changed_id,
        .document = edited_document,
    });

    try record_with_id(ctx, records.example_draft_id);

    const referring = try SDK.dispatch(ctx, records.Create, .{
        .type = "post",
        .document = referring_document,
    });

    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = referring.id });
}

/// Create a post and give it the id the examples name, so `--id a1b2...` resolves.
fn record_with_id(ctx: *Ctx, id: []const u8) Error!void {
    std.debug.assert(ctx.caller == .user);
    std.debug.assert(id.len == store.records.id_len);

    const created = try SDK.dispatch(ctx, records.Create, .{
        .type = "post",
        .document = records.example_document,
    });

    try store.records.rename(ctx.db, created.id, id);
}
