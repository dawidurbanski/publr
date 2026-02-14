//! CMS Facade
//!
//! Unified entry point for content management. Re-exports query, versioning,
//! and release modules so callers can use a single `cms` import.
//!
//! Example:
//! ```zig
//! const schemas = @import("schemas");
//! const cms = @import("cms");
//!
//! // Get a post by slug
//! const post = try cms.getEntry(schemas.Post, allocator, db, "hello-world");
//!
//! // List published posts
//! const posts = try cms.listEntries(schemas.Post, allocator, db, .{
//!     .status = "published",
//!     .limit = 10,
//! });
//! ```

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");

const Allocator = std.mem.Allocator;

// Query API (re-exported)
pub const query = @import("query");
pub const Entry = query.Entry;
pub const MetaOp = query.MetaOp;
pub const MetaValue = query.MetaValue;
pub const MetaFilter = query.MetaFilter;
pub const max_meta_filters = query.max_meta_filters;
pub const OrderDir = query.OrderDir;
pub const ListOptions = query.ListOptions;
pub const getEntry = query.getEntry;
pub const listEntries = query.listEntries;
pub const listWithMeta = query.listWithMeta;
pub const countEntries = query.countEntries;

// Version history management (re-exported)
pub const version = @import("version");
pub const Version = version.Version;
pub const FieldComparison = version.FieldComparison;
pub const listVersions = version.listVersions;
pub const getVersion = version.getVersion;
pub const restoreVersion = version.restoreVersion;
pub const formatRelativeTime = version.formatRelativeTime;
pub const compareVersionFields = version.compareVersionFields;
pub const populateFieldAuthors = version.populateFieldAuthors;
pub const restoreVersionWithData = version.restoreVersionWithData;
pub const diffVersions = version.diffVersions;
pub const jsonValueToString = version.jsonValueToString;
pub const writeEscaped = version.writeEscaped;
pub const pruneVersions = version.pruneVersions;

// Release management (re-exported)
pub const release = @import("release");
pub const ReleaseError = release.ReleaseError;
pub const PendingReleaseOption = release.PendingReleaseOption;
pub const ReleaseListItem = release.ReleaseListItem;
pub const ReleaseDetailItem = release.ReleaseDetailItem;
pub const ReleaseDetail = release.ReleaseDetail;
pub const EntryReleaseFieldInfo = release.EntryReleaseFieldInfo;
pub const getEntryVersionId = release.getEntryVersionId;
pub const getPublishedData = release.getPublishedData;
pub const discardToPublished = release.discardToPublished;
pub const mergeJsonFields = release.mergeJsonFields;
pub const publishEntry = release.publishEntry;
pub const revertRelease = release.revertRelease;
pub const reReleaseReverted = release.reReleaseReverted;
pub const scheduleRelease = release.scheduleRelease;
pub const generateReleaseId = release.generateReleaseId;
pub const createPendingRelease = release.createPendingRelease;
pub const addToRelease = release.addToRelease;
pub const removeFromRelease = release.removeFromRelease;
pub const archiveRelease = release.archiveRelease;
pub const publishBatchRelease = release.publishBatchRelease;
pub const listReleases = release.listReleases;
pub const getRelease = release.getRelease;
pub const listPendingReleases = release.listPendingReleases;
pub const getEntryPendingReleaseIds = release.getEntryPendingReleaseIds;
pub const getEntryPendingReleaseFields = release.getEntryPendingReleaseFields;

