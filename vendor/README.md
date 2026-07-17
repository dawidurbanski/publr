# Vendored third-party software

Each third-party library or compatibility asset lives in its own directory.
Its license, public-domain notice, and any provenance files are kept beside the
distributed source or asset.

- `sqlite/` — SQLite amalgamation and public-domain notice
- `stb/` — stb image libraries and dual MIT/public-domain license
- `libwebp/` — libwebp amalgamation, BSD license, patent grant, and provenance
- `tailwindcss/` — modified Preflight compatibility asset and MIT license

Publr-owned generated libraries belong in `lib/`, not `vendor/`. See
`THIRD_PARTY_NOTICES.md` for the distribution-wide inventory.
