//! Test aggregator for the kv (variables) module.
//!
//! Tests live here rather than inline in `src/kv/registry.zig` because
//! Zig 0.15's test runner only discovers tests reachable from the test
//! root via the import graph. From `src/tests/` the schema SQL path
//! resolves via `std.fs.cwd().openFile` against the package root.
//! Mirrors `src/tests/storage_tests.zig`.

const std = @import("std");

const Db = @import("db").Db;
const kv = @import("kv");
const publish_hooks = @import("publish_hooks");
const cms = @import("cms");

fn loadSchema(allocator: std.mem.Allocator) ![]u8 {
    var file = try std.fs.cwd().openFile("src/core/schema/content_schema.sql", .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1 * 1024 * 1024);
}

fn initTestDb() !Db {
    var db = try Db.init(std.testing.allocator, ":memory:");
    errdefer db.deinit();
    const sql = try loadSchema(std.testing.allocator);
    defer std.testing.allocator.free(sql);
    try db.exec(sql);
    return db;
}

test "materializeIfNeeded inserts a plugin-registered row" {
    var db = try initTestDb();
    defer db.deinit();

    const def = kv.Def{
        .key = "test.color",
        .label = "Brand color",
        .description = "Primary brand accent",
        .mode = .literal_baked,
        .source = "plugin:test",
    };
    try kv.materializeIfNeeded(&db, &def);

    var stmt = try db.prepare("SELECT mode, source, label FROM kv WHERE key = 'test.color'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("literal-baked", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("plugin:test", stmt.columnText(1).?);
    try std.testing.expectEqualStrings("Brand color", stmt.columnText(2).?);
}

test "materializeIfNeeded is idempotent (INSERT OR IGNORE)" {
    var db = try initTestDb();
    defer db.deinit();

    const def = kv.Def{
        .key = "test.greeting",
        .mode = .literal_baked,
        .source = "plugin:test",
    };
    try kv.materializeIfNeeded(&db, &def);
    try kv.materializeIfNeeded(&db, &def);
    try kv.materializeIfNeeded(&db, &def);

    var stmt = try db.prepare("SELECT COUNT(*) FROM kv WHERE key = 'test.greeting'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
}

test "materializeIfNeeded does not overwrite an editor-edited value" {
    var db = try initTestDb();
    defer db.deinit();

    const def = kv.Def{
        .key = "test.tagline",
        .mode = .literal_baked,
        .source = "plugin:test",
    };
    // First materialize creates an empty row.
    try kv.materializeIfNeeded(&db, &def);
    // Simulate editor edit.
    try db.exec("UPDATE kv SET value = 'Edited by editor' WHERE key = 'test.tagline'");
    // Subsequent materialize must not overwrite the editor's value.
    try kv.materializeIfNeeded(&db, &def);

    var stmt = try db.prepare("SELECT value FROM kv WHERE key = 'test.tagline'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqualStrings("Edited by editor", stmt.columnText(0).?);
}

test "resolve returns NotFound for unknown key (no Def, no row)" {
    var db = try initTestDb();
    defer db.deinit();

    const result = kv.resolve(&db, std.testing.allocator, "does.not.exist");
    try std.testing.expectError(error.NotFound, result);
}

test "resolve reads a literal value from kv table (editor-added var)" {
    var db = try initTestDb();
    defer db.deinit();

    try db.exec("INSERT INTO kv (key, value, source, mode, updated_at) VALUES ('site_name', 'Publr', 'editor', 'literal-baked', unixepoch())");

    const value = try kv.resolve(&db, std.testing.allocator, "site_name");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("Publr", value);
}

test "resolveDef runs compute fn and persists last_resolved for computed-baked" {
    var db = try initTestDb();
    defer db.deinit();

    const fn_ptr: kv.ComputeFn = struct {
        fn compute(ctx: *kv.Ctx) anyerror![]const u8 {
            return try ctx.allocator.dupe(u8, "computed-output");
        }
    }.compute;

    const def = kv.Def{
        .key = "plugin.now",
        .mode = .computed_baked,
        .compute = fn_ptr,
        .source = "plugin:test",
    };

    const value = try kv.resolveDef(&db, std.testing.allocator, &def);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("computed-output", value);

    // last_resolved is cached for computed-baked mode.
    var stmt = try db.prepare("SELECT last_resolved FROM kv WHERE key = 'plugin.now'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqualStrings("computed-output", stmt.columnText(0).?);
}

test "resolveDef does NOT persist last_resolved for computed-live mode" {
    var db = try initTestDb();
    defer db.deinit();

    const fn_ptr: kv.ComputeFn = struct {
        fn compute(ctx: *kv.Ctx) anyerror![]const u8 {
            return try ctx.allocator.dupe(u8, "live-output");
        }
    }.compute;

    const def = kv.Def{
        .key = "plugin.live",
        .mode = .computed_live,
        .compute = fn_ptr,
        .source = "plugin:test",
    };

    const value = try kv.resolveDef(&db, std.testing.allocator, &def);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("live-output", value);

    var stmt = try db.prepare("SELECT last_resolved FROM kv WHERE key = 'plugin.live'");
    defer stmt.deinit();
    _ = try stmt.step();
    // last_resolved stays NULL for live mode — value was not cached.
    try std.testing.expect(stmt.columnText(0) == null);
}

test "resolveDef falls back to last_resolved when compute fn fails" {
    var db = try initTestDb();
    defer db.deinit();

    const fn_ptr: kv.ComputeFn = struct {
        fn compute(_: *kv.Ctx) anyerror![]const u8 {
            return error.SimulatedFailure;
        }
    }.compute;

    const def = kv.Def{
        .key = "plugin.flaky",
        .mode = .computed_baked,
        .compute = fn_ptr,
        .source = "plugin:test",
    };

    // Seed a previous resolution so fallback has something to return.
    try kv.materializeIfNeeded(&db, &def);
    try db.exec("UPDATE kv SET last_resolved = 'previous-result' WHERE key = 'plugin.flaky'");

    const value = try kv.resolveDef(&db, std.testing.allocator, &def);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("previous-result", value);
}

test "resolveDef returns empty string when compute fails and no last_resolved" {
    var db = try initTestDb();
    defer db.deinit();

    const fn_ptr: kv.ComputeFn = struct {
        fn compute(_: *kv.Ctx) anyerror![]const u8 {
            return error.SimulatedFailure;
        }
    }.compute;

    const def = kv.Def{
        .key = "plugin.broken",
        .mode = .computed_baked,
        .compute = fn_ptr,
        .source = "plugin:test",
    };

    const value = try kv.resolveDef(&db, std.testing.allocator, &def);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("", value);
}

test "resolveDef on plugin-registered literal (no compute) reads kv.value" {
    var db = try initTestDb();
    defer db.deinit();

    const def = kv.Def{
        .key = "plugin.brand",
        .mode = .literal_baked,
        .source = "plugin:test",
    };
    try kv.materializeIfNeeded(&db, &def);
    try db.exec("UPDATE kv SET value = 'Acme Co' WHERE key = 'plugin.brand'");

    const value = try kv.resolveDef(&db, std.testing.allocator, &def);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("Acme Co", value);
}

// =============================================================================
// Reverse-index (kv.refs)
// =============================================================================

fn countRefs(db: *Db, var_key: []const u8) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM kv_refs WHERE var_key = ?");
    defer stmt.deinit();
    try stmt.bindText(1, var_key);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn countAllRefs(db: *Db) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM kv_refs");
    defer stmt.deinit();
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "refs.updateRefs adds rows for keys found in content" {
    var db = try initTestDb();
    defer db.deinit();

    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "body", "Hello [kv:site_name], welcome to [kv:tagline]");

    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "site_name"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "tagline"));
}

test "refs.updateRefs replaces rows for the same (entry, field)" {
    var db = try initTestDb();
    defer db.deinit();

    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "body", "[kv:a] [kv:b]");
    try std.testing.expectEqual(@as(i64, 2), try countAllRefs(&db));

    // Re-save with different keys — old rows must be cleared.
    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "body", "[kv:b] [kv:c]");
    try std.testing.expectEqual(@as(i64, 2), try countAllRefs(&db));
    try std.testing.expectEqual(@as(i64, 0), try countRefs(&db, "a"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "b"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "c"));
}

