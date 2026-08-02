#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Lithe.app"

cd "$ROOT_DIR"
swift build --configuration release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/Lithe" "$APP_DIR/Contents/MacOS/Lithe"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$ROOT_DIR/Resources/IDEAIcons" "$APP_DIR/Contents/Resources/IDEAIcons"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
