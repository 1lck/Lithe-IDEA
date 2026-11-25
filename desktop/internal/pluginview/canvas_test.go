package pluginview

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

func TestCanvasEllipsisShowsAllRunsAndKeepsGroupClick(t *testing.T) {
	d := drawView(t, `[{"type":"canvas","id":"graph","label":"Graph","height":180,"viewBox":[0,0,440,180],"nodes":[
		{"type":"group","id":"item","x":20,"y":20,"w":200,"h":80,"on":["click"],"label":"Open item","tooltip":"Group details","children":[
			{"type":"text","x":10,"y":30,"maxWidth":110,"runs":[
				{"text":"完整文件名称-with-a-long-extension.txt"},{"text":" · additional information"}]}]}]}]`)
	var text gfx.Rect
	for _, label := range d.driver.Snapshot().Labels {
		if strings.HasSuffix(label.Value, "…") {
			text = label.Bounds
			break
		}
	}
	if text.Width == 0 {
		t.Fatal("the canvas label was not ellipsized")
	}
	x, y := text.X+5, text.Y+text.Height/2
	if err := d.driver.Move(x, y); err != nil {
		t.Fatal(err)
	}
	if err := d.driver.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	var full strings.Builder
	for _, label := range d.driver.Snapshot().Labels {
		if label.Value == "Group details" {
			t.Fatal("the group and full-text tooltips appeared together")
		}
		if label.Layer == ui.TooltipLayer {
			full.WriteString(label.Value)
		}
	}
	if got, want := strings.Join(strings.Fields(full.String()), ""), "完整文件名称-with-a-long-extension.txt·additionalinformation"; got != want {
		t.Fatalf("canvas tooltip %q, want %q", got, want)
	}
	if err := d.driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
	if event := d.sent(); event["event"] != "click" || event["node"] != "item" {
		t.Fatalf("click through the full-text tooltip sent %v", event)
	}
}

// testCanvas is a canvas node of a 400 × 400 view box that pans, zooms from half to four
// times and tells the plugin where it lies.
func testCanvas() *Node {
	return &Node{
		Type: "canvas", ID: "graph", ViewBox: [4]float64{0, 0, 400, 400},
		Pan: true, Zoom: &[2]float64{0.5, 4}, On: []string{"viewport"},
	}
}

func TestCanvasScaleFollowsTheWidthAndTheZoom(t *testing.T) {
	n := testCanvas()
	state := &canvasState{zoom: 1}
	rect := gfx.Rect{Width: 200, Height: 100}
	if got := state.scale(rect, n); got != 0.5 {
		t.Fatalf("scale at zoom 1 = %v, want the view box's width across the canvas", got)
	}
	state.zoom = 3
	if got := state.scale(rect, n); got != 1.5 {
		t.Fatalf("scale at zoom 3 = %v", got)
	}
	flat := &Node{Type: "canvas", ViewBox: [4]float64{0, 0, 100, 0}}
	if got := state.scale(rect, flat); got != 0 {
		t.Fatalf("scale of a view box without area = %v, want 0", got)
	}
	if got := state.viewport(rect, flat); got != (Viewport{}) {
		t.Fatalf("viewport of a view box without area = %+v", got)
	}
}

func TestCanvasWithoutPanShowsItsWholeViewBoxFromTheTopLeft(t *testing.T) {
	// A scene designed 600 × 300 in a canvas 300 points tall.
	n := &Node{Type: "canvas", ID: "preview", ViewBox: [4]float64{10, 20, 600, 300}}
	state := &canvasState{zoom: 1}

	// As wide as designed it takes one pixel a unit.
	if got := state.scale(gfx.Rect{Width: 600, Height: 300}, n); got != 1 {
		t.Fatalf("scale at the designed width = %v, want 1", got)
	}
	// Narrower, it shrinks to the width.
	if got := state.scale(gfx.Rect{Width: 300, Height: 300}, n); got != 0.5 {
		t.Fatalf("scale at half the width = %v, want 0.5", got)
	}
	// Wider, it keeps its size, whole, from the leading edge.
	wide := gfx.Rect{Width: 1000, Height: 300}
	if got := state.scale(wide, n); got != 1 {
		t.Fatalf("scale wider than designed = %v, want the height kept", got)
	}
	state.clamp(wide, n)
	if state.x != 10 || state.y != 20 {
		t.Fatalf("wider than designed at (%v, %v), want the view box's top-left corner", state.x, state.y)
	}
	if got := state.viewport(wide, n); got != (Viewport{X: 10, Y: 20, Width: 1000, Height: 300}) {
		t.Fatalf("viewport = %+v", got)
	}

	// Its zoom scales the fitted scene.
	n.Zoom = &[2]float64{1, 2}
	state = &canvasState{zoom: 2}
	if got := state.scale(wide, n); got != 2 {
		t.Fatalf("scale at zoom 2 = %v, want twice the fitted scale", got)
	}
}

