#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx" ;;
    x86_64) TRIPLE="x86_64-apple-macosx" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

swift build --triple "$TRIPLE"
PLUGIN_ROOT=$(scripts/build-official-plugins.sh \
    --configuration debug \
    --triple "$TRIPLE")
plugins=("$PLUGIN_ROOT"/*(/N))
for plugin in "${plugins[@]}"; do
    swift run --triple "$TRIPLE" LitheOfficialPluginVerifier "$plugin"
done
print "Verified ${#plugins[@]} released official native plugin package(s)"
