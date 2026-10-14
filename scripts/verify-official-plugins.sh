#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
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
# Both official plugins are publisher-signed. Without the release key (pull
# request CI) build unsigned development packages instead, so their manifests
# and packaged resources are still verified; the signed path is covered when
# the key is available.
BUILD_ARGS=(--configuration debug --triple "$TRIPLE")
if [[ -z "${LITHE_PLUGIN_PACKAGE_PRIVATE_KEY:-}" ]]; then
    BUILD_ARGS+=(--development-unsigned)
fi
PLUGIN_ROOT=$(scripts/build-official-plugins.sh "${BUILD_ARGS[@]}")
[[ -d "$PLUGIN_ROOT" ]] || {
    print -u2 -- "Official plugin build returned an invalid package root: $PLUGIN_ROOT"
    exit 1
}
# A verification that sees zero packages must fail, not pass vacuously.
for official_plugin in dev.lithe.plugin.php-support dev.lithe.plugin.go-support; do
    [[ -d "$PLUGIN_ROOT/$official_plugin" ]] || {
        print -u2 -- "Official plugin package was not built: $official_plugin"
        exit 1
    }
done
plugins=("$PLUGIN_ROOT"/*(/N))
package_signer_binary=""
for plugin in "${plugins[@]}"; do
    swift run "${SWIFT_BUILD_ARGS[@]}" --skip-build LitheOfficialPluginVerifier "$plugin"
    if [[ "$plugin:t" == "dev.lithe.plugin.php-support" ]]; then
        [[ -f "$plugin/language-server.json" ]] || {
            print -u2 -- "PHP plugin language-server manifest is missing: $plugin"
            exit 1
        }
        php_launcher="$plugin/language-server/bin/intelephense"
        [[ -x "$php_launcher" ]] || {
            print -u2 -- "PHP plugin Intelephense launcher is missing: $php_launcher"
            exit 1
        }
    fi
    if [[ -n "${LITHE_PLUGIN_PACKAGE_PRIVATE_KEY:-}" && ! -f "$plugin/lithe-plugin-signature.json" ]]; then
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
print "Verified ${#plugins[@]} official declarative plugin package(s)"
