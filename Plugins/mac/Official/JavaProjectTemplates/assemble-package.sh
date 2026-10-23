#!/bin/zsh

set -euo pipefail

# Copies the resources plugin.json declares: generator icons and the template
# directories of the Java project generators. The package holds no runtime,
# so it is the same for every architecture. The assembled package is
# read-only at runtime; projects are generated in the user's chosen folder.
# See .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md.

PLUGIN_DIR="${0:A:h}"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --arch) shift 2 ;;
        *) print -u2 -- "Usage: $0 --output package-directory [--arch arm64|x86_64|universal]"; exit 2 ;;
    esac
done
[[ -n "$OUTPUT_DIR" ]] || { print -u2 -- "--output is required"; exit 2; }

rm -rf "$OUTPUT_DIR/icons" "$OUTPUT_DIR/templates"
cp -R "$PLUGIN_DIR/icons" "$OUTPUT_DIR/icons"
cp -R "$PLUGIN_DIR/templates" "$OUTPUT_DIR/templates"
