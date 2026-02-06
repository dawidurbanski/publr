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