func TestCanvasClampKeepsTheViewInsideTheViewBox(t *testing.T) {
	n := testCanvas()
	n.ViewBox = [4]float64{100, 50, 400, 200}
	rect := gfx.Rect{Width: 200, Height: 200}

	// Zoomed out the view box is narrower and shorter than the canvas: centered across it,
	// at its top.
	state := &canvasState{zoom: 0.5, x: 999, y: 999, placed: true}
	state.clamp(rect, n)
	if state.x != 100-(800-400)/2.0 || state.y != 50 {
		t.Fatalf("zoomed out at (%v, %v), want centered across and at the top", state.x, state.y)
	}

	// Zoomed in it is larger: the visible part stays inside it.
	state = &canvasState{zoom: 4, x: 999, y: -999, placed: true}
	state.clamp(rect, n)
	if state.x != 100+400-100 || state.y != 50 {
		t.Fatalf("zoomed in at (%v, %v), want the edges of the view box", state.x, state.y)
	}

	// A canvas not yet placed starts at the view box's top-left corner.
	state = &canvasState{zoom: 4}
	state.clamp(rect, n)
	if !state.placed || state.x != 100 || state.y != 50 {
		t.Fatalf("first placement at (%v, %v)", state.x, state.y)
	}
}

func TestCanvasZoomAtKeepsThePointUnderThePointer(t *testing.T) {
	n := testCanvas()
	rect := gfx.Rect{X: 10, Y: 20, Width: 400, Height: 400}
	state := &canvasState{zoom: 1}
	px, py := rect.X+200, rect.Y+100
	if !state.zoomAt(rect, n, 2, px, py) {
		t.Fatal("zooming in did not change the zoom")
	}
	if state.zoom != 2 {
		t.Fatalf("zoom = %v, want 2", state.zoom)
	}
	k := state.scale(rect, n)
	if x, y := state.x+200/k, state.y+100/k; x != 200 || y != 100 {
		t.Fatalf("the pointer is over (%v, %v) after zooming, want (200, 100) as before", x, y)
	}
	if got := state.viewport(rect, n); got != (Viewport{X: 100, Y: 50, Width: 200, Height: 200}) {
		t.Fatalf("viewport = %+v", got)
	}
	if !state.zoomAt(rect, n, 100, px, py) || state.zoom != 4 {
		t.Fatalf("zoom past the range = %v, want its top", state.zoom)
	}
	if state.zoomAt(rect, n, 100, px, py) {
		t.Fatal("zooming at the top of the range reported a change")
	}
	fixed := &Node{Type: "canvas", ViewBox: [4]float64{0, 0, 400, 400}}
	if (&canvasState{zoom: 1}).zoomAt(rect, fixed, 2, px, py) {
		t.Fatal("a canvas without zoom zoomed")
	}
}

// openCanvas is a canvas state drawn at 200 × 200 in an open session at zoom 2, where one
// view-box unit is one pixel.
func openCanvas(t *testing.T) (*backend, *Session, *canvasState) {
	b := newBackend(t)
	s := b.session()
	show(s)
	b.answered(s)
	state := &canvasState{zoom: 2}
	state.make()
	state.node, state.session, state.rect = testCanvas(), s, gfx.Rect{Width: 200, Height: 200}
	state.clamp(state.rect, state.node)
	return b, s, state
}

func TestCanvasDragPansAndSendsTheViewportOnceSettled(t *testing.T) {
	b, s, state := openCanvas(t)
	down := gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, X: 100, Y: 100}
	if !state.pointerEvent(down).Handled {
		t.Fatal("a press on the empty area did not start a drag")
	}
	state.pointerEvent(gfx.PointerEvent{Kind: gfx.PointerMove, X: 40, Y: 70})
	if state.x != 60 || state.y != 30 {
		t.Fatalf("dragged to (%v, %v), want (60, 30)", state.x, state.y)
	}
	state.pointerEvent(gfx.PointerEvent{Kind: gfx.PointerMove, X: -1000, Y: 100})
	if state.x != 200 || state.y != 0 {
		t.Fatalf("dragged past the edge to (%v, %v), want the edge", state.x, state.y)
	}
	if !state.pointerEvent(gfx.PointerEvent{Kind: gfx.PointerUp, X: -1000, Y: 100}).Handled || state.dragging {
		t.Fatal("releasing did not end the drag")
	}
	if wait := s.Take(); wait != settleDelay || len(b.pending) != 0 {
		t.Fatalf("while settling: wait %v, %d calls", wait, len(b.pending))
	}
	b.now = b.now.Add(settleDelay)
	s.Take()
	b.run()
	viewport, _ := b.last()["viewport"].(map[string]any)
	if b.last()["event"] != "viewport" || b.last()["canvas"] != "graph" || viewport["x"] != 200.0 || viewport["width"] != 200.0 {
		t.Fatalf("viewport event = %v", b.last())
	}
}