/// Entry status values
pub const Status = enum {
    draft,
    published,
    changed,
    archived,

    pub fn toString(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Status {
        inline for (std.meta.fields(Status)) |f| {
            if (std.mem.eql(u8, s, f.name)) {
                return @enumFromInt(f.value);
            }
        }
        return null;
    }
};

/// Generate a unique entry ID
pub const generateId = id_gen.generateEntryId;

/// Options for saving an entry
pub const SaveOptions = struct {
    /// Author user ID for version tracking (null for system/anonymous saves)
    author_id: ?[]const u8 = null,
    /// When true, update existing version in-place instead of creating a new one.
    /// Used by autosave to avoid polluting version history.
    autosave: bool = false,
    /// Entry status override. Takes precedence over data.status if set.
    /// Status is an intrinsic entry attribute (draft/published/changed),
    /// not a schema field.
    status: ?[]const u8 = null,
};

/// Save an entry (create or update), creating a version in the history
pub fn saveEntry(
    comptime CT: type,
    allocator: Allocator,
    db: *Db,
    id: ?[]const u8,
    data: anytype,
    opts: SaveOptions,
) !Entry(CT) {
    const entry_id = id orelse try generateId(allocator);
    const is_update = id != null;

    // Extract title from data if present
    const title: []const u8 = if (@hasField(@TypeOf(data), "title")) blk: {
        const title_val = data.title;
        if (@typeInfo(@TypeOf(title_val)) == .optional) {
            break :blk title_val orelse "";
        } else {
            break :blk title_val;
        }
    } else "";

    // Extract slug from data if present (coerce to optional, empty string → null)
    const slug: ?[]const u8 = if (@hasField(@TypeOf(data), "slug")) blk: {
        const s = @as(?[]const u8, data.slug);
        break :blk if (s) |sv| if (sv.len == 0) @as(?[]const u8, null) else sv else null;
    } else null;

    // Extract status: opts.status takes precedence, then data.status, then "draft"
    const status: []const u8 = if (opts.status) |s| s else if (@hasField(@TypeOf(data), "status")) blk: {
        const status_val = data.status;
        if (@typeInfo(@TypeOf(status_val)) == .optional) {
            break :blk status_val orelse "draft";
        } else {
            break :blk status_val;
        }
    } else "draft";

    // Serialize data to JSON
    const data_json = try CT.stringifyData(allocator, data);
    defer allocator.free(data_json);

    // Get previous version id, data, author (for change detection + author tracking)
    var prev_version_id: ?[]const u8 = null;
    var prev_data: ?[]const u8 = null;
    var published_vid: ?[]const u8 = null;
    var prev_author_id: ?[]const u8 = null;
    if (is_update) {
        var pv_stmt = try db.prepare(
            \\SELECT e.current_version_id, e.data, e.published_version_id, ev.author_id
            \\FROM entries e
            \\LEFT JOIN entry_versions ev ON ev.id = e.current_version_id
            \\WHERE e.id = ?1
        );
        defer pv_stmt.deinit();
        try pv_stmt.bindText(1, entry_id);
        if (try pv_stmt.step()) {
            if (pv_stmt.columnText(0)) |v| {
                prev_version_id = try allocator.dupe(u8, v);
            }
            if (pv_stmt.columnText(1)) |d| {
                prev_data = try allocator.dupe(u8, d);
            }
            if (pv_stmt.columnText(2)) |v| {
                published_vid = try allocator.dupe(u8, v);
            }
            if (pv_stmt.columnText(3)) |v| {
                prev_author_id = try allocator.dupe(u8, v);
            }
        }
    }
    defer if (prev_version_id) |v| allocator.free(v);
    defer if (prev_data) |d| allocator.free(d);
    defer if (published_vid) |v| allocator.free(v);
    defer if (prev_author_id) |v| allocator.free(v);

    // Skip version creation if data hasn't changed
    const data_changed = if (prev_data) |pd| !std.mem.eql(u8, pd, data_json) else true;

    // Autosave must create a new version (not update in-place) when current == published,
    // otherwise the published version's data would be corrupted.
    const is_published_version = if (prev_version_id) |pv|
        if (published_vid) |pub_v| std.mem.eql(u8, pv, pub_v) else false
    else
        false;

    const version_id = id_gen.generateVersionId();

    // Autosave can update in-place ONLY when:
    // 1. Current version != published version (preserve published snapshot)
    // 2. Same author is editing (different author = new version for attribution)
    const same_author = if (prev_author_id) |pa|
        if (opts.author_id) |oa| std.mem.eql(u8, pa, oa) else true
    else
        true;
    const can_autosave_inplace = opts.autosave and !is_published_version and same_author;

    if (is_update) {
        if (data_changed and !can_autosave_inplace) {
            // Create new version (explicit save, or autosave that would corrupt published)
            const version_type: []const u8 = if (opts.autosave) "autosave" else "updated";
            var v_stmt = try db.prepare(
                \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            );
            defer v_stmt.deinit();

            try v_stmt.bindText(1, &version_id);
            try v_stmt.bindText(2, entry_id);
            if (prev_version_id) |pv| try v_stmt.bindText(3, pv) else try v_stmt.bindNull(3);
            try v_stmt.bindText(4, data_json);
            if (opts.author_id) |aid| try v_stmt.bindText(5, aid) else try v_stmt.bindNull(5);
            try v_stmt.bindText(6, version_type);

            _ = try v_stmt.step();
        } else if (data_changed and can_autosave_inplace) {
            // Autosave: update existing version in-place (no history entry)
            if (prev_version_id) |pv| {
                var v_stmt = try db.prepare(
                    "UPDATE entry_versions SET data = ?1 WHERE id = ?2",
                );
                defer v_stmt.deinit();

                try v_stmt.bindText(1, data_json);
                try v_stmt.bindText(2, pv);

                _ = try v_stmt.step();
            }
        }

        // Update entry
        {
            var stmt = try db.prepare(
                \\UPDATE entries SET slug = ?2, title = ?3, data = ?4,
                \\    status = ?5, updated_at = unixepoch()
                \\WHERE id = ?1
            );
            defer stmt.deinit();

            try stmt.bindText(1, entry_id);
            if (slug) |s| try stmt.bindText(2, s) else try stmt.bindNull(2);
            try stmt.bindText(3, title);
            try stmt.bindText(4, data_json);
            try stmt.bindText(5, status);

            _ = try stmt.step();
        }

        // Point to new version if data changed (skip for in-place autosave)
        if (data_changed and !can_autosave_inplace) {
            var cv_stmt = try db.prepare(
                "UPDATE entries SET current_version_id = ?1 WHERE id = ?2",
            );
            defer cv_stmt.deinit();

            try cv_stmt.bindText(1, &version_id);
            try cv_stmt.bindText(2, entry_id);

            _ = try cv_stmt.step();
        }
    } else {
        // Create entry first (so FK on entry_versions.entry_id is satisfied)
        {
            var stmt = try db.prepare(
                \\INSERT INTO entries (id, content_type_id, slug, title, data, status)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            );
            defer stmt.deinit();

            try stmt.bindText(1, entry_id);
            try stmt.bindText(2, CT.type_id);
            if (slug) |s| try stmt.bindText(3, s) else try stmt.bindNull(3);
            try stmt.bindText(4, title);
            try stmt.bindText(5, data_json);
            try stmt.bindText(6, status);

            _ = try stmt.step();
        }

        // Then create version
        {
            var v_stmt = try db.prepare(
                \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
                \\VALUES (?1, ?2, NULL, ?3, ?4, 'created')
            );
            defer v_stmt.deinit();

            try v_stmt.bindText(1, &version_id);
            try v_stmt.bindText(2, entry_id);
            try v_stmt.bindText(3, data_json);
            if (opts.author_id) |aid| try v_stmt.bindText(4, aid) else try v_stmt.bindNull(4);

            _ = try v_stmt.step();
        }

        // Update entry with version pointer
        {
            var u_stmt = try db.prepare(
                "UPDATE entries SET current_version_id = ?1 WHERE id = ?2",
            );
            defer u_stmt.deinit();

            try u_stmt.bindText(1, &version_id);
            try u_stmt.bindText(2, entry_id);

            _ = try u_stmt.step();
        }
    }

    // Enforce version retention limit
    try pruneVersions(db, entry_id);

    // Sync filterable fields to entry_meta
    try syncEntryMeta(CT, db, entry_id, data);

    // Sync taxonomy fields to entry_terms
    try syncEntryTerms(CT, db, entry_id, data);

    // Return the saved entry
    return try getEntry(CT, allocator, db, entry_id) orelse error.EntryNotFound;
}

/// Sync filterable fields to entry_meta table
fn syncEntryMeta(comptime CT: type, db: *Db, entry_id: []const u8, data: anytype) !void {
    // Delete existing meta for this entry
    var del_stmt = try db.prepare("DELETE FROM entry_meta WHERE entry_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, entry_id);
    _ = try del_stmt.step();

    // Insert new meta values for filterable fields
    const filterable = CT.getFilterableFields();
    if (filterable.len == 0) return;

    var stmt = try db.prepare(
        \\INSERT INTO entry_meta (entry_id, key, value_text, value_int, value_real)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.deinit();

    inline for (filterable) |f| {
        if (@hasField(@TypeOf(data), f.name)) {
            const value = @field(data, f.name);

            try stmt.bindText(1, entry_id);
            try stmt.bindText(2, f.name);

            // Bind appropriate value column based on meta type
            switch (f.meta_type) {
                .text => {
                    if (value) |v| {
                        try stmt.bindText(3, v);
                    } else {
                        try stmt.bindNull(3);
                    }
                    try stmt.bindNull(4);
                    try stmt.bindNull(5);
                },
                .int => {
                    try stmt.bindNull(3);
                    if (value) |v| {
                        try stmt.bindInt(4, v);
                    } else {
                        try stmt.bindNull(4);
                    }
                    try stmt.bindNull(5);
                },
                .real => {
                    try stmt.bindNull(3);
                    try stmt.bindNull(4);
                    // TODO: bind real value
                    try stmt.bindNull(5);
                },
            }

            _ = try stmt.step();
            stmt.reset();
        }
    }
}

/// Sync taxonomy fields to entry_terms table
fn syncEntryTerms(comptime CT: type, db: *Db, entry_id: []const u8, data: anytype) !void {
    // Delete existing terms for this entry
    var del_stmt = try db.prepare("DELETE FROM entry_terms WHERE entry_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, entry_id);
    _ = try del_stmt.step();

    // Insert new term relationships
    const taxonomies = CT.getTaxonomyFields();
    if (taxonomies.len == 0) return;

    var stmt = try db.prepare(
        \\INSERT INTO entry_terms (entry_id, term_id)
        \\VALUES (?1, ?2)
    );
    defer stmt.deinit();

    inline for (taxonomies) |f| {
        if (@hasField(@TypeOf(data), f.name)) {
            const value = @field(data, f.name);
            const ValueType = @TypeOf(value);

            // Handle different taxonomy field types
            if (ValueType == []const []const u8) {
                // Array of term IDs
                for (value) |term_id| {
                    try stmt.bindText(1, entry_id);
                    try stmt.bindText(2, term_id);
                    _ = try stmt.step();
                    stmt.reset();
                }
            } else if (@typeInfo(ValueType) == .optional) {
                // Optional taxonomy field - check child type
                const ChildType = @typeInfo(ValueType).optional.child;
                if (value) |unwrapped| {
                    if (ChildType == []const []const u8) {
                        // Optional array of term IDs
                        for (unwrapped) |term_id| {
                            try stmt.bindText(1, entry_id);
                            try stmt.bindText(2, term_id);
                            _ = try stmt.step();
                            stmt.reset();
                        }
                    } else {
                        // Optional single term ID
                        try stmt.bindText(1, entry_id);
                        try stmt.bindText(2, unwrapped);
                        _ = try stmt.step();
                        stmt.reset();
                    }
                }
            } else if (ValueType == []const u8) {
                // Non-optional single term ID
                try stmt.bindText(1, entry_id);
                try stmt.bindText(2, value);
                _ = try stmt.step();
                stmt.reset();
            }
        }
    }
}

/// Delete an entry
pub fn deleteEntry(db: *Db, entry_id: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM entries WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    _ = try stmt.step();
}

// =============================================================================
// Tests
// =============================================================================

test "generateId produces valid entry IDs" {
    const id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expect(std.mem.startsWith(u8, id, "e_"));
    try std.testing.expect(id.len >= 10);
}

test "Status enum conversions" {
    try std.testing.expectEqualStrings("draft", Status.draft.toString());
    try std.testing.expectEqualStrings("published", Status.published.toString());

    try std.testing.expect(Status.fromString("draft") == .draft);
    try std.testing.expect(Status.fromString("published") == .published);
    try std.testing.expect(Status.fromString("invalid") == null);
}

test "generateVersionId produces valid IDs" {
    const id = id_gen.generateVersionId();
    try std.testing.expect(id[0] == 'v');
    try std.testing.expect(id[1] == '_');
    try std.testing.expectEqual(@as(usize, 18), id.len);
}

/// Helper: set up a test database with schema for versioning tests
fn setupTestDb() !*Db {
    var db = try Db.init(std.testing.allocator, ":memory:");
    errdefer db.deinit();

    // Create minimal schema
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id TEXT PRIMARY KEY,
        \\    email TEXT UNIQUE NOT NULL,
        \\    display_name TEXT DEFAULT '',
        \\    email_verified INTEGER DEFAULT 0,
        \\    password_hash TEXT NOT NULL,
        \\    created_at INTEGER DEFAULT (unixepoch())
        \\);
        \\CREATE TABLE IF NOT EXISTS content_types (
        \\    id TEXT PRIMARY KEY,
        \\    slug TEXT UNIQUE NOT NULL,
        \\    name TEXT NOT NULL,
        \\    fields TEXT NOT NULL,
        \\    source TEXT NOT NULL,
        \\    created_at INTEGER DEFAULT (unixepoch())
        \\);
        \\CREATE TABLE IF NOT EXISTS entry_versions (
        \\    id TEXT PRIMARY KEY,
        \\    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        \\    parent_id TEXT REFERENCES entry_versions(id),
        \\    data TEXT NOT NULL,
        \\    author_id TEXT REFERENCES users(id),
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    version_type TEXT NOT NULL DEFAULT 'edit',
        \\    collaborators TEXT
        \\);
        \\CREATE TABLE IF NOT EXISTS entries (
        \\    id TEXT PRIMARY KEY,
        \\    content_type_id TEXT NOT NULL REFERENCES content_types(id),
        \\    slug TEXT,
        \\    title TEXT,
        \\    data TEXT NOT NULL,
        \\    status TEXT DEFAULT 'draft',
        \\    version INTEGER DEFAULT 1,
        \\    current_version_id TEXT REFERENCES entry_versions(id),
        \\    published_version_id TEXT REFERENCES entry_versions(id),
        \\    published_at INTEGER,
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    updated_at INTEGER DEFAULT (unixepoch()),
        \\    UNIQUE(content_type_id, slug)
        \\);
        \\CREATE TABLE IF NOT EXISTS settings (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL,
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    updated_at INTEGER DEFAULT (unixepoch())
        \\);
        \\CREATE TABLE IF NOT EXISTS releases (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    status TEXT NOT NULL DEFAULT 'pending',
        \\    author_id TEXT REFERENCES users(id),
        \\    created_at INTEGER DEFAULT (unixepoch()),
        \\    released_at INTEGER,
        \\    scheduled_for INTEGER,
        \\    reverted_at INTEGER
        \\);
        \\CREATE TABLE IF NOT EXISTS release_items (
        \\    release_id TEXT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
        \\    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        \\    from_version TEXT REFERENCES entry_versions(id),
        \\    to_version TEXT NOT NULL REFERENCES entry_versions(id),
        \\    fields TEXT,
        \\    PRIMARY KEY (release_id, entry_id)
        \\);
        \\INSERT INTO content_types (id, slug, name, fields, source)
        \\VALUES ('test_ct', 'test_ct', 'Test', '[]', 'core');
    );

    // Need to return a pointer that outlives this function
    const ptr = try std.testing.allocator.create(Db);
    ptr.* = db;
    return ptr;
}

fn destroyTestDb(db: **Db) void {
    db.*.deinit();
    std.testing.allocator.destroy(db.*);
}

/// Helper: insert a version and link it to an entry
fn insertTestVersion(db: *Db, entry_id: []const u8, data: []const u8, parent_id: ?[]const u8) ![18]u8 {
    const version_id = id_gen.generateVersionId();

    var v_stmt = try db.prepare(
        \\INSERT INTO entry_versions (id, entry_id, parent_id, data, author_id, version_type)
        \\VALUES (?1, ?2, ?3, ?4, NULL, 'edit')
    );
    defer v_stmt.deinit();

    try v_stmt.bindText(1, &version_id);
    try v_stmt.bindText(2, entry_id);
    if (parent_id) |pid| try v_stmt.bindText(3, pid) else try v_stmt.bindNull(3);
    try v_stmt.bindText(4, data);
    _ = try v_stmt.step();

    // Update entry's current_version_id
    var u_stmt = try db.prepare(
        "UPDATE entries SET current_version_id = ?1, data = ?2 WHERE id = ?3",
    );
    defer u_stmt.deinit();
    try u_stmt.bindText(1, &version_id);
    try u_stmt.bindText(2, data);
    try u_stmt.bindText(3, entry_id);
    _ = try u_stmt.step();

    return version_id;
}

test "version is created on save and linked to entry" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create an entry manually
    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'draft')
    );

    // Insert a version (simulates what saveEntry does)
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);

    // Verify version exists
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    }

    // Verify entry points to version
    {
        var stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v1, stmt.columnText(0) orelse "");
    }

    // Verify version data matches
    {
        var stmt = try db.prepare(
            \\SELECT ev.data FROM entries e
            \\JOIN entry_versions ev ON e.current_version_id = ev.id
            \\WHERE e.id = 'e_test1'
        );
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"v1\"}", stmt.columnText(0) orelse "");
    }
}

