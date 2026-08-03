#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Lithe.app"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
DEFAULT_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
VERSION="${LITHE_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${LITHE_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
ARM64_TRIPLE="arm64-apple-macosx"
X86_64_TRIPLE="x86_64-apple-macosx"

cd "$ROOT_DIR"
swift build --configuration release --disable-sandbox --triple "$ARM64_TRIPLE"
swift build --configuration release --disable-sandbox --triple "$X86_64_TRIPLE"

ARM64_BINARY="$ROOT_DIR/.build/$ARM64_TRIPLE/release/Lithe"
X86_64_BINARY="$ROOT_DIR/.build/$X86_64_TRIPLE/release/Lithe"
if [[ ! -x "$ARM64_BINARY" || ! -x "$X86_64_BINARY" ]]; then
    print -u2 -- "Missing architecture-specific release binary"
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$APP_DIR/Contents/MacOS/Lithe"
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
