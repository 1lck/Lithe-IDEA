#!/usr/bin/env bash
# Verifies the remote workspace crate: protocol, client and server features.
#
#   --static  formatting, clippy, type checks of the server for every remote
#             host target and the Windows client, and static Linux builds held to a size
#             budget, because the server is uploaded to every remote
#   --tests   unit and end-to-end tests with per-test timing reports
#
# Without arguments both run. The end-to-end tests start the real server
# through the local transport, so they exercise the adapter of the machine
# running them: CI covers Linux, local runs on a Mac cover macOS.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MANIFEST=rust/Cargo.toml
PACKAGE=lithe-remote
SERVER_TARGETS=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin)
LINUX_TARGETS=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl)

# Largest accepted stripped release binary. The server is uploaded on first
# connection to every host and container, often over slow links; the first
# measured build was about 0.8 MiB. Raising the budget needs a measured reason
# in the remote development Agent Note.
SERVER_SIZE_BUDGET_BYTES=$((1536 * 1024))

run_static=false
run_tests=false
case "${1:-}" in
    --static) run_static=true ;;
    --tests) run_tests=true ;;
    "") run_static=true; run_tests=true ;;
    *) printf 'usage: %s [--static|--tests]\n' "$0" >&2; exit 2 ;;
esac

if [[ "$run_static" == true ]]; then
    cargo fmt --manifest-path "$MANIFEST" -p "$PACKAGE" -- --check
    for features in protocol client server client,server; do
        feature_arguments=(--no-default-features)
        if [[ "$features" != protocol ]]; then
            feature_arguments+=(--features "$features")
        fi
        cargo clippy --locked --manifest-path "$MANIFEST" -p "$PACKAGE" \
            "${feature_arguments[@]}" --tests -- -D warnings
    done
    installed_targets="$(rustup target list --installed 2>/dev/null || true)"
    if ! grep -qx x86_64-pc-windows-msvc <<<"$installed_targets"; then
        printf 'verify-remote-workspace: Rust target x86_64-pc-windows-msvc is missing; run: rustup target add x86_64-pc-windows-msvc\n' >&2
        exit 1
    fi
    for target in "${SERVER_TARGETS[@]}"; do
        if ! grep -qx "$target" <<<"$installed_targets"; then
            printf 'verify-remote-workspace: Rust target %s is missing; run: rustup target add %s\n' "$target" "$target" >&2
            exit 1
        fi
        # Type checking needs no cross linker, so every host target is checked
        # from any machine, including the adapter the tests cannot run here.
        cargo check --locked --manifest-path "$MANIFEST" -p "$PACKAGE" \
            --no-default-features --features server --target "$target" --tests
    done
    # The desktop client remains available on Windows even though server host
    # adapters support only Linux/macOS. This needs no Windows linker.
    cargo check --locked --manifest-path "$MANIFEST" -p "$PACKAGE" \
        --no-default-features --features client --target x86_64-pc-windows-msvc --tests
    # Rust's bundled lld links static musl binaries on Linux and macOS hosts
    # alike, so no cross toolchain, Docker image or zig is needed.
    for target in "${LINUX_TARGETS[@]}"; do
        linker_variable="CARGO_TARGET_$(tr '[:lower:]-' '[:upper:]_' <<<"$target")_LINKER"
        env "$linker_variable=rust-lld" \
            cargo build --locked --release --manifest-path "$MANIFEST" -p "$PACKAGE" \
                --no-default-features --features server --bin lithe-remote-server --target "$target"
        binary="rust/target/$target/release/lithe-remote-server"
        size="$(wc -c <"$binary" | tr -d ' ')"
        printf 'lithe-remote-server %s: %s bytes (budget %s)\n' "$target" "$size" "$SERVER_SIZE_BUDGET_BYTES"
        if (( size > SERVER_SIZE_BUDGET_BYTES )); then
            printf 'verify-remote-workspace: %s exceeds the size budget\n' "$binary" >&2
            exit 1
        fi
    done
fi

if [[ "$run_tests" == true ]]; then
    node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
        --manifest "$MANIFEST" --package "$PACKAGE" \
        --no-default-features --features client,server \
        --suite-timeout-ms 180000 \
        --report .artifacts/test-stability/remote-rust.json
fi

printf 'Remote workspace verification passed\n'
