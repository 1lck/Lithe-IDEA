#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Lithe.app"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
DEFAULT_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
VERSION="${LITHE_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${LITHE_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"

cd "$ROOT_DIR"
swift build --configuration release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/Lithe" "$APP_DIR/Contents/MacOS/Lithe"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$ROOT_DIR/Resources/IDEAIcons" "$APP_DIR/Contents/Resources/IDEAIcons"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
