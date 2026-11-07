#!/bin/zsh
# Runs the go command in desktop/ with cgo pointed at the Lithe-core-rust library staged by
# scripts/desktop/build-desktop-core.sh:
#
#   scripts/desktop/desktop-go.sh test ./...
#   scripts/desktop/desktop-go.sh build -o ../.artifacts/desktop/bin/lithe ./cmd/lithe
#
# The core is staged again before every run. A changed pin or a changed LITHE_CORE_RUST_DIR
# checkout would otherwise keep linking the library of the previous revision; when nothing
# changed, git and cargo find everything up to date and the step takes about a second.
#
# LITHE_DESKTOP_CORE_PROFILE picks the staged profile (debug by default). The flags are passed
# through CGO_CFLAGS and CGO_LDFLAGS, so no path of this machine is written into the Go sources.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
PROFILE="${LITHE_DESKTOP_CORE_PROFILE:-debug}"
STAGE_DIR="$ROOT_DIR/.artifacts/desktop/lithe-core/$PROFILE"
PROFILE_FLAG="--debug"
[[ "$PROFILE" == "release" ]] && PROFILE_FLAG="--release"
"$ROOT_DIR/scripts/desktop/build-desktop-core.sh" "$PROFILE_FLAG" >&2

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export CGO_ENABLED=1
export CGO_CFLAGS="${CGO_CFLAGS:-} -I$STAGE_DIR/include"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -L$STAGE_DIR/lib $(<"$STAGE_DIR/native-static-libs.txt")"
cd "$ROOT_DIR/desktop"
exec go "$@"
