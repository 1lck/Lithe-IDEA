#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Lithe.app"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
VERSION="${LITHE_VERSION:-$DEFAULT_VERSION}"
DMG_PATH="$ROOT_DIR/dist/Lithe-${VERSION}.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lithe-dmg.XXXXXX")"

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
