#!/bin/zsh

set -euo pipefail

# Assembles the resources of the Java Support plugin package: the pinned
# JDT LS distribution with its Lombok, Debug, and Test extensions, and the
# JDK it runs on. Everything is fetched and checksum-verified by the shared
# prepare scripts; this script only arranges the result in the layout
# plugin.json declares. The assembled package is read-only at runtime.
# See .agents/notes/implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md.

PLUGIN_DIR="${0:A:h}"
ROOT_DIR="${PLUGIN_DIR:h:h:h:h}"
OUTPUT_DIR=""
ARCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 --output package-directory --arch arm64|x86_64|universal"; exit 2 ;;
    esac
done
[[ -n "$OUTPUT_DIR" ]] || { print -u2 -- "--output is required"; exit 2; }
case "$ARCH" in
    arm64|x86_64) runtime_architectures=("$ARCH") ;;
    universal) runtime_architectures=(arm64 x86_64) ;;
    *) print -u2 -- "Unsupported architecture: $ARCH"; exit 2 ;;
esac

jdtls_root=$(LITHE_ARCH="$ARCH" "$ROOT_DIR/scripts/prepare-jdtls.sh")
language_server="$OUTPUT_DIR/language-server"
rm -rf "$language_server" "$OUTPUT_DIR/runtime"
mkdir -p "$language_server/configuration"

# Only what a macOS launch reads is packaged. The wrapper scripts and the
# configuration areas of other platforms are left out.
for entry in plugins features lombok java-debug java-test manifest.json LICENSE-EPL-2.0.txt; do
    [[ -e "$jdtls_root/$entry" ]] || {
        print -u2 -- "JDT LS distribution is missing $entry: $jdtls_root"
        exit 1
    }
    cp -R "$jdtls_root/$entry" "$language_server/$entry"
done

# Equinox reads one configuration per architecture. The packaged copy stays
# read-only; Rust Core gives each launch a writable area in the host cache.
for runtime_arch in "${runtime_architectures[@]}"; do
    case "$runtime_arch" in
        arm64) configuration_name="config_mac_arm" ;;
        x86_64) configuration_name="config_mac" ;;
    esac
    [[ -f "$jdtls_root/$configuration_name/config.ini" ]] || {
        print -u2 -- "JDT LS configuration is missing: $jdtls_root/$configuration_name/config.ini"
        exit 1
    }
    mkdir -p "$language_server/configuration/$runtime_arch"
    cp "$jdtls_root/$configuration_name/config.ini" "$language_server/configuration/$runtime_arch/config.ini"

    if [[ "$ARCH" == "universal" ]]; then
        override_variable="LITHE_JDK_${runtime_arch:u}_ROOT"
        jdk_root=$(LITHE_JDK_ROOT="${(P)override_variable:-}" LITHE_JDK_TARGET_ARCH="$runtime_arch" \
            "$ROOT_DIR/scripts/prepare-jdk.sh")
    else
        jdk_root=$(LITHE_JDK_TARGET_ARCH="$runtime_arch" "$ROOT_DIR/scripts/prepare-jdk.sh")
    fi
    mkdir -p "$OUTPUT_DIR/runtime"
    cp -R "$jdk_root" "$OUTPUT_DIR/runtime/$runtime_arch"
done

# plugin.json names these files exactly, so a JDT LS upgrade that renames one
# fails here instead of at the user's first Java file.
launcher=$(/usr/bin/plutil -extract languageServers.0.launch.entry raw "$PLUGIN_DIR/plugin.json")
test_runner=$(/usr/bin/plutil -extract languageServers.0.hostIntegration.resources.testRunner raw "$PLUGIN_DIR/plugin.json")
for declared in "$launcher" "$test_runner" language-server/lombok/lombok.jar; do
    [[ -f "$OUTPUT_DIR/$declared" ]] || {
        print -u2 -- "Java Support declares $declared, which the assembled package does not contain. Update Plugins/mac/Official/JavaSupport/plugin.json for the pinned JDT LS version."
        exit 1
    }
done

# The contract forbids symbolic links inside a package.
if [[ -n "$(find "$OUTPUT_DIR" -type l -print -quit)" ]]; then
    print -u2 -- "The Java Support package contains symbolic links: $(find "$OUTPUT_DIR" -type l -print -quit)"
    exit 1
fi
