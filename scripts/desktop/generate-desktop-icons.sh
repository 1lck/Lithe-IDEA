#!/bin/zsh
# Regenerates the icon package of the Viva desktop client (desktop/internal/icons/):
#
#   icons.go   every icon below compiled into a ui.Icon value by the Viva icon compiler
#   NOTICE     the Lucide copyright and ISC license text that icons.go carries in its header
#
# The icons are the Lucide icons named in ICONS, downloaded at the pinned LUCIDE_VERSION tag.
# To add or drop an icon, edit ICONS and run this script again; do not edit icons.go by hand.
# The downloads go into a fresh temporary directory that is removed on exit. They are only read
# as data by the compiler, never executed, and nothing is written outside desktop/internal/icons/.
# The compiler runs through "go run <module>@<version>", so it does not depend on the go.sum of
# the desktop module and is pinned to the same Viva version as desktop/go.mod.
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
LUCIDE_VERSION="0.469.0"
VIVA_VERSION="v0.4.0"
ICONS=(
    folder folder-open folder-tree file file-text file-code chevron-down chevron-right
    git-commit-horizontal git-branch list-tree search square-terminal circle-alert play bug
    shield-check bell sparkles refresh-cw image settings ellipsis pin pin-off x plus download
    server lock lock-open check circle-check cpu activity minus history layout-grid
    chevron-left chevron-up chevrons-up-down chevrons-down-up arrow-down-left arrow-left-right
    trash-2 cloud-download locate tag cloud ellipsis-vertical panel-right eye eye-off clock
    arrow-up-down arrow-down-to-line circle-x loader-circle
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

# Run from the repository root so the compiler resolves the pinned module outside any go.mod.
cd "$ROOT_DIR"
go run "github.com/vivaui/viva/cmd/viva@$VIVA_VERSION" icons \
    -o "$OUT_FILE" -pkg icons -license "$NOTICE_FILE" "$TMP_DIR"/*.svg

UNFORMATTED="$(gofmt -l "$OUT_FILE")"
if [[ -n "$UNFORMATTED" ]]; then
    print -u2 -- "gofmt reports that the generated file is not formatted: $UNFORMATTED"
    exit 1
fi
print -r -- "$OUT_FILE"
