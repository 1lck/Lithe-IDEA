#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo test --manifest-path rust/Cargo.toml

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx"; RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-macosx"; RUST_TARGET="x86_64-apple-darwin" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

RUST_LIBRARY="$(scripts/build-rust-core.sh --debug --target "$RUST_TARGET")"

swift build --disable-sandbox --triple "$TRIPLE" \
    -Xswiftc -Xfrontend \
    -Xswiftc -disable-round-trip-debug-types \
    -Xlinker -force_load \
    -Xlinker "$RUST_LIBRARY"

BRIDGE_BINARY="$(mktemp -t lithe-rust-bridge).out"
trap 'rm -f "$BRIDGE_BINARY"' EXIT
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc scripts/RustCoreBridgeVerification.swift \
    Sources/LitheRustCore/bridge.c \
    -sdk "$MACOS_SDK" \
    -target "${TRIPLE}14.0" \
    -Xlinker -force_load \
    -Xlinker "$RUST_LIBRARY" \
    -o "$BRIDGE_BINARY"
"$BRIDGE_BINARY"

BINARY=".build/$TRIPLE/debug/Lithe"
if ! nm -gU "$BINARY" | rg -q "_lithe_core_execute_json"; then
    print -u2 -- "Rust Core symbols are missing from the macOS binary"
    exit 1
fi

print "Rust Core verification passed: Rust tests, Swift bridge build, and linked symbols"
