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

// adoptArea takes the splitter's position as the height of the commit area.
func (v *commitView) adoptArea() {
	room := v.bodyHeight - shellSplitter
	v.areaHeight = min(max(room-v.split.Pos, commitAreaMin), max(room-commitListMin, commitAreaMin))
}
