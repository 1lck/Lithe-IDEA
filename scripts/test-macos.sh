#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/verify-runtime-bundle-immutability.sh"

SWIFT_ARGS=(
    test --disable-sandbox
    -Xswiftc -Xfrontend
    -Xswiftc -disable-round-trip-debug-types
    -Xcc -include
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h"
)

# Text classification is a production Core dependency, including in the file
# policy unit tests. Link the same implementation instead of testing a Swift copy.
case "$(uname -m)" in
    arm64) RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac
RUST_LIBRARY="$(scripts/build-rust-core.sh --debug --target "$RUST_TARGET")"
# Integration callers may already pass this exact archive explicitly.
core_link_supplied=0
for argument in "$@"; do
    if [[ "$argument" == "$RUST_LIBRARY" ]]; then core_link_supplied=1; fi
done
if (( ! core_link_supplied )); then
    SWIFT_ARGS+=(-Xlinker -force_load -Xlinker "$RUST_LIBRARY")
fi

if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_ARGS+=(-Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh")
fi

swift "${SWIFT_ARGS[@]}" "$@"
