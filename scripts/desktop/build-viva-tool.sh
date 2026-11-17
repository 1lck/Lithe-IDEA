#!/usr/bin/env bash
# Builds the viva command the desktop client is packaged and its update feeds are signed with, and
# prints its path:
#
# Usage: scripts/desktop/build-viva-tool.sh
#
# desktop/go.mod (its require and replace) is the only place the Viva source is pinned; the tool is
# built from that same source, the Lithe-IDEA/viva fork through the replace, because
# "go install <module>@<version>" ignores replace directives. The download honours the replace and
# fills the module cache, and the Dir lookup names the directory of the source that gets built. The
# tool is built for the host, whatever GOOS and GOARCH the caller packages for.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

go -C "$ROOT_DIR/desktop" mod download github.com/vivaui/viva
VIVA_DIR="$(go -C "$ROOT_DIR/desktop" list -m -f '{{.Dir}}' github.com/vivaui/viva)"
# The version of the source actually built (the fork's pseudo-version, which names the commit) is the
# tool cache key; a replacement by a local directory has no version.
VIVA_VERSION="$(go -C "$ROOT_DIR/desktop" list -m -f '{{if .Replace}}{{.Replace.Version}}{{else}}{{.Version}}{{end}}' github.com/vivaui/viva)"

# This versioned host-tool cache is writable build state owned by the worktree; it remains until the
# worktree or .artifacts/desktop/tools is removed. Viva uses it only while packaging or signing a
# feed; it is never copied into the app bundle or installed app, so it cannot affect code signing or
# Sparkle delta inputs.
if [[ -n "$VIVA_VERSION" ]]; then
    VIVA_BIN_DIR="$ROOT_DIR/.artifacts/desktop/tools/viva-$VIVA_VERSION"
else
    VIVA_BIN_DIR="$ROOT_DIR/.artifacts/desktop/tools/viva-local"
fi
mkdir -p "$VIVA_BIN_DIR"
VIVA_BIN_NAME="viva"
if [[ "$(go env GOHOSTOS)" == "windows" ]]; then
    VIVA_BIN_NAME="viva.exe"
fi
VIVA_BIN="$VIVA_BIN_DIR/$VIVA_BIN_NAME"
if [[ -z "$VIVA_VERSION" ]]; then
    # A local-directory replacement has no version to key the cache and its source can change: rebuild.
    rm -f -- "$VIVA_BIN"
fi
if [[ ! -f "$VIVA_BIN" ]]; then
    (
        unset GOOS GOARCH CGO_ENABLED CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_FFLAGS CGO_LDFLAGS \
            CGO_CFLAGS_ALLOW CGO_CFLAGS_DISALLOW CGO_LDFLAGS_ALLOW CGO_LDFLAGS_DISALLOW \
            CC GCCGO CXX FC PKG_CONFIG
        # -C makes -o relative to VIVA_DIR, so it must be absolute; VIVA_DIR already comes from go.
        go -C "$VIVA_DIR" build -o "$(native_path "$VIVA_BIN")" ./cmd/viva
    ) >&2
fi
if [[ ! -f "$VIVA_BIN" ]]; then
    printf '%s\n' "go build did not create the Viva tool at $VIVA_BIN." >&2
    exit 1
fi
printf '%s\n' "$VIVA_BIN"