test "refs.updateRefs with no keys leaves the index empty" {
    var db = try initTestDb();
    defer db.deinit();

    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "body", "plain text, no tokens here");
    try std.testing.expectEqual(@as(i64, 0), try countAllRefs(&db));
}

test "refs.updateRefs ignores escaped [[kv:foo]] tokens" {
    var db = try initTestDb();
    defer db.deinit();

    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "body", "this is literal: [[kv:not_a_ref]]");
    try std.testing.expectEqual(@as(i64, 0), try countAllRefs(&db));
}

test "refs.dropEntryRefs removes all rows for the entry" {
    var db = try initTestDb();
    defer db.deinit();

    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "body", "[kv:a]");
    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "subtitle", "[kv:b]");
    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-2", "body", "[kv:c]");

    try kv.refs.dropEntryRefs(&db, "entry-1");

    try std.testing.expectEqual(@as(i64, 0), try countRefs(&db, "a"));
    try std.testing.expectEqual(@as(i64, 0), try countRefs(&db, "b"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "c")); // entry-2 untouched
}

test "refs.dropFieldRefs removes only that field's rows" {
    var db = try initTestDb();
    defer db.deinit();

    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "body", "[kv:a]");
    try kv.refs.updateRefs(&db, std.testing.allocator, "entry-1", "subtitle", "[kv:b]");

    try kv.refs.dropFieldRefs(&db, "entry-1", "body");

    try std.testing.expectEqual(@as(i64, 0), try countRefs(&db, "a"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "b"));
}

