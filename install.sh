#!/bin/sh
# Publr installer: detects your OS and CPU, downloads the matching binary, verifies it, puts it on PATH.
#   curl -fsSL https://publr.dev/install.sh | sh
# Optional: PUBLR_VERSION=v0.2.0 (default: latest), PUBLR_INSTALL_DIR=/some/bin (default: ~/.local/bin)
#
# Trust: this script is only as trustworthy as where you got it. The README publishes its SHA-256 and a
# tag-pinned GitHub URL; verify before running if that matters to you. The binary's own checksum is
# checked below against the .sha256 published with the release.
set -eu

repo="https://github.com/publr-org/publr/releases"
version="${PUBLR_VERSION:-latest}"
dir="${PUBLR_INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)  os="linux" ;;
    *) echo "publr: unsupported OS '$(uname -s)'; download a build from $repo" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) echo "publr: unsupported CPU '$(uname -m)'; download a build from $repo" >&2; exit 1 ;;
esac

file="publr-$os-$arch"
if [ "$version" = "latest" ]; then
    url="$repo/latest/download/$file"
else
    url="$repo/download/$version/$file"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "publr: downloading $url"
curl -fsSL "$url" -o "$tmp/publr"
curl -fsSL "$url.sha256" -o "$tmp/publr.sha256"

expected="$(cut -d' ' -f1 < "$tmp/publr.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tmp/publr" | cut -d' ' -f1)"
else
    actual="$(shasum -a 256 "$tmp/publr" | cut -d' ' -f1)"
fi
if [ "$expected" != "$actual" ]; then
    echo "publr: checksum mismatch, refusing to install" >&2
    exit 1
fi

mkdir -p "$dir"
install -m 755 "$tmp/publr" "$dir/publr"

echo "publr: installed $("$dir/publr" --version) to $dir/publr"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "publr: add $dir to your PATH, for example: export PATH=\"$dir:\$PATH\"" ;;
esac
echo
echo "Next:"
echo "  publr serve                                             # start on http://127.0.0.1:8080"
echo "  publr init --email you@example.com --display_name You   # create the first admin"
