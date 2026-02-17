const std = @import("std");
const core_init = @import("core_init");
const cms = @import("cms");
const Db = @import("db").Db;
const schemas = @import("schemas");
const auth_mod = @import("auth");

pub const TestContext = struct {
    allocator: std.mem.Allocator,
    db: Db,
};

pub fn initTestDb() !TestContext {
    var db = try core_init.initDatabase(std.testing.allocator, ":memory:");
    errdefer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);
    try seedFixtures(&db);

    return .{
        .allocator = std.testing.allocator,
        .db = db,
    };
}

pub fn deinit(ctx: *TestContext) void {
    ctx.db.deinit();
}

pub fn expectEntryExists(db: *Db, entry_id: []const u8) !void {
    var stmt = try db.prepare("SELECT 1 FROM content_entries WHERE id = ?1 LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    try std.testing.expect(try stmt.step());
}

pub fn expectEntryStatus(db: *Db, entry_id: []const u8, expected_status: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT CASE
        \\  WHEN archived = 1 THEN 'archived'
        \\  WHEN published_version_id IS NULL THEN 'draft'
        \\  WHEN published_version_id = current_version_id THEN 'published'
        \\  ELSE 'changed'
        \\END
        \\FROM content_entries
        \\WHERE id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings(expected_status, stmt.columnText(0) orelse "");
}

pub fn expectEntryCount(db: *Db, content_type: []const u8, expected_count: usize) !void {
    var stmt = try db.prepare(
        \\SELECT COUNT(*)
        \\FROM content_anchors
        \\WHERE content_type = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, content_type);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, @intCast(expected_count)), stmt.columnInt(0));
}

pub fn expectVersionCount(db: *Db, entry_id: []const u8, expected_count: usize) !void {
    var stmt = try db.prepare("SELECT COUNT(*) FROM content_versions WHERE entry_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, @intCast(expected_count)), stmt.columnInt(0));
}

fn seedFixtures(db: *Db) !void {
    const fixture_allocator = std.heap.page_allocator;
    var auth = auth_mod.Auth.init(fixture_allocator, db);

    // Deterministic baseline user for CLI/REST auth tests.
    const created_user_id = auth.createUser("admin@test.local", "Admin", "secret123") catch |err| switch (err) {
        error.EmailExists => null,
        else => return err,
    };
    if (created_user_id) |user_id| fixture_allocator.free(user_id);

    if (!anchorExists(db, "e_test_post")) {
        _ = try cms.saveEntry(schemas.Post, fixture_allocator, db, "e_test_post", schemas.Post.Data{
            .title = "Fixture Post",
            .slug = "fixture-post",
            .body = "Fixture body",
        }, .{ .status = "draft" });
    }

    if (!anchorExists(db, "e_test_page")) {
        _ = try cms.saveEntry(schemas.Page, fixture_allocator, db, "e_test_page", schemas.Page.Data{
            .title = "Fixture Page",
            .slug = "fixture-page",
            .body = "Fixture body",
        }, .{ .status = "draft" });
    }
}

fn anchorExists(db: *Db, anchor_id: []const u8) bool {
    var stmt = db.prepare("SELECT 1 FROM content_anchors WHERE id = ?1 LIMIT 1") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, anchor_id) catch return false;
    return stmt.step() catch false;
}
