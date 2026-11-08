#!/bin/zsh
# Runs the go command in desktop/ with cgo pointed at the Lithe-core-rust library staged by
# scripts/desktop/build-desktop-core.sh:
#
#   scripts/desktop/desktop-go.sh test ./...
#   scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe ./cmd/lithe
#   GOARCH=amd64 scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe-amd64 ./cmd/lithe
#
# The core is staged again before every run. A changed pin or a changed LITHE_CORE_RUST_DIR
# checkout would otherwise keep linking the library of the previous revision; when nothing
# changed, git and cargo find everything up to date and the step takes about a second.
#
# LITHE_DESKTOP_CORE_PROFILE picks the staged profile (debug by default). On macOS, a GOARCH
# other than the host's builds the core for the matching Rust target, so an Apple silicon Mac
# can build the Intel client; that target must be installed with rustup. The flags are passed
# through CGO_CFLAGS and CGO_LDFLAGS, so no path of this machine is written into the Go sources.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
PROFILE="${LITHE_DESKTOP_CORE_PROFILE:-debug}"
PROFILE_FLAG="--debug"
[[ "$PROFILE" == "release" ]] && PROFILE_FLAG="--release"

if [[ -n "${GOARCH:-}" && "$(uname -s)" == "Darwin" ]]; then
    case "$GOARCH" in
        arm64) export LITHE_CORE_TARGET="aarch64-apple-darwin" ;;
        amd64) export LITHE_CORE_TARGET="x86_64-apple-darwin" ;;
        *) print -u2 -- "GOARCH=$GOARCH has no macOS build of the core; use arm64 or amd64."; exit 2 ;;
    esac
fi
STAGE_DIR="$("$ROOT_DIR/scripts/desktop/build-desktop-core.sh" "$PROFILE_FLAG")"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export CGO_ENABLED=1
export CGO_CFLAGS="${CGO_CFLAGS:-} -I$STAGE_DIR/include"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -L$STAGE_DIR/lib $(<"$STAGE_DIR/native-static-libs.txt")"
cd "$ROOT_DIR/desktop"
exec go "$@"
