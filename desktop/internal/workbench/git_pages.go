package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Git surfaces (the Commit tool window, the log tab and the overlays of the branch
// popup and the sync dialogs) are Pages inside the window's Frame. A pane page is drawn into
// a Slot of the panel that holds it and registers as a panel of the page host; the overlay
// page covers the window while something of it is open and is a layer of the page host.

// gitHost is one Page of the Git surfaces with the draw callback that puts it in a Slot,
// made once because a closure made in each paint allocates.
type gitHost struct {
	page *ui.Page
	// draw puts the page in a Slot; paint draws it over a rectangle of the canvas, for a page
	// that covers the window.
	draw  func(*ui.DrawContext)
	paint func(*gfx.Canvas, ui.Rect)
	// panel is what a pane page registers with the page host each time it is drawn.
	panel panelPage
}

// newGitHost makes the Page root names, painted with view; after, when not nil, runs once
// the page has been drawn, for what the window reads from the boxes of the paint.
func (a *App) newGitHost(root string, view func(ui.C), after func(), panel panelPage) gitHost {
	var h gitHost
	h.page = ui.NewPage(ui.PageConfig{View: view, Tree: &tree, Root: root, Theme: &a.theme, Invalidator: &a.invalidator})
	h.paint = func(canvas *gfx.Canvas, rect ui.Rect) {
		h.page.Draw(canvas, rect, view)
		if after != nil {
			after()
		}
	}
	panel.page = h.page
	h.panel = panel
	h.draw = func(d *ui.DrawContext) {
		a.pages.register(h.panel)
		h.paint(d.Canvas, d.Rect)
	}
	return h
}

// close ends the page's effects and forgets it.
func (h *gitHost) close() {
	if h.page != nil {
		h.page.Close()
		h.page = nil
	}
}

// closeGitPages ends every Git page with the window.
func (a *App) closeGitPages() {
	a.commitView.host.close()
	a.logView.host.close()
	a.gitOverlay.host.close()
	a.problemsHost.close()
}

// gitOverlayOpen reports that the overlay page is on screen and has the window's input.
func (a *App) gitOverlayOpen() bool {
	return a.gitOverlay.host.page != nil && a.gitOverlayShown()
}
