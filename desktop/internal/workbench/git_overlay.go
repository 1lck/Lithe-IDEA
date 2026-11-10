package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// gitOverlay is the Page that covers the window while the branch popup, one of its dialogs
// or a dialog of the log tab's sync operations is open. It is drawn after the window's own
// frame, so what it opens lies over the title bar the popup hangs off.
type gitOverlay struct {
	host gitHost
}

// gitOverlayShown reports that something of the overlay is open.
func (a *App) gitOverlayShown() bool {
	p := a.project
	return p != nil && (a.branch.open || a.branch.dialog != branchDialogNone || p.log.sync.dialog != syncDialogNone)
}

// paintGitOverlay draws the overlay page over the window when it has something to show.
func (a *App) paintGitOverlay(canvas *gfx.Canvas, bounds gfx.Rect) {
	if !a.gitOverlayShown() {
		return
	}
	o := &a.gitOverlay
	if o.host.page == nil {
		o.host = a.newGitHost("git-overlay", a.gitOverlayView, nil, panelPage{})
	}
	o.host.paint(canvas, bounds)
}

// gitOverlayView declares the open parts of the overlay: the popup, or the dialog of the
// branch writes, or the dialog of the sync operations. A dialog closes the popup first, so
// at most one of them is open.
func (a *App) gitOverlayView(c ui.C) {
	p := a.project
	if p == nil {
		return
	}
	if a.branch.open {
		a.drawBranchPopup(c, p)
	}
	a.drawBranchDialog(c, p)
	a.drawSyncDialog(c, p)
}
