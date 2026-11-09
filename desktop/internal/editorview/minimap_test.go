package editorview

import (
	"fmt"
	"math"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/gfx"
)

// The parts of a view made by newChromeView.
var (
	testMinimap  = gfx.Item(2)
	testToggle   = gfx.Item(3)
	testVertical = gfx.Item(4)
	testSideways = gfx.Item(5)
)

// newChromeView is a view of text with a minimap, its button and both scrollbars, the minimap
// shown.
func newChromeView(t *testing.T, text string) *View {
	t.Helper()
	v := New(Config{
		HitID: gfx.Item(1), Label: "test", Text: []byte(text),
		MinimapID: testMinimap, MinimapToggleID: testToggle,
		VerticalBarID: testVertical, HorizontalBarID: testSideways,
	})
	t.Cleanup(v.Close)
	v.SetMinimap(true)
	return v
}

// numberedLines is count lines of differing lengths.
func numberedLines(count int) string {
	var text strings.Builder
	for i := range count {
		fmt.Fprintf(&text, "line %d %s\n", i+1, strings.Repeat("x", i%13))
	}
	return text.String()
}

// paintIn paints v in area and returns the canvas.
func paintIn(v *View, area gfx.Rect) *gfx.Canvas {
	canvas := new(gfx.Canvas)
	v.Paint(canvas, area, Look{})
	return canvas
}

func hitOf(canvas *gfx.Canvas, id gfx.ID) (gfx.Hit, bool) {
	for _, hit := range canvas.Hits() {
		if hit.ID == id {
			return hit, true
		}
	}
	return gfx.Hit{}, false
}

func near(a, b float32) bool { return math.Abs(float64(a-b)) < 0.01 }

// pointer sends v a primary button event of kind at (x, y) over target.
func pointer(v *View, kind gfx.PointerEventKind, target gfx.ID, x, y float32) bool {
	_, ok := v.Pointer(gfx.PointerEvent{Kind: kind, Button: gfx.PointerButtonPrimary, X: x, Y: y, Target: target})
	return ok
}

// The minimap sits between the text and the vertical scrollbar and takes the text's room, and a
// view too narrow for it, or one the window hid it in, gives the text the whole width.
func TestMinimapTakesRoomLeftOfTheScrollbar(t *testing.T) {
	v := newChromeView(t, numberedLines(300))
	area := gfx.Rect{X: 20, Y: 30, Width: 800, Height: 400}
	canvas := paintIn(v, area)
	want := gfx.Rect{X: area.X + area.Width - barTrack - minimapWidth, Y: area.Y, Width: minimapWidth, Height: area.Height}
	if v.mm.rect != want {
		t.Fatalf("minimap at %+v, want %+v", v.mm.rect, want)
	}
	if v.textRight != want.X {
		t.Fatalf("the text ends at %v, want the minimap's left edge %v", v.textRight, want.X)
	}
	if hit, ok := hitOf(canvas, testMinimap); !ok || hit.Bounds != want {
		t.Fatalf("minimap hit = %+v (declared %v), want it over the minimap", hit, ok)
	}
	if hit, ok := hitOf(canvas, testVertical); !ok || hit.Bounds.X != area.X+area.Width-barTrack {
		t.Fatalf("vertical bar hit = %+v (declared %v), want it at the right edge", hit, ok)
	}
	if _, ok := hitOf(canvas, testToggle); ok {
		t.Fatal("the minimap's button shows with the pointer away from the minimap")
	}

	narrow := gfx.Rect{X: 0, Y: 0, Width: 300, Height: 400}
	canvas = paintIn(v, narrow)
	if v.mm.rect != (gfx.Rect{}) || v.textRight != narrow.Width {
		t.Fatalf("a narrow view shows the minimap at %+v, the text ending at %v", v.mm.rect, v.textRight)
	}
	if _, ok := hitOf(canvas, testMinimap); ok {
		t.Fatal("a narrow view declares the minimap")
	}

	v.SetMinimap(false)
	paintIn(v, area)
	if v.mm.rect != (gfx.Rect{}) || v.textRight != area.X+area.Width {
		t.Fatalf("a hidden minimap is at %+v, the text ending at %v", v.mm.rect, v.textRight)
	}
}

