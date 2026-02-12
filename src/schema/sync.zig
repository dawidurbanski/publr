//! Schema Sync Module
//!
//! Syncs comptime schema definitions to SQLite tables. Uses hash-based
//! optimization to avoid sync overhead on every startup - only syncs
//! when the comptime schema hash differs from the stored hash.

const std = @import("std");
const registry = @import("schema_registry");
const field_mod = @import("field");
const Db = @import("db").Db;

/// SQL for creating content schema tables
pub const content_schema_sql =
    \\-- Schema version tracking (for hash-based sync)
    \\CREATE TABLE IF NOT EXISTS _schema_version (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
    \\
    \\-- Content type definitions (synced from comptime)
    \\CREATE TABLE IF NOT EXISTS content_types (
    \\    id TEXT PRIMARY KEY,
    \\    slug TEXT UNIQUE NOT NULL,
    \\    name TEXT NOT NULL,
    \\    fields TEXT NOT NULL,
    \\    source TEXT NOT NULL,
    \\    created_at INTEGER DEFAULT (unixepoch())
    \\);
    \\
    \\-- Entries (all content items)
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
    \\
    \\CREATE INDEX IF NOT EXISTS idx_entries_type_status ON entries(content_type_id, status, created_at DESC);
    \\CREATE INDEX IF NOT EXISTS idx_entries_slug ON entries(content_type_id, slug);
    \\
    \\-- Entry metadata (filterable scalar fields)
    \\CREATE TABLE IF NOT EXISTS entry_meta (
    \\    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    \\    key TEXT NOT NULL,
    \\    value_text TEXT,
    \\    value_int INTEGER,
    \\    value_real REAL,
    \\    PRIMARY KEY (entry_id, key)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_meta_lookup_text ON entry_meta(key, value_text);
    \\CREATE INDEX IF NOT EXISTS idx_meta_lookup_int ON entry_meta(key, value_int);
    \\CREATE INDEX IF NOT EXISTS idx_meta_lookup_real ON entry_meta(key, value_real);
    \\
    \\-- Taxonomy definitions
    \\CREATE TABLE IF NOT EXISTS taxonomies (
    \\    id TEXT PRIMARY KEY,
    \\    slug TEXT UNIQUE NOT NULL,
    \\    name TEXT NOT NULL,
    \\    hierarchical INTEGER DEFAULT 0,
    \\    created_at INTEGER DEFAULT (unixepoch())
    \\);
    \\
    \\-- Taxonomy terms
    \\CREATE TABLE IF NOT EXISTS terms (
    \\    id TEXT PRIMARY KEY,
    \\    taxonomy_id TEXT NOT NULL REFERENCES taxonomies(id) ON DELETE CASCADE,
    \\    slug TEXT NOT NULL,
    \\    name TEXT NOT NULL,
    \\    parent_id TEXT REFERENCES terms(id) ON DELETE SET NULL,
    \\    description TEXT DEFAULT '',
    \\    sort_order INTEGER DEFAULT 0,
    \\    created_at INTEGER DEFAULT (unixepoch()),
    \\    UNIQUE(taxonomy_id, slug)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_terms_taxonomy ON terms(taxonomy_id);
    \\CREATE INDEX IF NOT EXISTS idx_terms_parent ON terms(parent_id);
    \\
    \\-- Entry-term relationships
    \\CREATE TABLE IF NOT EXISTS entry_terms (
    \\    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    \\    term_id TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    \\    sort_order INTEGER DEFAULT 0,
    \\    PRIMARY KEY (entry_id, term_id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_entry_terms_term ON entry_terms(term_id);
    \\
    \\-- Content versioning
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
    \\
    \\CREATE INDEX IF NOT EXISTS idx_versions_entry ON entry_versions(entry_id, created_at DESC);
    \\CREATE INDEX IF NOT EXISTS idx_versions_parent ON entry_versions(parent_id);
    \\
    \\-- Releases (every publish = a release)
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
    \\
    \\CREATE INDEX IF NOT EXISTS idx_releases_status ON releases(status, created_at DESC);
    \\
    \\-- Release items (entries changed in a release)
    \\CREATE TABLE IF NOT EXISTS release_items (
    \\    release_id TEXT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    \\    from_version TEXT REFERENCES entry_versions(id),
    \\    to_version TEXT NOT NULL REFERENCES entry_versions(id),
    \\    fields TEXT,
    \\    PRIMARY KEY (release_id, entry_id)
    \\);
    \\
    \\-- Global settings (key-value store)
    \\CREATE TABLE IF NOT EXISTS settings (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL,
    \\    created_at INTEGER DEFAULT (unixepoch()),
    \\    updated_at INTEGER DEFAULT (unixepoch())
    \\);
;

/// Comptime schema hash - computed from all content type definitions
pub const schema_hash: []const u8 = computeSchemaHash();

/// Compute a hash of all schema definitions at comptime
fn computeSchemaHash() []const u8 {
    comptime {
        // Build a string representation of all content types and their fields
        var hash_input: [8192]u8 = undefined;
        var len: usize = 0;

        for (registry.content_types) |ct| {
            // Add content type info
            @memcpy(hash_input[len..][0..ct.id.len], ct.id);
            len += ct.id.len;
            hash_input[len] = ':';
            len += 1;

            // Add field info
            for (ct.fields) |f| {
                @memcpy(hash_input[len..][0..f.name.len], f.name);
                len += f.name.len;
                hash_input[len] = ',';
                len += 1;
                @memcpy(hash_input[len..][0..f.field_type_id.len], f.field_type_id);
                len += f.field_type_id.len;
                hash_input[len] = ';';
                len += 1;
            }
            hash_input[len] = '\n';
            len += 1;
        }

        // Simple hash: use first 16 chars of content as "hash"
        // In practice we could use a proper hash function
        const hash_len = @min(len, 32);
        const result = hash_input[0..hash_len].*;
        return &result;
    }
}

/// Ensure content schema tables exist
pub fn ensureSchema(db: *Db) Db.Error!void {
    try db.exec(content_schema_sql);
}

/// Sync schemas if the comptime hash differs from stored hash
pub fn syncIfNeeded(db: *Db) !void {
    // Ensure tables exist first
    try ensureSchema(db);

    // Get stored hash
    const stored_hash = try getStoredHash(db);

    // Compare with comptime hash
    if (stored_hash) |hash| {
        if (std.mem.eql(u8, hash, schema_hash)) {
            // No changes, skip sync
            return;
        }
        db.allocator.free(hash);
    }

    // Sync schemas
    try syncSchemas(db);

    // Update stored hash
    try setStoredHash(db, schema_hash);
}

/// Get the stored schema hash from database
fn getStoredHash(db: *Db) !?[]u8 {
    var stmt = try db.prepare("SELECT value FROM _schema_version WHERE key = 'hash'");
    defer stmt.deinit();

    if (try stmt.step()) {
        const value = stmt.columnText(0) orelse return null;
        return try db.allocator.dupe(u8, value);
    }
    return null;
}

/// Store the schema hash in database
fn setStoredHash(db: *Db, hash: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO _schema_version (key, value) VALUES ('hash', ?1)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    );
    defer stmt.deinit();

    try stmt.bindText(1, hash);
    _ = try stmt.step();
}

/// Generate a version ID (v_ prefix + 16 random alphanumeric chars)
pub fn generateVersionId() [18]u8 {
    var id_buf: [18]u8 = undefined;
    id_buf[0] = 'v';
    id_buf[1] = '_';

    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (rand_buf, 0..) |byte, i| {
        id_buf[2 + i] = charset[byte % charset.len];
    }

    return id_buf;
}

/// Sync all content types and taxonomies to database
fn syncSchemas(db: *Db) !void {
    // Sync content types
    var ct_stmt = try db.prepare(
        \\INSERT INTO content_types (id, slug, name, fields, source)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
        \\ON CONFLICT(id) DO UPDATE SET
        \\    name = excluded.name,
        \\    fields = excluded.fields,
        \\    source = excluded.source
    );
    defer ct_stmt.deinit();

    inline for (registry.content_types) |ct| {
        const fields_json = try serializeFieldsToJson(ct.fields, db.allocator);
        defer db.allocator.free(fields_json);

        const source_str = @tagName(ct.source);

        try ct_stmt.bindText(1, ct.id);
        try ct_stmt.bindText(2, ct.id); // slug = id for now
        try ct_stmt.bindText(3, ct.display_name);
        try ct_stmt.bindText(4, fields_json);
        try ct_stmt.bindText(5, source_str);

        _ = try ct_stmt.step();
        ct_stmt.reset();
    }

    // Sync taxonomies
    const taxonomy_ids = registry.all_taxonomy_ids;

    var tax_stmt = try db.prepare(
        \\INSERT INTO taxonomies (id, slug, name, hierarchical)
        \\VALUES (?1, ?2, ?3, 0)
        \\ON CONFLICT(id) DO NOTHING
    );
    defer tax_stmt.deinit();

    inline for (taxonomy_ids) |tax_id| {
        try tax_stmt.bindText(1, tax_id);
        try tax_stmt.bindText(2, tax_id);
        // Use humanized name computed at comptime
        try tax_stmt.bindText(3, comptime field_mod.humanize(tax_id));

        _ = try tax_stmt.step();
        tax_stmt.reset();
    }
}

/// Serialize field definitions to JSON (inline to handle comptime field types)
fn serializeFieldsToJson(comptime fields: []const field_mod.FieldDef, allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .{};
    errdefer list.deinit(allocator);

    try list.append(allocator, '[');

    comptime var i: usize = 0;
    inline for (fields) |f| {
        if (i > 0) try list.append(allocator, ',');

        try list.appendSlice(allocator, "{\"name\":\"");
        try list.appendSlice(allocator, f.name);
        try list.appendSlice(allocator, "\",\"display_name\":\"");
        try list.appendSlice(allocator, f.display_name);
        try list.appendSlice(allocator, "\",\"type\":\"");
        try list.appendSlice(allocator, f.field_type_id);
        try list.appendSlice(allocator, "\",\"required\":");
        try list.appendSlice(allocator, if (f.required) "true" else "false");
        try list.append(allocator, '}');
        i += 1;
    }

    try list.append(allocator, ']');

    return list.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "schema_hash is computed at comptime" {
    // Just verify the hash exists and has some length
    try std.testing.expect(schema_hash.len > 0);
}

test "ensureSchema creates tables" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    // Verify content_types table exists
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='content_types'");
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
}

test "syncIfNeeded syncs content types" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try syncIfNeeded(&db);

    // Verify content types were synced
    var stmt = try db.prepare("SELECT COUNT(*) FROM content_types");
    defer stmt.deinit();

    _ = try stmt.step();
    const count = stmt.columnInt(0);
    try std.testing.expect(count >= 3); // At least post, page, author
}

test "syncIfNeeded skips if hash unchanged" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    // First sync
    try syncIfNeeded(&db);

    // Second sync should be a no-op (hash unchanged)
    try syncIfNeeded(&db);

    // Should still work
    var stmt = try db.prepare("SELECT COUNT(*) FROM content_types");
    defer stmt.deinit();

    _ = try stmt.step();
    const count = stmt.columnInt(0);
    try std.testing.expect(count >= 3);
}

test "ensureSchema creates entry_versions table" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='entry_versions'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
}

test "ensureSchema creates settings table" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
}

test "entries table has current_version_id column" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    // Insert an entry with current_version_id to verify column exists
    try db.exec(
        \\INSERT INTO content_types (id, slug, name, fields, source)
        \\VALUES ('test_ct', 'test_ct', 'Test', '[]', 'plugin')
    );
    try db.exec(
        \\INSERT INTO entries (id, content_type_id, data, current_version_id)
        \\VALUES ('e_test1', 'test_ct', '{}', NULL)
    );

    var stmt = try db.prepare("SELECT current_version_id FROM entries WHERE id = 'e_test1'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    // Should be NULL
    try std.testing.expect(stmt.columnIsNull(0));
}

test "generateVersionId produces valid IDs" {
    const id = generateVersionId();
    try std.testing.expect(id[0] == 'v');
    try std.testing.expect(id[1] == '_');
    try std.testing.expectEqual(@as(usize, 18), id.len);

    // Verify all chars are in valid charset
    const charset = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (id[2..]) |ch| {
        var found = false;
        for (charset) |valid| {
            if (ch == valid) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}
