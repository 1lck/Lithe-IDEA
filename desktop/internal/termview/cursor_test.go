package termview

import (
	"testing"

	"github.com/vivaui/viva/gfx"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
)

// cursorRectangle is the rectangle of the cursor color the last paint drew from the cursor's
// top-left corner or along its cell's bottom edge, as a bar or an underline is.
func cursorRectangle(t *testing.T, rig *fontRig, what string) gfx.Rect {
	t.Helper()
	x, y := rig.view.layout.left, rig.view.layout.top
	return rectangleWhere(t, rig.canvas, what, func(r gfx.Rectangle) bool {
		return r.Color == fontTestLook.Cursor && r.Bounds.X == x &&
			(r.Bounds.Y == y && r.Bounds.Height == rig.view.rowH || r.Bounds.Y+r.Bounds.Height == y+rig.view.rowH && r.Bounds.Width == rig.view.cellW)
	}).Bounds
}

// The shape chosen is the cursor's until a program asks for another, and the thickness
// chosen is how wide the bar and how tall the underline draw, whichever asked for them.
func TestChosenCursorShapesAndThicknessesPaint(t *testing.T) {
	tests := []struct {
		name      string
		cursor    Cursor
		program   string
		bar       bool
		thickness float32
	}{
		{"normal bar", Cursor{Shape: term.CursorBar}, "", true, 3},
		{"thin bar", Cursor{Shape: term.CursorBar, Thickness: CursorThin}, "", true, 2},
		{"thick bar", Cursor{Shape: term.CursorBar, Thickness: CursorThick}, "", true, 5},
		{"normal underline", Cursor{Shape: term.CursorUnderline}, "", false, 2},
		{"thin underline", Cursor{Shape: term.CursorUnderline, Thickness: CursorThin}, "", false, 1},
		{"thick underline", Cursor{Shape: term.CursorUnderline, Thickness: CursorThick}, "", false, 3},
		{"a program's underline at the chosen thickness", Cursor{Shape: term.CursorBar, Thickness: CursorThick}, "\x1b[4 q", false, 3},
		{"a program's bar over a chosen block", Cursor{Thickness: CursorThin}, "\x1b[6 q", true, 2},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			rig := newFontRig(t)
			rig.view.SetCursor(test.cursor)
			rig.print(test.program)
			rig.paint()
			bounds := cursorRectangle(t, rig, "bar or underline cursor")
			switch {
			case test.bar && (bounds.Width != test.thickness || bounds.Height != rig.view.rowH):
				t.Fatalf("bar drawn %v by %v, want %v wide and the row's %v tall", bounds.Width, bounds.Height, test.thickness, rig.view.rowH)
			case !test.bar && (bounds.Height != test.thickness || bounds.Width != rig.view.cellW):
				t.Fatalf("underline drawn %v by %v, want the cell's %v wide and %v tall", bounds.Width, bounds.Height, rig.view.cellW, test.thickness)
			}
		})
	}
}

// A block chosen, or none chosen, keeps the cursor its cell's outline while the terminal does
// not have the keyboard, whatever the thickness.
func TestChosenBlockCursorStaysTheCellsOutline(t *testing.T) {
	rig := newFontRig(t)
	rig.view.SetCursor(Cursor{Shape: term.CursorBar, Thickness: CursorThick})
	rig.paint()
	rig.view.SetCursor(Cursor{Thickness: CursorThick})
	rig.paint()
	x, y := rig.view.layout.left, rig.view.layout.top
	rectangleWhere(t, rig.canvas, "left edge of the block's outline", func(r gfx.Rectangle) bool {
		return r.Color == fontTestLook.Cursor && r.Bounds.X == x && r.Bounds.Y == y && r.Bounds.Width == 1 && r.Bounds.Height == rig.view.rowH
	})
	for _, r := range rig.canvas.Rectangles() {
		if r.Color == fontTestLook.Cursor && r.Bounds.Width > 1 && r.Bounds.Height > 1 {
			t.Fatalf("a block cursor drew a bar or an underline: %+v", r.Bounds)
		}
	}
}
