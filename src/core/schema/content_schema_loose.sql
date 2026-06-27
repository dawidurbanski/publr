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
    name_plural TEXT NOT NULL DEFAULT '',
    icon TEXT NOT NULL DEFAULT 'bookmark',
    fields TEXT NOT NULL,
    source TEXT NOT NULL,
    localized INTEGER NOT NULL DEFAULT 0,
    locales TEXT,
    workflow TEXT,
    internal INTEGER NOT NULL DEFAULT 0,
    is_taxonomy INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER DEFAULT (unixepoch())
);

-- Unified content lifecycle tables
CREATE TABLE IF NOT EXISTS content_anchors (
    -- NOT NULL on TEXT PK + FK on created_by stripped for cr-sqlite CRR
    -- compatibility; DEFAULT added on the NOT NULL column. See
    -- content_entries below for the detailed rationale.
    id TEXT PRIMARY KEY NOT NULL,
    content_type TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    created_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_anchors_content_type ON content_anchors(content_type);

CREATE TABLE IF NOT EXISTS content_entries (
    -- NOT NULL added: SQLite quirk — only INTEGER PRIMARY KEY is implicitly
    -- NOT NULL (via rowid aliasing). TEXT PRIMARY KEY allows NULL unless
    -- you say so explicitly, and cr-sqlite refuses to mark a CRR if any
    -- PK column is nullable.
    id TEXT PRIMARY KEY NOT NULL,
    -- DEFAULTs added on these three NOT NULL columns vs upstream schema:
    -- cr-sqlite refuses crsql_as_crr on a NOT NULL column without a
    -- DEFAULT (it can't materialise stub rows during merge otherwise).
    -- Writers always supply real values, so the defaults are never read.
    anchor_id TEXT NOT NULL DEFAULT '',
    locale TEXT NOT NULL DEFAULT 'en',
    -- Inline `REFERENCES content_types(id)` stripped from upstream: cr-sqlite
    -- refuses CRR-marking on any table with "checked" FKs (the constraint
    -- can be violated by a remote-applied changeset that arrives before the
    -- referenced row). FK enforcement is off in SQLite by default anyway.
    content_type_id TEXT NOT NULL DEFAULT '',
    slug TEXT,
    title TEXT,
    data TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'draft',
    version INTEGER NOT NULL DEFAULT 1,
    current_version_id TEXT,
    published_version_id TEXT,
    published_at INTEGER,
    archived INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
    -- Stripped from upstream for cr-sqlite compatibility:
    --   FOREIGN KEY (anchor_id) REFERENCES content_anchors(id) ON DELETE CASCADE
    --   FOREIGN KEY (current_version_id) REFERENCES content_versions(id)
    --   FOREIGN KEY (published_version_id) REFERENCES content_versions(id)
    --   UNIQUE(anchor_id, locale)
    --   UNIQUE(content_type_id, locale, slug)
    -- cr-sqlite 0.16 refuses both: "checked" FKs (a remote changeset can
    -- arrive before its referenced row) and non-PK UNIQUE indices (no
    -- merge strategy for unique conflicts). The demo writers naturally
    -- generate unique ids; FK enforcement is off by default in SQLite, so
    -- dropping these is a no-op at runtime.
);
CREATE INDEX IF NOT EXISTS idx_content_entries_anchor ON content_entries(anchor_id);
CREATE INDEX IF NOT EXISTS idx_content_entries_locale ON content_entries(locale);
CREATE INDEX IF NOT EXISTS idx_content_entries_type_status ON content_entries(content_type_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_entries_published ON content_entries(published_version_id) WHERE published_version_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS content_versions (
    -- Same cr-sqlite CRR adjustments as content_entries: NOT NULL on
    -- TEXT PK, DEFAULTs on NOT NULL columns, inline + table-level FKs
    -- stripped. The admin list query JOINs through content_versions
    -- so it has to sync alongside content_entries — otherwise merged
    -- entries get filtered out for missing version rows.
    id TEXT PRIMARY KEY NOT NULL,
    entry_id TEXT NOT NULL DEFAULT '',
    parent_id TEXT,
    data_json TEXT NOT NULL DEFAULT '{}',
    author_id TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    version_type TEXT NOT NULL DEFAULT 'edit',
    collaborators TEXT
);
CREATE INDEX IF NOT EXISTS idx_content_versions_entry ON content_versions(entry_id);
CREATE INDEX IF NOT EXISTS idx_content_versions_entry_created ON content_versions(entry_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_versions_parent ON content_versions(parent_id);

CREATE TABLE IF NOT EXISTS content_meta (
    entry_id TEXT NOT NULL,
    version_id TEXT NOT NULL,
    field_name TEXT NOT NULL,
    value TEXT,
    PRIMARY KEY (entry_id, version_id, field_name),
    FOREIGN KEY (entry_id) REFERENCES content_entries(id) ON DELETE CASCADE,
    FOREIGN KEY (version_id) REFERENCES content_versions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_content_meta_field_value ON content_meta(field_name, value);

-- Typed-column meta projection for the new runtime registry. One row per
-- filterable field on a content entry. Reads stay JOIN-free (data lives in
-- content_entries.data JSON); these rows exist purely to make filter / sort
-- / range queries hit indexes without CASTs.
CREATE TABLE IF NOT EXISTS entry_meta (
    entry_id TEXT NOT NULL REFERENCES content_entries(id) ON DELETE CASCADE,
    field_name TEXT NOT NULL,
    text_value TEXT,
    int_value INTEGER,
    real_value REAL,
    datetime_value INTEGER,
    PRIMARY KEY (entry_id, field_name)
);
CREATE INDEX IF NOT EXISTS idx_entry_meta_text ON entry_meta(field_name, text_value);
CREATE INDEX IF NOT EXISTS idx_entry_meta_int ON entry_meta(field_name, int_value);
CREATE INDEX IF NOT EXISTS idx_entry_meta_real ON entry_meta(field_name, real_value);
CREATE INDEX IF NOT EXISTS idx_entry_meta_datetime ON entry_meta(field_name, datetime_value);

-- Full-text search index for fields flagged `.searchable = true`. Generic
-- shape (entry_id + content_type_id + field_name + value) so runtime-loaded
-- content types can write rows without table-creation-time column DDL.
CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
    entry_id UNINDEXED,
    content_type_id UNINDEXED,
    field_name UNINDEXED,
    value,
    tokenize = 'porter'
);

CREATE TABLE IF NOT EXISTS content_term_assignments (
    entry_id TEXT NOT NULL,
    taxonomy_id TEXT NOT NULL,
    field_name TEXT NOT NULL,
    term_anchor_id TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (entry_id, field_name, term_anchor_id),
    FOREIGN KEY (entry_id) REFERENCES content_entries(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_content_terms_entry ON content_term_assignments(entry_id);
CREATE INDEX IF NOT EXISTS idx_content_terms_lookup ON content_term_assignments(taxonomy_id, term_anchor_id);

CREATE TABLE IF NOT EXISTS version_history (
    id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL,
    parent_id TEXT,
    merge_parent_id TEXT,
    type TEXT NOT NULL,
    version_id TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (entry_id) REFERENCES content_entries(id) ON DELETE CASCADE,
    FOREIGN KEY (parent_id) REFERENCES version_history(id),
    FOREIGN KEY (merge_parent_id) REFERENCES version_history(id),
    FOREIGN KEY (version_id) REFERENCES content_versions(id)
);
CREATE INDEX IF NOT EXISTS idx_version_history_entry ON version_history(entry_id);
CREATE INDEX IF NOT EXISTS idx_version_history_parent ON version_history(parent_id);
CREATE INDEX IF NOT EXISTS idx_version_history_merge_parent ON version_history(merge_parent_id);

CREATE TABLE IF NOT EXISTS entry_flow_state (
    anchor_id TEXT PRIMARY KEY,
    flow_id TEXT NOT NULL,
    current_step INTEGER NOT NULL DEFAULT 0,
    started_at INTEGER NOT NULL DEFAULT (unixepoch()),
    started_by TEXT REFERENCES users(id),
    FOREIGN KEY (anchor_id) REFERENCES content_anchors(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_flow_state_flow_id ON entry_flow_state(flow_id);

CREATE TABLE IF NOT EXISTS entry_flow_claims (
    anchor_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    assignee_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    claimed_at INTEGER,
    decided_at INTEGER,
    PRIMARY KEY (anchor_id, step_index, assignee_id),
    FOREIGN KEY (anchor_id) REFERENCES content_anchors(id) ON DELETE CASCADE,
    FOREIGN KEY (assignee_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_flow_claims_assignee ON entry_flow_claims(assignee_id, status);

CREATE TABLE IF NOT EXISTS entry_flow_history (
    id TEXT PRIMARY KEY,
    anchor_id TEXT NOT NULL,
    version_id TEXT REFERENCES content_versions(id) ON DELETE CASCADE,
    action TEXT NOT NULL,
    user_id TEXT,
    from_step INTEGER,
    to_step INTEGER,
    details TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (anchor_id) REFERENCES content_anchors(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_flow_history_anchor_created ON entry_flow_history(anchor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_flow_history_version_created ON entry_flow_history(version_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_flow_history_action ON entry_flow_history(action);

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
    author_id TEXT REFERENCES users(id),
    last_updated_by TEXT REFERENCES users(id),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE(taxonomy_id, slug)
);

CREATE INDEX IF NOT EXISTS idx_terms_taxonomy ON terms(taxonomy_id);
CREATE INDEX IF NOT EXISTS idx_terms_parent ON terms(parent_id);

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

CREATE TABLE IF NOT EXISTS release_entries (
    release_id TEXT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    entry_id TEXT NOT NULL REFERENCES content_entries(id) ON DELETE CASCADE,
    from_version_id TEXT REFERENCES content_versions(id),
    to_version_id TEXT NOT NULL REFERENCES content_versions(id),
    selected_fields TEXT,
    PRIMARY KEY (release_id, entry_id)
);
CREATE INDEX IF NOT EXISTS idx_release_entries_entry ON release_entries(entry_id);

-- Global settings (key-value store)
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch())
);

-- Variables (KV with interpolation).
-- Editor-facing named string values, referenced inline in field content via
-- `[kv:key]` tokens. Distinct from `settings` above (which is opaque plugin
-- storage). `mode` is one of literal-baked / computed-baked / literal-live /
-- computed-live. `source` is "editor" or "plugin:<id>". `last_resolved`
-- caches the computed value for `computed-baked` rows between publishes.
CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL,
    mode TEXT NOT NULL,
    label TEXT,
    description TEXT,
    last_resolved TEXT,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

-- Reverse index from variable keys to the (entry, field) locations that
-- reference them. Populated by the field-save hook on text-bearing fields.
-- Used by the publish-session cascade to enqueue referencers when a baked
-- variable changes value.
CREATE TABLE IF NOT EXISTS kv_refs (
    var_key TEXT NOT NULL,
    entry_id TEXT NOT NULL,
    field_path TEXT NOT NULL,
    PRIMARY KEY (var_key, entry_id, field_path)
);
CREATE INDEX IF NOT EXISTS idx_kv_refs_entry ON kv_refs(entry_id);
CREATE INDEX IF NOT EXISTS idx_kv_refs_var ON kv_refs(var_key);
