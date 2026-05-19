//! cr-sqlite plugin: opt-in CRDT sync for the content schema.
//!
//! The plugin's manifest declares `requires_schema = .loose` and points
//! `sqlite_override_dir` at vendored sqlite + cr-sqlite glue (see
//! manifest.zon). That swap happens at build time before any C source
//! gets compiled — by the time Zig code is linked, every TU has been
//! built against the cr-sqlite-enabled SQLite, and crsqlite.c is folded
//! into publr_vendors with -DSQLITE_CORE so it links statically rather
//! than expecting runtime extension loading.
//!
//! Runtime responsibilities (this file):
//!   - db_open_hook: initialize cr-sqlite UDFs on the freshly opened
//!     connection, then mark `content_entries` as a CRR. Both calls are
//!     idempotent so this is safe across restarts and starter-DB imports.
//!   - admin page: surfaces the relay's bearer token + per-replica WS
//!     config (URL + token, persisted to localStorage). Auth on the
//!     relay endpoint (`/admin/ws/sync`) is bearer-token only — no
//!     cookie sharing, so a WASM replica on a different origin can
//!     connect without going through the cookie-auth dance.
//!   - save_hook: stub — changeset capture + broadcast goes here next.

const std = @import("std");
const builtin = @import("builtin");
const Db = @import("db").Db;
const dbh = @import("db_open_hooks");
const sh = @import("save_hooks");
const arh = @import("apply_remote_hooks");
const sch = @import("sync_catchup_hooks");
const admin = @import("admin_api");
const sync_token_mod = @import("sync_token");
const sync_transport = @import("sync_transport");
const plugin_views = @import("plugin_views");
const sync = @import("sync.zig");

// cr-sqlite's static entry point. Same signature as a loadable-extension
// init function but compiled with SQLITE_CORE so it bypasses the function
// pointer table that normally routes sqlite3_* calls.
extern fn sqlite3_crsqlite_init(
    db: ?*anyopaque,
    pz_err_msg: [*c][*c]u8,
    p_thunk: ?*const anyopaque,
) callconv(.c) c_int;

pub const db_open_hooks: []const dbh.Hook = &.{initOnOpen};

fn initOnOpen(d: *Db) anyerror!void {
    var err: [*c]u8 = null;
    const rc = sqlite3_crsqlite_init(@as(?*anyopaque, @ptrCast(d.handle)), &err, null);
    if (rc != 0) {
        std.log.warn("cr-sqlite init failed (rc={d}): {s}", .{
            rc,
            if (err) |e| std.mem.span(e) else @as([]const u8, "no message"),
        });
        return error.CrSqliteInitFailed;
    }
    // Three tables sync as CRRs: the admin's list query inner-joins
    // through content_anchors + content_versions, so syncing just
    // content_entries leaves merged rows invisible (anchor / version
    // missing → JOIN filters the row out). Other tables (taxonomies,
    // content_types) stay local-only as descriptive metadata.
    try d.exec("SELECT crsql_as_crr('content_anchors');");
    try d.exec("SELECT crsql_as_crr('content_entries');");
    try d.exec("SELECT crsql_as_crr('content_versions');");
}

pub const apply_remote_hooks: []const arh.Hook = &.{applyFrame};

fn applyFrame(ctx: arh.Context) anyerror!void {
    // ctx.payload is the inner JSON array (the envelope's `data` field,
    // already unwrapped by the WS handler). cr-sqlite's merge engine
    // dedupes against existing rows so re-applying the same frame is a
    // no-op — safe under at-least-once delivery.
    try sync.applyChanges(ctx.db, ctx.allocator, ctx.payload);
}

pub const sync_catchup_hooks: []const sch.Hook = &.{emitCatchUp};

fn emitCatchUp(ctx: sch.Context) anyerror!void {
    // Reset the high-water-mark and broadcast everything in
    // `crsql_changes`. Fired when a sync transport becomes available
    // (WS open on WASM, new replica connect on native). Receivers
    // dedupe against rows they already have, so this is correctness-
    // safe even if a peer already knows half the changes.
    const payload = try sync.captureAll(ctx.db, ctx.allocator);
    defer ctx.allocator.free(payload);
    if (payload.len <= 2) return;
    sync_transport.send(payload);
}

pub const save_hooks: []const sh.Hook = &.{onSave};

fn onSave(ctx: sh.Context) void {
    // Drain crsql_changes for everything written since our last broadcast
    // and ship the JSON array via sync_transport. On the relay (native)
    // this broadcasts to every connected WS replica; on a WASM replica
    // it hands the bytes to js_sync_send which posts them to the relay.
    // Failures are logged — the local write already succeeded and the
    // changes will go out on the next save (cr-sqlite's merge is
    // idempotent so re-sending is harmless).
    const payload = sync.captureChanges(ctx.db, ctx.allocator) catch |err| {
        std.debug.print("[sync] captureChanges failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer ctx.allocator.free(payload);
    std.debug.print("[sync] onSave: entry={s} payload={d} bytes\n", .{ ctx.entry_id, payload.len });
    // Empty array means nothing to do — no peers should see a no-op frame.
    if (payload.len <= 2) return;
    sync_transport.send(payload);
}

// =============================================================================
// Admin page
// =============================================================================

const page_crsqlite = admin.registerPage(.{
    .id = "cr-sqlite",
    .title = "cr-sqlite",
    .path = "/cr-sqlite",
    .icon = .sync,
    .position = 10,
    .menu_section = "plugins",
    .view = plugin_views.cr_sqlite.CrSqlite,
    .loader = loadCrSqlite,
});

pub const pages = [_]admin.Page{page_crsqlite};

fn loadCrSqlite(ctx: *admin.Context) !plugin_views.cr_sqlite.Props {
    // sync_token.get on a WASM build returns "" so the view hides the
    // relay-token block. On native it reads (or lazily generates) the
    // base64 token from `data/sync_token`.
    const tok = sync_token_mod.get(ctx.allocator) catch "";
    return .{
        .relay_token = tok,
        .is_native = comptime !(builtin.os.tag == .wasi or builtin.cpu.arch == .wasm32),
    };
}
