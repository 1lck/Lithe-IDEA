#!/bin/zsh
# Regenerates the compiled IntelliJ icons of the Viva desktop client:
#
#   desktop/internal/fileicons/icons.go       file-type and folder icons, from fileicons/svg/
#   desktop/internal/fileicons/icons_tree.go  disclosure icons, from fileicons/svg/tree/
#   desktop/internal/toolicons/icons.go       tool window stripe icons, from toolicons/svg/
#
# With no argument the script regenerates all three. Pass --tree-only to regenerate the
# disclosure icons alone, or --tools-only to regenerate the tool window icons alone; the other
# vectors stay as they are.
#
# The SVGs are IntelliJ Community icons (see the NOTICE of each package). Many of them draw
# strokes, so each SVG first goes through picosvg, which turns every stroke into a filled outline
# of the same color.
#
# File-type icons keep their colors, because the Viva icon compiler keeps the colors of filled
# shapes. picosvg drops the fill of a path that relied on the SVG default (black), so the script
# writes that default back. Every underscore of a file name becomes a hyphen, which the compiler
# reads as a word break: <name>_dark.svg becomes the Go name <Name>Dark, and the IntelliJ name
# db_set_breakpoint.svg becomes DbSetBreakpoint.
#
# Tool window icons lose their single color instead: the stripe tints them by state. The compiler
# draws all uncolored shapes of an icon as one path filled with the nonzero rule, where two shapes
# that overlap with opposite windings would cut holes into each other, so the script unions the
# shapes of each icon into one outline with skia-pathops, writes it without a fill and marks the
# root stroke-width="0", which tells the compiler the tinted shapes are filled rather than stroked.
# <name>@20x20.svg becomes the Go name <Name>. Only the light variants are kept: the dark ones draw
# the same shapes in another color.
#
# To add or change an icon, edit the svg/ directory and run this script again; do not edit the
# generated files by hand. Python 3.9 or 3.11, picosvg and its dependencies are fixed to versions
# that reproduce the existing icon vectors. Set LITHE_ICON_PYTHON to a supported executable when
# it is not on PATH. Dependencies are installed in a fresh temporary virtual environment that is
# removed on exit; nothing is written outside desktop/internal/fileicons/ and
# desktop/internal/toolicons/. The compiler is built into the same temporary directory (also
# removed on exit) from the Viva source that desktop/go.mod resolves to (through its replace
# directive, the Lithe-IDEA/viva fork) with Viva's own go.mod and go.sum. "go run
# <module>@<version>" would ignore the replace.
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
TOOL_DIR="$ROOT_DIR/desktop/internal/toolicons"
TOOL_OUT_FILE="$TOOL_DIR/icons.go"
MODE=all
if [[ $# == 1 && "${1:-}" == "--tree-only" ]]; then
    MODE=tree
elif [[ $# == 1 && "${1:-}" == "--tools-only" ]]; then
    MODE=tools
elif [[ $# != 0 ]]; then
    print -u2 -- "Usage: $0 [--tree-only | --tools-only]"
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

# Built once for every compile below; the binary lives in the temporary directory only.
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

# UNION_SHAPES reads a picosvg output (argv[1]) and writes it (argv[2]) with all its shapes
# unioned into one uncolored path under a root marked stroke-width="0". It refuses an icon of more
# than one color, or one that keeps anything but paths after picosvg, rather than flatten it.
UNION_SHAPES='
import sys

import pathops
from lxml import etree
from picosvg.svg_pathops import skia_path, svg_commands
from picosvg.svg_types import SVGPath

SVG = "{http://www.w3.org/2000/svg}"
source, target = sys.argv[1], sys.argv[2]
tree = etree.parse(source)
root = tree.getroot()
for defs in root.findall(SVG + "defs"):
    if len(defs):
        sys.exit(source + ": definitions are not supported in a tool window icon")
    root.remove(defs)
others = [child.tag for child in root if child.tag != SVG + "path"]
if others:
    sys.exit(source + ": unexpected elements " + ", ".join(others))
paths = list(root)
if len({path.get("fill") for path in paths}) != 1:
    sys.exit(source + ": a tool window icon must draw in one color")
outline = pathops.Path()
for path in paths:
    shape = skia_path(SVGPath(d=path.get("d")).as_cmd_seq(), path.get("fill-rule", "nonzero"))
    outline = pathops.op(outline, shape, pathops.PathOp.UNION)
    root.remove(path)
etree.SubElement(root, SVG + "path", d=SVGPath.from_commands(svg_commands(outline)).round_floats(3).d)
root.set("stroke-width", "0")
tree.write(target)
'

compile_tool_icons() {
    local converted_dir="$TMP_DIR/tools" name source
    mkdir "$converted_dir"
    for source in "$TOOL_DIR"/svg/*@20x20.svg; do
        name="${source:t:r}"
        name="${name%@20x20}"
        (cd "$TMP_DIR" && "$TMP_DIR/venv/bin/picosvg" "$source") > "$TMP_DIR/$name.tool.pico"
        # -I keeps the interpreter from importing anything from the working directory.
        "$TMP_DIR/venv/bin/python" -I -c "$UNION_SHAPES" "$TMP_DIR/$name.tool.pico" "$converted_dir/$name.svg"
    done
    "$TMP_DIR/viva" icons \
        -o "$TOOL_OUT_FILE" -pkg toolicons -license "$TOOL_DIR/NOTICE" "$converted_dir"/*.svg
    rm "$converted_dir"/*.svg
    rmdir "$converted_dir"
}

OUTPUTS=()
if [[ "$MODE" == all ]]; then
    compile_icons "$ICON_DIR/svg" "$OUT_FILE"
    OUTPUTS+=("$OUT_FILE")
fi
if [[ "$MODE" != tools ]]; then
    compile_icons "$ICON_DIR/svg/tree" "$TREE_OUT_FILE"
    OUTPUTS+=("$TREE_OUT_FILE")
fi
if [[ "$MODE" != tree ]]; then
    compile_tool_icons
    OUTPUTS+=("$TOOL_OUT_FILE")
fi

UNFORMATTED="$(gofmt -l "${OUTPUTS[@]}")"
if [[ -n "$UNFORMATTED" ]]; then
    print -u2 -- "gofmt reports that the generated file is not formatted: $UNFORMATTED"
    exit 1
fi
print -rl -- "${OUTPUTS[@]}"