// Seed a minimal content_types row to satisfy the content_type_id FK on
// content_entries. Idempotent.
fn seedContentType(db: *Db) !void {
    try db.exec(
        \\INSERT OR IGNORE INTO content_types (id, slug, name, fields, source)
        \\VALUES ('ct_post', 'post', 'Post', '[]', 'core')
    );
}

// Minimal content_anchors row to satisfy the anchor_id FK on content_entries.
fn seedAnchor(db: *Db, anchor_id: []const u8) !void {
    var stmt = try db.prepare("INSERT INTO content_anchors (id, content_type) VALUES (?, 'post')");
    defer stmt.deinit();
    try stmt.bindText(1, anchor_id);
    _ = try stmt.step();
}

// Insert a content_entries row for the hook to read back. Bypasses saveEntry
// to keep this aggregator focused on the kv layer.
fn seedEntry(db: *Db, entry_id: []const u8, anchor_id: []const u8, data_json: []const u8) !void {
    try seedContentType(db);
    try seedAnchor(db, anchor_id);
    var stmt = try db.prepare(
        \\INSERT INTO content_entries (id, anchor_id, locale, content_type_id, data)
        \\VALUES (?, ?, 'en', 'ct_post', ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    try stmt.bindText(2, anchor_id);
    try stmt.bindText(3, data_json);
    _ = try stmt.step();
}

test "refs.afterSave indexes top-level string fields from JSON" {
    var db = try initTestDb();
    defer db.deinit();

    try seedEntry(&db, "entry-1", "anchor-1",
        \\{"title":"Welcome to [kv:site_name]","body":"Tagline: [kv:tagline]","slug":"hello"}
    );

    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });

    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "site_name"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "tagline"));
}

test "refs.afterSave recurses into nested objects with dot-path" {
    var db = try initTestDb();
    defer db.deinit();

    try seedEntry(&db, "entry-1", "anchor-1",
        \\{"seo":{"meta_description":"by [kv:author]"},"body":"text"}
    );

    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });

    var stmt = try db.prepare("SELECT field_path FROM kv_refs WHERE var_key = 'author'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("seo.meta_description", stmt.columnText(0).?);
}

test "refs.afterSave recurses into arrays with index-path" {
    var db = try initTestDb();
    defer db.deinit();

    try seedEntry(&db, "entry-1", "anchor-1",
        \\{"sections":[{"intro":"hi [kv:greeting]"},{"intro":"bye"}]}
    );

    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });

    var stmt = try db.prepare("SELECT field_path FROM kv_refs WHERE var_key = 'greeting'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("sections.0.intro", stmt.columnText(0).?);
}

test "refs.afterSave rebuilds — second invocation reflects the new data" {
    var db = try initTestDb();
    defer db.deinit();

    try seedEntry(&db, "entry-1", "anchor-1", "{\"body\":\"[kv:old]\"}");
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "old"));

    // Simulate an edit + re-save.
    try db.exec("UPDATE content_entries SET data = '{\"body\":\"[kv:new]\"}' WHERE id = 'entry-1'");
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });

    try std.testing.expectEqual(@as(i64, 0), try countRefs(&db, "old"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "new"));
}

test "refs.afterSave on missing entry is a no-op (no panic, no rows)" {
    var db = try initTestDb();
    defer db.deinit();

    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "does-not-exist",
        .content_type = "post",
    });
    try std.testing.expectEqual(@as(i64, 0), try countAllRefs(&db));
}

// =============================================================================
// Publish session + cascade (kv.session)
// =============================================================================

// Singleton capture for publish_hooks. Zig functions can't carry closure
// state, so the test hook reads/writes module-level vars. Tests must call
// beginPublishCapture before and endPublishCapture after.
var test_publish_arena: ?std.heap.ArenaAllocator = null;
var test_publishes: std.ArrayListUnmanaged([]const u8) = .{};

fn capturePublishHook(_: *Db, _: std.mem.Allocator, entry_id: []const u8) void {
    var arena = &(test_publish_arena orelse return);
    const a = arena.allocator();
    const owned = a.dupe(u8, entry_id) catch return;
    test_publishes.append(a, owned) catch return;
}

fn beginPublishCapture() void {
    test_publish_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    test_publishes = .{};
    publish_hooks.register(capturePublishHook);
}

fn endPublishCapture() void {
    if (test_publish_arena) |*ar| ar.deinit();
    test_publish_arena = null;
    test_publishes = .{};
}

fn seedKvLiteralBaked(db: *Db, key: []const u8, value: []const u8) !void {
    var stmt = try db.prepare("INSERT INTO kv (key, value, source, mode, updated_at) VALUES (?, ?, 'editor', 'literal-baked', unixepoch())");
    defer stmt.deinit();
    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    _ = try stmt.step();
}

