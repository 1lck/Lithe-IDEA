#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
VERSION=2.10.0
CHECKSUM=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DESTINATION="$ROOT_DIR/.build/sparkle-tools/$VERSION"
if [[ ! -x "$DESTINATION/bin/generate_appcast" ]]; then
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
        --output "$temporary/sparkle.tar.xz"
    actual=$(shasum -a 256 "$temporary/sparkle.tar.xz")
    [[ "${actual%% *}" == "$CHECKSUM" ]] || { print -u2 -- "Sparkle tools checksum mismatch"; exit 1; }
    mkdir -p "$DESTINATION"
    tar -xJf "$temporary/sparkle.tar.xz" -C "$DESTINATION"
fi
print -r -- "$DESTINATION/bin"
