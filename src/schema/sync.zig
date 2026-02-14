//! Schema DDL Module
//!
//! Contains the DDL for all content schema tables and a function to
//! ensure they exist. Content type/taxonomy seeding is handled by
//! the seed module (comptime-generated INSERT statements).

const std = @import("std");
const Db = @import("db").Db;

/// SQL for creating content schema tables
pub const content_schema_sql =
    \\-- Auth tables
    \\CREATE TABLE IF NOT EXISTS users (
    \\    id TEXT PRIMARY KEY,
    \\    email TEXT UNIQUE NOT NULL,
    \\    display_name TEXT DEFAULT '',
    \\    email_verified INTEGER DEFAULT 0,
    \\    password_hash TEXT NOT NULL,
    \\    created_at INTEGER DEFAULT (unixepoch())
    \\);
    \\CREATE TABLE IF NOT EXISTS sessions (
    \\    id TEXT PRIMARY KEY,
    \\    secret_hash BLOB NOT NULL,
    \\    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\    expires_at INTEGER NOT NULL,
    \\    created_at INTEGER DEFAULT (unixepoch())
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
    \\CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
    \\
    \\-- Schema version tracking
    \\CREATE TABLE IF NOT EXISTS _schema_version (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
    \\
    \\-- Content type definitions
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
    \\CREATE INDEX IF NOT EXISTS idx_entries_type_created ON entries(content_type_id, created_at DESC);
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
    \\-- Media
    \\CREATE TABLE IF NOT EXISTS media (
    \\    id TEXT PRIMARY KEY,
    \\    filename TEXT NOT NULL,
    \\    mime_type TEXT NOT NULL,
    \\    size INTEGER NOT NULL,
    \\    width INTEGER,
    \\    height INTEGER,
    \\    storage_key TEXT NOT NULL,
    \\    visibility TEXT NOT NULL DEFAULT 'public',
    \\    hash TEXT,
    \\    data TEXT NOT NULL DEFAULT '{}',
    \\    created_at INTEGER DEFAULT (unixepoch()),
    \\    updated_at INTEGER DEFAULT (unixepoch())
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS media_meta (
    \\    media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    \\    key TEXT NOT NULL,
    \\    value_text TEXT,
    \\    value_int INTEGER,
    \\    value_real REAL,
    \\    PRIMARY KEY (media_id, key)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_media_meta_key_text ON media_meta(key, value_text);
    \\CREATE INDEX IF NOT EXISTS idx_media_meta_key_int ON media_meta(key, value_int);
    \\CREATE INDEX IF NOT EXISTS idx_media_meta_key_real ON media_meta(key, value_real);
    \\
    \\CREATE TABLE IF NOT EXISTS media_terms (
    \\    media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    \\    term_id TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    \\    sort_order INTEGER DEFAULT 0,
    \\    PRIMARY KEY (media_id, term_id)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_media_terms_term ON media_terms(term_id);
    \\
    \\-- Media taxonomies
    \\INSERT OR IGNORE INTO taxonomies (id, slug, name, hierarchical) VALUES ('tax_media_folders', 'media-folders', 'Media Folders', 1);
    \\INSERT OR IGNORE INTO taxonomies (id, slug, name, hierarchical) VALUES ('tax_media_tags', 'media-tags', 'Media Tags', 0);
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

/// Ensure content schema tables exist
pub fn ensureSchema(db: *Db) Db.Error!void {
    try db.exec(content_schema_sql);
}

// =============================================================================
// Tests
// =============================================================================

test "ensureSchema creates tables" {
    var db = try Db.init(std.testing.allocator, ":memory:");
    defer db.deinit();

    try ensureSchema(&db);

    // Verify content_types table exists
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='content_types'");
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
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