fn seedKvComputedBaked(db: *Db, key: []const u8, last_resolved: ?[]const u8) !void {
    var stmt = try db.prepare("INSERT INTO kv (key, value, source, mode, last_resolved, updated_at) VALUES (?, '', 'plugin:test', 'computed-baked', ?, unixepoch())");
    defer stmt.deinit();
    try stmt.bindText(1, key);
    if (last_resolved) |v| {
        try stmt.bindText(2, v);
    } else {
        try stmt.bindNull(2);
    }
    _ = try stmt.step();
}

fn seedRef(db: *Db, var_key: []const u8, entry_id: []const u8, field_path: []const u8) !void {
    var stmt = try db.prepare("INSERT INTO kv_refs (var_key, entry_id, field_path) VALUES (?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, var_key);
    try stmt.bindText(2, entry_id);
    try stmt.bindText(3, field_path);
    _ = try stmt.step();
}

fn containsPublish(needle: []const u8) bool {
    for (test_publishes.items) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

test "session.Session: ensureResolved caches across calls (resolver-once)" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "site_name", "Acme");

    var s = kv.session.Session.init(std.testing.allocator, &db);
    defer s.deinit();

    const a = try s.ensureResolved("site_name");
    const b = try s.ensureResolved("site_name");
    try std.testing.expectEqualStrings("Acme", a);
    try std.testing.expectEqualStrings("Acme", b);
    // Both calls return the SAME slice (cache hit).
    try std.testing.expectEqual(a.ptr, b.ptr);
}

test "session.Session: enqueue dedupes" {
    var db = try initTestDb();
    defer db.deinit();

    var s = kv.session.Session.init(std.testing.allocator, &db);
    defer s.deinit();

    try std.testing.expect(try s.enqueue("e1"));
    try std.testing.expect(!try s.enqueue("e1")); // second time: false
    try std.testing.expect(try s.enqueue("e2"));
    try std.testing.expectEqual(@as(usize, 2), s.queue.items.len);
}

test "cascadeOnPublish with no build-time refs triggers no extra publishes" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try kv.session.cascadeOnPublish(&db, std.testing.allocator, "entry-1");

    // Seed entry is NOT published by the cascade (caller handles it).
    try std.testing.expectEqual(@as(usize, 0), test_publishes.items.len);
}

test "cascadeOnPublish via computed-baked var enqueues other referencers" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvComputedBaked(&db, "now", "12:14");
    try seedRef(&db, "now", "entry-X", "body");
    try seedRef(&db, "now", "entry-Y", "body");
    try seedRef(&db, "now", "entry-Z", "body");

    try kv.session.cascadeOnPublish(&db, std.testing.allocator, "entry-X");

    // Cascade should call afterPublish for Y and Z (not X — that's the caller's job).
    try std.testing.expectEqual(@as(usize, 2), test_publishes.items.len);
    try std.testing.expect(containsPublish("entry-Y"));
    try std.testing.expect(containsPublish("entry-Z"));
    try std.testing.expect(!containsPublish("entry-X"));
}

test "cascadeOnPublish does NOT propagate via literal-baked vars" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvLiteralBaked(&db, "site_name", "Acme");
    try seedRef(&db, "site_name", "entry-X", "body");
    try seedRef(&db, "site_name", "entry-Y", "body");

    try kv.session.cascadeOnPublish(&db, std.testing.allocator, "entry-X");

    // Literal vars don't change value on a publish action — no cascade.
    try std.testing.expectEqual(@as(usize, 0), test_publishes.items.len);
}

test "cascadeOnPublish dedupes — referencer appears once even if reachable via multiple vars" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvComputedBaked(&db, "now", "12:14");
    try seedKvComputedBaked(&db, "weather", "sunny");

    // entry-X uses both vars; entry-Y also uses both.
    try seedRef(&db, "now", "entry-X", "body");
    try seedRef(&db, "weather", "entry-X", "footer");
    try seedRef(&db, "now", "entry-Y", "body");
    try seedRef(&db, "weather", "entry-Y", "footer");

    try kv.session.cascadeOnPublish(&db, std.testing.allocator, "entry-X");

    // entry-Y reachable via both vars but should appear exactly once.
    try std.testing.expectEqual(@as(usize, 1), test_publishes.items.len);
    try std.testing.expectEqualStrings("entry-Y", test_publishes.items[0]);
}

test "cascadeOnVarEdit for literal-baked: all referencers are re-published" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvLiteralBaked(&db, "tagline", "Hello");
    try seedRef(&db, "tagline", "entry-X", "body");
    try seedRef(&db, "tagline", "entry-Y", "body");
    try seedRef(&db, "tagline", "entry-Z", "subtitle");

    try kv.session.cascadeOnVarEdit(&db, std.testing.allocator, "tagline");

    try std.testing.expectEqual(@as(usize, 3), test_publishes.items.len);
    try std.testing.expect(containsPublish("entry-X"));
    try std.testing.expect(containsPublish("entry-Y"));
    try std.testing.expect(containsPublish("entry-Z"));
}

