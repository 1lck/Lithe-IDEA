package workbench

import "github.com/vivaui/viva/ui"

// commitView is the window's state of the Commit tool window that is not the project's: the
// Page that shows it, the splitter between the change list and the commit area, and what the
// page declared for the capture after it is drawn.
type commitView struct {
	host  gitHost
	split ui.SplitterState
	// areaHeight is the chosen height of the commit area; the change list takes what is
	// left, so the commit area keeps its height when the tool window is resized.
	areaHeight float32
	// bodyHeight is the height the list and the area shared in the last paint, and derived
	// the splitter position that paint was declared with.
	bodyHeight, derived float32
	body                ui.Box
	hasBody             bool
}

func newCommitView() commitView { return commitView{areaHeight: commitAreaHeight} }

// drawCommitPanel puts the Commit tool window's page in the room the panel leaves under its
// header.
func (a *App) drawCommitPanel(f *ui.Frame, p *project) {
	v := &a.commitView
	if v.host.page == nil {
		v.host = a.newGitHost("commit", a.commitPageView, v.capture)
	}
	f.Slot().Fill().Draw(v.host.draw)
}

// capture keeps the height the list and the area shared, and takes a drag of the splitter as
// a new height of the commit area.
func (v *commitView) capture() {
	if !v.hasBody {
		return
	}
	height := v.body.Rect().Height
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
