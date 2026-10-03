#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CONFIGURATION="debug"
TRIPLE=""
OUTPUT_DIR=""
SIGNING_IDENTITY="${LITHE_CODESIGN_IDENTITY:--}"
PLUGIN_ID=""
BUNDLED_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --triple) TRIPLE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --bundled-only) BUNDLED_ONLY=true; shift ;;
        --plugin-id) PLUGIN_ID="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 --triple triple [--configuration debug|release] [--output directory] [--plugin-id id]"; exit 2 ;;
    esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    print -u2 -- "Unsupported configuration: $CONFIGURATION"
    exit 2
fi
case "$TRIPLE" in
    arm64-apple-macosx) TARGET="arm64-apple-macosx13.0" ;;
    x86_64-apple-macosx) TARGET="x86_64-apple-macosx13.0" ;;
    *) print -u2 -- "Unsupported macOS Swift triple: $TRIPLE"; exit 2 ;;
esac

SWIFT_LAYOUT_ARGS=(
    --triple "$TRIPLE"
    --configuration "$CONFIGURATION"
)
SWIFT_BIN_PATH=$(swift build --show-bin-path "${SWIFT_LAYOUT_ARGS[@]}")
if [[ -e "$SWIFT_BIN_PATH/Modules/LitheModuleAPI.swiftmodule" && \
      -e "$SWIFT_BIN_PATH/Modules/LitheCoreContracts.swiftmodule" ]]; then
    MODULE_DIR="$SWIFT_BIN_PATH/Modules"
else
    # SwiftPM 6.4 places package modules directly beside the executable.
    MODULE_DIR="$SWIFT_BIN_PATH"
fi
if [[ ! -e "$MODULE_DIR/LitheModuleAPI.swiftmodule" || ! -e "$MODULE_DIR/LitheCoreContracts.swiftmodule" ]]; then
    print -u2 -- "Build Lithe for $TRIPLE ($CONFIGURATION) before packaging official plugins"
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$SWIFT_BIN_PATH/OfficialPlugins"
fi
# Match the host build's explicit SDK when multiple SDKs are installed.
SDK_PATH="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
if ! SWIFT_COMPILER=$(command -v swiftc); then
    print -u2 -- "Swift compiler is not available on PATH"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
for stale_package in "$OUTPUT_DIR"/*(/N); do
    [[ -f "$stale_package/plugin.json" ]] || continue
    rm -rf "$stale_package"
done
matched=0
signer_binary=""
for plugin_source in "$ROOT_DIR"/Plugins/mac/Official/*(/N); do
    manifest="$plugin_source/plugin.json"
    info_plist="$plugin_source/Info.plist"
    [[ -f "$manifest" && -f "$info_plist" ]] || continue
    package_id=$(/usr/bin/plutil -extract id raw "$manifest")
    if [[ -n "$PLUGIN_ID" && "$package_id" != "$PLUGIN_ID" ]]; then
        continue
    fi
    if [[ "$BUNDLED_ONLY" == true ]] && ! node "$ROOT_DIR/scripts/official-plugin-distribution.mjs" "$package_id"; then
        continue
    fi
    signature_requirement=$(/usr/bin/plutil -extract vendor.signatureRequirement raw "$manifest")
    if [[ "$signature_requirement" == "publisherPackage" && -z "${LITHE_PLUGIN_PACKAGE_PRIVATE_KEY:-}" ]]; then
        if [[ "$CONFIGURATION" == "release" ]]; then
            print -u2 -- "Configure LITHE_PLUGIN_PACKAGE_PRIVATE_KEY for publisher-signed plugin packages"
            exit 1
        fi
        print -u2 -- "Skipping publisher-signed debug plugin package $package_id; set LITHE_PLUGIN_PACKAGE_PRIVATE_KEY to build it"
        continue
    fi
    matched=$((matched + 1))
    module_suffix="${plugin_source:t}"
    source_dir="$plugin_source/Sources/Lithe${module_suffix}Module"
    source_files=("$source_dir"/**/*.swift(N))
    if (( ${#source_files[@]} == 0 )); then
        print -u2 -- "Official plugin $package_id has no Swift sources at $source_dir"
        exit 1
    fi
    bundle_name=$(/usr/bin/plutil -extract entrypoint.bundlePath raw "$manifest")
    executable_name=$(/usr/bin/plutil -extract CFBundleExecutable raw "$info_plist")
    package_dir="$OUTPUT_DIR/$package_id"
    bundle_dir="$package_dir/$bundle_name"
    executable_dir="$bundle_dir/Contents/MacOS"

    rm -rf "$package_dir"
    mkdir -p "$executable_dir"
    cp "$manifest" "$package_dir/plugin.json"
    if [[ "$package_id" == "dev.lithe.plugin.php-support" ]]; then
        language_server_manifest="$plugin_source/language-server.json"
        [[ -f "$language_server_manifest" ]] || {
            print -u2 -- "PHP Support is missing its language-server manifest: $language_server_manifest"
            exit 1
        }
        cp "$language_server_manifest" "$package_dir/language-server.json"
    fi
    cp "$info_plist" "$bundle_dir/Contents/Info.plist"

    "$SWIFT_COMPILER" \
        -emit-library \
        -parse-as-library \
        -module-name "Lithe${module_suffix}Plugin" \
        -swift-version 6 \
        -target "$TARGET" \
        -sdk "$SDK_PATH" \
        -I "$MODULE_DIR" \
        -Xlinker -undefined \
        -Xlinker dynamic_lookup \
        "${source_files[@]}" \
        -o "$executable_dir/$executable_name"

    if [[ "$package_id" == "dev.lithe.plugin.php-support" ]]; then
        "$ROOT_DIR/scripts/prepare-php-language-server.sh" \
            --manifest "$plugin_source/language-server.json" \
            --output "$bundle_dir/Contents/Resources/LanguageServers/php" >&2
    fi

    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$bundle_dir"

    if [[ "$signature_requirement" == "publisherPackage" ]]; then
        if [[ -z "$signer_binary" ]]; then
            swift build \
                "${SWIFT_LAYOUT_ARGS[@]}" \
                --product LithePluginPackageSigner >&2
            signer_bin_dir=$(swift build \
                "${SWIFT_LAYOUT_ARGS[@]}" \
                --show-bin-path)
            signer_binary="$signer_bin_dir/LithePluginPackageSigner"
            [[ -x "$signer_binary" ]] || {
                print -u2 -- "Plugin package signer was not built: $signer_binary"
                exit 1
            }
        fi
        print -rn -- "$LITHE_PLUGIN_PACKAGE_PRIVATE_KEY" | "$signer_binary" "$package_dir"
        "$signer_binary" --verify "$package_dir"
    fi
done

if (( matched == 0 )); then
    if [[ -n "$PLUGIN_ID" ]]; then
        print -u2 -- "No official plugin matched $PLUGIN_ID"
        exit 1
    fi
fi
print -r -- "$OUTPUT_DIR"
