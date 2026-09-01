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

# Real process-backed integration tests need the same Rust Core static library
# that is force-loaded into the application and the bridge verification binary.
# Keep it opt-in so the normal unit-test build remains lightweight and does not
# change its existing linkage behavior.
if [[ "${LITHE_RUN_JAVA_DEBUG_INTEGRATION:-0}" == "1" \
   || "${LITHE_RUN_JAVA_TEST_DEBUG_INTEGRATION:-0}" == "1" ]]; then
    case "$(uname -m)" in
        arm64) RUST_TARGET="aarch64-apple-darwin" ;;
        x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
        *) print -u2 -- "Unsupported host architecture for Rust Core integration tests: $(uname -m)"; exit 1 ;;
    esac
    RUST_LIBRARY="$(scripts/build-rust-core.sh --debug --target "$RUST_TARGET")"
    SWIFT_ARGS+=(-Xlinker -force_load -Xlinker "$RUST_LIBRARY")
fi

if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_ARGS+=(-Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh")
fi

swift "${SWIFT_ARGS[@]}" "$@"
