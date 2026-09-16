#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
bun install --frozen-lockfile --filter @lithe/editor --cwd "$root"
bun "$root/macos/EditorFrontend/build.ts"