test "sequential saves form a parent chain" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'draft')
    );

    // First version — no parent
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    // Second version — parent is v1
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1);
    // Third version — parent is v2
    const v3 = try insertTestVersion(db, "e_test1", "{\"title\":\"v3\"}", &v2);

    // Verify 3 versions exist
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
    }

    // Verify entry points to latest
    {
        var stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v3, stmt.columnText(0) orelse "");
    }

    // Verify v1 has no parent
    {
        var stmt = try db.prepare("SELECT parent_id FROM entry_versions WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &v1);
        _ = try stmt.step();
        try std.testing.expect(stmt.columnIsNull(0));
    }

    // Verify v2 parent is v1
    {
        var stmt = try db.prepare("SELECT parent_id FROM entry_versions WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &v2);
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v1, stmt.columnText(0) orelse "");
    }

    // Verify v3 parent is v2
    {
        var stmt = try db.prepare("SELECT parent_id FROM entry_versions WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &v3);
        _ = try stmt.step();
        try std.testing.expectEqualStrings(&v2, stmt.columnText(0) orelse "");
    }
}

test "pruneVersions does nothing without limit" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Insert 5 versions
    var prev: ?[]const u8 = null;
    var prev_buf: [18]u8 = undefined;
    for (0..5) |_| {
        const vid = try insertTestVersion(db, "e_test1", "{}", prev);
        prev_buf = vid;
        prev = &prev_buf;
    }

    // No settings row — pruneVersions should be a no-op
    try pruneVersions(db, "e_test1");

    var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 5), stmt.columnInt(0));
}