func TestCanvasDragNeedsPanAndThePrimaryButton(t *testing.T) {
	_, _, state := openCanvas(t)
	secondary := gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonSecondary, X: 100, Y: 100}
	if state.pointerEvent(secondary).Handled || state.dragging {
		t.Fatal("the secondary button started a drag")
	}
	state.node.Pan = false
	primary := gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, X: 100, Y: 100}
	if state.pointerEvent(primary).Handled || state.dragging {
		t.Fatal("a canvas without pan started a drag")
	}
}

func TestCanvasWheelZoomsOnlyWithCommandOrControl(t *testing.T) {
	b, s, state := openCanvas(t)
	state.node.On = nil
	plain := gfx.ScrollEvent{X: 100, Y: 100, DeltaY: -50}
	if state.scroll(plain).Handled || state.zoom != 2 {
		t.Fatal("the plain wheel zoomed instead of scrolling the page")
	}
	in := gfx.ScrollEvent{X: 100, Y: 100, DeltaY: -float32(math.Log(2) / canvasWheelZoom), Modifiers: gfx.ModifierMeta}
	if !state.scroll(in).Handled || math.Abs(state.zoom-4) > 1e-4 {
		t.Fatalf("⌘ and the wheel zoomed to %v, want 4", state.zoom)
	}
	out := gfx.ScrollEvent{X: 100, Y: 100, DeltaY: 1000, Modifiers: gfx.ModifierControl}
	if !state.scroll(out).Handled || state.zoom != 0.5 {
		t.Fatalf("Control and the wheel zoomed to %v, want the bottom of the range", state.zoom)
	}
	b.now = b.now.Add(settleDelay)
	if s.Take(); len(b.pending) != 0 {
		t.Fatal("a canvas that does not ask for viewport sent one")
	}
}

// A line of runs that fits is drawn whole. The room the runs had left was the line's float32
// width minus the runs before, which can come out a hair under the last run's own width, and
// fitting the run into that hair cut its last character for an ellipsis: a Python settings
// preview showed "bad-argument-type · 2 erro…" with plenty of room in its bar.
func TestCanvasTextDrawsRunsThatFitWhole(t *testing.T) {
	widths := map[string]float32{"bad-argument-type": 101.3, " · 2 errors": 62.7}
	canvas := new(gfx.Canvas)
	canvas.SetMeasurer(func(value string, _, _ float32) float32 {
		if width, ok := widths[value]; ok {
			return width
		}
		return float32(len(value)) * 6
	})
	var total float32
	total += widths["bad-argument-type"]
	total += widths[" · 2 errors"]
	if total-widths["bad-argument-type"] >= widths[" · 2 errors"] {
		t.Fatal("the widths no longer round below the last run; pick others")
	}
	for _, maxWidth := range []float64{0, 400} {
		canvas.Reset()
		pt := &painter{d: &ui.DrawContext{Canvas: canvas}, state: &canvasState{}, p: &Palette{}}
		pt.text(&Shape{X: 10, Y: 20, Style: "caption", MaxWidth: maxWidth, Runs: []Run{
			{Text: "bad-argument-type"}, {Text: " · 2 errors"},
		}}, place{k: 1}, 1)
		var drawn []string
		for _, text := range canvas.Texts() {
			drawn = append(drawn, text.Value)
		}
		if len(drawn) != 2 || drawn[0] != "bad-argument-type" || drawn[1] != " · 2 errors" {
			t.Fatalf("maxWidth %v drew %q", maxWidth, drawn)
		}
	}
	// A line wider than maxWidth is still cut, in the run that crosses it.
	canvas.Reset()
	pt := &painter{d: &ui.DrawContext{Canvas: canvas}, state: &canvasState{}, p: &Palette{}}
	pt.text(&Shape{X: 10, Y: 20, Style: "caption", MaxWidth: 130, Runs: []Run{
		{Text: "bad-argument-type"}, {Text: " · 2 errors"},
	}}, place{k: 1}, 1)
	texts := canvas.Texts()
	if len(texts) != 2 || texts[0].Value != "bad-argument-type" || !strings.HasSuffix(texts[1].Value, "…") {
		t.Fatalf("a line past maxWidth drew %+v", texts)
	}
}
