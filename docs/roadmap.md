# Roadmap

## Vision

A complete content platform — CMS, block editor, real-time collaboration, and static site generator — compiled into a single binary with minimal, curated dependencies.

**Philosophy:**
- One binary, minimal dependencies
- Every line of Zig is ours
- Dependencies must be vendored single-file C with zero transitive deps
- No npm, no cargo, no package managers at runtime
- Audit the entire codebase in a day

**End state:**
```bash
$ ls -la
-rwxr-xr-x  1 user  staff  4.2M  publr
-rw-r--r--  1 user  staff  128K  data.db

$ ./publr serve
Publr running at http://localhost:8080
```

## Product Tiers

| Tier | Name | What |
|------|------|------|
| Free | **Publr** | Self-hosted, open source, single binary |
| Paid | **Publr Cloud** | Hosted, RTC, automatic updates, managed |

## Architecture Phases

### Phase 1: CMS Core ← START HERE

- Content types with field definitions
- Entries with draft/published status
- Media uploads with image processing
- Single admin user
- JSON API
- Server-rendered admin UI + vanilla JS

### Phase 2: Block Editor

- Block-based content model
- Vanilla JS editor (~3-5k lines)
- Core blocks: paragraph, heading, image, list, quote, code
- Comptime extensible block types
- Clean JSON serialization

### Phase 3: Real-time Collaboration

- WebSocket server (Zig std)
- OT or CRDT engine
- Presence (cursors, selections)
- Conflict resolution
- Client sync layer

### Phase 4: Build Pipeline

- Astro-compatible `.publr` template format
- **Hybrid template parsing (hard requirement)**
- Static site generation
- Asset handling
- Image optimization

## Build Phases (Detailed)

### Phase 1: Skeleton
1. `build.zig` — project setup
2. `main.zig` — CLI args, server init
3. `http.zig` — router, static files
4. Embed static assets
5. Hello world page

### Phase 2: Database
1. `db.zig` — SQLite @cImport
2. Schema migrations
3. CRUD helpers

### Phase 3: Auth
1. `auth.zig` — Argon2 via std.crypto
2. Sessions
3. Login page + middleware

### Phase 4: CMS Core
1. `cms.zig` — content types, entries
2. `api.zig` — JSON endpoints
3. Admin templates
4. Media handling

### Phase 5: Block Editor
1. Block data model
2. Core blocks (paragraph, heading, image, list, quote, code)
3. Vanilla JS editor
4. Block serialization

### Phase 6: Real-time Collaboration
1. WebSocket server
2. OT/CRDT engine
3. Presence
4. Client sync

### Phase 7: Build Pipeline
1. `.publr` parser (hybrid comptime/runtime)
2. Template rendering
3. Static site generation
4. Asset pipeline

## CLI Interface

```bash
# --- Site Management ---

publr init my-site              # Initialize a new site
publr serve --port 8080         # Start server
publr serve --dev               # Development mode (hot reload)
publr build --output ./dist     # Build static site (Phase 4)

# --- Plugin Management ---

publr plugin add code-field                  # From registry
publr plugin add github:someone/webhook      # From GitHub
publr plugin add webhook@2.1.0               # Specific version
publr plugin add ./my-plugins/custom         # Local
publr plugin remove webhook
publr plugin list
publr plugin update

# --- User Management ---

publr user create admin@example.com
publr user reset-password admin@example.com
publr user recovery-link admin@example.com
publr user list
```

## What Success Looks Like

```bash
# Install Publr globally
$ zig build -Doptimize=ReleaseFast
$ cp zig-out/bin/publr /usr/local/bin/

# Create a new site
$ publr init my-blog
$ cd my-blog

# Add a plugin
$ publr plugin add code-field
Fetching code-field@1.0.0...
Updated publr.zon
Regenerated .publr/plugins.zig
Run `publr serve` to start with new plugins

# Start development
$ publr serve --dev
Publr running at http://localhost:8080
Admin: http://localhost:8080/admin
Hot reload: enabled

# Build for production
$ publr build --output ./dist
$ ls dist/
index.html  blog/  assets/  media/
```

## Resources

- [Zig Documentation](https://ziglang.org/documentation/master/)
- [Zig std.http.Server](https://ziglang.org/documentation/master/std/#/std/http)
- [SQLite C Interface](https://sqlite.org/c3ref/intro.html)
- [Astro Docs](https://docs.astro.build) — Template syntax reference
- [Lucia Auth](https://lucia-auth.com/) — Auth pattern reference
- [The Copenhagen Book](https://thecopenhagenbook.com/) — Security reference
