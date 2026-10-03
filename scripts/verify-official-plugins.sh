#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PLUGIN_CHANNEL="${LITHE_PLUGIN_PACKAGE_CHANNEL:-${LITHE_UPDATE_CHANNEL:-stable}}"
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
PLUGIN_ROOT=$(scripts/build-official-plugins.sh \
    --configuration debug \
    --triple "$TRIPLE")
[[ -d "$PLUGIN_ROOT" ]] || {
    print -u2 -- "Official plugin build returned an invalid package root: $PLUGIN_ROOT"
    exit 1
}
if [[ -n "${LITHE_PLUGIN_PACKAGE_PRIVATE_KEY:-}" ]]; then
    [[ -d "$PLUGIN_ROOT/dev.lithe.plugin.php-support" ]] || {
        print -u2 -- "Publisher key was provided but the PHP plugin package was not built"
        exit 1
    }
fi
plugins=("$PLUGIN_ROOT"/*(/N))
package_signer_binary=""
for plugin in "${plugins[@]}"; do
    swift run "${SWIFT_BUILD_ARGS[@]}" --skip-build LitheOfficialPluginVerifier "$plugin"
    if [[ "$plugin:t" == "dev.lithe.plugin.php-support" ]]; then
        [[ -f "$plugin/language-server.json" ]] || {
            print -u2 -- "PHP plugin language-server manifest is missing: $plugin"
            exit 1
        }
        php_launcher="$plugin/PhpSupport.bundle/Contents/Resources/LanguageServers/php/bin/intelephense"
        [[ -x "$php_launcher" ]] || {
            print -u2 -- "PHP plugin Intelephense launcher is missing: $php_launcher"
            exit 1
        }
        /usr/bin/codesign --verify --deep --strict "$plugin/PhpSupport.bundle"
        if [[ -z "$package_signer_binary" ]]; then
            swift build "${SWIFT_BUILD_ARGS[@]}" --product LithePluginPackageSigner
            signer_bin_dir=$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)
            package_signer_binary="$signer_bin_dir/LithePluginPackageSigner"
            [[ -x "$package_signer_binary" ]] || {
                print -u2 -- "Plugin package signer was not built: $package_signer_binary"
                exit 1
            }
        fi
        "$package_signer_binary" --verify --channel "$PLUGIN_CHANNEL" "$plugin"
    fi
done
print "Verified ${#plugins[@]} official native plugin package(s)"
