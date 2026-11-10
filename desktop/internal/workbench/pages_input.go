package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The window routes input to the pages painted into it before its own handlers:
// first the modal pages (an open dialog keeps the keyboard and the pointer from
// the workbench behind it), then the panels that are pages. A page leaves what it
// does not own to the window.

// modalPages are the pages that can hold a dialog open, front-most first.
func (a *App) modalPages() []*ui.Page {
	pages := make([]*ui.Page, 0, 2)
	if a.overlay.page != nil {
		pages = append(pages, a.overlay.page)
	}
	if n := &a.newProject; n.open && n.page != nil {
		pages = append(pages, n.page)
	}
	return pages
}

// pagePointer gives a pointer event to the page that owns it.
func (a *App) pagePointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	for _, page := range a.modalPages() {
		if result, ok := page.Pointer(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// pageKey lets a page's open list, menu or dialog take keys first.
func (a *App) pageKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	if a.project != nil && a.everywhereView.open {
		if result := a.everywhereKey(a.project, event); result.Handled {
			return result, true
		}
	}
	for _, page := range a.modalPages() {
		if result, ok := page.Key(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// pageShortcut keeps workbench shortcuts from acting behind a dialog, while the
// page's own fields keep copy, paste and select-all.
func (a *App) pageShortcut(event gfx.KeyEvent) (gfx.EventResult, bool) {
	for _, page := range a.modalPages() {
		if result, ok := page.Key(event); ok && result.Handled {
			return result, true
		}
		if page.Owns(event.Target) {
			return gfx.EventResult{}, true
		}
		if page.Overlay() || page == a.newProject.page {
			return gfx.EventResult{Handled: true}, true
		}
	}
	return gfx.EventResult{}, false
}

// pageWheel scrolls a page's list or form while its dialog is open.
func (a *App) pageWheel(event gfx.ScrollEvent) (gfx.EventResult, bool) {
	for _, page := range a.modalPages() {
		if page.Overlay() || page == a.newProject.page || page.Owns(event.Target) {
			return page.Wheel(event), true
		}
	}
	return gfx.EventResult{}, false
}

// pageTextInput answers the platform's text input query for a page's fields.
func (a *App) pageTextInput(ctx app.TextInputContext) *app.TextInput {
	for _, page := range a.modalPages() {
		if input := page.TextInput(ctx); input != nil {
			return input
		}
	}
	return nil
}
