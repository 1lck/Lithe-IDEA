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
PLUGIN_ROOT=$(scripts/build-official-plugins.sh \
    --configuration debug \
    --triple "$TRIPLE")
plugins=("$PLUGIN_ROOT"/*(/N))
for plugin in "${plugins[@]}"; do
    swift run "${SWIFT_BUILD_ARGS[@]}" --skip-build LitheOfficialPluginVerifier "$plugin"
done
print "Verified ${#plugins[@]} released official native plugin package(s)"
