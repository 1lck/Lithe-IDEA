package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
)

// The stored cursor names the cursor the terminals draw; a value the Terminal page does not
// offer is the default block of normal thickness.
func TestTerminalCursorFollowsTheStoredChoice(t *testing.T) {
	tests := []struct {
		shape, thickness string
		want             termview.Cursor
	}{
		{"", "", termview.Cursor{}},
		{"bar", "thick", termview.Cursor{Shape: term.CursorBar, Thickness: termview.CursorThick}},
		{"underline", "thin", termview.Cursor{Shape: term.CursorUnderline, Thickness: termview.CursorThin}},
		{"beam", "heavy", termview.Cursor{}},
	}
	for _, test := range tests {
		a := &App{settings: settings{TerminalCursorShape: test.shape, TerminalCursorThickness: test.thickness}}
		if got := a.terminalCursor(); got != test.want {
			t.Errorf("%q %q: cursor %+v, want %+v", test.shape, test.thickness, got, test.want)
		}
	}
}

// barWidths are the widths of the tall thin rectangles the last frame drew inside the
// terminal, the bar cursor among them.
func barWidths(h *harness, terminal *terminal) map[float32]bool {
	area := h.topHit(terminal.hit)
	widths := map[float32]bool{}
	for _, primitive := range h.driver.Snapshot().Primitives {
		bounds := primitive.Bounds
		if bounds.Width > 1 && bounds.Width <= 5 && bounds.Height >= 8 &&
			bounds.X >= area.X && bounds.X+bounds.Width <= area.X+area.Width && bounds.Y >= area.Y && bounds.Y+bounds.Height <= area.Y+area.Height {
			widths[bounds.Width] = true
		}
	}
	return widths
}

// A cursor chosen on the Terminal page is stored, shown back to the page, and drawn at once by
// a terminal already open.
func TestChosenTerminalCursorReachesOpenTerminals(t *testing.T) {
	h, terminal, _ := pasteTerminal(t, nil)
	h.settle()
	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.click(center(h.button(itemTerminal)))
	}
	h.settle()
	if terminal.hit.IsZero() {
		t.Fatal("the terminal is not shown")
	}
	// choose hands the choice over as the settings window's SetTerminalCursor does.
	choose := func(shape, thickness string) {
		h.app.post(func(a *App) { a.setTerminalCursor(shape, thickness) })
		h.settle()
	}
	if widths := barWidths(h, terminal); widths[5] || widths[2] {
		t.Fatalf("the default cursor drew a bar: %v", widths)
	}

	choose(settingswindow.CursorShapeBar, settingswindow.CursorThicknessThick)
	if widths := barWidths(h, terminal); !widths[5] {
		t.Fatalf("a thick bar was not drawn in the open terminal: %v", widths)
	}
	choose(settingswindow.CursorShapeBar, settingswindow.CursorThicknessThin)
	if widths := barWidths(h, terminal); !widths[2] || widths[5] {
		t.Fatalf("a thin bar was not drawn in the open terminal: %v", widths)
	}

	h.settle()
	var stored settings
	if _, err := h.app.store.Load(settingsFile, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.TerminalCursorShape != "bar" || stored.TerminalCursorThickness != "thin" {
		t.Fatalf("stored %q %q, want bar thin", stored.TerminalCursorShape, stored.TerminalCursorThickness)
	}
	h.app.setTerminalCursor("beam", "")
	if h.app.settings.TerminalCursorShape != settingswindow.CursorShapeBlock || h.app.settings.TerminalCursorThickness != settingswindow.CursorThicknessNormal {
		t.Fatalf("an unknown shape was stored as %q %q", h.app.settings.TerminalCursorShape, h.app.settings.TerminalCursorThickness)
	}
}
