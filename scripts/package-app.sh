#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
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

case "$ARCH" in
    universal) APP_DIR="$DIST_ROOT/Lithe.app" ;;
    arm64|x86_64) APP_DIR="$DIST_ROOT/Lithe-$ARCH.app" ;;
    *) print -u2 -- "Unsupported app architecture: $ARCH"; exit 1 ;;
esac

cd "$ROOT_DIR"
JDTLS_ROOT=$("$ROOT_DIR/scripts/prepare-jdtls.sh")
jdk_arch="$ARCH"
if [[ "$jdk_arch" == "universal" ]]; then
    jdk_arch="$(uname -m)"
fi
JDK_ROOT=$(LITHE_JDK_TARGET_ARCH="$jdk_arch" "$ROOT_DIR/scripts/prepare-jdk.sh")
if [[ "$ARCH" == "universal" ]]; then
    scripts/build-macos.sh --configuration release --triple "$ARM64_TRIPLE"
    scripts/build-macos.sh --configuration release --triple "$X86_64_TRIPLE"
else
    triple="$ARCH-apple-macosx"
    scripts/build-macos.sh --configuration release --triple "$triple"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

database_sidecar="${LITHE_DB_SIDECAR_EXECUTABLE:-}"
if [[ -z "$database_sidecar" && "${LITHE_SKIP_DATABASE_SIDECAR:-0}" != "1" ]]; then
    database_sidecar=$(LITHE_ARCH="$ARCH" "$ROOT_DIR/scripts/build-database-sidecar.sh")
fi
if [[ -n "$database_sidecar" ]]; then
    if [[ ! -x "$database_sidecar" ]]; then
        print -u2 -- "LITHE_DB_SIDECAR_EXECUTABLE is not executable: $database_sidecar"
        exit 1
    fi
    if [[ "$ARCH" == "universal" ]] && ! lipo "$database_sidecar" -verify_arch arm64 -verify_arch x86_64 >/dev/null 2>&1; then
        print -u2 -- "Universal packaging requires a fat database helper with arm64 and x86_64 slices"
        exit 1
    fi
    mkdir -p "$APP_DIR/Contents/Helpers"
    cp "$database_sidecar" "$APP_DIR/Contents/Helpers/lithe-db-sidecar"
fi
database_mcp="${LITHE_DB_MCP_EXECUTABLE:-}"
if [[ -z "$database_mcp" && "${LITHE_SKIP_DATABASE_MCP:-0}" != "1" ]]; then
    database_mcp=$(LITHE_ARCH="$ARCH" "$ROOT_DIR/scripts/build-database-mcp.sh")
fi
if [[ -n "$database_mcp" ]]; then
    if [[ ! -x "$database_mcp" ]]; then
        print -u2 -- "LITHE_DB_MCP_EXECUTABLE is not executable: $database_mcp"
        exit 1
    fi
    if [[ "$ARCH" == "universal" ]] && ! lipo "$database_mcp" -verify_arch arm64 -verify_arch x86_64 >/dev/null 2>&1; then
        print -u2 -- "Universal packaging requires a fat database MCP helper with arm64 and x86_64 slices"
        exit 1
    fi
    mkdir -p "$APP_DIR/Contents/Helpers"
    cp "$database_mcp" "$APP_DIR/Contents/Helpers/lithe-db-mcp"
fi
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
    resource_bundle="$ROOT_DIR/.build/$ARM64_TRIPLE/release/Lithe_Lithe.bundle"
else
    resource_bundle="$ROOT_DIR/.build/$ARCH-apple-macosx/release/Lithe_Lithe.bundle"
fi
if [[ ! -d "$resource_bundle" ]]; then
    print -u2 -- "Missing SwiftPM resource bundle: $resource_bundle"
    exit 1
fi
cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/Lithe_Lithe.bundle"
mkdir -p "$APP_DIR/Contents/Resources/LanguageServers"
cp -R "$JDTLS_ROOT" "$APP_DIR/Contents/Resources/LanguageServers/jdtls"
cp -R "$JDK_ROOT" "$APP_DIR/Contents/Resources/LanguageServers/jdk"

OFFICIAL_PLUGIN_DESTINATION="$APP_DIR/Contents/Resources/OfficialPlugins"
mkdir -p "$OFFICIAL_PLUGIN_DESTINATION"
if [[ "$ARCH" == "universal" ]]; then
    arm64_plugin_root=$(LITHE_CODESIGN_IDENTITY="$SIGNING_IDENTITY" scripts/build-official-plugins.sh \
        --configuration release \
        --triple "$ARM64_TRIPLE")
    x86_64_plugin_root=$(LITHE_CODESIGN_IDENTITY="$SIGNING_IDENTITY" scripts/build-official-plugins.sh \
        --configuration release \
        --triple "$X86_64_TRIPLE")
    for arm64_plugin in "$arm64_plugin_root"/*(/N); do
        plugin_id="${arm64_plugin:t}"
        x86_64_plugin="$x86_64_plugin_root/$plugin_id"
        [[ -d "$x86_64_plugin" ]] || { print -u2 -- "Missing x86_64 plugin package: $plugin_id"; exit 1; }
        cp -R "$arm64_plugin" "$OFFICIAL_PLUGIN_DESTINATION/$plugin_id"
        bundle_path=$(/usr/bin/plutil -extract entrypoint.bundlePath raw "$arm64_plugin/plugin.json")
        executable_name=$(/usr/bin/plutil -extract CFBundleExecutable raw "$arm64_plugin/$bundle_path/Contents/Info.plist")
        plugin_executable="$bundle_path/Contents/MacOS/$executable_name"
        universal_plugin=$(mktemp "$OFFICIAL_PLUGIN_DESTINATION/$plugin_id/.plugin.XXXXXX")
        lipo -create \
            "$arm64_plugin/$plugin_executable" \
            "$x86_64_plugin/$plugin_executable" \
            -output "$universal_plugin"
        mv "$universal_plugin" "$OFFICIAL_PLUGIN_DESTINATION/$plugin_id/$plugin_executable"
        codesign --force --sign "$SIGNING_IDENTITY" \
            "$OFFICIAL_PLUGIN_DESTINATION/$plugin_id/$bundle_path"
    done
else
    plugin_root=$(LITHE_CODESIGN_IDENTITY="$SIGNING_IDENTITY" scripts/build-official-plugins.sh \
        --configuration release \
        --triple "$ARCH-apple-macosx")
    for plugin_package in "$plugin_root"/*(/N); do
        cp -R "$plugin_package" "$OFFICIAL_PLUGIN_DESTINATION/${plugin_package:t}"
    done
fi

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
"$ROOT_DIR/scripts/stamp-macos-app-build-info.sh" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/macos/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$ROOT_DIR/macos/Resources/IDEAIcons" "$APP_DIR/Contents/Resources/IDEAIcons"
cp -R "$ROOT_DIR/macos/Resources/DatabaseIcons" "$APP_DIR/Contents/Resources/DatabaseIcons"
cp -R "$ROOT_DIR/macos/Resources/Fonts" "$APP_DIR/Contents/Resources/Fonts"
for localization in en.lproj zh-Hans.lproj; do
    if [[ -d "$ROOT_DIR/macos/Resources/$localization" ]]; then
        cp -R "$ROOT_DIR/macos/Resources/$localization" "$APP_DIR/Contents/Resources/$localization"
    fi
done
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "$APP_DIR"
