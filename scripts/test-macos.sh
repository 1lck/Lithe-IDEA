#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

# Note: .agents/notes/implemented/testing/2026-10-09-macos-test-desktop-isolation.md
# Keep native tests running while suppressing their WindowServer presentation.
if [[ -z "${LITHE_TEST_WINDOW_MODE+x}" ]]; then
    LITHE_TEST_WINDOW_MODE=isolated
    if [[ "${LITHE_RUN_GIT_COMPOSITOR_TESTS:-0}" == 1 ]]; then LITHE_TEST_WINDOW_MODE=visible; fi
fi
export LITHE_TEST_WINDOW_MODE
case "$LITHE_TEST_WINDOW_MODE" in
    isolated|visible) ;;
    *) print -u2 -- "LITHE_TEST_WINDOW_MODE must be isolated or visible"; exit 2 ;;
esac
if [[ "$LITHE_TEST_WINDOW_MODE" == isolated && "${LITHE_RUN_GIT_COMPOSITOR_TESTS:-0}" == 1 ]]; then
    print -u2 -- "Real compositor tests require LITHE_TEST_WINDOW_MODE=visible"
    exit 2
fi

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
