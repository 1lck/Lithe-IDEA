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
"$ROOT_DIR/scripts/verify-macos-app-build-safety.sh"

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

# SwiftPM can reuse binary modules produced by an incompatible compiler after
# an Xcode/toolchain upgrade. Keep the full compiler identity, including its
# build number, and let SwiftPM clean build products while retaining checkouts.
SWIFT_TOOLCHAIN_VERSION="$(swift --version)"
if [[ -n "${SWIFT_EXEC:-}" ]]; then
    SWIFT_TOOLCHAIN_VERSION+=$'\n'"$("$SWIFT_EXEC" --version)"
fi
SWIFT_TOOLCHAIN_STAMP="$ROOT_DIR/.build/.lithe-swift-toolchain"
PREVIOUS_SWIFT_TOOLCHAIN_VERSION=""
if [[ -f "$SWIFT_TOOLCHAIN_STAMP" ]]; then
    PREVIOUS_SWIFT_TOOLCHAIN_VERSION="$(<"$SWIFT_TOOLCHAIN_STAMP")"
fi
if [[ -d "$ROOT_DIR/.build" && "$PREVIOUS_SWIFT_TOOLCHAIN_VERSION" != "$SWIFT_TOOLCHAIN_VERSION" ]]; then
    if [[ -n "$PREVIOUS_SWIFT_TOOLCHAIN_VERSION" ]]; then
        print -- "Swift compiler changed; cleaning incompatible SwiftPM build products."
    else
        # Existing caches predate this stamp, so their compiler is unknown.
        print -- "Swift compiler cache version is unknown; cleaning SwiftPM build products once."
    fi
    swift package clean
fi
mkdir -p "$ROOT_DIR/.build"
# Record only after cleaning succeeds; failed builds can safely resume with
# this compiler without discarding their newly compiled modules.
print -r -- "$SWIFT_TOOLCHAIN_VERSION" > "$SWIFT_TOOLCHAIN_STAMP"
swift "${SWIFT_ARGS[@]}"
