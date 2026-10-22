#!/bin/zsh

set -euo pipefail

# Assembles the Subversion Support plugin package: the provider's modules and
# the Node SDK they import, vendored from sdk/node/src so the package runs
# offline without node_modules. The package holds no native code and is the
# same for every architecture; it is read-only at runtime. See
# .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md.

PLUGIN_DIR="${0:A:h}"
ROOT_DIR="${PLUGIN_DIR:h:h:h:h}"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --arch) shift 2 ;;
        *) print -u2 -- "Usage: $0 --output package-directory [--arch arm64|x86_64|universal]"; exit 2 ;;
    esac
done
[[ -n "$OUTPUT_DIR" ]] || { print -u2 -- "--output is required"; exit 2; }

provider="$OUTPUT_DIR/provider"
rm -rf "$provider"
mkdir -p "$provider/vendor/lithe-plugin-sdk"
cp "$PLUGIN_DIR"/provider/*.mjs "$provider/"
# The SDK's runtime modules only; its type declarations are for authors.
cp "$ROOT_DIR"/sdk/node/src/*.mjs "$provider/vendor/lithe-plugin-sdk/"

# plugin.json names the entry exactly, so a rename fails here instead of when
# the host first opens a working copy.
entry=$(node -e 'const m = require(process.argv[1]); process.stdout.write(m.vcsProviders[0].launch.entry)' \
    "$PLUGIN_DIR/plugin.json")
[[ -f "$OUTPUT_DIR/$entry" ]] || {
    print -u2 -- "Subversion Support declares $entry, which the assembled package does not contain."
    exit 1
}
