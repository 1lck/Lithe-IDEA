#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
ARCH="${LITHE_ARCH:-$(uname -m)}"
MANIFEST="$ROOT_DIR/rust/Cargo.toml"
OUTPUT_DIR="$ROOT_DIR/dist/database-mcp"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
mkdir -p "$OUTPUT_DIR"

build_arch() {
    local architecture="$1"
    local target
    case "$architecture" in
        arm64) target="aarch64-apple-darwin" ;;
        x86_64) target="x86_64-apple-darwin" ;;
        *) print -u2 -- "Unsupported database MCP architecture: $architecture"; exit 1 ;;
    esac

    cargo build --manifest-path "$MANIFEST" --release --target "$target" -p lithe-db-mcp >&2
    print -r -- "$ROOT_DIR/rust/target/$target/release/lithe-db-mcp"
}

case "$ARCH" in
    arm64|x86_64)
        binary=$(build_arch "$ARCH")
        output="$OUTPUT_DIR/lithe-db-mcp-$ARCH"
        cp "$binary" "$output"
        print -r -- "$output"
        ;;
    universal)
        arm_binary=$(build_arch arm64)
        intel_binary=$(build_arch x86_64)
        output="$OUTPUT_DIR/lithe-db-mcp"
        lipo -create "$arm_binary" "$intel_binary" -output "$output"
        print -r -- "$output"
        ;;
    *)
        print -u2 -- "Unsupported database MCP architecture: $ARCH"
        exit 1
        ;;
esac