test "cascadeOnVarEdit with no referencers is a no-op" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvLiteralBaked(&db, "orphan_var", "");

    try kv.session.cascadeOnVarEdit(&db, std.testing.allocator, "orphan_var");
    try std.testing.expectEqual(@as(usize, 0), test_publishes.items.len);
}

test "cascadeOnPublish transitive: X→T→Y; Y→S→Z. Publishing X re-publishes Y and Z." {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvComputedBaked(&db, "T", "t-val");
    try seedKvComputedBaked(&db, "S", "s-val");

    try seedRef(&db, "T", "entry-X", "body");
    try seedRef(&db, "T", "entry-Y", "body");
    try seedRef(&db, "S", "entry-Y", "footer");
    try seedRef(&db, "S", "entry-Z", "body");

    try kv.session.cascadeOnPublish(&db, std.testing.allocator, "entry-X");

    // Y enqueued via T (used by X). Z enqueued via S (used by Y).
    try std.testing.expectEqual(@as(usize, 2), test_publishes.items.len);
    try std.testing.expect(containsPublish("entry-Y"));
    try std.testing.expect(containsPublish("entry-Z"));
}

// =============================================================================
// resolveCached (used by render path — task-07 will wire this in)
// =============================================================================

test "resolveCached for literal-baked reads kv.value" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "tagline", "Hello");

    const value = try kv.resolveCached(&db, std.testing.allocator, "tagline");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("Hello", value);
}

test "resolveCached for computed-baked reads last_resolved (does NOT re-run resolver)" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvComputedBaked(&db, "now", "cached-12:14");

    const value = try kv.resolveCached(&db, std.testing.allocator, "now");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("cached-12:14", value);
}

test "resolveCached for computed-baked with NULL last_resolved returns empty string" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvComputedBaked(&db, "uncached", null);

    const value = try kv.resolveCached(&db, std.testing.allocator, "uncached");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("", value);
}

test "resolveCached returns NotFound for unknown key" {
    var db = try initTestDb();
    defer db.deinit();

    const result = kv.resolveCached(&db, std.testing.allocator, "nope");
    try std.testing.expectError(error.NotFound, result);
}

// =============================================================================
// Live-mode render substitution (kv.live)
// =============================================================================

fn seedKvLiteralLive(db: *Db, key: []const u8, value: []const u8) !void {
    var stmt = try db.prepare("INSERT INTO kv (key, value, source, mode, updated_at) VALUES (?, ?, 'editor', 'literal-live', unixepoch())");
    defer stmt.deinit();
    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    _ = try stmt.step();
}

test "live.substitute fast-path: no [kv: substring returns null" {
    var db = try initTestDb();
    defer db.deinit();

    const result = try kv.live.substitute(std.testing.allocator, &db, "<html><body>plain content</body></html>");
    try std.testing.expect(result == null);
}

test "live.substitute replaces literal-live tokens with kv.value" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralLive(&db, "promo_banner", "20% OFF");

    const body = "<p>Today only: [kv:promo_banner]!</p>";
    const result = try kv.live.substitute(std.testing.allocator, &db, body);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("<p>Today only: 20% OFF!</p>", result.?);
}

test "live.substitute leaves baked-mode tokens untouched (logs warning)" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "site_name", "Acme");

    const body = "<title>[kv:site_name]</title>";
    const result = try kv.live.substitute(std.testing.allocator, &db, body);
    // Baked tokens shouldn't be substituted at render-time — they should
    // already be substituted in the baked output. Token is preserved as-is.
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("<title>[kv:site_name]</title>", result.?);
}

test "live.substitute preserves unknown-key tokens" {
    var db = try initTestDb();
    defer db.deinit();

    const body = "<p>[kv:unknown_var]</p>";
    const result = try kv.live.substitute(std.testing.allocator, &db, body);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("<p>[kv:unknown_var]</p>", result.?);
}

test "live.substitute handles escaped [[kv:foo]] as literal" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralLive(&db, "tag", "WOULD_BE_REPLACED");

    const body = "code sample: [[kv:tag]]";
    const result = try kv.live.substitute(std.testing.allocator, &db, body);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("code sample: [kv:tag]", result.?);
}

test "live.substitute mixes live (substituted) and baked (preserved) in same body" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralLive(&db, "banner", "FLASH SALE");
    try seedKvLiteralBaked(&db, "tagline", "Built for editors");

    const body = "<header>[kv:banner]</header><p>[kv:tagline]</p>";
    const result = try kv.live.substitute(std.testing.allocator, &db, body);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("<header>FLASH SALE</header><p>[kv:tagline]</p>", result.?);
}

test "live.substitute handles multiple live tokens of the same key" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralLive(&db, "phone", "555-1234");

    const body = "Call us: [kv:phone] or text [kv:phone].";
    const result = try kv.live.substitute(std.testing.allocator, &db, body);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("Call us: 555-1234 or text 555-1234.", result.?);
}

