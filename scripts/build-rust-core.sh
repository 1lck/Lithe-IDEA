#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PROFILE="debug"
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) PROFILE="release"; shift ;;
        --debug) PROFILE="debug"; shift ;;
        --target) TARGET="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 [--debug|--release] [--target rust-target]"; exit 2 ;;
    esac
done

cd "$ROOT_DIR"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export CARGO_TARGET_DIR="${LITHE_RUST_TARGET_DIR:-$ROOT_DIR/rust/target/macos}"
if [[ -n "$TARGET" ]]; then
    TARGET_LIBDIR="$(rustc --print target-libdir --target "$TARGET")"
    if [[ ! -d "$TARGET_LIBDIR" || -z "$(find "$TARGET_LIBDIR" -maxdepth 1 -name 'libcore-*.rlib' -print -quit)" ]]; then
        print -u2 -- "Rust target $TARGET is not installed; install it with: rustup target add $TARGET"
        exit 1
    fi
fi
if [[ -n "${RUSTFLAGS:-}" ]]; then
    export RUSTFLAGS="$RUSTFLAGS -C link-arg=-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
else
    export RUSTFLAGS="-C link-arg=-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
fi
BUILD_ARGS=(build --manifest-path rust/Cargo.toml)
OUTPUT_DIR="$CARGO_TARGET_DIR"
if [[ -n "$TARGET" ]]; then
    BUILD_ARGS+=(--target "$TARGET")
    OUTPUT_DIR+="/$TARGET"
fi
if [[ "$PROFILE" == "release" ]]; then
    BUILD_ARGS+=(--release)
fi
cargo "${BUILD_ARGS[@]}"
print -r -- "$OUTPUT_DIR/$PROFILE/liblithe_core.a"
