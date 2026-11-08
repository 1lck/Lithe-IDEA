#!/bin/zsh
# Packages and verifies one architecture of a Desktop Release:
#
#   package-release.sh <arm64|amd64> <version>
#
# Signing comes from the environment, as viva package reads it: APPLE_CERTIFICATE (a base64
# .p12), APPLE_CERTIFICATE_PASSWORD and, optionally, APPLE_SIGNING_IDENTITY. With none of them
# set the package is unsigned; a partial set is refused rather than silently left unsigned.
# The app, zip and dmg are written to dist/desktop/<arch>/, each archive with a .sha256 next to
# it, and checked: the bundle version, the architecture of the program and the version stamped
# into it, the signature when there is one, and that the disk image opens.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h:h}"
if [[ $# -ne 2 ]]; then
    print -u2 -- "Usage: $0 <arm64|amd64> <version>"
    exit 2
fi
ARCH="$1"
VERSION="$2"
case "$ARCH" in
    arm64) MACHO_ARCH="arm64" ;;
    amd64) MACHO_ARCH="x86_64" ;;
    *) print -u2 -- "The architecture must be arm64 or amd64, not $ARCH."; exit 2 ;;
esac

SIGN_ARGS=()
if [[ -n "${APPLE_CERTIFICATE:-}" ]]; then
    if [[ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]]; then
        print -u2 -- "APPLE_CERTIFICATE is set without APPLE_CERTIFICATE_PASSWORD."
        exit 1
    fi
    SIGNED=1
elif [[ -n "${APPLE_CERTIFICATE_PASSWORD:-}" || -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    print -u2 -- "Incomplete signing configuration: provide APPLE_CERTIFICATE, or remove the password and identity."
    exit 1
else
    print -r -- "No signing certificate is configured; the package is unsigned."
    SIGN_ARGS=(--no-sign)
    SIGNED=0
fi

OUT_DIR="$ROOT_DIR/dist/desktop/$ARCH"
"$ROOT_DIR/scripts/desktop/package-desktop.sh" --arch "$ARCH" --format app,zip,dmg --out "$OUT_DIR" "${SIGN_ARGS[@]}"

APP="$OUT_DIR/Lithe Desktop.app"
STEM="lithe-$VERSION-darwin-$ARCH"
PLIST="$APP/Contents/Info.plist"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
    print -u2 -- "The bundle says version $BUNDLE_VERSION, not $VERSION."
    exit 1
fi
EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")"
lipo "$APP/Contents/MacOS/$EXECUTABLE" -verify_arch "$MACHO_ARCH"
# The client shows main.version, which the build stamps; -trimpath keeps -ldflags out of the
# build info, so the stamped string itself is looked for.
if ! strings -a "$APP/Contents/MacOS/$EXECUTABLE" | grep -qxF -- "$VERSION"; then
    print -u2 -- "The program does not carry version $VERSION; check the -X main.version stamp."
    exit 1
fi
if [[ "$SIGNED" == 1 ]]; then
    codesign --verify --deep --strict "$APP"
fi
# diskutil image replaces the deprecated hdiutil imageinfo, which older runners still need.
diskutil image info "$OUT_DIR/$STEM.dmg" > /dev/null 2>&1 || hdiutil imageinfo "$OUT_DIR/$STEM.dmg" > /dev/null
for archive in "$STEM.zip" "$STEM.dmg"; do
    test -s "$OUT_DIR/$archive"
    (cd "$OUT_DIR" && shasum -a 256 "$archive" > "$archive.sha256" && shasum -a 256 -c "$archive.sha256")
done