test "live.substitute handles multiple distinct live tokens" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralLive(&db, "a", "Hello");
    try seedKvLiteralLive(&db, "b", "World");

    const body = "[kv:a], [kv:b]!";
    const result = try kv.live.substitute(std.testing.allocator, &db, body);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("Hello, World!", result.?);
}

// =============================================================================
// End-to-end integration scenarios
// =============================================================================

test "integration: four modes coexist — refs index all, live substitutes only live" {
    var db = try initTestDb();
    defer db.deinit();

    // Set up one var in each mode.
    try seedKvLiteralBaked(&db, "tagline", "Built for editors");
    try seedKvComputedBaked(&db, "footer_year", "2026");
    try seedKvLiteralLive(&db, "banner", "FLASH SALE");
    try db.exec(
        \\INSERT INTO kv (key, value, source, mode, updated_at)
        \\VALUES ('visitor_count', '', 'plugin:test', 'computed-live', unixepoch())
    );

    // Save an entry whose data JSON references all four.
    try seedEntry(&db, "entry-1", "anchor-1",
        \\{"title":"Site: [kv:tagline]","footer":"©[kv:footer_year]","banner":"[kv:banner]","stats":"[kv:visitor_count] online"}
    );

    // afterSave indexes ALL token references regardless of mode.
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });

    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "tagline"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "footer_year"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "banner"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "visitor_count"));

    // Simulated bake output where ONLY baked-mode tokens have been pre-substituted.
    // (In a real flow this happens at publish time; we simulate it here.)
    const baked_html = "Site: Built for editors © 2026 [kv:banner] [kv:visitor_count] online";

    // The live-render hook substitutes the live tokens that remain.
    const rendered = try kv.live.substitute(std.testing.allocator, &db, baked_html);
    try std.testing.expect(rendered != null);
    defer std.testing.allocator.free(rendered.?);
    // banner (literal-live) → "FLASH SALE"
    // visitor_count (computed-live, no Def, falls to readValue → "") → ""
    try std.testing.expectEqualStrings("Site: Built for editors © 2026 FLASH SALE  online", rendered.?);
}

test "integration: cascadeOnVarEdit for literal-live is a no-op (no rebuilds)" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvLiteralLive(&db, "promo", "20% OFF");
    try seedRef(&db, "promo", "entry-1", "body");
    try seedRef(&db, "promo", "entry-2", "body");
    try seedRef(&db, "promo", "entry-3", "body");

    // Editing a literal-live var should NOT trigger any cascade — the new
    // value is visible on next render via live substitution.
    try kv.session.cascadeOnVarEdit(&db, std.testing.allocator, "promo");

    try std.testing.expectEqual(@as(usize, 0), test_publishes.items.len);
}

test "integration: cascadeOnVarEdit for computed-baked is a no-op (function-owned, not editor-edited)" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvComputedBaked(&db, "now", "12:14");
    try seedRef(&db, "now", "entry-1", "body");

    // Defensive: even if called for a computed-baked var (which shouldn't
    // happen since editors don't edit computed values), cascade is a no-op.
    try kv.session.cascadeOnVarEdit(&db, std.testing.allocator, "now");

    try std.testing.expectEqual(@as(usize, 0), test_publishes.items.len);
}

test "integration: cascade does not modify kv_refs" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvLiteralBaked(&db, "tagline", "old");
    try seedRef(&db, "tagline", "entry-1", "body");
    try seedRef(&db, "tagline", "entry-2", "subtitle");

    const before = try countAllRefs(&db);
    try kv.session.cascadeOnVarEdit(&db, std.testing.allocator, "tagline");
    const after = try countAllRefs(&db);

    try std.testing.expectEqual(before, after);
}

test "integration: lifecycle save → re-save → delete maintains kv_refs correctly" {
    var db = try initTestDb();
    defer db.deinit();

    // Save with `[kv:a]` in body.
    try seedEntry(&db, "entry-1", "anchor-1", "{\"body\":\"intro [kv:a]\"}");
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });
    try std.testing.expectEqual(@as(i64, 1), try countAllRefs(&db));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "a"));

    // Edit (re-save) with mixed token changes: `a` removed, `b` and `c` added.
    try db.exec("UPDATE content_entries SET data = '{\"body\":\"[kv:b] and [kv:c]\"}' WHERE id = 'entry-1'");
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });
    try std.testing.expectEqual(@as(i64, 2), try countAllRefs(&db));
    try std.testing.expectEqual(@as(i64, 0), try countRefs(&db, "a"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "b"));
    try std.testing.expectEqual(@as(i64, 1), try countRefs(&db, "c"));

    // Delete cleans up all refs for the entry.
    try kv.refs.dropEntryRefs(&db, "entry-1");
    try std.testing.expectEqual(@as(i64, 0), try countAllRefs(&db));
}

