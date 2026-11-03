#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
cd "$ROOT_DIR"

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx" ;;
    x86_64) TRIPLE="x86_64-apple-macosx" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

SWIFT_BUILD_ARGS=(
    --triple "$TRIPLE"
    -Xswiftc -Xfrontend
    -Xswiftc -disable-round-trip-debug-types
)

# The package verifier only needs the plugin API and contract modules. Building
# every product also recompiles the macOS application and exposes this focused
# check to unrelated Swift compiler failures.
swift build "${SWIFT_BUILD_ARGS[@]}" --product LitheOfficialPluginVerifier
# Go and PHP Support are publisher-signed. Without the release key (pull
# request CI) build unsigned development packages instead, so their manifests
# and packaged resources are still verified; the signed path is covered when
# the key is available.
BUILD_ARGS=(--configuration debug --triple "$TRIPLE")
if [[ -z "${LITHE_PLUGIN_PACKAGE_PRIVATE_KEY:-}" ]]; then
    BUILD_ARGS+=(--development-unsigned)
fi
PLUGIN_ROOT=$(scripts/plugins/build-official-plugins.sh "${BUILD_ARGS[@]}")
[[ -d "$PLUGIN_ROOT" ]] || {
    print -u2 -- "Official plugin build returned an invalid package root: $PLUGIN_ROOT"
    exit 1
}
# A verification that sees zero packages must fail, not pass vacuously.
for official_plugin in dev.lithe.plugin.java-support dev.lithe.plugin.editor-keymap-import; do
    [[ -d "$PLUGIN_ROOT/$official_plugin" ]] || {
        print -u2 -- "Official plugin package was not built: $official_plugin"
        exit 1
    }
done
plugins=("$PLUGIN_ROOT"/*(/N))
package_signer_binary=""
for plugin in "${plugins[@]}"; do
    swift run "${SWIFT_BUILD_ARGS[@]}" --skip-build LitheOfficialPluginVerifier "$plugin"
    # A package that ships inside the application is sealed by the app's code
    # signature instead of a publisher signature.
    signature_requirement=$(/usr/bin/plutil -extract vendor.signatureRequirement raw "$plugin/plugin.json")
    if [[ "$signature_requirement" == "publisherPackage" \
        && -n "${LITHE_PLUGIN_PACKAGE_PRIVATE_KEY:-}" && ! -f "$plugin/lithe-plugin-signature.json" ]]; then
        print -u2 -- "Publisher key was provided but $plugin:t is not signed"
        exit 1
    fi
    if [[ -f "$plugin/lithe-plugin-signature.json" ]]; then
        if [[ -z "$package_signer_binary" ]]; then
            swift build "${SWIFT_BUILD_ARGS[@]}" --product LithePluginPackageSigner
            signer_bin_dir=$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)
            package_signer_binary="$signer_bin_dir/LithePluginPackageSigner"
            [[ -x "$package_signer_binary" ]] || {
                print -u2 -- "Plugin package signer was not built: $package_signer_binary"
                exit 1
            }
        fi
        "$package_signer_binary" --verify "$plugin"
    fi
done

# The import provider is the first official package with a packaged native
# backend. Verify the declared binary is required and no sibling binary is
# accidentally admitted by the verifier's native-code policy.
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/lithe-official-plugin-verifier.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT
fixture="$fixture_root/dev.lithe.plugin.editor-keymap-import"
cp -R "$PLUGIN_ROOT/dev.lithe.plugin.editor-keymap-import" "$fixture"
verifier_bin_dir=$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)
verifier_binary="$verifier_bin_dir/LitheOfficialPluginVerifier"
cp "$fixture/bin/editor-keymap-import" "$fixture/bin/undeclared-native"
if "$verifier_binary" "$fixture" > "$fixture_root/unexpected.log" 2>&1; then
    print -u2 -- "Official plugin verifier accepted undeclared native code"
    exit 1
fi
grep -Fq 'Native code is only allowed in a declared backend or packaged runtime:' "$fixture_root/unexpected.log"
rm "$fixture/bin/undeclared-native" "$fixture/bin/editor-keymap-import"
if "$verifier_binary" "$fixture" > "$fixture_root/missing.log" 2>&1; then
    print -u2 -- "Official plugin verifier accepted a missing backend executable"
    exit 1
fi
grep -Fq 'A declared launch file is missing or not executable:' "$fixture_root/missing.log"
cp "$PLUGIN_ROOT/dev.lithe.plugin.editor-keymap-import/bin/editor-keymap-import" "$fixture_root/outside"
node -e 'const fs = require("node:fs"); const path = process.argv[1]; const manifest = JSON.parse(fs.readFileSync(path, "utf8")); manifest.backend.launch.path = "../outside"; fs.writeFileSync(path, JSON.stringify(manifest));' "$fixture/plugin.json"
if "$verifier_binary" "$fixture" > "$fixture_root/traversal.log" 2>&1; then
    print -u2 -- "Official plugin verifier accepted a backend outside its package"
    exit 1
fi
grep -Fq 'A declared launch file is missing or not executable:' "$fixture_root/traversal.log"
print "Verified ${#plugins[@]} official declarative plugin package(s)"
