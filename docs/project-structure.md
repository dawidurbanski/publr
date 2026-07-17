# Project Structure

There are two separate directories: the CMS source (this repo) and user sites.

## CMS Source (this repo — immutable)

Users never edit these files. This is the Publr core.

```
publr/
├── build.zig              # Zig build configuration
│
├── src/
│   ├── main.zig           # Entry point, CLI
│   ├── http.zig           # HTTP server, router, WebSocket
│   ├── db.zig             # SQLite wrapper
│   ├── auth.zig           # Sessions, password hashing
│   ├── cms.zig            # Content types, entries
│   ├── media.zig          # Upload, resize, serve
│   ├── api.zig            # JSON API handlers
│   ├── plugin.zig         # Plugin interface definition
│   │
│   ├── cli/               # CLI commands
│   │   ├── init.zig       # `publr init`
│   │   ├── serve.zig      # `publr serve`
│   │   ├── build.zig      # `publr build`
│   │   └── plugin.zig     # `publr plugin add/remove/list`
│   │
│   ├── templates/         # Admin UI (Zig)
│   │   ├── layout.zig
│   │   ├── entries.zig
│   │   ├── media.zig
│   │   └── types.zig
│   │
│   ├── blocks/            # Phase 2
│   │   ├── block.zig
│   │   ├── paragraph.zig
│   │   ├── heading.zig
│   │   └── image.zig
│   │
│   ├── rtc/            # Phase 3
│   │   ├── websocket.zig
│   │   ├── ot.zig
│   │   └── presence.zig
│   │
│   └── build/             # Phase 4
│       ├── parser.zig     # .publr template parser
│       ├── generator.zig  # Static site generator
│       └── assets.zig     # Asset pipeline
│
├── static/
│   ├── scripts/            # CMS-authored PublrJS stores + the publr-admin.js bootstrap
│   │   └── media-library.js  # (also: entry-editor, presence, repeater, …)
│   ├── styles/
│   │   └── tokens.css      # Publr design-system tokens
│   └── logo.svg
│
├── lib/                    # Generated/vendored first-party Publr libraries
│   ├── publr/              # PublrJS runtime (publr.js + addons; served at /static/scripts/*)
│   ├── zsx.zig
│   ├── publr_ui.zig
│   ├── publr_icons.zig
│   └── publr_jit.zig
│
└── vendor/
    ├── sqlite/             # SQLite source + public-domain notice
    ├── stb/                # stb image sources + dual license
    ├── libwebp/            # libwebp source + license/provenance
    └── tailwindcss/        # Preflight asset + MIT license
```

## User Site (created via `publr init my-site`)

This is what users create and manage. They use CLI commands, never touch source.

```
my-site/
├── publr.zon                # Site config + plugin list
│
├── plugins/                 # Downloaded plugins (like node_modules)
│   ├── code-field/
│   │   ├── plugin.zig
│   │   └── ...
│   └── webhook/
│       └── plugin.zig
│
├── themes/                  # Site templates (.publr files)
│   └── default/
│       ├── layouts/
│       │   └── base.publr
│       ├── pages/
│       │   ├── index.publr
│       │   └── [slug].publr
│       └── components/
│           └── header.publr
│
├── data/
│   └── publr.db             # SQLite database
│
└── .publr/                  # Auto-generated (gitignored)
    └── plugins.zig          # Generated plugin imports
```

## Key Files to Understand

1. **src/main.zig** — Start here. CLI parsing, server init.
2. **src/http.zig** — Router implementation, middleware pattern.
3. **src/db.zig** — SQLite bindings, query helpers.
4. **src/templates/entries.zig** — Example of HTML generation pattern.
5. **static/scripts/*.js** — PublrJS store modules per admin page (entry-editor, media-library, …).
