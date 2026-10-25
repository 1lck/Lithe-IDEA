#!/bin/zsh
# Builds the remote workspace servers that the macOS app ships read-only in
# Contents/Resources/RemoteServers and uploads to SSH hosts on first connect.
#
# Only Linux servers are shipped for now: they are static musl ELF files, which
# code signing treats as plain resources. macOS servers are Mach-O executables
# and need Developer ID signing and notarization in the release pipeline first.
#
# Rust's bundled lld links the static binaries on macOS hosts, so no cross
# toolchain is needed. Prints the output directory: <target>/lithe-remote-server
# for each target, plus manifest.json with the server version.
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
TARGETS=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl)
# Build output stays in this worktree's Cargo target directory; it is rebuilt
# from source and never shared between worktrees.
OUTPUT_DIR="$ROOT_DIR/rust/target/remote-servers"

installed_targets="$(rustup target list --installed 2>/dev/null || true)"
for target in "${TARGETS[@]}"; do
    if ! grep -qx "$target" <<<"$installed_targets"; then
        print -u2 -- "build-remote-servers: Rust target $target is missing; run: rustup target add $target"
        exit 1
    fi
done

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
for target in "${TARGETS[@]}"; do
    linker_variable="CARGO_TARGET_$(tr '[:lower:]-' '[:upper:]_' <<<"$target")_LINKER"
    # The server is uploaded over slow links, so it is always an optimized build.
    env "$linker_variable=rust-lld" \
        cargo build --locked --release --manifest-path "$ROOT_DIR/rust/Cargo.toml" \
        -p lithe-remote-server --target "$target" >&2
    mkdir -p "$OUTPUT_DIR/$target"
    cp "$ROOT_DIR/rust/target/$target/release/lithe-remote-server" "$OUTPUT_DIR/$target/lithe-remote-server"
done

version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT_DIR/rust/lithe-remote-server/Cargo.toml" | head -1)"
if [[ -z "$version" ]]; then
    print -u2 -- "build-remote-servers: could not read the server version"
    exit 1
fi
printf '{"serverVersion":"%s"}\n' "$version" > "$OUTPUT_DIR/manifest.json"
print -- "$OUTPUT_DIR"
