#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
bun install --frozen-lockfile --cwd "$root/frontend/editor"
bun "$root/macos/EditorFrontend/build.ts"
