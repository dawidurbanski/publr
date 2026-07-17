#!/bin/sh
set -eu

# Explicit dependency update: normal CMS builds are offline and npm-free.
REVISION="832eebe"
SHA256="b7f4d1f9acaaf206b677349a187e07cff6f915e45ebf751defdd415562300cef"
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
