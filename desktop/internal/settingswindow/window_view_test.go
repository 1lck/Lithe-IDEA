package settingswindow

import (
	"math"
	"testing"
)

// TestSidebarTilesAndTitlesLineUp: in the window's compact density every top-level row has its
// tile in one column, with a chevron in front of it or not, and every title inside a group
// starts where the group's title starts.
func TestSidebarTilesAndTitlesLineUp(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{Language: "en"})
	d := openWindow(t, w)
	snapshot := d.driver.Snapshot()

	var tiles []float32
	for _, p := range snapshot.Primitives {
		if p.Bounds.X < sidebarWidth && p.Bounds.Width == tileSize && p.Bounds.Height == tileSize && p.Radius == tileRadius {
			tiles = append(tiles, p.Bounds.X)
		}
	}
	if len(tiles) != 8 {
		t.Fatalf("the sidebar paints %d tiles, want one for each of the 8 top-level rows", len(tiles))
	}
	for _, x := range tiles[1:] {
		if math.Abs(float64(x-tiles[0])) > 0.5 {
			t.Fatalf("the tiles start at %v, want one column", tiles)
		}
	}

	titleX := func(page pageID) float32 {
		t.Helper()
		title := titleOf(english(), page)
		for _, text := range snapshot.Texts {
			if text.Value == title && text.Bounds.X < sidebarWidth {
				return text.Bounds.X
			}
		}
		t.Fatalf("the sidebar does not show %q", title)
		return 0
	}
	group := titleX(pageAppearance)
	for _, page := range []pageID{pageGeneral, pageKeymap, pagePlugins, pageTools, pageAbout} {
		if x := titleX(page); math.Abs(float64(x-group)) > 0.5 {
			t.Fatalf("%q starts at %v, the group's title at %v", titleOf(english(), page), x, group)
		}
	}
}