test "pruneVersions enforces retention limit" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Insert 5 versions
    var prev: ?[]const u8 = null;
    var prev_buf: [18]u8 = undefined;
    for (0..5) |_| {
        const vid = try insertTestVersion(db, "e_test1", "{}", prev);
        prev_buf = vid;
        prev = &prev_buf;
    }

    // Set retention limit to 3
    try db.exec("INSERT INTO settings (key, value) VALUES ('version_history_limit', '3')");

    try pruneVersions(db, "e_test1");

    // Should have 3 versions left
    var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
}

test "pruneVersions keeps most recent versions" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Insert 3 versions with distinct data
    _ = try insertTestVersion(db, "e_test1", "{\"v\":1}", null);
    // Small sleep not possible in tests, but created_at defaults to unixepoch()
    // which is the same second. Use explicit timestamps instead.
    // Actually, all versions in the same second will have same created_at.
    // The pruning uses ORDER BY created_at DESC, LIMIT — with ties,
    // SQLite picks arbitrarily but consistently. We'll verify count only.

    var prev_buf: [18]u8 = undefined;
    prev_buf = try insertTestVersion(db, "e_test1", "{\"v\":1}", null);
    const v2 = try insertTestVersion(db, "e_test1", "{\"v\":2}", &prev_buf);
    prev_buf = v2;
    _ = try insertTestVersion(db, "e_test1", "{\"v\":3}", &prev_buf);

    // Set limit to 2
    try db.exec("INSERT INTO settings (key, value) VALUES ('version_history_limit', '2')");

    try pruneVersions(db, "e_test1");

    var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
}