// The slider of a text taller than the minimap travels the whole height, the rows scrolling
// under it, and dragging it to where it is keeps the scroll.
func TestMinimapSliderTravelsTheWholeHeightOfATallText(t *testing.T) {
	v := newChromeView(t, numberedLines(2000))
	area := gfx.Rect{Width: 800, Height: 400}
	paintIn(v, area)
	l := v.minimapLayout()
	extent := v.maxScroll() / v.lineH * minimapRowH
	if l.sliderTop != 0 || l.offset != 0 {
		t.Fatalf("at the top the slider is at %v and the rows scrolled %v", l.sliderTop, l.offset)
	}
	if !near(l.sliderH, area.Height/v.lineH*minimapRowH) {
		t.Fatalf("slider height = %v, want the %v rows in view", l.sliderH, area.Height/v.lineH)
	}
	v.scroll = v.maxScroll()
	paintIn(v, area)
	l = v.minimapLayout()
	if !near(l.sliderTop+l.sliderH, area.Height) || !near(l.offset, extent+l.sliderH-area.Height) {
		t.Fatalf("at the bottom the slider ends at %v and the rows scrolled %v, want %v and %v",
			l.sliderTop+l.sliderH, l.offset, area.Height, extent+l.sliderH-area.Height)
	}
	v.scroll = v.maxScroll() / 3
	paintIn(v, area)
	l = v.minimapLayout()
	if got := l.scrollFor(l.sliderTop); math.Abs(float64(got-v.scroll)) > 0.5 {
		t.Fatalf("the slider at its place scrolls to %v, want %v", got, v.scroll)
	}
	// The rows the minimap shows are the ones the slider is over.
	_, first, last, _ := v.minimapRange()
	viewFirst := int(v.scroll / v.lineH)
	viewLast := int((v.scroll + area.Height) / v.lineH)
	if first > viewFirst || last < viewLast {
		t.Fatalf("the minimap shows rows %d-%d, not all of %d-%d in view", first, last, viewFirst, viewLast)
	}
}

// The slider of a text that fits in the minimap moves over its rows and the rows stay still,
// and at the bottom of the scroll it ends where the last row does.
func TestMinimapSliderOfAShortTextMovesOverItsRows(t *testing.T) {
	v := newChromeView(t, numberedLines(60))
	area := gfx.Rect{Width: 800, Height: 400}
	v.scroll = 1e9
	paintIn(v, area)
	l := v.minimapLayout()
	end := float32(v.rowCount()) * minimapRowH
	if l.offset != 0 || !near(l.sliderTop+l.sliderH, end) {
		t.Fatalf("at the bottom the rows scrolled %v and the slider ends at %v, want 0 and the last row's end %v",
			l.offset, l.sliderTop+l.sliderH, end)
	}
}

