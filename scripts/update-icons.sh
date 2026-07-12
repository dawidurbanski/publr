#!/bin/sh
set -eu

# Explicit dependency update: normal CMS builds are offline and npm-free.
REVISION="bb2b18e"
SHA256="dd8673d57eab83c1b5ace1d5f81ba2fb6b2e354b8f1f9b23207f2ad6db103cba"
URL="https://raw.githubusercontent.com/publr-org/publr-icons/${REVISION}/publr_icons.zig"
TARGET="vendor/publr_icons.zig"
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