test "integration: literal-baked edit AND publish flow together" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    // Two entries share a literal-baked var.
    try seedKvLiteralBaked(&db, "tagline", "Initial");
    try seedEntry(&db, "entry-A", "anchor-A", "{\"body\":\"Welcome — [kv:tagline]\"}");
    try seedEntry(&db, "entry-B", "anchor-B", "{\"footer\":\"By [kv:tagline]\"}");
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-A",
        .content_type = "post",
    });
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-B",
        .content_type = "post",
    });

    // Editor updates the tagline. Cascade should re-publish both entries.
    try db.exec("UPDATE kv SET value = 'Updated' WHERE key = 'tagline'");
    try kv.session.cascadeOnVarEdit(&db, std.testing.allocator, "tagline");

    try std.testing.expectEqual(@as(usize, 2), test_publishes.items.len);
    try std.testing.expect(containsPublish("entry-A"));
    try std.testing.expect(containsPublish("entry-B"));
}

test "integration: literal-live edit triggers no rebuild, next render reflects new value" {
    var db = try initTestDb();
    defer db.deinit();
    beginPublishCapture();
    defer endPublishCapture();

    try seedKvLiteralLive(&db, "banner", "Day 1");
    try seedRef(&db, "banner", "entry-1", "header");

    // Editor updates the banner.
    try db.exec("UPDATE kv SET value = 'Day 2' WHERE key = 'banner'");

    // Cascade does nothing for literal-live.
    try kv.session.cascadeOnVarEdit(&db, std.testing.allocator, "banner");
    try std.testing.expectEqual(@as(usize, 0), test_publishes.items.len);

    // But the next render picks up the new value via live substitution.
    const rendered = try kv.live.substitute(std.testing.allocator, &db, "<h1>[kv:banner]</h1>");
    try std.testing.expect(rendered != null);
    defer std.testing.allocator.free(rendered.?);
    try std.testing.expectEqualStrings("<h1>Day 2</h1>", rendered.?);
}

test "integration: escaped token round-trips through save → live (never substituted)" {
    var db = try initTestDb();
    defer db.deinit();

    try seedKvLiteralLive(&db, "tag", "WOULD_BE_REPLACED");
    // Field content has an ESCAPED token — should not be indexed and should
    // render as literal text.
    try seedEntry(&db, "entry-1", "anchor-1", "{\"body\":\"docs: [[kv:tag]]\"}");
    kv.refs.afterSave(.{
        .db = &db,
        .allocator = std.testing.allocator,
        .entry_id = "entry-1",
        .content_type = "post",
    });

    // Escaped token: no kv_refs entry created.
    try std.testing.expectEqual(@as(i64, 0), try countRefs(&db, "tag"));

    // Even at live-render time, the escape is preserved (parser handles `[[`).
    const rendered = try kv.live.substitute(std.testing.allocator, &db, "docs: [[kv:tag]]");
    try std.testing.expect(rendered != null);
    defer std.testing.allocator.free(rendered.?);
    try std.testing.expectEqualStrings("docs: [kv:tag]", rendered.?);
}

// =============================================================================
// Admin-UI data-layer prerequisites (variables-store-ui task-01)
// =============================================================================

test "recursive resolve: single-level chain" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "a", "Hi [kv:b]");
    try seedKvLiteralBaked(&db, "b", "world");

    const value = try kv.resolve(&db, std.testing.allocator, "a");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("Hi world", value);
}

test "recursive resolve: two-level chain" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "a", "[kv:b]");
    try seedKvLiteralBaked(&db, "b", "[kv:c]");
    try seedKvLiteralBaked(&db, "c", "deep");

    const value = try kv.resolve(&db, std.testing.allocator, "a");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("deep", value);
}

test "recursive resolve: no nesting still works (regression)" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "a", "just text");

    const value = try kv.resolve(&db, std.testing.allocator, "a");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("just text", value);
}

test "recursive resolve: defensive cycle returns empty + does not stack-overflow" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "a", "[kv:b]");
    try seedKvLiteralBaked(&db, "b", "[kv:a]");

    // Should not infinite-loop; cycle detected, returns "" for the cycling ref.
    const value = try kv.resolve(&db, std.testing.allocator, "a");
    defer std.testing.allocator.free(value);
    // The outer "a" returns the substituted form of "b" which substitutes "a"
    // (cycle) to "". So b resolves to "", then a substitutes [kv:b] with "".
    try std.testing.expectEqualStrings("", value);
}

test "recursive resolveCached: literal value with nested refs substitutes" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "a", "outer [kv:b]");
    try seedKvLiteralBaked(&db, "b", "inner");

    const value = try kv.resolveCached(&db, std.testing.allocator, "a");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("outer inner", value);
}

test "validateNoCycle: direct self-reference detected" {
    var db = try initTestDb();
    defer db.deinit();
    // No existing rows; just check the proposed self-reference.
    const path = try kv.validateNoCycle(std.testing.allocator, &db, "a", "[kv:a]");
    try std.testing.expect(path != null);
    defer kv.freeCyclePath(std.testing.allocator, path.?);
    try std.testing.expectEqual(@as(usize, 2), path.?.len);
    try std.testing.expectEqualStrings("a", path.?[0]);
    try std.testing.expectEqualStrings("a", path.?[1]);
}

