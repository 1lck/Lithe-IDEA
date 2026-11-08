#!/bin/zsh
# Packages the Lithe desktop client for macOS:
#
#   scripts/desktop/package-desktop.sh [--arch arm64|amd64] [--format app,zip,dmg] [--out DIR] [--no-sign]
#
# The program is built with the release core and the [app] version of desktop/viva.toml written
# into main.version, then handed to viva package --program, which makes the bundle and the
# archives next to it:
#
#   DIR/Lithe Desktop.app
#   DIR/lithe-<version>-darwin-<arch>.zip   with --format ...zip
#   DIR/lithe-<version>-darwin-<arch>.dmg   with --format ...dmg
#
# DIR defaults to dist/desktop/<arch>/. Only the files above are replaced in it; nothing else in
# DIR is removed. viva package signs with
# $APPLE_SIGNING_IDENTITY and notarizes when the notary credentials are set; --no-sign skips
# both. Everything is written below DIR, never into the source tree.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
VIVA_VERSION="v0.4.0"
ARCH="$(go env GOARCH)"
FORMATS="app,zip,dmg"
OUT_DIR=""
SIGN_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --format) FORMATS="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --no-sign) SIGN_ARGS=(--no-sign); shift ;;
        *) print -u2 -- "Usage: $0 [--arch arm64|amd64] [--format app,zip,dmg] [--out DIR] [--no-sign]"; exit 2 ;;
    esac
done
case "$ARCH" in
    arm64|amd64) ;;
    *) print -u2 -- "--arch must be arm64 or amd64, not $ARCH."; exit 2 ;;
esac

MANIFEST="$ROOT_DIR/desktop/viva.toml"
VERSION="$(sed -n 's/^version = "\([0-9.]*\)"$/\1/p' "$MANIFEST")"
if [[ -z "$VERSION" ]]; then
    print -u2 -- "$MANIFEST has no [app] version line of the form version = \"MAJOR.MINOR.PATCH\"."
    exit 1
fi
OUT_DIR="${${OUT_DIR:-$ROOT_DIR/dist/desktop/$ARCH}:A}"
APP="$OUT_DIR/Lithe Desktop.app"
STEM="lithe-$VERSION-darwin-$ARCH"
PROGRAM="$OUT_DIR/lithe"
mkdir -p "$OUT_DIR"
rm -rf -- "$APP"
rm -f -- "$OUT_DIR/$STEM.zip" "$OUT_DIR/$STEM.dmg" "$PROGRAM"

# -trimpath and -s -w keep build paths and symbols of this machine out of the released program.
GOARCH="$ARCH" LITHE_DESKTOP_CORE_PROFILE=release "$ROOT_DIR/scripts/desktop/desktop-go.sh" build \
    -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$PROGRAM" ./cmd/lithe

# viva package only copies the program into the bundle, so it runs without the cgo setup and
# for the host architecture whatever --arch is.
cd "$ROOT_DIR/desktop"
env -u GOARCH go run "github.com/vivaui/viva/cmd/viva@$VIVA_VERSION" package \
    --target darwin --arch "$ARCH" --program "$PROGRAM" --format "$FORMATS" \
    -o "$APP" "${SIGN_ARGS[@]}"
rm -f -- "$PROGRAM"
print -r -- "$OUT_DIR"
