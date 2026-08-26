#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

scripts/verify-rust-core-comments.sh
scripts/verify-rust-core-layout.sh
cargo fmt --manifest-path rust/Cargo.toml -p lithe-core -- --check
cargo test --manifest-path rust/Cargo.toml -p lithe-core

case "$(uname -m)" in
    arm64) TRIPLE="arm64-apple-macosx"; RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-macosx"; RUST_TARGET="x86_64-apple-darwin" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

RUST_LIBRARY="$(scripts/build-rust-core.sh --debug --target "$RUST_TARGET")"

SWIFT_LINKER_ARGS=()
if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_LINKER_ARGS=(-Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh")
fi

swift build --disable-sandbox --triple "$TRIPLE" "${SWIFT_LINKER_ARGS[@]}" \
    -Xswiftc -Xfrontend \
    -Xswiftc -disable-round-trip-debug-types \
    -Xcc -include \
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h" \
    -Xlinker -force_load \
    -Xlinker "$RUST_LIBRARY"

BRIDGE_BINARY="$(mktemp -t lithe-rust-bridge).out"
trap 'rm -f "$BRIDGE_BINARY"' EXIT
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc scripts/RustCoreBridgeVerification.swift \
    macos/Sources/LitheRustCore/bridge.c \
    -sdk "$MACOS_SDK" \
    -target "${TRIPLE}13.0" \
    -Xlinker -force_load \
    -Xlinker "$RUST_LIBRARY" \
    -o "$BRIDGE_BINARY"
"$BRIDGE_BINARY"

BINARY=".build/$TRIPLE/debug/Lithe"
if ! nm -gU "$BINARY" | grep -F "_lithe_core_execute_json" > /dev/null; then
    print -u2 -- "Rust Core symbols are missing from the macOS binary"
    exit 1
fi
if ! nm -gU "$BINARY" | grep -F "_lithe_core_lsp_provider_catalog_json" > /dev/null; then
    print -u2 -- "Rust Core LSP provider catalog symbol is missing from the macOS binary"
    exit 1
fi

print "Rust Core verification passed: comments, Rust tests, Swift bridge build, and linked symbols"
