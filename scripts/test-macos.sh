#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

SWIFT_ARGS=(
    test --disable-sandbox
    -Xswiftc -Xfrontend
    -Xswiftc -disable-round-trip-debug-types
    -Xcc -include
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h"
)
if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_ARGS+=(-Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh")
fi

swift "${SWIFT_ARGS[@]}" "$@"
