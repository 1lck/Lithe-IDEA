#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INFO_PLIST="$ROOT_DIR/macos/Resources/Info.plist"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
VERSION="${LITHE_VERSION:-$DEFAULT_VERSION}"
ARCH="${LITHE_ARCH:-universal}"
DIST_ROOT="${LITHE_DIST_ROOT:-$ROOT_DIR/dist}"
case "$ARCH" in
    universal)
        APP_DIR="$DIST_ROOT/Lithe.app"
        DMG_PATH="$DIST_ROOT/Lithe-${VERSION}.dmg"
        ;;
    arm64|x86_64)
        APP_DIR="$DIST_ROOT/Lithe-$ARCH.app"
        DMG_PATH="$DIST_ROOT/Lithe-${VERSION}-${ARCH}.dmg"
        ;;
    *)
        print -u2 -- "Unsupported app architecture: $ARCH"
        exit 1
        ;;
esac
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lithe-dmg.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT

if [[ ! -d "$APP_DIR" ]]; then
    print -u2 -- "Missing app bundle: $APP_DIR"
    exit 1
fi

cp -R "$APP_DIR" "$STAGING_DIR/Lithe.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Lithe" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

print -r -- "$DMG_PATH"
