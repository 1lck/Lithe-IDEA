#!/bin/zsh

set -euo pipefail

# Assembles official declarative plugin packages (plugin contract v1). A
# package holds plugin.json plus the resources it declares; it contains no
# host-loaded code and is not rebuilt against a particular Lithe binary. A
# package that ships its own runtime (Java Support) is assembled for the
# architectures given by --arch; every other package is identical for all. See
# .agents/notes/implemented/architecture/2026-10-12-declarative-language-plugins.md.

ROOT_DIR="${0:A:h:h}"
CONFIGURATION="debug"
TRIPLE=""
OUTPUT_DIR=""
PLUGIN_ID=""
BUNDLED_ONLY=false
# Architectures a package's own runtime is assembled for: arm64, x86_64, or
# universal. Defaults to the architecture of --triple.
RUNTIME_ARCH=""
# Development builds of Lithe accept unsigned packages installed from disk.
# This flag builds publisher-signed plugins without the release key for that
# local path only; release configuration rejects it.
DEVELOPMENT_UNSIGNED=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --triple) TRIPLE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --bundled-only) BUNDLED_ONLY=true; shift ;;
        --plugin-id) PLUGIN_ID="$2"; shift 2 ;;
        --arch) RUNTIME_ARCH="$2"; shift 2 ;;
        --development-unsigned) DEVELOPMENT_UNSIGNED=true; shift ;;
        *) print -u2 -- "Usage: $0 --triple triple [--configuration debug|release] [--output directory] [--plugin-id id] [--arch arm64|x86_64|universal] [--bundled-only] [--development-unsigned]"; exit 2 ;;
    esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    print -u2 -- "Unsupported configuration: $CONFIGURATION"
    exit 2
fi
if [[ "$DEVELOPMENT_UNSIGNED" == true && "$CONFIGURATION" != "debug" ]]; then
    print -u2 -- "--development-unsigned is only available for debug plugin builds"
    exit 2
fi
# The triple only selects the SwiftPM layout for the default output directory
# and the package signer; plugin packages themselves are architecture-neutral.
case "$TRIPLE" in
    arm64-apple-macosx|x86_64-apple-macosx) ;;
    *) print -u2 -- "Unsupported macOS Swift triple: $TRIPLE"; exit 2 ;;
esac

if [[ -z "$RUNTIME_ARCH" ]]; then
    RUNTIME_ARCH="${TRIPLE%%-*}"
fi
case "$RUNTIME_ARCH" in
    arm64|x86_64|universal) ;;
    *) print -u2 -- "Unsupported runtime architecture: $RUNTIME_ARCH"; exit 2 ;;
esac

SWIFT_LAYOUT_ARGS=(
    --triple "$TRIPLE"
    --configuration "$CONFIGURATION"
)
SWIFT_BIN_PATH=$(swift build --show-bin-path "${SWIFT_LAYOUT_ARGS[@]}")
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$SWIFT_BIN_PATH/OfficialPlugins"
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
    [[ -f "$manifest" ]] || continue
    package_id=$(/usr/bin/plutil -extract id raw "$manifest")
    if [[ -n "$PLUGIN_ID" && "$package_id" != "$PLUGIN_ID" ]]; then
        continue
    fi
    if [[ "$BUNDLED_ONLY" == true ]] && ! node "$ROOT_DIR/scripts/official-plugin-distribution.mjs" "$package_id"; then
        continue
    fi
    schema_version=$(/usr/bin/plutil -extract schemaVersion raw "$manifest")
    if [[ "$schema_version" != "2" ]]; then
        print -u2 -- "Official plugin $package_id must use the declarative manifest (schemaVersion 2)"
        exit 1
    fi
    signature_requirement=$(/usr/bin/plutil -extract vendor.signatureRequirement raw "$manifest")
    publisher_signed=false
    if [[ "$signature_requirement" == "publisherPackage" && "$DEVELOPMENT_UNSIGNED" == false ]]; then
        publisher_signed=true
    fi
    if [[ "$publisher_signed" == true && -z "${LITHE_PLUGIN_PACKAGE_PRIVATE_KEY:-}" ]]; then
        if [[ "$CONFIGURATION" == "release" ]]; then
            print -u2 -- "Configure LITHE_PLUGIN_PACKAGE_PRIVATE_KEY for publisher-signed plugin packages"
            exit 1
        fi
        print -u2 -- "Skipping publisher-signed debug plugin package $package_id; set LITHE_PLUGIN_PACKAGE_PRIVATE_KEY or pass --development-unsigned to build it"
        continue
    fi
    matched=$((matched + 1))
    package_dir="$OUTPUT_DIR/$package_id"

    rm -rf "$package_dir"
    mkdir -p "$package_dir"
    cp "$manifest" "$package_dir/plugin.json"

    # A plugin that needs more than one pinned archive keeps its assembly
    # next to its manifest, so the steps that are specific to one plugin are
    # not spread through shared build scripts.
    package_assembler="$plugin_source/assemble-package.sh"
    if [[ -x "$package_assembler" ]]; then
        "$package_assembler" --output "$package_dir" --arch "$RUNTIME_ARCH" >&2
    fi

    if [[ "$signature_requirement" == "publisherPackage" && "$publisher_signed" == false ]]; then
        print -u2 -- "Built unsigned development package $package_id; only development builds of Lithe can install it"
    fi
    if [[ "$publisher_signed" == true ]]; then
        if [[ -z "$signer_binary" ]]; then
            swift build \
                "${SWIFT_LAYOUT_ARGS[@]}" \
                --product LithePluginPackageSigner >&2
            signer_binary="$SWIFT_BIN_PATH/LithePluginPackageSigner"
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
