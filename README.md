# zig-cms

A single-file CMS written in Zig. Zero dependencies, one binary, one SQLite database.

## Philosophy

No frameworks, no npm, no external dependencies. Single binary, zero runtime dependencies. Every line of code is ours.

## Tech Stack

- **Language:** Zig 0.15.x
- **Database:** SQLite (embedded)
- **Frontend:** Server-rendered HTML + vanilla JS + plain CSS

## Quick Start

```bash
# Build
zig build

# Run
zig build run -- serve --port 8080

# Test
zig build test
```

## Documentation

- [Architecture](docs/architecture.md) - Design decisions and technical approach
- [Dependencies](docs/dependencies.md) - Dependency policy and vendored libraries
- [Contributing](docs/contributing.md) - Coding conventions and common tasks
- [Project Structure](docs/project-structure.md) - Codebase layout and key files

## Current Status

**Phase:** Phase 1 complete

**Completed:**
- `build.zig` with SQLite compilation and static asset embedding
- `vendor/` with permissively licensed third-party code and `lib/` with pinned Publr libraries
- `src/main.zig` with CLI (serve command, --port, --dev flags, PORT env var)
- `src/http.zig` with HTTP server (/, /admin, /static/*)
- Graceful shutdown on SIGINT/SIGTERM
- Thread-per-connection request handling

**Next steps:**
1. Add router with path parameters
2. Add middleware pattern
3. Build admin authentication

### Shared UI icons

CMS consumes [`publr-icons`](https://github.com/publr-org/publr-icons) through
the checked-in `lib/publr_icons.zig` adapter. There is no npm package,
submodule, build-time network access, or runtime fetch. Upgrades are explicit:

```sh
./scripts/update-icons.sh
zig build test
```

The updater pins both a Git revision and SHA-256 checksum.

## Resources

- [Zig Documentation](https://ziglang.org/documentation/master/)
- [SQLite C Interface](https://sqlite.org/c3ref/intro.html)
