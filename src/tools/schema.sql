-- Publr Database Schema
-- Generated at build time

-- Auth tables
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    display_name TEXT DEFAULT '',
    email_verified INTEGER DEFAULT 0,
    password_hash TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    secret_hash BLOB NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);

-- Content schema tables
CREATE TABLE IF NOT EXISTS _schema_version (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS content_types (
    id TEXT PRIMARY KEY,
    slug TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    fields TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS entries (
    id TEXT PRIMARY KEY,
    content_type_id TEXT NOT NULL REFERENCES content_types(id),
    slug TEXT,
    title TEXT,
    data TEXT NOT NULL,
    status TEXT DEFAULT 'draft',
    version INTEGER DEFAULT 1,
    current_version_id TEXT REFERENCES entry_versions(id),
    published_version_id TEXT REFERENCES entry_versions(id),
    published_at INTEGER,
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch()),
    UNIQUE(content_type_id, slug)
);

CREATE INDEX IF NOT EXISTS idx_entries_type_status ON entries(content_type_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_entries_slug ON entries(content_type_id, slug);

CREATE TABLE IF NOT EXISTS entry_meta (
    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    value_text TEXT,
    value_int INTEGER,
    value_real REAL,
    PRIMARY KEY (entry_id, key)
);

CREATE INDEX IF NOT EXISTS idx_meta_lookup_text ON entry_meta(key, value_text);
CREATE INDEX IF NOT EXISTS idx_meta_lookup_int ON entry_meta(key, value_int);
CREATE INDEX IF NOT EXISTS idx_meta_lookup_real ON entry_meta(key, value_real);

CREATE TABLE IF NOT EXISTS taxonomies (
    id TEXT PRIMARY KEY,
    slug TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    hierarchical INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS terms (
    id TEXT PRIMARY KEY,
    taxonomy_id TEXT NOT NULL REFERENCES taxonomies(id) ON DELETE CASCADE,
    slug TEXT NOT NULL,
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES terms(id) ON DELETE SET NULL,
    description TEXT DEFAULT '',
    sort_order INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT (unixepoch()),
    UNIQUE(taxonomy_id, slug)
);

CREATE INDEX IF NOT EXISTS idx_terms_taxonomy ON terms(taxonomy_id);
CREATE INDEX IF NOT EXISTS idx_terms_parent ON terms(parent_id);

CREATE TABLE IF NOT EXISTS entry_terms (
    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    term_id TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    sort_order INTEGER DEFAULT 0,
    PRIMARY KEY (entry_id, term_id)
);

CREATE INDEX IF NOT EXISTS idx_entry_terms_term ON entry_terms(term_id);

-- Media tables
CREATE TABLE IF NOT EXISTS media (
    id TEXT PRIMARY KEY,
    filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size INTEGER NOT NULL,
    width INTEGER,
    height INTEGER,
    storage_key TEXT NOT NULL,
    visibility TEXT NOT NULL DEFAULT 'public',
    hash TEXT,
    data TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS media_meta (
    media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    value_text TEXT,
    value_int INTEGER,
    value_real REAL,
    PRIMARY KEY (media_id, key)
);
CREATE INDEX IF NOT EXISTS idx_media_meta_key_text ON media_meta(key, value_text);
CREATE INDEX IF NOT EXISTS idx_media_meta_key_int ON media_meta(key, value_int);
CREATE INDEX IF NOT EXISTS idx_media_meta_key_real ON media_meta(key, value_real);

CREATE TABLE IF NOT EXISTS media_terms (
    media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    term_id TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    sort_order INTEGER DEFAULT 0,
    PRIMARY KEY (media_id, term_id)
);
CREATE INDEX IF NOT EXISTS idx_media_terms_term ON media_terms(term_id);

-- Media taxonomies
INSERT OR IGNORE INTO taxonomies (id, slug, name, hierarchical) VALUES ('tax_media_folders', 'media-folders', 'Media Folders', 1);
INSERT OR IGNORE INTO taxonomies (id, slug, name, hierarchical) VALUES ('tax_media_tags', 'media-tags', 'Media Tags', 0);

-- Content versioning
CREATE TABLE IF NOT EXISTS entry_versions (
    id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    parent_id TEXT REFERENCES entry_versions(id),
    data TEXT NOT NULL,
    author_id TEXT REFERENCES users(id),
    created_at INTEGER DEFAULT (unixepoch()),
    version_type TEXT NOT NULL DEFAULT 'edit',
    collaborators TEXT
);

CREATE INDEX IF NOT EXISTS idx_versions_entry ON entry_versions(entry_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_versions_parent ON entry_versions(parent_id);

-- Releases (every publish = a release)
CREATE TABLE IF NOT EXISTS releases (
    id TEXT PRIMARY KEY,
    name TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    author_id TEXT REFERENCES users(id),
    created_at INTEGER DEFAULT (unixepoch()),
    released_at INTEGER,
    scheduled_for INTEGER,
    reverted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_releases_status ON releases(status, created_at DESC);

-- Release items (entries changed in a release)
CREATE TABLE IF NOT EXISTS release_items (
    release_id TEXT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    from_version TEXT REFERENCES entry_versions(id),
    to_version TEXT NOT NULL REFERENCES entry_versions(id),
    fields TEXT,
    PRIMARY KEY (release_id, entry_id)
);

-- Global settings (key-value store)
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch())
);
