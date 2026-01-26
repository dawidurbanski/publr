# Dependencies

## The Curated Exceptions List

This project has exactly two external dependencies, both vendored as single C files:

| File | Purpose | Lines | License |
|------|---------|-------|---------|
| `vendor/sqlite3.c` + `.h` | Database | ~250k | Public domain |
| `vendor/stb_image.h` | Image decode | ~8k | Public domain |
| `vendor/stb_image_resize2.h` | Image resize | ~3k | Public domain |
| `vendor/stb_image_write.h` | Image encode | ~2k | Public domain |

**Total external code:** ~263k lines of C, all public domain, all vendored.

## Decision Flow

```
                    ┌─────────────────────────┐
                    │  "I need functionality  │
                    │   not in Zig std..."    │
                    └───────────┬─────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │ Can we implement it in  │
                    │ <500 lines of Zig?      │
                    └───────────┬─────────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
                   YES                      NO
                    │                       │
                    ▼                       ▼
            ┌───────────────┐   ┌─────────────────────────┐
            │ Write it      │   │ Is this critical infra? │
            │ ourselves     │   │ (DB, crypto, images)    │
            └───────────────┘   └───────────┬─────────────┘
                                            │
                                ┌───────────┴───────────┐
                                │                       │
                               YES                      NO
                                │                       │
                                ▼                       ▼
                    ┌─────────────────────┐   ┌───────────────────┐
                    │ Find a C library... │   │ Write it ourselves│
                    └─────────┬───────────┘   │ (even if >500 LOC)│
                              │               └───────────────────┘
                              ▼
                    ┌─────────────────────────┐
                    │ Single file or          │────NO───┐
                    │ amalgamation available? │         │
                    └───────────┬─────────────┘         │
                               YES                      │
                                │                       │
                                ▼                       │
                    ┌─────────────────────────┐         │
                    │ Zero transitive         │────NO───┤
                    │ dependencies?           │         │
                    └───────────┬─────────────┘         │
                               YES                      │
                                │                       │
                                ▼                       │
                    ┌─────────────────────────┐         │
                    │ Public domain, MIT,     │────NO───┤
                    │ or BSD license?         │         │
                    └───────────┬─────────────┘         │
                               YES                      │
                                │                       │
                                ▼                       │
                    ┌─────────────────────────┐         │
                    │ Battle-tested?          │────NO───┤
                    │ (10+ years OR widely    │         │
                    │ adopted in industry)    │         │
                    └───────────┬─────────────┘         │
                               YES                      │
                                │                       │
                                ▼                       ▼
                    ┌─────────────────────┐   ┌───────────────────┐
                    │ ✓ VENDOR IT         │   │ ✗ REJECTED        │
                    │                     │   │                   │
                    │ • Copy to vendor/   │   │ Write it yourself │
                    │ • Document in table │   │ or find another   │
                    │ • Add to build.zig  │   │ approach          │
                    └─────────────────────┘   └───────────────────┘
```

## Decision Examples

| Need | Decision | Reasoning |
|------|----------|-----------|
| JSON parsing | Use Zig std | `std.json` exists |
| HTTP server | Use Zig std | `std.http.Server` exists |
| UUID generation | Write ourselves | ~50 lines of Zig |
| Password hashing | Use Zig std | `std.crypto.pwhash` exists |
| Database | ✓ Vendor SQLite | Critical infra, passes all criteria |
| Image resize | ✓ Vendor stb_image | Critical infra, passes all criteria |
| Markdown parsing | Write ourselves | Not critical, ~800 lines |
| WebSocket | Write ourselves | Not critical, ~400 lines on top of std |
| YAML config | REJECTED | Just use JSON, no need |
| libcurl | REJECTED | Has deps, use `std.http.Client` |
| OpenSSL | REJECTED | Massive, has deps, use `std.crypto` |
| libpng | REJECTED | stb_image already covers this |
| zlib | Use Zig std | `std.compress.zlib` exists |

## The Nuclear Option

Any approved dependency can be replaced with a pure Zig implementation if:
- We have time and motivation
- The Zig implementation passes equivalent test coverage
- Performance is acceptable (within 2x of C version)

This is explicitly allowed and encouraged long-term. SQLite and stb_image are "best available solution today," not permanent decisions.