test "validateNoCycle: indirect 2-hop cycle detected" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "b", "[kv:a]"); // existing: b → a

    // Proposed: a → b. Combined with existing b → a, this creates a cycle.
    const path = try kv.validateNoCycle(std.testing.allocator, &db, "a", "[kv:b]");
    try std.testing.expect(path != null);
    defer kv.freeCyclePath(std.testing.allocator, path.?);
    try std.testing.expectEqual(@as(usize, 3), path.?.len);
    try std.testing.expectEqualStrings("a", path.?[0]);
    try std.testing.expectEqualStrings("b", path.?[1]);
    try std.testing.expectEqualStrings("a", path.?[2]);
}

test "validateNoCycle: deep chain without cycle returns null" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "b", "[kv:c]");
    try seedKvLiteralBaked(&db, "c", "[kv:d]");
    try seedKvLiteralBaked(&db, "d", "leaf");

    const path = try kv.validateNoCycle(std.testing.allocator, &db, "a", "[kv:b]");
    try std.testing.expect(path == null);
}

test "validateNoCycle: no refs at all returns null" {
    var db = try initTestDb();
    defer db.deinit();

    const path = try kv.validateNoCycle(std.testing.allocator, &db, "a", "plain text only");
    try std.testing.expect(path == null);
}

test "validateNoCycle: refs to non-existent vars are not cycles" {
    var db = try initTestDb();
    defer db.deinit();

    const path = try kv.validateNoCycle(std.testing.allocator, &db, "a", "[kv:nonexistent]");
    try std.testing.expect(path == null);
}

test "Options.default: materialize seeds the row with the provided default" {
    var db = try initTestDb();
    defer db.deinit();

    const def = kv.Def{
        .key = "seo.title_sep",
        .label = "Title separator",
        .mode = .literal_baked,
        .default = " — ",
        .source = "plugin:seo",
    };
    try kv.materializeIfNeeded(&db, &def);

    var stmt = try db.prepare("SELECT value FROM kv WHERE key = 'seo.title_sep'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqualStrings(" — ", stmt.columnText(0).?);
}

test "Options.default: materialize without default seeds empty string (regression)" {
    var db = try initTestDb();
    defer db.deinit();

    const def = kv.Def{
        .key = "plugin.no_default",
        .mode = .literal_baked,
        .source = "plugin:test",
    };
    try kv.materializeIfNeeded(&db, &def);

    var stmt = try db.prepare("SELECT value FROM kv WHERE key = 'plugin.no_default'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqualStrings("", stmt.columnText(0).?);
}

test "Options.default: editor-overridden value survives subsequent materialize call" {
    var db = try initTestDb();
    defer db.deinit();

    const def = kv.Def{
        .key = "plugin.brand",
        .mode = .literal_baked,
        .default = "DefaultBrand",
        .source = "plugin:test",
    };
    try kv.materializeIfNeeded(&db, &def);
    // Editor overrides.
    try db.exec("UPDATE kv SET value = 'EditorChoice' WHERE key = 'plugin.brand'");
    // Plugin re-loads (e.g., reboot) — INSERT OR IGNORE preserves the editor's value.
    try kv.materializeIfNeeded(&db, &def);

    var stmt = try db.prepare("SELECT value FROM kv WHERE key = 'plugin.brand'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqualStrings("EditorChoice", stmt.columnText(0).?);
}

test "refresh: returns NotFound for missing key" {
    var db = try initTestDb();
    defer db.deinit();

    const result = kv.refresh(&db, std.testing.allocator, "does-not-exist");
    try std.testing.expectError(error.NotFound, result);
}

test "refresh: returns WrongMode for literal-baked var" {
    var db = try initTestDb();
    defer db.deinit();
    try seedKvLiteralBaked(&db, "tagline", "Hi");

    const result = kv.refresh(&db, std.testing.allocator, "tagline");
    try std.testing.expectError(error.WrongMode, result);
}

test "refresh: returns NoComputeFn for computed-baked without registered Def" {
    var db = try initTestDb();
    defer db.deinit();
    // Manually seed a computed-baked row without registering a Def (simulating
    // a stale row from a removed plugin).
    try seedKvComputedBaked(&db, "stale.var", "");

    const result = kv.refresh(&db, std.testing.allocator, "stale.var");
    try std.testing.expectError(error.NoComputeFn, result);
}

// NOTE: replaceKvToken / bakeVariableReferences / removeVariableReferences
// were intentionally removed from src/core/content.zig — their tests are
// disabled here until the new home is decided. Task-01's task-file flags
// this as work to revisit; task-06 (integration tests) is the natural slot
// once the helpers' final location is known.
