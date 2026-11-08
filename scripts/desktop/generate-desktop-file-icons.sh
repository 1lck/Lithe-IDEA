#!/bin/zsh
# Regenerates the compiled file-type icons of the Viva desktop client
# (desktop/internal/fileicons/icons.go) from the SVGs in desktop/internal/fileicons/svg/.
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
# picosvg is installed at the pinned PICOSVG_VERSION into a virtual environment in a fresh
# temporary directory that is removed on exit; nothing is written outside
# desktop/internal/fileicons/. The compiler runs through "go run <module>@<version>", pinned to
# the same Viva version as desktop/go.mod.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
PICOSVG_VERSION="0.22.3"
VIVA_VERSION="v0.5.1-0.20261108113640-16ca40bd07ab"
ICON_DIR="$ROOT_DIR/desktop/internal/fileicons"
OUT_FILE="$ICON_DIR/icons.go"
NOTICE_FILE="$ICON_DIR/NOTICE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 -m venv "$TMP_DIR/venv"
"$TMP_DIR/venv/bin/python" -m pip install --quiet --disable-pip-version-check "picosvg==$PICOSVG_VERSION"

mkdir "$TMP_DIR/svg"
for source in "$ICON_DIR"/svg/*.svg; do
    name="${source:t}"
    name="${name//_/-}"
    # picosvg runs from the temporary directory so it never reads from the repository's.
    (cd "$TMP_DIR" && "$TMP_DIR/venv/bin/picosvg" "$source") > "$TMP_DIR/$name.pico"
    sed -E '/<path /{/ fill=/!s/<path /<path fill="#000000" /;}' "$TMP_DIR/$name.pico" > "$TMP_DIR/svg/$name"
done

# Run from the repository root so the compiler resolves the pinned module outside any go.mod.
cd "$ROOT_DIR"
go run "github.com/vivaui/viva/cmd/viva@$VIVA_VERSION" icons \
    -o "$OUT_FILE" -pkg fileicons -license "$NOTICE_FILE" "$TMP_DIR"/svg/*.svg

UNFORMATTED="$(gofmt -l "$OUT_FILE")"
if [[ -n "$UNFORMATTED" ]]; then
    print -u2 -- "gofmt reports that the generated file is not formatted: $UNFORMATTED"
    exit 1
fi
print -r -- "$OUT_FILE"
