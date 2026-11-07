#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h:h:h}"
INFO_PLIST="$ROOT_DIR/macos/Resources/Info.plist"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
DEFAULT_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
VERSION="${LITHE_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${LITHE_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
ARCH="${LITHE_ARCH:-universal}"
DIST_ROOT="${LITHE_DIST_ROOT:-$ROOT_DIR/dist}"
SIGNING_IDENTITY="${LITHE_CODESIGN_IDENTITY:--}"
ARM64_TRIPLE="arm64-apple-macosx"
X86_64_TRIPLE="x86_64-apple-macosx"
MARKETPLACE_INDEX="${LITHE_OFFICIAL_PLUGIN_INDEX:-$ROOT_DIR/Plugins/marketplace/index.json}"

case "$ARCH" in
    universal) APP_DIR="$DIST_ROOT/Lithe.app" ;;
    arm64|x86_64) APP_DIR="$DIST_ROOT/Lithe-$ARCH.app" ;;
    *) print -u2 -- "Unsupported app architecture: $ARCH"; exit 1 ;;
esac

cd "$ROOT_DIR"
if [[ "$ARCH" == "universal" ]]; then
    scripts/macos/build/build-macos.sh --configuration release --triple "$ARM64_TRIPLE"
    scripts/macos/build/build-macos.sh --configuration release --triple "$X86_64_TRIPLE"
else
    triple="$ARCH-apple-macosx"
    scripts/macos/build/build-macos.sh --configuration release --triple "$triple"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

ide_mcp=$(LITHE_ARCH="$ARCH" "$ROOT_DIR/scripts/ide-mcp/build-ide-mcp.sh")
mkdir -p "$APP_DIR/Contents/Helpers"
cp "$ide_mcp" "$APP_DIR/Contents/Helpers/lithe-mcp"
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
if [[ "$ARCH" == "universal" ]]; then
    swiftpm_resource_root="$ROOT_DIR/.build/$ARM64_TRIPLE/release"
else
    swiftpm_resource_root="$ROOT_DIR/.build/$ARCH-apple-macosx/release"
fi
# SwiftTerm compiles its Metal shaders from this SwiftPM bundle at runtime.
# Without it, setUseMetal(true) falls back to Core Graphics in packaged apps.
for bundle_name in Lithe_Lithe.bundle SwiftTerm_SwiftTerm.bundle; do
    resource_bundle="$swiftpm_resource_root/$bundle_name"
    if [[ ! -d "$resource_bundle" ]]; then
        print -u2 -- "Missing SwiftPM resource bundle: $resource_bundle"
        exit 1
    fi
    cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/$bundle_name"
done
# The app bundles no official plugin package: language, build and VCS plugins
# are community plugins installed from Lithe Store into Application Support.

# Remote workspace servers ship read-only; Lithe uploads them to SSH hosts
# and never writes into this directory.
remote_server_root=$(scripts/remote/build-remote-servers.sh)
cp -R "$remote_server_root" "$APP_DIR/Contents/Resources/RemoteServers"

# The official marketplace index ships read-only so the catalog works
# offline; refreshed copies are written to the user's Caches at runtime.
mkdir -p "$APP_DIR/Contents/Resources/PluginMarketplace"
cp "$MARKETPLACE_INDEX" "$APP_DIR/Contents/Resources/PluginMarketplace/index.json"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
zsh "$ROOT_DIR/scripts/macos/package/embed-sparkle.sh" "$APP_DIR"
zsh "$ROOT_DIR/scripts/macos/package/configure-sparkle-app.sh" "$APP_DIR/Contents/Info.plist" "$ARCH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
"$ROOT_DIR/scripts/macos/package/stamp-macos-app-build-info.sh" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/macos/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$ROOT_DIR/macos/Resources/IDEAIcons" "$APP_DIR/Contents/Resources/IDEAIcons"
cp -R "$ROOT_DIR/macos/Resources/GitGraph" "$APP_DIR/Contents/Resources/GitGraph"
cp -R "$ROOT_DIR/macos/Resources/Fonts" "$APP_DIR/Contents/Resources/Fonts"
cp -R "$ROOT_DIR/.artifacts/editor/macos" "$APP_DIR/Contents/Resources/MonacoEditor"
zsh "$ROOT_DIR/scripts/macos/package/package-macos-localizations.sh" \
    "$ROOT_DIR/macos/Resources" "$APP_DIR/Contents/Resources"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "$APP_DIR"
