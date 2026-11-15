package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// commitView is the window's state of the Commit tool window that is not the project's: the
// splitter between the change list and the commit area, and what the last paint declared.
type commitView struct {
	split ui.SplitterState
	// areaHeight is the chosen height of the commit area; the change list takes what is
	// left, so the commit area keeps its height when the tool window is resized.
	areaHeight float32
	// bodyHeight is the height the list and the area shared in the last paint, and derived
	// the splitter position that paint was declared with.
	bodyHeight, derived float32
	// bodyRect is where the list and the area were laid out in the last paint, read from the
	// draw callback bodyDraw gave the box.
	bodyRect ui.Rect
	bodyDraw func(*ui.DrawContext)
	hasBody  bool
}

func newCommitView() commitView { return commitView{areaHeight: commitAreaHeight} }

// begin starts a paint: what the splitter was dragged to in the last one is the commit area's
// height now, and the body is not declared until drawCommitBody declares it.
func (v *commitView) begin() {
	if v.areaHeight == 0 {
		v.areaHeight = commitAreaHeight
	}
	if v.bodyDraw == nil {
		v.bodyDraw = func(d *ui.DrawContext) { v.bodyRect = d.Rect }
	}
	v.capture()
	v.hasBody = false
}

// drawCommitBody declares the change list list draws over the commit area area draws, with
// the splitter between them; the area keeps its chosen height while the list keeps its least,
// and the list takes the rest.
func (a *App) drawCommitBody(c ui.C, v *commitView, list, area func() ui.Box) {
	height := v.areaHeight
	if v.bodyHeight > 0 {
		height = min(height, max(v.bodyHeight-shellSplitter-commitListMin, commitAreaMin))
	}
	ui.Column(c).Grow(1).FillWidth().Draw(v.bodyDraw).Children(func() {
		if v.bodyHeight > 0 && !v.split.Dragging() {
			v.derived = max(v.bodyHeight-shellSplitter-height, commitListMin)
			v.split.Pos = v.derived
		}
		list().Grow(1)
		ui.Splitter(c, &v.split).Mins(commitListMin, commitAreaMin).Label(a.text.Panel.Resize)
		area().Height(height).Shrink(0)
	})
	v.hasBody = true
}

// capture keeps the height the list and the area shared, and takes a drag of the splitter as
// a new height of the commit area.
func (v *commitView) capture() {
	if !v.hasBody {
		return
	}
	height := v.bodyRect.Height
	if v.split.Dragging() && v.split.Pos != v.derived && v.bodyHeight > 0 {
		v.adoptArea()
	}
	v.bodyHeight = height
}

// splitKey gives a key to the splitter between the list and the commit area, which a Page does
// not route to the splitter.
func (v *commitView) splitKey(event gfx.KeyEvent) gfx.EventResult {
	r := v.split.Key(event)
	if r.Handled {
		v.adoptArea()
	}
	return r
}

// adoptArea takes the splitter's position as the height of the commit area.
func (v *commitView) adoptArea() {
	room := v.bodyHeight - shellSplitter
	v.areaHeight = min(max(room-v.split.Pos, commitAreaMin), max(room-commitListMin, commitAreaMin))
}
