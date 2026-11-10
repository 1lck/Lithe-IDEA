package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Git surfaces (the Commit tool window, the log tab and the overlays of the branch
// popup and the sync dialogs) are Pages inside the window's Frame. A pane page is drawn into
// a Slot of the panel that holds it; the overlay page covers the window while something of it
// is open. This file makes them and routes the window's input to them, so app.go only calls
// the git* functions below at the points a window-level handler already has.

// gitHost is one Page of the Git surfaces with the draw callback that puts it in a Slot,
// made once because a closure made in each paint allocates.
type gitHost struct {
	page *ui.Page
	// draw puts the page in a Slot; paint draws it over a rectangle of the canvas, for a page
	// that covers the window.
	draw  func(*ui.DrawContext)
	paint func(*gfx.Canvas, ui.Rect)
}

// newGitHost makes the Page root names, painted with view; after, when not nil, runs once
// the page has been drawn, for what the window reads from the boxes of the paint.
func (a *App) newGitHost(root string, view func(ui.C), after func()) gitHost {
	var h gitHost
	h.page = ui.NewPage(ui.PageConfig{View: view, Tree: &tree, Root: root, Theme: &a.theme, Invalidator: &a.invalidator})
	h.paint = func(canvas *gfx.Canvas, rect ui.Rect) {
		h.page.Draw(canvas, rect, view)
		if after != nil {
			after()
		}
	}
	h.draw = func(d *ui.DrawContext) { h.paint(d.Canvas, d.Rect) }
	return h
}

// close ends the page's effects and forgets it.
func (h *gitHost) close() {
	if h.page != nil {
		h.page.Close()
		h.page = nil
	}
}

// gitPanes are the pane pages that are drawn: the Commit tool window and the log tab. A pane
// is the window's business until a press, a key or the wheel is aimed at one of its controls.
func (a *App) gitPanes() [2]*ui.Page {
	return [2]*ui.Page{a.commitView.host.page, a.logView.host.page}
}

// closeGitPages ends every Git page with the window.
func (a *App) closeGitPages() {
	a.commitView.host.close()
	a.logView.host.close()
	a.gitOverlay.host.close()
}

// gitOverlayOpen reports that the overlay page is on screen and has the window's input.
func (a *App) gitOverlayOpen() bool {
	return a.gitOverlay.host.page != nil && a.gitOverlayShown()
}

// gitOverlayPointer gives the open overlay every pointer event, since it covers the window.
func (a *App) gitOverlayPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	if !a.gitOverlayOpen() {
		return gfx.EventResult{}, false
	}
	return a.gitOverlay.host.page.Pointer(event)
}

// gitPanePointer gives a pane page the press aimed at one of its controls.
func (a *App) gitPanePointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	for _, page := range a.gitPanes() {
		if page == nil {
			continue
		}
		if result, ok := page.Pointer(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// gitOverlayKey lets the open overlay take keys first.
func (a *App) gitOverlayKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	if !a.gitOverlayOpen() {
		return gfx.EventResult{}, false
	}
	return a.gitOverlay.host.page.Key(event)
}

// gitPaneKey gives a key to the pane page whose control has the keyboard.
func (a *App) gitPaneKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	if a.project == nil {
		return gfx.EventResult{}, false
	}
	if r := a.commitView.split.Key(event); r.Handled {
		a.commitView.adoptArea()
		return r, true
	}
	if r := a.logView.splitKey(event); r.Handled {
		return r, true
	}
	for _, page := range a.gitPanes() {
		// A pane with a popover or a dialog open has the keyboard, whatever is focused.
		if page == nil || !page.Overlay() && !page.Owns(event.Target) {
			continue
		}
		if result, ok := page.Key(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// gitOverlayShortcut keeps workbench shortcuts from acting behind the open overlay while
// its own fields keep copy, paste and select-all.
func (a *App) gitOverlayShortcut(event gfx.KeyEvent) (gfx.EventResult, bool) {
	if !a.gitOverlayOpen() {
		return gfx.EventResult{}, false
	}
	page := a.gitOverlay.host.page
	if result, ok := page.Key(event); ok && result.Handled {
		return result, true
	}
	if page.Owns(event.Target) {
		return gfx.EventResult{}, true
	}
	return gfx.EventResult{Handled: true}, true
}

// gitPaneShortcut gives the chords of a pane page's own controls to the page.
func (a *App) gitPaneShortcut(event gfx.KeyEvent) (gfx.EventResult, bool) {
	for _, page := range a.gitPanes() {
		if page == nil || !page.Overlay() && !page.Owns(event.Target) {
			continue
		}
		if result, ok := page.Key(event); ok && result.Handled {
			return result, true
		}
		if page.Overlay() {
			// What is behind an open popover or dialog gets no shortcut.
			return gfx.EventResult{Handled: !page.Owns(event.Target)}, true
		}
	}
	return gfx.EventResult{}, false
}

// gitWheel scrolls the page the wheel is over: the overlay while it is open, else a pane.
func (a *App) gitWheel(event gfx.ScrollEvent) (gfx.EventResult, bool) {

	if a.gitOverlayOpen() {
		return a.gitOverlay.host.page.Wheel(event), true
	}
	for _, page := range a.gitPanes() {
		if page != nil && (page.Overlay() || page.Owns(event.Target)) {
			// Viva's List scrolls sideways by any horizontal part of a swipe; one that is mostly
			// up and down is the vertical scroll, as it was for the lists of the Git tool windows.
			if event.Modifiers&gfx.ModifierShift == 0 && max(event.DeltaX, -event.DeltaX) < max(event.DeltaY, -event.DeltaY) {
				event.DeltaX = 0
			}
			return page.Wheel(event), true
		}
	}
	return gfx.EventResult{}, false
}

// gitTextInput answers the platform's text input query for the fields of the Git pages.
func (a *App) gitTextInput(ctx app.TextInputContext) *app.TextInput {
	if a.gitOverlay.host.page != nil {
		if input := a.gitOverlay.host.page.TextInput(ctx); input != nil {
			return input
		}
	}
	for _, page := range a.gitPanes() {
		if page == nil {
			continue
		}
		if input := page.TextInput(ctx); input != nil {
			return input
		}
	}
	return nil
}
