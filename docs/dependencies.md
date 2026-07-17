# Dependencies

## The Curated Exceptions List

This project has exactly three external dependencies, all vendored:

| File | Purpose | Lines | License |
|------|---------|-------|---------|
| `vendor/sqlite/` | Database | ~250k | Public domain |
| `vendor/stb/stb_image.h` | Image decode | ~8k | MIT or public domain |
| `vendor/stb/stb_image_resize2.h` | Image resize | ~3k | MIT or public domain |
| `vendor/stb/stb_image_write.h` | Image encode | ~2k | MIT or public domain |
| `vendor/libwebp/` | WebP encoding | ~64k | BSD-3-Clause |

**Total external code:** ~323k lines of C, all permissively licensed, all vendored.

## First-party libraries

Generated libraries maintained in other Publr repositories live in `lib/`,
not `vendor/`. They are first-party Apache-2.0 code and are covered by the
CMS distribution's root license:

- `lib/zsx.zig`
- `lib/publr_ui.zig`
- `lib/publr_icons.zig`
- `lib/publr_jit.zig`

`vendor/` is reserved for third-party code and derived third-party assets.
Each library has its own directory, with its license and provenance files
beside its source. `THIRD_PARTY_NOTICES.md` provides the consolidated inventory.

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
                    │ • Copy to vendor/x/ │   │ Write it yourself │
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
| WebP encoding | ✓ Vendor libwebp | Critical infra (image optimization), BSD-3, widely adopted |
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