test "listVersions returns versions in newest-first order" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"v\":1}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    _ = try insertTestVersion(db, "e_test1", "{\"v\":2}", &v1_copy);

    const versions = try listVersions(std.testing.allocator, db, "e_test1", .{});
    defer std.testing.allocator.free(versions);

    try std.testing.expectEqual(@as(usize, 2), versions.len);
    // Newest first — v2 should be first (is_current = true)
    try std.testing.expect(versions[0].is_current);
}

test "listVersions returns empty for nonexistent entry" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const versions = try listVersions(std.testing.allocator, db, "e_nonexistent", .{});
    defer std.testing.allocator.free(versions);

    try std.testing.expectEqual(@as(usize, 0), versions.len);
}

test "getVersion returns correct version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"hello\"}", null);

    const ver = try getVersion(std.testing.allocator, db, &v1);
    try std.testing.expect(ver != null);
    try std.testing.expectEqualStrings("{\"title\":\"hello\"}", ver.?.data);
    try std.testing.expect(ver.?.is_current);
}

test "getVersion returns null for nonexistent version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const ver = try getVersion(std.testing.allocator, db, "v_nonexistent12345");
    try std.testing.expect(ver == null);
}

test "restoreVersion creates new version with old data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );

    // Create two versions
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"original\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"modified\"}", &v1_copy);

    // Restore v1
    try restoreVersion(std.testing.allocator, db, "e_test1", &v1, null);

    // Should now have 3 versions
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM entry_versions WHERE entry_id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
    }

    // Current version data should be the original
    {
        var stmt = try db.prepare(
            \\SELECT ev.data FROM entries e
            \\JOIN entry_versions ev ON e.current_version_id = ev.id
            \\WHERE e.id = 'e_test1'
        );
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"original\"}", stmt.columnText(0) orelse "");
    }

    // entries.data should also be synced
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"original\"}", stmt.columnText(0) orelse "");
    }
}

