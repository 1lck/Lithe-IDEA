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

for attempt in 1 2 3; do
    if hdiutil create \
        -volname "Lithe" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"; then
        break
    fi
    if (( attempt == 3 )); then
        print -u2 -- "Unable to create disk image after $attempt attempts: $DMG_PATH"
        exit 1
    fi
    # macOS can briefly report the temporary image resource as busy while a
    # previous hdiutil helper exits; retry without changing the package input.
    sleep $((attempt * 2))
done

print -r -- "$DMG_PATH"