// The text scrolls down until its last row is at the bottom of the view, not past it, and a
// text that fits does not scroll. A horizontal bar keeps its track under the last row.
func TestTheTextStopsScrollingAtItsLastRow(t *testing.T) {
	area := gfx.Rect{X: 20, Y: 30, Width: 800, Height: 400}
	lastRowEnd := func(v *View) float32 {
		return area.Y + float32(v.rowCount())*v.lineH - v.scroll
	}
	wheel := func(v *View, dy float32) {
		v.Scroll(gfx.ScrollEvent{Target: v.cfg.HitID, DeltaY: dy, Precise: true})
		paintIn(v, area)
	}

	tall := newChromeView(t, numberedLines(200))
	paintIn(tall, area)
	wheel(tall, 1e6)
	if end := lastRowEnd(tall); !near(end, area.Y+area.Height) {
		t.Fatalf("at the bottom the last row ends at %v, want the view's bottom %v", end, area.Y+area.Height)
	}
	if _, ok := tall.Scroll(gfx.ScrollEvent{Target: tall.cfg.HitID, DeltaY: 30, Precise: true}); !ok || !near(lastRowEnd(tall), area.Y+area.Height) {
		t.Fatalf("the wheel past the bottom moved the last row to %v", lastRowEnd(tall))
	}

	short := newChromeView(t, numberedLines(5))
	paintIn(short, area)
	wheel(short, 1e6)
	if short.scroll != 0 {
		t.Fatalf("a text that fits scrolled %v", short.scroll)
	}

	wide := newChromeView(t, strings.Repeat(strings.Repeat("w", 400)+"\n", 200))
	paintIn(wide, area)
	if thumb, _ := wide.horizontalThumb(); thumb.Width <= 0 {
		t.Fatal("a text wider than the view has no horizontal bar")
	}
	wheel(wide, 1e6)
	if end := lastRowEnd(wide); !near(end, area.Y+area.Height-barTrack) {
		t.Fatalf("with the horizontal bar the last row ends at %v, want %v above the bar", end, area.Y+area.Height-barTrack)
	}
}

// The vertical thumb follows a drag and keeps the point it was pressed at under the pointer,
// and the scroll stops at the ends.
func TestDraggingTheVerticalThumbScrollsTheText(t *testing.T) {
	v := newChromeView(t, numberedLines(1000))
	area := gfx.Rect{Width: 800, Height: 400}
	paintIn(v, area)
	thumb, maxY := v.verticalThumb()
	if thumb.Height < barMin || thumb.Height >= area.Height {
		t.Fatalf("thumb = %+v", thumb)
	}
	x, y := thumb.X+thumb.Width/2, thumb.Y+thumb.Height/2
	if !pointer(v, gfx.PointerDown, testVertical, x, y) || v.grip.kind != gripVertical {
		t.Fatal("a press on the thumb does not hold it")
	}
	pointer(v, gfx.PointerMove, testVertical, x, y+100)
	if want := 100 / (area.Height - thumb.Height) * maxY; !near(v.scroll, want) {
		t.Fatalf("after a 100pt drag scroll = %v, want %v", v.scroll, want)
	}
	paintIn(v, area)
	if moved, _ := v.verticalThumb(); !near(moved.Y, thumb.Y+100) {
		t.Fatalf("the thumb is at %v, want it under the pointer at %v", moved.Y, thumb.Y+100)
	}
	// The drag goes on away from the track, past its end.
	pointer(v, gfx.PointerMove, gfx.Item(1), 0, area.Height+500)
	if v.scroll != maxY {
		t.Fatalf("past the bottom scroll = %v, want %v", v.scroll, maxY)
	}
	pointer(v, gfx.PointerUp, gfx.Item(1), 0, area.Height+500)
	if v.grip.kind != gripNone {
		t.Fatal("the release did not let go of the thumb")
	}
	pointer(v, gfx.PointerMove, gfx.Item(1), 0, 0)
	if v.scroll != maxY {
		t.Fatalf("a move after the release scrolled to %v", v.scroll)
	}
}

// A press on the track beside the thumb scrolls a page towards the press.
func TestPressingTheTrackBesideTheThumbScrollsAPage(t *testing.T) {
	v := newChromeView(t, numberedLines(1000))
	area := gfx.Rect{Width: 800, Height: 400}
	paintIn(v, area)
	page := area.Height - v.lineH
	track := v.bars.vertical
	pointer(v, gfx.PointerDown, testVertical, track.X+barTrack/2, area.Height-2)
	if v.scroll != page || v.grip.kind != gripNone {
		t.Fatalf("a press below the thumb scrolled to %v (holding %v), want a page %v", v.scroll, v.grip.kind, page)
	}
	pointer(v, gfx.PointerUp, testVertical, track.X+barTrack/2, area.Height-2)
	paintIn(v, area)
	pointer(v, gfx.PointerDown, testVertical, track.X+barTrack/2, 1)
	if v.scroll != 0 {
		t.Fatalf("a press above the thumb scrolled to %v, want the top", v.scroll)
	}
}

