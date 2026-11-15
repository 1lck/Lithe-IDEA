#!/bin/zsh
# Regenerates the icon package of the Viva desktop client (desktop/internal/icons/):
#
#   icons.go   every icon below compiled into a gfx.Icon value by the Viva icon compiler
#   NOTICE     the Lucide copyright and ISC license text that icons.go carries in its header
#
# The icons are the Lucide icons named in ICONS, downloaded at the pinned LUCIDE_VERSION tag.
# To add or drop an icon, edit ICONS and run this script again; do not edit icons.go by hand.
# The downloads go into a fresh temporary directory that is removed on exit. They are only read
# as data by the compiler, never executed, and nothing is written outside desktop/internal/icons/.
# The compiler is built from the Viva source that desktop/go.mod resolves to (through its replace
# directive, the Lithe-IDEA/viva fork) with Viva's own go.mod and go.sum, so it does not depend on
# the go.sum of the desktop module. "go run <module>@<version>" would ignore the replace.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
LUCIDE_VERSION="0.469.0"
# desktop/go.mod (its require and replace) is the only place the Viva source is pinned; the tools
# come from the same module. The download honours the replace and fills the module cache, and the
# Dir lookup then names the replacement's directory (or upstream's when there is no replace).
go -C "$ROOT_DIR/desktop" mod download github.com/vivaui/viva
VIVA_DIR="$(go -C "$ROOT_DIR/desktop" list -m -f '{{.Dir}}' github.com/vivaui/viva)"
ICONS=(
    folder folder-open folder-tree file file-text file-code chevron-down chevron-right
    git-commit-horizontal git-branch list-tree search square-terminal circle-alert play bug
    shield-check bell sparkles refresh-cw image settings ellipsis pin pin-off x plus download
    server lock lock-open check circle-check cpu activity minus history layout-grid
    chevron-left chevron-up chevrons-up-down chevrons-down-up arrow-down-left arrow-left-right
    trash-2 cloud-download locate tag cloud ellipsis-vertical panel-right eye eye-off clock
    arrow-up-down arrow-down-to-line circle-x loader-circle wrap-text info copy square wrench
    eraser undo-2 pencil arrow-up arrow-down git-compare fold-vertical unfold-vertical archive
    columns-2 pause redo-dot arrow-down-to-dot arrow-up-from-dot circle-dot circle-slash braces
    variable rotate-ccw github monitor external-link message-circle messages-square
    zoom-in zoom-out image-off
)

RAW_URL="https://raw.githubusercontent.com/lucide-icons/lucide/$LUCIDE_VERSION"
OUT_DIR="$ROOT_DIR/desktop/internal/icons"
OUT_FILE="$OUT_DIR/icons.go"
NOTICE_FILE="$OUT_DIR/NOTICE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for name in "${ICONS[@]}"; do
    curl -fsSL --retry 2 --max-time 30 -o "$TMP_DIR/$name.svg" "$RAW_URL/icons/$name.svg"
done
curl -fsSL --retry 2 --max-time 30 -o "$TMP_DIR/LICENSE" "$RAW_URL/LICENSE"

mkdir -p "$OUT_DIR"
{
    print -r -- "Icons from Lucide $LUCIDE_VERSION (https://lucide.dev), used under the ISC License:"
    print -r -- ""
    cat "$TMP_DIR/LICENSE"
} > "$NOTICE_FILE"

# The compiler binary goes into the temporary directory (removed on exit); it is named viva, so it
# does not match the *.svg glob below.
go -C "$VIVA_DIR" build -o "$TMP_DIR/viva" ./cmd/viva
"$TMP_DIR/viva" icons \
    -o "$OUT_FILE" -pkg icons -license "$NOTICE_FILE" "$TMP_DIR"/*.svg

UNFORMATTED="$(gofmt -l "$OUT_FILE")"
if [[ -n "$UNFORMATTED" ]]; then
    print -u2 -- "gofmt reports that the generated file is not formatted: $UNFORMATTED"
    exit 1
fi
print -r -- "$OUT_FILE"
