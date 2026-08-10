#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CONFIGURATION="debug"
TRIPLE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --triple) TRIPLE="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 [--configuration debug|release] [--triple triple]"; exit 2 ;;
    esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    print -u2 -- "Unsupported configuration: $CONFIGURATION"
    exit 2
fi

cd "$ROOT_DIR"
RUST_TARGET=""
if [[ -n "$TRIPLE" ]]; then
    case "$TRIPLE" in
        arm64-apple-macosx) RUST_TARGET="aarch64-apple-darwin" ;;
        x86_64-apple-macosx) RUST_TARGET="x86_64-apple-darwin" ;;
        *) print -u2 -- "Unsupported macOS Swift triple: $TRIPLE"; exit 2 ;;
    esac
fi

RUST_BUILD_ARGS=()
if [[ "$CONFIGURATION" == "release" ]]; then
    RUST_BUILD_ARGS+=(--release)
    # Swift 6.2 can crash while emitting round-trip debug types for the
    # optimized DiffSplitLayout.plan function on the macOS release runner.
    SWIFT_CONFIGURATION_ARGS=(
        --configuration release
        -Xswiftc -Xfrontend
        -Xswiftc -disable-round-trip-debug-types
    )
else
    RUST_BUILD_ARGS+=(--debug)
    # Swift 6.2 can crash while emitting round-trip debug types for the
    # existing DiffSplitLayout.plan function, even in a debug preview build.
    # Keep preview builds aligned with the release workaround below so the
    # app can be launched locally with ./scripts/preview.sh.
    SWIFT_CONFIGURATION_ARGS=(
        -Xswiftc -Xfrontend
        -Xswiftc -disable-round-trip-debug-types
    )
fi

if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_CONFIGURATION_ARGS+=(
        -Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh"
    )
fi

if [[ -n "$RUST_TARGET" ]]; then
    RUST_BUILD_ARGS+=(--target "$RUST_TARGET")
fi
RUST_LIBRARY="$(scripts/build-rust-core.sh "${RUST_BUILD_ARGS[@]}")"

SWIFT_ARGS=(build --disable-sandbox "${SWIFT_CONFIGURATION_ARGS[@]}")
SWIFT_ARGS+=(
    -Xcc -include
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h"
)
if [[ -n "$TRIPLE" ]]; then
    SWIFT_ARGS+=(--triple "$TRIPLE")
fi
SWIFT_ARGS+=(-Xlinker -force_load -Xlinker "$RUST_LIBRARY")
swift "${SWIFT_ARGS[@]}"
