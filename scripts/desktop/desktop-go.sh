#!/usr/bin/env bash
# Runs a Go command in desktop/ with cgo linked to the staged Lithe-core-rust library:
#
# Usage:
#   scripts/desktop/desktop-go.sh test ./...
#   scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe ./cmd/lithe
#   GOARCH=amd64 scripts/desktop/desktop-go.sh build ./cmd/lithe
#   scripts/desktop/desktop-go.sh --exec PROGRAM [ARGS...]
#
# The core is staged before every run so a changed pin or local LITHE_CORE_RUST_DIR cannot leave
# cgo linking the previous revision. GOOS must be the host OS; GOARCH selects a supported core
# target. The --exec mode keeps the same directory, core staging and cgo environment for tools
# such as Viva that build the application themselves.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

GOOS="$(go env GOOS)"
GOHOSTOS="$(go env GOHOSTOS)"
if [[ "$GOOS" != "$GOHOSTOS" ]]; then
    printf '%s\n' "Cross-OS builds are not supported: GOOS=$GOOS but the Go host is $GOHOSTOS." >&2
    exit 2
fi
GOARCH="${GOARCH:-$(go env GOARCH)}"
export GOOS GOARCH

case "$GOOS:$GOARCH" in
    darwin:arm64) MAPPED_CORE_TARGET="aarch64-apple-darwin" ;;
    darwin:amd64) MAPPED_CORE_TARGET="x86_64-apple-darwin" ;;
    linux:amd64) MAPPED_CORE_TARGET="x86_64-unknown-linux-gnu" ;;
    linux:arm64) MAPPED_CORE_TARGET="aarch64-unknown-linux-gnu" ;;
    windows:amd64) MAPPED_CORE_TARGET="x86_64-pc-windows-gnu" ;;
    windows:arm64)
        printf '%s\n' 'Windows arm64 is not supported; use the x86_64 Windows client.' >&2
        exit 2
        ;;
    *)
        printf '%s\n' "No Lithe-core-rust target is configured for GOOS=$GOOS GOARCH=$GOARCH." >&2
        exit 2
        ;;
esac
if [[ -z "${LITHE_CORE_TARGET:-}" ]]; then
    export LITHE_CORE_TARGET="$MAPPED_CORE_TARGET"
fi

PROFILE="${LITHE_DESKTOP_CORE_PROFILE:-debug}"
PROFILE_FLAG="--debug"
if [[ "$PROFILE" == "release" ]]; then
    PROFILE_FLAG="--release"
elif [[ "$PROFILE" != "debug" ]]; then
    printf '%s\n' "LITHE_DESKTOP_CORE_PROFILE must be debug or release, not $PROFILE." >&2
    exit 2
fi

if [[ "$GOOS" == "darwin" ]]; then
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
else
    unset MACOSX_DEPLOYMENT_TARGET
fi
STAGE_DIR="$("$ROOT_DIR/scripts/desktop/build-desktop-core.sh" "$PROFILE_FLAG")"

export CGO_ENABLED=1
CGO_INCLUDE_DIR="$(native_path "$STAGE_DIR/include")"
CGO_LIBRARY_DIR="$(native_path "$STAGE_DIR/lib")"
NATIVE_STATIC_LIBS="$(<"$STAGE_DIR/native-static-libs.txt")"
export CGO_CFLAGS="${CGO_CFLAGS:-} -I$CGO_INCLUDE_DIR"
# GNU ld and MinGW resolve static archives from left to right, so rustc's native libraries must
# follow liblithe_core.a, which depends on them.
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -L$CGO_LIBRARY_DIR -llithe_core $NATIVE_STATIC_LIBS"

cd "$ROOT_DIR/desktop"
if [[ "${1:-}" == "--exec" ]]; then
    if [[ $# -lt 2 ]]; then
        printf '%s\n' "Usage: $0 --exec PROGRAM [ARGS...]" >&2
        exit 2
    fi
    shift
    exec "$@"
fi
exec go "$@"
