#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
DEFAULT_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
VERSION="${LITHE_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${LITHE_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
ARCH="${LITHE_ARCH:-universal}"
ARM64_TRIPLE="arm64-apple-macosx"
X86_64_TRIPLE="x86_64-apple-macosx"

case "$ARCH" in
    universal) APP_DIR="$ROOT_DIR/dist/Lithe.app" ;;
    arm64|x86_64) APP_DIR="$ROOT_DIR/dist/Lithe-$ARCH.app" ;;
    *) print -u2 -- "Unsupported app architecture: $ARCH"; exit 1 ;;
esac

cd "$ROOT_DIR"
if [[ "$ARCH" == "universal" ]]; then
    scripts/build-macos.sh --configuration release --triple "$ARM64_TRIPLE"
    scripts/build-macos.sh --configuration release --triple "$X86_64_TRIPLE"
else
    triple="$ARCH-apple-macosx"
    scripts/build-macos.sh --configuration release --triple "$triple"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
if [[ "$ARCH" == "universal" ]]; then
    arm64_binary="$ROOT_DIR/.build/$ARM64_TRIPLE/release/Lithe"
    x86_64_binary="$ROOT_DIR/.build/$X86_64_TRIPLE/release/Lithe"
    if [[ ! -x "$arm64_binary" || ! -x "$x86_64_binary" ]]; then
        print -u2 -- "Missing architecture-specific release binary"
        exit 1
    fi
    lipo -create "$arm64_binary" "$x86_64_binary" -output "$APP_DIR/Contents/MacOS/Lithe"
else
    arch_binary="$ROOT_DIR/.build/$ARCH-apple-macosx/release/Lithe"
    if [[ ! -x "$arch_binary" ]]; then
        print -u2 -- "Missing $ARCH release binary"
        exit 1
    fi
    cp "$arch_binary" "$APP_DIR/Contents/MacOS/Lithe"
fi
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$ROOT_DIR/Resources/IDEAIcons" "$APP_DIR/Contents/Resources/IDEAIcons"
for localization in en.lproj zh-Hans.lproj; do
    if [[ -d "$ROOT_DIR/Resources/$localization" ]]; then
        cp -R "$ROOT_DIR/Resources/$localization" "$APP_DIR/Contents/Resources/$localization"
    fi
done
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
