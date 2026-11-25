package editorview

import (
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
)

func TestLineIconAtHitsSlotsAfterScrollAndRejectsGaps(t *testing.T) {
	v := gutterView(t, 120)
	v.SetLineIcons([]LineIcon{
		{Line: 0, Slot: 0, Icon: icons.GutterImplemented(false)},
		{Line: 25, Slot: 0, Icon: icons.GutterImplementing(true)},
		{Line: 25, Slot: 1, Icon: icons.GutterOverridden(true)},
	})
	canvas := new(gfx.Canvas)
	area := gfx.Rect{X: 10, Y: 20, Width: 600, Height: 220}
	v.Paint(canvas, area, Look{})

	// Scroll down so line 25 is visible.
	v.Scroll(gfx.ScrollEvent{Target: gfx.Item(1), DeltaY: 20 * v.lineH, Precise: true})
	canvas.Reset()
	v.Paint(canvas, area, Look{})

	top := area.Y + float32(v.lineRow(25))*v.lineH - v.scroll
	for slot := range 2 {
		x := v.iconX + float32(slot)*lineIconWidth + 4
		y := top + v.lineH/2
		line, gotSlot, cell, ok := v.LineIconAt(x, y)
		if !ok || line != 25 || gotSlot != slot {
			t.Fatalf("slot %d hit = (%d, %d, %v), want (25, %d, true)", slot, line, gotSlot, ok, slot)
		}
		if cell.X != v.iconX+float32(slot)*lineIconWidth || cell.Y != top {
			t.Fatalf("slot %d cell = %+v, want X=%v Y=%v", slot, cell, v.iconX+float32(slot)*lineIconWidth, top)
		}
	}

	// Trailing inset margin, left of iconX, outside viewport, and undecorated lines must miss.
	if _, _, _, ok := v.LineIconAt(v.iconX-1, top+2); ok {
		t.Fatal("left of iconX matched")
	}
	if _, _, _, ok := v.LineIconAt(v.iconX+lineIconWidth-0.5, top+2); ok {
		t.Fatal("slot inset gap matched")
	}
	if _, _, _, ok := v.LineIconAt(v.iconX+4, top-v.lineH); ok {
		t.Fatal("undecorated line matched")
	}
	if _, _, _, ok := v.LineIconAt(v.iconX+4, area.Y-2); ok {
		t.Fatal("above viewport matched")
	}
}

func TestMultiLayerLineIconsPaintWithoutAllocating(t *testing.T) {
	v := gutterView(t, 2000)
	var marks []LineIcon
	for line := 0; line < 2000; line += 2 {
		marks = append(marks,
			LineIcon{Line: line, Slot: 0, Icon: icons.GutterImplementing(true)},
			LineIcon{Line: line, Slot: 1, Icon: icons.GutterImplemented(true)},
		)
	}
	v.SetLineIcons(marks)
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 400}
	paint := func() {
		canvas.Reset()
		v.Paint(canvas, area, Look{})
	}
	paint()
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("a frame with multi-layer line icons allocated %v times", allocs)
	}
}

func TestLineIconAtOnlyHitsFirstVisualRowOfWrappedLine(t *testing.T) {
	text := strings.Repeat("word ", 40) + "\nsecond\n"
	v := New(Config{HitID: gfx.Item(1), Label: "wrap-icons", Content: Prepare([]byte(text))})
	t.Cleanup(v.Close)
	v.SetWrap(true)
	v.SetLineIcons([]LineIcon{{Line: 0, Slot: 0, Icon: icons.GutterImplemented(false)}})
	area := gfx.Rect{Width: 260, Height: 220}
	v.Paint(new(gfx.Canvas), area, Look{})
	if v.lineRow(1) < 2 {
		t.Fatalf("expected line 0 to wrap onto at least 2 rows, lineRow(1)=%d", v.lineRow(1))
	}

	x := v.iconX + 4
	line, slot, _, ok := v.LineIconAt(x, area.Y+v.lineH/2)
	if !ok || line != 0 || slot != 0 {
		t.Fatalf("first visual row hit = (%d, %d, %v), want (0, 0, true)", line, slot, ok)
	}
	if gotLine, gotSlot, _, gotOK := v.LineIconAt(x, area.Y+v.lineH+v.lineH/2); gotOK {
		t.Fatalf("continuation row hit = (%d, %d, %v), want miss", gotLine, gotSlot, gotOK)
	}
}