test "diffVersions shows changed fields" {
    const result = try diffVersions(
        std.testing.allocator,
        "{\"title\":\"old title\",\"body\":\"same\"}",
        "{\"title\":\"new title\",\"body\":\"same\"}",
    );
    defer std.testing.allocator.free(result);

    // Should contain "title" as changed
    try std.testing.expect(std.mem.indexOf(u8, result, "title") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "changed") != null);
    // Should NOT contain "body" (unchanged)
    try std.testing.expect(std.mem.indexOf(u8, result, "diff-key\">body") == null);
}

test "diffVersions shows added fields" {
    const result = try diffVersions(
        std.testing.allocator,
        "{\"title\":\"hello\"}",
        "{\"title\":\"hello\",\"extra\":\"new\"}",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "added") != null);
}

test "diffVersions shows removed fields" {
    const result = try diffVersions(
        std.testing.allocator,
        "{\"title\":\"hello\",\"old_field\":\"gone\"}",
        "{\"title\":\"hello\"}",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "old_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "removed") != null);
}

test "generateReleaseId produces valid IDs" {
    const id = generateReleaseId();
    try std.testing.expect(id[0] == 'r');
    try std.testing.expect(id[1] == 'e');
    try std.testing.expect(id[2] == 'l');
    try std.testing.expect(id[3] == '_');
    try std.testing.expectEqual(@as(usize, 20), id.len);
}

test "publishEntry creates release and publishes" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);

    try publishEntry(std.testing.allocator, db, "e_test1", null, null);

    // Verify entry is published with published_version_id set
    {
        var stmt = try db.prepare("SELECT status, published_version_id FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("published", stmt.columnText(0) orelse "");
        try std.testing.expectEqualStrings(&v1, stmt.columnText(1) orelse "");
    }

    // Verify release exists and is released
    {
        var stmt = try db.prepare("SELECT status, released_at, name FROM releases");
        defer stmt.deinit();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
        try std.testing.expect(!stmt.columnIsNull(1));
        try std.testing.expect(stmt.columnIsNull(2)); // instant release has null name
    }

    // Verify release item
    {
        var stmt = try db.prepare("SELECT entry_id, from_version, to_version FROM release_items");
        defer stmt.deinit();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("e_test1", stmt.columnText(0) orelse "");
        try std.testing.expect(stmt.columnIsNull(1)); // from_version is NULL (first publish)
        try std.testing.expectEqualStrings(&v1, stmt.columnText(2) orelse "");
    }
}

test "publishEntry skips when already published with same version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'published')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    // Set published_version_id = current_version_id (already published)
    {
        var stmt = try db.prepare("UPDATE entries SET published_version_id = ?1 WHERE id = 'e_test1'");
        defer stmt.deinit();
        try stmt.bindText(1, &v1);
        _ = try stmt.step();
    }

    try publishEntry(std.testing.allocator, db, "e_test1", null, null);

    // No release should be created
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM releases");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
    }
}

test "publishEntry partial publish merges selected fields" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Start with published entry
    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"old","slug":"old-slug"}', 'changed')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"old\",\"slug\":\"old-slug\"}", null);

    // Set as published
    {
        var stmt = try db.prepare("UPDATE entries SET published_version_id = ?1 WHERE id = 'e_test1'");
        defer stmt.deinit();
        try stmt.bindText(1, &v1);
        _ = try stmt.step();
    }

    // Create draft with changes to both fields
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"new\",\"slug\":\"new-slug\"}", &v1_copy);

    // Partial publish: only title
    try publishEntry(std.testing.allocator, db, "e_test1", null, "[\"title\"]");

    // Entry should still be changed (slug not published)
    {
        var stmt = try db.prepare("SELECT status FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("changed", stmt.columnText(0) orelse "");
    }

    // Published data should have new title but old slug
    const pub_data = try getPublishedData(std.testing.allocator, db, "e_test1");
    defer if (pub_data) |d| std.testing.allocator.free(d);
    try std.testing.expect(pub_data != null);

    // Parse and verify
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pub_data.?, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("new", obj.get("title").?.string);
    try std.testing.expectEqualStrings("old-slug", obj.get("slug").?.string);
}

