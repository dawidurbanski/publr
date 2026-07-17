#!/bin/sh
set -eu

# Explicit dependency update: normal CMS builds are offline and npm-free.
REVISION="365ca0e"
SHA256="96673acc28e4b8a1e9a19f1f88b7c00ba71f7c84bb936cf34495c67a73ba2337"
URL="https://raw.githubusercontent.com/publr-org/publr-icons/${REVISION}/publr_icons.zig"
TARGET="lib/publr_icons.zig"
TEMP="${TARGET}.tmp"

mkdir -p vendor
curl --fail --location --silent --show-error "$URL" --output "$TEMP"

ACTUAL="$(shasum -a 256 "$TEMP" | cut -d ' ' -f 1)"
if [ "$ACTUAL" != "$SHA256" ]; then
  rm -f "$TEMP"
  echo "publr-icons checksum mismatch: expected $SHA256, got $ACTUAL" >&2
  exit 1
fi

mv "$TEMP" "$TARGET"
echo "Updated $TARGET to publr-icons@$REVISION"
