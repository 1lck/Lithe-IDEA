#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
ARCH="${LITHE_ARCH:-$(uname -m)}"
MANIFEST="$ROOT_DIR/rust/Cargo.toml"
DIST_ROOT="${LITHE_DIST_ROOT:-$ROOT_DIR/dist}"
OUTPUT_DIR="$DIST_ROOT/database-sidecar"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
mkdir -p "$OUTPUT_DIR"

build_arch() {
    local architecture="$1"
    local target
    case "$architecture" in
        arm64) target="aarch64-apple-darwin" ;;
        x86_64) target="x86_64-apple-darwin" ;;
    esac
    local rust_sysroot
    rust_sysroot=$(rustc --print sysroot)
    if [[ ! -d "$rust_sysroot/lib/rustlib/$target" ]]; then
        print -u2 -- "Rust target $target is not installed. Install it with: rustup target add $target"
        return 2
    fi
    cargo build --manifest-path "$MANIFEST" --release --target "$target" -p lithe-db-sidecar >&2
    print -r -- "$ROOT_DIR/rust/target/$target/release/lithe-db-sidecar"
}

case "$ARCH" in
    arm64|x86_64)
        binary=$(build_arch "$ARCH")
        cp "$binary" "$OUTPUT_DIR/lithe-db-sidecar-$ARCH"
        print -r -- "$OUTPUT_DIR/lithe-db-sidecar-$ARCH"
        ;;
    universal)
        arm_binary=$(build_arch arm64)
        intel_binary=$(build_arch x86_64)
        lipo -create "$arm_binary" "$intel_binary" -output "$OUTPUT_DIR/lithe-db-sidecar"
        print -r -- "$OUTPUT_DIR/lithe-db-sidecar"
        ;;
    *)
        print -u2 -- "Unsupported database sidecar architecture: $ARCH"
        exit 1
        ;;
esac
