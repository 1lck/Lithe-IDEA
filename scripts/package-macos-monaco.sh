#!/bin/zsh
set -euo pipefail

# Local verification package using the ordinary product build and editor assets.
root=${0:A:h:h}
cd "$root"
destination=$(mktemp -d "$root/.artifacts/monaco-workbench/release.XXXXXX")
LITHE_DIST_ROOT="$destination" LITHE_ARCH="$(uname -m)" ./scripts/package-app.sh
app="$destination/Lithe-$(uname -m).app"
print -r -- "$app" > .artifacts/monaco-workbench/app-path.txt
print "Monaco experiment packaged: $app"