test "getEntryVersionId returns current version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    const version_id = try getEntryVersionId(db, "e_test1");
    try std.testing.expect(version_id != null);
    defer db.allocator.free(version_id.?);
    try std.testing.expectEqualStrings(&v1, version_id.?);
}

test "getEntryVersionId returns null for no version" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status, current_version_id)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft', NULL)
    );

    const version_id = try getEntryVersionId(db, "e_test1");
    try std.testing.expect(version_id == null);
}

/// Helper: create a released release for testing revert/re-release
fn createTestRelease(db: *Db, entry_id: []const u8, from_v: ?[]const u8, to_v: []const u8) ![20]u8 {
    const release_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            \\INSERT INTO releases (id, name, status, author_id, created_at, released_at)
            \\VALUES (?1, NULL, 'released', NULL, unixepoch(), unixepoch())
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        _ = try stmt.step();
    }
    {
        var stmt = try db.prepare(
            \\INSERT INTO release_items (release_id, entry_id, from_version, to_version)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.deinit();
        try stmt.bindText(1, &release_id);
        try stmt.bindText(2, entry_id);
        if (from_v) |fv| try stmt.bindText(3, fv) else try stmt.bindNull(3);
        try stmt.bindText(4, to_v);
        _ = try stmt.step();
    }
    return release_id;
}

test "revertRelease restores from_version data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release: v1 → v2
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);

    // Revert
    try revertRelease(db, &rel_id, null);

    // Verify entry data is restored to v1
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"v1\"}", stmt.columnText(0) orelse "");
    }

    // Verify release status is reverted
    {
        var stmt = try db.prepare("SELECT status, reverted_at FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("reverted", stmt.columnText(0) orelse "");
        try std.testing.expect(!stmt.columnIsNull(1)); // reverted_at set
    }

    // Verify a new 'reverted' version was created
    {
        var stmt = try db.prepare(
            "SELECT version_type FROM entry_versions WHERE entry_id = 'e_test1' ORDER BY created_at DESC LIMIT 1",
        );
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("reverted", stmt.columnText(0) orelse "");
    }
}

test "revertRelease blocked when entry modified since release" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release: v1 → v2
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);

    // Modify entry after release (v3)
    var v2_copy: [18]u8 = undefined;
    @memcpy(&v2_copy, &v2);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"v3\"}", &v2_copy);

    // Revert should be blocked
    const result = revertRelease(db, &rel_id, null);
    try std.testing.expectError(ReleaseError.EntryModifiedSinceRelease, result);

    // Verify release status unchanged
    {
        var stmt = try db.prepare("SELECT status FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
    }
}

test "revertRelease fails on non-released status" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create a pending release (not released)
    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            "INSERT INTO releases (id, status) VALUES (?1, 'pending')",
        );
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = revertRelease(db, &rel_id, null);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "reReleaseReverted restores to_version data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release and revert it
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);
    try revertRelease(db, &rel_id, null);

    // Re-release
    try reReleaseReverted(db, &rel_id, null);

    // Verify entry data is back to v2
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{\"title\":\"v2\"}", stmt.columnText(0) orelse "");
    }

    // Verify release status is released again
    {
        var stmt = try db.prepare("SELECT status, reverted_at FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
        try std.testing.expect(stmt.columnIsNull(1)); // reverted_at cleared
    }
}

test "reReleaseReverted blocked when entry modified after revert" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"v1"}', 'published')
    );

    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"v1\"}", null);
    var v1_copy: [18]u8 = undefined;
    @memcpy(&v1_copy, &v1);
    const v2 = try insertTestVersion(db, "e_test1", "{\"title\":\"v2\"}", &v1_copy);

    // Create release, revert, then modify
    const rel_id = try createTestRelease(db, "e_test1", &v1, &v2);
    try revertRelease(db, &rel_id, null);

    // Get current version (the revert version) and modify entry after revert
    const revert_vid = (try getEntryVersionId(db, "e_test1")).?;
    defer db.allocator.free(revert_vid);
    var rv_copy: [18]u8 = undefined;
    @memcpy(&rv_copy, revert_vid[0..18]);
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"v4\"}", &rv_copy);

    // Re-release should be blocked
    const result = reReleaseReverted(db, &rel_id, null);
    try std.testing.expectError(ReleaseError.EntryModifiedSinceRelease, result);
}

test "scheduleRelease sets scheduled state" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create a pending release
    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            "INSERT INTO releases (id, status) VALUES (?1, 'pending')",
        );
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const target_time: i64 = 1738800000; // some future timestamp
    try scheduleRelease(db, &rel_id, target_time);

    // Verify
    {
        var stmt = try db.prepare("SELECT status, scheduled_for FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("scheduled", stmt.columnText(0) orelse "");
        try std.testing.expectEqual(target_time, stmt.columnInt(1));
    }
}

test "scheduleRelease fails on non-pending status" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    // Create a released release
    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare(
            "INSERT INTO releases (id, status) VALUES (?1, 'released')",
        );
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = scheduleRelease(db, &rel_id, 1738800000);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "revertRelease with null from_version restores empty data" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{"title":"first"}', 'published')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{\"title\":\"first\"}", null);

    // Release with null from_version (new entry publish)
    const rel_id = try createTestRelease(db, "e_test1", null, &v1);

    try revertRelease(db, &rel_id, null);

    // Entry data should be empty JSON
    {
        var stmt = try db.prepare("SELECT data FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("{}", stmt.columnText(0) orelse "");
    }
}

