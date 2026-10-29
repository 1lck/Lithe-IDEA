#!/bin/zsh
set -euo pipefail

args=()
for arg in "$@"; do
    # SwiftPM 6.2 emits this warning-control option unconditionally, but the
    # linker bundled with Xcode Command Line Tools 14.x does not recognize it.
    [[ "$arg" == "-no_warn_duplicate_libraries" ]] || args+=("$arg")
done

exec "$(/usr/bin/xcrun --find ld)" "${args[@]}"
