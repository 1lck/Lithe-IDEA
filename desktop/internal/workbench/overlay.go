package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The window's modal dialogs and its notice are one Page painted over the
// workbench: the clone dialog, the plugin review and prompts, the search and
// navigation popups, the rename dialog and the toast that carries a notice.
// Each dialog's state stays with its own file; this file only hosts the page
// they are declared in and routes the window's input to it.

// overlayHost is the page every dialog is declared in.
type overlayHost struct {
	page *ui.Page
	// theme is what the page paints with; the dialogs open without a fade.
	theme   ui.Theme
	toaster ui.Toaster
}

// overlayPage makes the page on first use.
func (a *App) overlayPage() *ui.Page {
	h := &a.overlay
	if h.page == nil {
		h.page = ui.NewPage(ui.PageConfig{
			View: a.overlayView, Tree: &tree, Root: "overlay",
			Theme: &h.theme, Invalidator: &a.invalidator,
		})
	}
	return h.page
}

// closeOverlay ends every effect the dialogs started.
func (a *App) closeOverlay() {
	if a.overlay.page != nil {
		a.overlay.page.Close()
		a.overlay.page = nil
	}
}

// paintOverlay declares the dialogs over what the window just painted.
func (a *App) paintOverlay(canvas *gfx.Canvas, bounds gfx.Rect, theme ui.Theme) {
	a.overlay.theme = theme
	a.overlayPage().Draw(canvas, bounds, a.overlayView)
}

// overlayView declares every dialog that is open, the last on top.
func (a *App) overlayView(c ui.C) {
	a.cloneView(c)
	if a.project != nil {
		a.everywherePopup(c)
		a.navigationPopup(c)
		a.semanticPopups(c)
	}
	a.pluginReviewView(c)
	a.pluginPromptView(c)
	a.noticeView(c)
}

// noticeView paints the toasts notify raised.
func (a *App) noticeView(c ui.C) { ui.Toasts(c, &a.overlay.toaster) }