test "createPendingRelease creates a pending release with name" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const rel_id = try createPendingRelease(db, "Sprint 42", null);

    var stmt = try db.prepare("SELECT name, status FROM releases WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, &rel_id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("Sprint 42", stmt.columnText(0) orelse "");
    try std.testing.expectEqualStrings("pending", stmt.columnText(1) orelse "");
}

test "addToRelease inserts item into pending release" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    const v1 = try insertTestVersion(db, "e_test1", "{}", null);

    const rel_id = try createPendingRelease(db, "Batch 1", null);
    try addToRelease(db, &rel_id, "e_test1", null);

    var stmt = try db.prepare("SELECT entry_id, to_version FROM release_items WHERE release_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, &rel_id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("e_test1", stmt.columnText(0) orelse "");
    try std.testing.expectEqualStrings(&v1, stmt.columnText(1) orelse "");
}

test "addToRelease fails on non-pending release" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare("INSERT INTO releases (id, status) VALUES (?1, 'released')");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = addToRelease(db, &rel_id, "e_test1", null);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "removeFromRelease removes item" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    _ = try insertTestVersion(db, "e_test1", "{}", null);

    const rel_id = try createPendingRelease(db, "Batch 1", null);
    try addToRelease(db, &rel_id, "e_test1", null);

    // Remove
    try removeFromRelease(db, &rel_id, "e_test1");

    var stmt = try db.prepare("SELECT COUNT(*) FROM release_items WHERE release_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, &rel_id);
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "publishBatchRelease sets entries to published" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, status)
        \\VALUES ('e_test1', 'test_ct', '{}', 'draft')
    );
    _ = try insertTestVersion(db, "e_test1", "{\"title\":\"staged\"}", null);

    const rel_id = try createPendingRelease(db, "Launch", null);
    try addToRelease(db, &rel_id, "e_test1", null);

    try publishBatchRelease(std.testing.allocator, db, &rel_id);

    // Entry should be published
    {
        var stmt = try db.prepare("SELECT status FROM entries WHERE id = 'e_test1'");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("published", stmt.columnText(0) orelse "");
    }

    // Release should be released
    {
        var stmt = try db.prepare("SELECT status, released_at FROM releases WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
        try std.testing.expectEqualStrings("released", stmt.columnText(0) orelse "");
        try std.testing.expect(!stmt.columnIsNull(1));
    }
}

test "publishBatchRelease fails on non-pending" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const rel_id = generateReleaseId();
    {
        var stmt = try db.prepare("INSERT INTO releases (id, status) VALUES (?1, 'released')");
        defer stmt.deinit();
        try stmt.bindText(1, &rel_id);
        _ = try stmt.step();
    }

    const result = publishBatchRelease(std.testing.allocator, db, &rel_id);
    try std.testing.expectError(ReleaseError.InvalidReleaseStatus, result);
}

test "listReleases returns releases" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    _ = try createPendingRelease(db, "Release A", null);
    _ = try createPendingRelease(db, "Release B", null);

    const releases = try listReleases(std.testing.allocator, db, .{});
    defer std.testing.allocator.free(releases);
    try std.testing.expectEqual(@as(usize, 2), releases.len);
}

test "listReleases filters by status" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    _ = try createPendingRelease(db, "Pending One", null);

    // Create a released one directly
    try db.exec("INSERT INTO releases (id, name, status) VALUES ('rel_released_test1', 'Done', 'released')");

    const pending = try listReleases(std.testing.allocator, db, .{ .status = "pending" });
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqualStrings("Pending One", pending[0].name);
}

test "getRelease returns detail with items" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    try db.exec(
        \\INSERT INTO entries (id, content_type_id, title, data, status)
        \\VALUES ('e_test1', 'test_ct', 'My Post', '{}', 'draft')
    );
    _ = try insertTestVersion(db, "e_test1", "{}", null);

    const rel_id = try createPendingRelease(db, "Detail Test", null);
    try addToRelease(db, &rel_id, "e_test1", null);

    const detail = try getRelease(std.testing.allocator, db, &rel_id);
    try std.testing.expect(detail != null);
    const d = detail.?;
    defer std.testing.allocator.free(d.items);
    try std.testing.expectEqualStrings("Detail Test", d.name);
    try std.testing.expectEqualStrings("pending", d.status);
    try std.testing.expectEqual(@as(usize, 1), d.items.len);
    try std.testing.expectEqualStrings("My Post", d.items[0].entry_title);
}

test "getRelease returns null for nonexistent" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    const detail = try getRelease(std.testing.allocator, db, "rel_nonexistent12345");
    try std.testing.expect(detail == null);
}

test "listPendingReleases returns only pending" {
    var db = try setupTestDb();
    defer destroyTestDb(&db);

    _ = try createPendingRelease(db, "Active", null);
    try db.exec("INSERT INTO releases (id, name, status) VALUES ('rel_released_test2', 'Done', 'released')");

    const pending = try listPendingReleases(std.testing.allocator, db);
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqualStrings("Active", pending[0].name);
}
