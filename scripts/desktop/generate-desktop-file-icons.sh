#!/bin/zsh
# Regenerates the compiled file-type icons of the Viva desktop client
# (desktop/internal/fileicons/icons.go and icons_tree.go) from the SVGs in
# desktop/internal/fileicons/svg/. Pass --tree-only to regenerate disclosure icons without
# changing the existing file-type and folder vectors.
#
# The SVGs are IntelliJ Community icons (see desktop/internal/fileicons/NOTICE). Many of them
# draw colored strokes, and the Viva icon compiler keeps the colors of filled shapes only, so
# each SVG first goes through picosvg, which turns every stroke into a filled outline of the same
# color. picosvg drops the fill of a path that relied on the SVG default (black), so the script
# writes that default back. Every underscore of a file name becomes a hyphen, which the compiler
# reads as a word break: <name>_dark.svg becomes the Go name <Name>Dark, and the IntelliJ name
# db_set_breakpoint.svg becomes DbSetBreakpoint.
#
# To add or change an icon, edit svg/ and run this script again; do not edit icons.go by hand.
# Python 3.9 or 3.11, picosvg and its dependencies are fixed to versions that reproduce the
# existing icon vectors. Set LITHE_ICON_PYTHON to a supported executable when it is not on PATH.
# Dependencies are installed in a fresh temporary virtual environment that is removed on exit;
# nothing is written outside desktop/internal/fileicons/. The compiler is built into the same
# temporary directory (also removed on exit) from the Viva source that desktop/go.mod resolves to
# (through its replace directive, the Lithe-IDEA/viva fork) with Viva's own go.mod and go.sum.
# "go run <module>@<version>" would ignore the replace.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
# desktop/go.mod (its require and replace) is the only place the Viva source is pinned; the tools
# come from the same module. The download honours the replace and fills the module cache, and the
# Dir lookup then names the replacement's directory (or upstream's when there is no replace).
go -C "$ROOT_DIR/desktop" mod download github.com/vivaui/viva
VIVA_DIR="$(go -C "$ROOT_DIR/desktop" list -m -f '{{.Dir}}' github.com/vivaui/viva)"
ICON_DIR="$ROOT_DIR/desktop/internal/fileicons"
OUT_FILE="$ICON_DIR/icons.go"
TREE_OUT_FILE="$ICON_DIR/icons_tree.go"
NOTICE_FILE="$ICON_DIR/NOTICE"
TREE_ONLY=false
if [[ "${1:-}" == "--tree-only" && $# == 1 ]]; then
    TREE_ONLY=true
elif [[ $# != 0 ]]; then
    print -u2 -- "Usage: $0 [--tree-only]"
    exit 2
fi

is_supported_python() {
    "$1" -c 'import sys; sys.exit(0 if sys.version_info[:2] in ((3, 9), (3, 11)) else 1)' >/dev/null 2>&1
}

PYTHON="${LITHE_ICON_PYTHON:-}"
if [[ -n "$PYTHON" ]]; then
    if ! is_supported_python "$PYTHON"; then
        print -u2 -- "LITHE_ICON_PYTHON must name a working Python 3.9 or 3.11 interpreter."
        exit 1
    fi
else
    for candidate in python3.11 python3.9 /usr/bin/python3 python3; do
        if command -v "$candidate" >/dev/null 2>&1 && is_supported_python "$candidate"; then
            PYTHON="$candidate"
            break
        fi
    done
    if [[ -z "$PYTHON" ]]; then
        print -u2 -- "Python 3.9 or 3.11 is required; set LITHE_ICON_PYTHON to its executable."
        exit 1
    fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

"$PYTHON" -m venv "$TMP_DIR/venv"
"$TMP_DIR/venv/bin/python" -m pip install --quiet --disable-pip-version-check \
    "picosvg==0.22.3" "skia-pathops==0.8.0.post2" "lxml==6.1.3" "absl-py==2.3.1"

# Built once for both compile_icons calls; the binary lives in the temporary directory only.
go -C "$VIVA_DIR" build -o "$TMP_DIR/viva" ./cmd/viva

compile_icons() {
    local source_dir="$1" output="$2" name source
    local converted_dir="$TMP_DIR/converted"
    mkdir "$converted_dir"
    for source in "$source_dir"/*.svg; do
        name="${source:t}"
        name="${name//_/-}"
        # picosvg runs from the temporary directory so it never reads from the repository's.
        (cd "$TMP_DIR" && "$TMP_DIR/venv/bin/picosvg" "$source") > "$TMP_DIR/$name.pico"
        sed -E '/<path /{/ fill=/!s/<path /<path fill="#000000" /;}' "$TMP_DIR/$name.pico" > "$converted_dir/$name"
    done
    "$TMP_DIR/viva" icons \
        -o "$output" -pkg fileicons -license "$NOTICE_FILE" "$converted_dir"/*.svg
    rm "$converted_dir"/*.svg
    rmdir "$converted_dir"
}

if [[ "$TREE_ONLY" == false ]]; then
    compile_icons "$ICON_DIR/svg" "$OUT_FILE"
fi
compile_icons "$ICON_DIR/svg/tree" "$TREE_OUT_FILE"

UNFORMATTED="$(gofmt -l "$OUT_FILE" "$TREE_OUT_FILE")"
if [[ -n "$UNFORMATTED" ]]; then
    print -u2 -- "gofmt reports that the generated file is not formatted: $UNFORMATTED"
    exit 1
fi
if [[ "$TREE_ONLY" == false ]]; then
    print -r -- "$OUT_FILE"
fi
print -r -- "$TREE_OUT_FILE"
