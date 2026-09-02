CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS users (
    id                         TEXT PRIMARY KEY,
    email                      TEXT NOT NULL UNIQUE,
    display_name               TEXT NOT NULL,
    password_hash              TEXT,
    password_token_hash        BLOB,
    password_token_expires_at  INTEGER,
    role                       TEXT NOT NULL,
    created_at                 INTEGER NOT NULL,
    updated_at                 INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT PRIMARY KEY,
    secret_hash BLOB NOT NULL,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at  INTEGER NOT NULL,
    created_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS sessions_user_id ON sessions(user_id);
CREATE INDEX IF NOT EXISTS sessions_expires_at ON sessions(expires_at);

CREATE TABLE IF NOT EXISTS content_types (
    id            TEXT PRIMARY KEY,
    handle        TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    name_plural   TEXT NOT NULL,
    icon          TEXT NOT NULL,
    public        INTEGER NOT NULL,
    system        INTEGER NOT NULL,
    editor        TEXT NOT NULL,
    editor_config TEXT NOT NULL,
    definition    TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS records (
    id         TEXT PRIMARY KEY,
    type_id    TEXT NOT NULL REFERENCES content_types(id) ON DELETE CASCADE,
    status     TEXT NOT NULL,
    changed    INTEGER NOT NULL,
    version    INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    created_by TEXT,
    updated_by TEXT
) STRICT;

CREATE INDEX IF NOT EXISTS records_list ON records(type_id, status, updated_at);
CREATE INDEX IF NOT EXISTS records_changed ON records(type_id, updated_at) WHERE changed = 1;

CREATE TABLE IF NOT EXISTS record_values (
    record  TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    slot    TEXT NOT NULL,
    type_id TEXT NOT NULL,
    field   TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    kind    TEXT NOT NULL,
    value   ANY NOT NULL,
    PRIMARY KEY (record, slot, field, ordinal),
    CHECK ((kind = 'int' AND typeof(value) = 'integer')
        OR (kind = 'real' AND typeof(value) = 'real')
        OR (kind IN ('text', 'ref', 'long') AND typeof(value) = 'text'))
) STRICT;

CREATE INDEX IF NOT EXISTS record_values_lookup
    ON record_values(type_id, field, value, record) WHERE slot = 'live' AND kind <> 'long';
CREATE INDEX IF NOT EXISTS record_values_referrers
    ON record_values(value) WHERE slot = 'live' AND kind = 'ref';

CREATE VIRTUAL TABLE IF NOT EXISTS record_search USING fts5(
    text,
    record UNINDEXED,
    slot UNINDEXED,
    type_id UNINDEXED,
    field UNINDEXED
);

CREATE TABLE IF NOT EXISTS snapshots (
    record   TEXT NOT NULL,
    seq      INTEGER NOT NULL,
    kind     TEXT NOT NULL,
    at       INTEGER NOT NULL,
    by       TEXT,
    document TEXT NOT NULL,
    PRIMARY KEY (record, seq)
) STRICT;

CREATE INDEX IF NOT EXISTS snapshots_kind ON snapshots(record, kind, seq);
