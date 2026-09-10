#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_DIR="${1:?Usage: embed-sparkle.sh app-directory}"
frameworks=("$ROOT_DIR"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework(N))
if [[ ${#frameworks} != 1 ]]; then
    print -u2 -- "Resolve the pinned Sparkle Swift package before packaging."
    exit 1
fi
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "${frameworks[1]}" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
