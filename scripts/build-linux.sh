#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROFILE="debug"
TARGET=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            PROFILE="release"
            shift
            ;;
        --debug)
            PROFILE="debug"
            shift
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

cd "$ROOT_DIR"

CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/target}"
export CARGO_TARGET_DIR

BUILD_ARGS=(build --manifest-path "$ROOT_DIR/linux/Cargo.toml" -p lithe-linux)

if [[ -n "$TARGET" ]]; then
    BUILD_ARGS+=(--target "$TARGET")
fi

if [[ "$PROFILE" == "release" ]]; then
    BUILD_ARGS+=(--release)
fi

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    BUILD_ARGS+=("${EXTRA_ARGS[@]}")
fi

printf '==> Building Lithe Linux frontend (%s)...\n' "$PROFILE"
cargo "${BUILD_ARGS[@]}"

OUTPUT_BIN="$CARGO_TARGET_DIR"
if [[ -n "$TARGET" ]]; then
    OUTPUT_BIN="$OUTPUT_BIN/$TARGET"
fi
OUTPUT_BIN="$OUTPUT_BIN/$PROFILE/lithe-linux"

if [[ -f "$OUTPUT_BIN" ]]; then
    printf '==> Build successful: %s\n' "$OUTPUT_BIN"
else
    printf '==> Error: Output binary not found at %s\n' "$OUTPUT_BIN" >&2
    exit 1
fi
