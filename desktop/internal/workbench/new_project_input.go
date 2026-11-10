package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// The New Project sheet's contents are a Page drawn into a Frame slot, so the
// window routes input to the page first while the sheet is open.

// newProjectPointer gives the page the pointer events it owns, and holds the
// rest back from the window behind an open list or menu.
func (a *App) newProjectPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	n := &a.newProject
	if !n.open || n.page == nil {
		return gfx.EventResult{}, false
	}
	return n.page.Pointer(event)
}

// newProjectKey lets the page's open list or menu take keys first.
func (a *App) newProjectKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	n := &a.newProject
	if !n.open || n.page == nil {
		return gfx.EventResult{}, false
	}
	return n.page.Key(event)
}

// newProjectShortcut keeps workbench shortcuts from acting behind the sheet,
// while the page's own fields keep copy, paste and select-all.
func (a *App) newProjectShortcut(event gfx.KeyEvent) (gfx.EventResult, bool) {
	n := &a.newProject
	if !n.open || n.page == nil {
		return gfx.EventResult{}, false
	}
	if result, ok := n.page.Key(event); ok && result.Handled {
		return result, true
	}
	if n.page.Owns(event.Target) {
		return gfx.EventResult{}, true
	}
	return gfx.EventResult{Handled: true}, true
}

// newProjectWheel scrolls the page's list or form.
func (a *App) newProjectWheel(event gfx.ScrollEvent) (gfx.EventResult, bool) {
	n := &a.newProject
	if !n.open || n.page == nil {
		return gfx.EventResult{}, false
	}
	return n.page.Wheel(event), true
}

// newProjectTextInput answers the platform's text input query for the page's fields.
func (a *App) newProjectTextInput(ctx app.TextInputContext) *app.TextInput {
	n := &a.newProject
	if !n.open || n.page == nil {
		return nil
	}
	return n.page.TextInput(ctx)
}
