# Architecture

## Database

- SQLite only, no Postgres/MySQL option
- Schema uses JSON columns for flexible field storage
- Media stored as BLOBs in SQLite (keeps single-file simplicity)
- IDs are prefixed random strings: `e_` (entries), `m_` (media), `t_` (types), `s_` (sessions)

### Content Types

```sql
CREATE TABLE content_types (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    fields TEXT NOT NULL,         -- JSON field definitions
    created_at INTEGER DEFAULT (unixepoch())
);
```

### Entries

```sql
CREATE TABLE entries (
    id TEXT PRIMARY KEY,
    content_type_id TEXT NOT NULL REFERENCES content_types(id),
    slug TEXT,
    data TEXT NOT NULL,           -- JSON field values (includes blocks)
    status TEXT DEFAULT 'draft',  -- draft | published
    version INTEGER DEFAULT 1,    -- For collab
    published_at INTEGER,
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch()),
    UNIQUE(content_type_id, slug)
);
```

Entry with blocks (Phase 2+):
```json
{
  "title": "My Post",
  "content": {
    "blocks": [
      {"id": "b_1", "type": "heading", "data": {"level": 1, "text": "Hello"}},
      {"id": "b_2", "type": "paragraph", "data": {"text": "World"}},
      {"id": "b_3", "type": "image", "data": {"media_id": "m_9xk2n"}}
    ]
  },
  "featured_image": "m_8xk2n"
}
```

### Media

```sql
CREATE TABLE media (
    id TEXT PRIMARY KEY,
    filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size INTEGER NOT NULL,
    width INTEGER,
    height INTEGER,
    data BLOB NOT NULL,
    thumb BLOB,
    created_at INTEGER DEFAULT (unixepoch())
);
```

## Authentication (Lucia Auth Pattern)

Following [Lucia Auth](https://lucia-auth.com/) and [The Copenhagen Book](https://thecopenhagenbook.com/):

**Key principles:**
- Session token = `id.secret` (separate to prevent timing attacks)
- Secret is hashed (SHA-256) before storage
- Sliding expiration (extend active sessions)
- CSRF protection for cookie-based auth
- Invalidate all sessions on password change

### Users & Sessions

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    email_verified INTEGER DEFAULT 0,
    password_hash TEXT NOT NULL,       -- Argon2id
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    secret_hash BLOB NOT NULL,         -- SHA-256 of secret portion
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE INDEX idx_sessions_user ON sessions(user_id);
CREATE INDEX idx_sessions_expires ON sessions(expires_at);
```

**Session token format:**
```
id.secret
└─┘ └────┘
 │    │
 │    └── Random secret (hashed before storage)
 └─────── Session ID (stored as-is)
```

**Cookie settings:**
- `HttpOnly: true`
- `Secure: true` (HTTPS only in production)
- `SameSite: Lax` (CSRF protection)
- `MaxAge: 30 days`

**CSRF protection:**
- Check `Origin` header matches expected origin
- Reject requests without `Origin` header (for non-GET requests)
- Use `SameSite=Lax` cookies as additional layer

## HTTP

- Uses `std.http.Server` from Zig stdlib
- Partial page loads via `X-Partial` header (HTMX-style, but handwritten)
- Routes return full HTML or fragment based on header

### Routes

**Admin UI:**
```
GET  /admin                     → Dashboard
GET  /admin/entries             → Entry list
GET  /admin/entries/new/:type   → New entry form
GET  /admin/entries/:id         → Edit entry
POST /admin/entries             → Create
POST /admin/entries/:id         → Update
DELETE /admin/entries/:id       → Delete

GET  /admin/media               → Media library
POST /admin/media               → Upload
DELETE /admin/media/:id         → Delete

GET  /admin/types               → Content types
POST /admin/types               → Create type
POST /admin/types/:id           → Update type

GET  /admin/login               → Login form
POST /admin/login               → Authenticate
POST /admin/logout              → Logout
```

**Public API:**
```
GET  /api/content/:type         → List published
GET  /api/content/:type/:slug   → Single entry
GET  /api/media/:id             → Serve media
GET  /api/media/:id/thumb       → Thumbnail
```

**WebSocket (Phase 3):**
```
WS   /ws/collab/:entry_id       → Real-time collaboration
```

## Templates

- Zig functions that return `[]u8`
- Use `std.fmt.allocPrint` and `ArrayList(u8).writer()`
- No template language — just Zig string formatting

### Template System (Phase 4)

Astro-compatible `.mz` template format with **hybrid parsing (hard requirement):**

| Mode | Behavior | Use Case |
|------|----------|----------|
| **Development** | Runtime parsing — read `.mz` from disk each request | Instant hot reload |
| **Production** | Comptime parsing — templates compiled into binary | Zero overhead |

```
---
const post = try ctx.db.getEntry(ctx.params.slug);
---

<article>
  <h1>{post.data.title}</h1>
  {for (post.data.tags) |tag| (
    <span class="tag">{tag}</span>
  )}
</article>
```

## Frontend

- No React, no Vue, no framework
- `contenteditable` for rich text (no external editor)
- ~300 lines of vanilla JS handles: partial loads, form submissions, media picker, toasts
- Plain CSS, no Tailwind, no preprocessor

## Plugin System

Plugins are comptime only — managed via CLI, compiled into binary.

### Config: `minizen.zon`

```zig
.{
    .name = "my-site",
    .plugins = .{
        .code_field = .{
            .version = "1.0.0",
            .source = "github:minizen/code-field",
        },
    },
}
```

### Plugin Interface

```zig
pub const Plugin = struct {
    name: []const u8,
    field_types: []const FieldType = &.{},
    routes: []const Route = &.{},
    hooks: []const Hook = &.{},
    admin_nav: []const NavItem = &.{},
    static_assets: []const Asset = &.{},
};
```

## Email Strategy

**Principle:** Install Minizen, everything works. No SMTP config required.

### Phase 1: No Email Required

Single-admin self-hosted CMS doesn't need email. User has shell access:
```bash
mz user reset-password admin@example.com
mz user recovery-link admin@example.com
```

### Phase 2+: Minizen Relay (Zero Config)

Default relay service — password reset works out of box:
- Free tier: 100 emails/month
- Overridable with own provider (Resend, SendGrid, SMTP)

## Performance Targets

| Metric | Target |
|--------|--------|
| Binary size | < 5MB |
| Startup time | < 100ms |
| Memory (idle) | < 50MB |
| Requests/sec | 1000+ (simple reads) |
| Template hot reload | < 50ms |
