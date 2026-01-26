# zig-cms

A single-file CMS written in Zig. Zero dependencies, one binary, one SQLite database.

## Philosophy

No frameworks, no npm, no external dependencies. Every line of code is ours. Target ~4,000 lines of Zig total.

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
- `vendor/` with SQLite amalgamation and stb_image headers
- `src/main.zig` with CLI (serve command, --port, --dev flags, PORT env var)
- `src/http.zig` with HTTP server (/, /admin, /static/*)
- Graceful shutdown on SIGINT/SIGTERM
- Thread-per-connection request handling

**Next steps:**
1. Add router with path parameters
2. Add middleware pattern
3. Build admin authentication

## Resources

- [Zig Documentation](https://ziglang.org/documentation/master/)
- [SQLite C Interface](https://sqlite.org/c3ref/intro.html)