// A long line that does not wrap has a horizontal thumb that scrolls it sideways; a wrapped
// text has none.
func TestDraggingTheHorizontalThumbScrollsSideways(t *testing.T) {
	v := newChromeView(t, strings.Repeat("abcdefghij", 60)+"\nshort\n")
	area := gfx.Rect{Width: 800, Height: 400}
	canvas := paintIn(v, area)
	thumb, maxX := v.horizontalThumb()
	if thumb.Width <= 0 || maxX <= 0 {
		t.Fatalf("thumb = %+v, max %v", thumb, maxX)
	}
	if hit, ok := hitOf(canvas, testSideways); !ok || hit.Bounds.X+hit.Bounds.Width > v.mm.rect.X+0.01 {
		t.Fatalf("horizontal bar hit = %+v (declared %v), want it under the text, left of the minimap", hit, ok)
	}
	x, y := thumb.X+thumb.Width/2, thumb.Y+thumb.Height/2
	pointer(v, gfx.PointerDown, testSideways, x, y)
	pointer(v, gfx.PointerMove, testSideways, x+50, y)
	if want := 50 / (v.bars.horizontal.Width - thumb.Width) * maxX; !near(v.scrollX, want) {
		t.Fatalf("after a 50pt drag scrollX = %v, want %v", v.scrollX, want)
	}
	pointer(v, gfx.PointerUp, testSideways, area.Width+300, y)
	if v.scrollX != maxX {
		t.Fatalf("released past the end scrollX = %v, want %v", v.scrollX, maxX)
	}

	v.SetWrap(true)
	canvas = paintIn(v, area)
	if thumb, _ := v.horizontalThumb(); thumb.Width > 0 || v.scrollX != 0 {
		t.Fatalf("a wrapped text has a horizontal thumb %+v, scrolled %v", thumb, v.scrollX)
	}
	if _, ok := hitOf(canvas, testSideways); ok {
		t.Fatal("a wrapped text declares a horizontal bar")
	}
}

// A press on the minimap beside the slider brings the row under it to the middle of the view,
// and the slider then follows the pointer from there.
func TestPressingTheMinimapCentersTheRowAndHoldsTheSlider(t *testing.T) {
	v := newChromeView(t, numberedLines(2000))
	area := gfx.Rect{Width: 800, Height: 400}
	paintIn(v, area)
	mm := v.mm.rect
	y := mm.Y + 300
	pointer(v, gfx.PointerDown, testMinimap, mm.X+mm.Width/2, y)
	if want := 150*v.lineH - area.Height/2; !near(v.scroll, want) {
		t.Fatalf("after the press scroll = %v, want row 150 in the middle at %v", v.scroll, want)
	}
	if v.grip.kind != gripMinimap {
		t.Fatal("the press does not hold the slider")
	}
	paintIn(v, area)
	before := v.minimapLayout().sliderTop
	pointer(v, gfx.PointerMove, testMinimap, mm.X+mm.Width/2, y+20)
	paintIn(v, area)
	if after := v.minimapLayout().sliderTop; !near(after, before+20) {
		t.Fatalf("a 20pt drag moved the slider from %v to %v", before, after)
	}
	pointer(v, gfx.PointerUp, testMinimap, mm.X+mm.Width/2, y+20)
	if v.grip.kind != gripNone {
		t.Fatal("the release did not let go of the slider")
	}
}

