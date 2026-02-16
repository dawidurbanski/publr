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
    id TEXT PRIMARY KEY,
    content_type TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    created_by TEXT REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_anchors_content_type ON content_anchors(content_type);

CREATE TABLE IF NOT EXISTS content_entries (
    id TEXT PRIMARY KEY,
    anchor_id TEXT NOT NULL,
    locale TEXT NOT NULL,
    content_type_id TEXT NOT NULL REFERENCES content_types(id),
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
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (anchor_id) REFERENCES content_anchors(id) ON DELETE CASCADE,
    FOREIGN KEY (current_version_id) REFERENCES content_versions(id),
    FOREIGN KEY (published_version_id) REFERENCES content_versions(id),
    UNIQUE(anchor_id, locale),
    UNIQUE(content_type_id, locale, slug)
);
CREATE INDEX IF NOT EXISTS idx_content_entries_anchor ON content_entries(anchor_id);
CREATE INDEX IF NOT EXISTS idx_content_entries_locale ON content_entries(locale);
CREATE INDEX IF NOT EXISTS idx_content_entries_type_status ON content_entries(content_type_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_entries_published ON content_entries(published_version_id) WHERE published_version_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS content_versions (
    id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL,
    parent_id TEXT REFERENCES content_versions(id),
    data_json TEXT NOT NULL,
    author_id TEXT REFERENCES users(id),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    version_type TEXT NOT NULL DEFAULT 'edit',
    collaborators TEXT,
    FOREIGN KEY (entry_id) REFERENCES content_entries(id) ON DELETE CASCADE
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
    created_at INTEGER DEFAULT (unixepoch()),
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
