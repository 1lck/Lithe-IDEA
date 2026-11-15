package termview

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

// A clear Background lets what is behind the terminal show through, while the terminal's own
// color stays the Solid one: the ink of the text under the cursor and the color programs are
// told the terminal has.
func TestAClearBackgroundKeepsTheSolidColorForInkAndQueries(t *testing.T) {
	solid := gfx.RGB(10, 20, 30)
	look := fontTestLook
	look.Background = gfx.Color{}
	look.Solid = solid

	pal := newPalette(look, 1)
	if pal.ground != (gfx.Color{}) {
		t.Fatalf("ground = %+v, want the clear Background", pal.ground)
	}
	if pal.terminal != solid {
		t.Fatalf("terminal = %+v, want Solid %+v", pal.terminal, solid)
	}

	rig := newFontRig(t)
	rig.canvas.Reset()
	rig.view.Paint(rig.canvas, fontTestArea, look)
	ground := rectangleWhere(t, rig.canvas, "fill of the whole area", func(r gfx.Rectangle) bool {
		return r.Bounds == fontTestArea
	})
	if ground.Color != (gfx.Color{}) {
		t.Fatalf("the area was filled with %+v, want the clear Background", ground.Color)
	}
	for _, r := range rig.canvas.Rectangles() {
		if r.Color == solid {
			t.Fatalf("the paint filled %+v with the Solid color; only ink and the composition clear use it", r.Bounds)
		}
	}
}

// Without Solid the terminal's own color is Background, as it was before Solid existed.
func TestNoSolidColorTakesTheBackground(t *testing.T) {
	pal := newPalette(fontTestLook, 1)
	if pal.terminal != fontTestLook.Background || pal.ground != fontTestLook.Background {
		t.Fatalf("terminal = %+v, ground = %+v, want both %+v", pal.terminal, pal.ground, fontTestLook.Background)
	}
}

// The system terminal's colors are measured against the Solid color, not the clear ground:
// against a clear ground every color would read as black and pass or fail at random.
func TestNativeColorsAreMeasuredAgainstTheSolidColor(t *testing.T) {
	white := [3]uint8{255, 255, 255}
	var native [16]NativeColor
	native[1] = NativeColor{RGB: white, Set: true}
	look := Look{Dark: true, Background: gfx.Color{}, Solid: gfx.RGB(255, 255, 255), Native: &native}
	if got := newPalette(look, 1).ansi[1]; got == white {
		t.Fatalf("white replaced ANSI red although it cannot be read on the white Solid color")
	}
	look.Solid = gfx.RGB(0, 0, 0)
	if got := newPalette(look, 1).ansi[1]; got != white {
		t.Fatalf("ANSI red = %v, want the native white, which reads on the black Solid color", got)
	}
}
