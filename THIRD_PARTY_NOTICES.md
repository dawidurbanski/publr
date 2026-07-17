# Third-party software in Publr core

This inventory covers third-party code and compatibility assets distributed as
part of Publr core. Userland plugins and Publr-owned repositories are outside
its scope.

## SQLite 3.45.0

SQLite provides the embedded database. Its authors dedicate the source to the
public domain. The public-domain declaration is retained in the source files
and summarized in `vendor/sqlite/LICENSE.md`.

Upstream: <https://sqlite.org/>

## stb image libraries

Publr uses stb_image 2.30, stb_image_resize2 2.17, and stb_image_write 1.16 for
image decoding, resizing, and encoding. These files are available under a
choice of the MIT License or public-domain dedication; the complete terms are
retained in each vendored header and in `vendor/stb/LICENSE.txt`.

Upstream: <https://github.com/nothings/stb>

## libwebp 1.6.0

Publr uses libwebp for WebP encoding. It is distributed under a BSD 3-Clause
license with an additional patent grant.

Copyright (c) 2010, Google Inc. All rights reserved.

Upstream: <https://chromium.googlesource.com/webm/libwebp>

Vendored provenance and complete terms:

- `vendor/libwebp/VERSION`
- `vendor/libwebp/COPYING`
- `vendor/libwebp/PATENTS`
- `vendor/libwebp/AUTHORS`

## Tailwind CSS 4.2.2

Publr's Zig class compiler is an independent implementation. It does not
contain or derive from Tailwind CSS compiler source code. It accepts many of
the same class strings and aims to produce CSS with equivalent browser-visible
behavior, although generated CSS is not necessarily byte-for-byte identical.

The only incorporated Tailwind CSS material is the modified compatibility
reset in `vendor/tailwindcss/preflight.css`.

Copyright (c) Tailwind Labs, Inc.

Upstream: <https://github.com/tailwindlabs/tailwindcss/tree/v4.2.2>

License: MIT; see `vendor/tailwindcss/LICENSE.txt`.

The covered material is provided **as is**, without warranty; the bundled MIT
license contains the complete permission notice and warranty/liability
disclaimer.

## Browser bundle toolchain archives

The optional browser-source bundle contains precompiled Zig runtime and WASI
libc support archives. These are browser compilation support files, not Publr
core dependencies. The bundle generator copies the applicable Zig, musl, and
WASI libc license and copyright files from the toolchain used to produce the
archives into `vendor/zig/` beside them.