// The wheel over the minimap or a scrollbar scrolls the text as it does over the text.
func TestWheelOverTheMinimapScrollsTheText(t *testing.T) {
	v := newChromeView(t, numberedLines(500))
	paintIn(v, gfx.Rect{Width: 800, Height: 400})
	for _, target := range []gfx.ID{testMinimap, testVertical} {
		before := v.scroll
		if _, ok := v.Scroll(gfx.ScrollEvent{Target: target, DeltaY: 30, Precise: true}); !ok || v.scroll != before+30 {
			t.Fatalf("the wheel over %v scrolled from %v to %v (taken %v)", target, before, v.scroll, ok)
		}
	}
	if _, ok := v.Scroll(gfx.ScrollEvent{Target: gfx.Item(9), DeltaY: 30, Precise: true}); ok {
		t.Fatal("the view takes the wheel over another part")
	}
}

// A row's bars are its runs of one color: characters of tokens that share a color make one bar,
// a change of color starts another, and spaces and tabs leave gaps. Columns past the minimap's
// width are left out.
func TestMinimapBarsAreRunsOfOneColor(t *testing.T) {
	v := newChromeView(t, "")
	paintIn(v, gfx.Rect{Width: 800, Height: 400})
	keyword, comment := syntax.Intern("keyword"), syntax.Intern("comment")
	color := func(n syntax.Name) gfx.Color { return uiColor(v.theme.Style(n).Foreground) }
	if color(keyword) == color(comment) {
		t.Fatal("the theme gives keywords and comments one color")
	}
	text := "func ab\tcd//x"
	v.mm.tokens = []syntax.Token{{Start: 0, Name: keyword}, {Start: 5, Name: comment}, {Start: 6, Name: comment}, {Start: 10, Name: keyword}}
	v.mm.marks = v.mm.marks[:0]
	v.markRow(text, wrapRow{}, len(text), 7, 100)
	want := []minimapMark{
		{row: 7, col: 0, cells: 4, color: color(keyword)},
		// "ab" is two tokens of one color, one bar; the tab leaves the gap to column 8.
		{row: 7, col: 5, cells: 2, color: color(comment)},
		{row: 7, col: 8, cells: 2, color: color(comment)},
		{row: 7, col: 10, cells: 3, color: color(keyword)},
	}
	if !slices.Equal(v.mm.marks, want) {
		t.Fatalf("marks = %+v, want %+v", v.mm.marks, want)
	}

	v.mm.marks = v.mm.marks[:0]
	v.markRow(text, wrapRow{}, len(text), 0, 6)
	if got := v.mm.marks; len(got) != 2 || got[1].col+got[1].cells != 6 {
		t.Fatalf("at 6 columns marks = %+v, want the bars cut at column 6", got)
	}
}

// As the minimap scrolls, it keeps the bars of the rows still shown and makes only the new
// ones, and those are the bars a fresh build makes.
func TestScrolledMinimapHasTheBarsOfAFreshBuild(t *testing.T) {
	v := newChromeView(t, numberedLines(3000))
	area := gfx.Rect{Width: 800, Height: 400}
	for _, scroll := range []float32{0, 40, 900, 30000, 20000, 1e9, 0} {
		v.scroll = scroll
		paintIn(v, area)
		got := slices.Clone(v.mm.marks)
		_, first, last, _ := v.minimapRange()
		// Forgetting what the bars were made from makes the next paint build them all.
		v.mm.key = minimapKey{}
		paintIn(v, area)
		want := v.mm.marks
		order := func(a, b minimapMark) int {
			if a.row != b.row {
				return int(a.row - b.row)
			}
			return int(a.col - b.col)
		}
		slices.SortFunc(got, order)
		slices.SortFunc(want, order)
		if len(got) < last-first {
			t.Fatalf("at scroll %v the minimap has %d bars for rows %d-%d", scroll, len(got), first, last)
		}
		if !slices.Equal(got, want) {
			t.Fatalf("at scroll %v the kept bars (%d) differ from a fresh build (%d)", scroll, len(got), len(want))
		}
		for _, m := range got {
			if int(m.row) < first || int(m.row) > last {
				t.Fatalf("at scroll %v a bar of row %d is kept outside rows %d-%d", scroll, m.row, first, last)
			}
		}
	}
}
