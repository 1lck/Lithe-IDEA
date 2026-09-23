#!/usr/bin/env bash

# Builds the Linux Tauri product. Mirrors scripts/build-windows.ps1: it prepares
# the bundled JDTLS and JDK artifacts, checks the frontend toolchain, then runs
# the Tauri build with the Linux configuration.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOWS_APP="$ROOT_DIR/windows/tauri"

CONFIGURATION="Debug"
RUST_TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || { echo "--configuration requires a value" >&2; exit 2; }
            CONFIGURATION="$2"
            shift 2
            ;;
        --target)
            [[ $# -ge 2 ]] || { echo "--target requires a value" >&2; exit 2; }
            RUST_TARGET="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--configuration Debug|Release] [--target <rust-triple>]" >&2
            exit 2
            ;;
    esac
done

case "$CONFIGURATION" in
    Debug | Release) ;;
    *)
        echo "Unsupported configuration: $CONFIGURATION (expected Debug or Release)" >&2
        exit 2
        ;;
esac

if [[ -z "$RUST_TARGET" ]]; then
    case "$(uname -m)" in
        x86_64 | amd64) RUST_TARGET="x86_64-unknown-linux-gnu" ;;
        aarch64 | arm64) RUST_TARGET="aarch64-unknown-linux-gnu" ;;
        *)
            echo "Unsupported Linux host architecture: $(uname -m); pass --target explicitly" >&2
            exit 2
            ;;
    esac
fi

if ! command -v bun >/dev/null 2>&1; then
    echo "Bun is required to build the Linux application. Install it with: curl -fsSL https://bun.sh/install | bash" >&2
    exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "Rust is required to build the Linux application. Install it with: apt-get install -y cargo, or curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" >&2
    exit 1
fi

# The prepare scripts stage into the canonical bundle roots consumed by
# src-tauri/tauri.linux-jdtls.conf.json: .artifacts/jdtls-linux and
# .artifacts/jdk-linux. Callers can pre-provision bundles by exporting
# LITHE_JDTLS_ROOT / LITHE_JDK_ROOT; the prepare scripts then validate and reuse
# them instead of downloading.
prepared_jdtls_root="$(printf '%s\n' "$("$ROOT_DIR/scripts/prepare-jdtls-linux.sh")" | tail -n 1)"
[[ -d "$prepared_jdtls_root" ]] || { echo "Prepared JDTLS root is missing: $prepared_jdtls_root" >&2; exit 1; }
prepared_jdk_root="$(printf '%s\n' "$("$ROOT_DIR/scripts/prepare-jdk-linux.sh")" | tail -n 1)"
[[ -d "$prepared_jdk_root" ]] || { echo "Prepared JDK root is missing: $prepared_jdk_root" >&2; exit 1; }

cd "$WINDOWS_APP"

bun install --frozen-lockfile
bun run typecheck
bun run build

TAURI_ARGS=(
    build
    --config src-tauri/tauri.linux.conf.json
    --target "$RUST_TARGET"
)
if [[ "$CONFIGURATION" == "Debug" ]]; then
    TAURI_ARGS+=(--debug)
else
    # Release bundles the staged runtime under LanguageServers/ so a user without
    # a system JDK still gets the Java language server.
    TAURI_ARGS+=(--config src-tauri/tauri.linux-jdtls.conf.json)
fi
bunx tauri "${TAURI_ARGS[@]}"

if [[ "$CONFIGURATION" == "Debug" ]]; then
    PROFILE_NAME="debug"
else
    PROFILE_NAME="release"
fi
PRODUCT_PATH="$WINDOWS_APP/src-tauri/target/$RUST_TARGET/$PROFILE_NAME/lithe-linux"
[[ -f "$PRODUCT_PATH" ]] || { echo "Linux Tauri executable is missing: $PRODUCT_PATH" >&2; exit 1; }

echo "$PRODUCT_PATH"
