package termview

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// rowIdentities is the text identity of every row label the last paint drew, top to bottom.
func rowIdentities(view *View, canvas *gfx.Canvas) []gfx.TextIdentity {
	var identities []gfx.TextIdentity
	for _, text := range canvas.Texts() {
		if text.Identity.Owner == view.owner && text.Identity.Item != 0 {
			identities = append(identities, text.Identity)
		}
	}
	return identities
}

// Each row is painted with its line's identity, so the rows a scroll keeps on the grid keep
// theirs and a backend that retains rasterized text (the Windows one) redraws only the rows
// that enter.
func TestRowsKeepTheirTextIdentityAcrossScrolling(t *testing.T) {
	rig := newFontRig(t)
	var lines strings.Builder
	for i := range 50 {
		fmt.Fprintf(&lines, "line %d\r\n", i)
	}
	output(rig.view, &rig.shell.fakeShell, lines.String())
	// Off the live screen every row holds a written line; the blank row under the cursor
	// paints no label.
	rig.view.screen.Scroll(2)
	rig.paint()
	before := rowIdentities(rig.view, rig.canvas)
	_, rows := rig.view.screen.Size()
	if len(before) != rows {
		t.Fatalf("row labels with an identity = %d, want one per row (%d)", len(before), rows)
	}
	for row, identity := range before {
		if want := (gfx.TextIdentity{Owner: rig.view.owner, Item: rig.view.screen.Row(row).ID}); identity != want {
			t.Fatalf("row %d identity = %+v, want %+v", row, identity, want)
		}
	}

	// One line of scrolling moves every row down a place; the rows still on the grid keep
	// the identities they had.
	rig.view.screen.Scroll(1)
	rig.paint()
	after := rowIdentities(rig.view, rig.canvas)
	if len(after) != len(before) {
		t.Fatalf("row labels after scrolling = %d, want %d", len(after), len(before))
	}
	if !slices.Equal(after[1:], before[:len(before)-1]) {
		t.Fatalf("identities after scrolling = %+v, want the earlier ones moved down a row: %+v", after, before)
	}
}

// Line IDs are only unique within one screen, so every view paints under an owner of its
// own: two terminals side by side never give two labels of a frame the same identity.
func TestViewsPaintUnderOwnersOfTheirOwn(t *testing.T) {
	first, second := newFontRig(t), newFontRig(t)
	if first.view.owner == 0 || second.view.owner == 0 {
		t.Fatalf("owners = %d and %d, want both nonzero: zero means no identity", first.view.owner, second.view.owner)
	}
	if first.view.owner == second.view.owner {
		t.Fatalf("two views share owner %d", first.view.owner)
	}
}
