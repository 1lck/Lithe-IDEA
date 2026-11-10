package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The workbench window still paints through a Frame, so a tool window written as a
// Page is drawn into a Frame slot and the window routes the input the page owns to
// it. A page that is always on screen (a tool window) differs from the New Project
// sheet: it takes only the events whose target is one of its controls, or all of
// them while it has a popup open, and leaves the rest to the window.

// pageHost lists the pages the last paint drew into the window, in paint order.
type pageHost struct {
	drawn []*ui.Page
}

// begin forgets the pages of the previous paint; each page registers again as it
// is drawn, so a tool window that is no longer shown stops receiving input.
func (h *pageHost) begin() {
	clear(h.drawn)
	h.drawn = h.drawn[:0]
}

// newHostedPage makes a Page for a Frame slot. root names its top scope in the
// window's identity tree and must differ between the pages of one window.
func (a *App) newHostedPage(root string) *ui.Page {
	return ui.NewPage(ui.PageConfig{Tree: &tree, Root: root, Theme: &a.theme, Invalidator: &a.invalidator})
}

// embedPage fills the Frame element being declared with page, drawn with view.
func (a *App) embedPage(f *ui.Frame, page *ui.Page, view func(ui.C)) {
	f.Slot().Fill().Draw(func(d *ui.DrawContext) {
		a.pages.drawn = append(a.pages.drawn, page)
		page.Draw(d.Canvas, d.Rect, view)
	})
}

// hostedPointer gives a hosted page the pointer events it owns.
func (a *App) hostedPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	for _, page := range a.pages.drawn {
		if result, ok := page.Pointer(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// hostedKey gives a hosted page the keys it acts on: a list's arrows, a menu's, a
// popup's Escape.
func (a *App) hostedKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	for _, page := range a.pages.drawn {
		if result, ok := page.Key(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// hostedShortcut keeps the window's chords from acting while a hosted page's field
// has the focus, so the field keeps copy, paste and select-all.
func (a *App) hostedShortcut(event gfx.KeyEvent) (gfx.EventResult, bool) {
	for _, page := range a.pages.drawn {
		if result, ok := page.Key(event); ok && result.Handled {
			return result, true
		}
		if page.Owns(event.Target) {
			return gfx.EventResult{}, true
		}
	}
	return gfx.EventResult{}, false
}

// hostedWheel scrolls the list or area of a hosted page under the pointer.
func (a *App) hostedWheel(event gfx.ScrollEvent) (gfx.EventResult, bool) {
	for _, page := range a.pages.drawn {
		if page.Owns(event.Target) || page.Overlay() {
			return page.Wheel(event), true
		}
	}
	return gfx.EventResult{}, false
}

// hostedTextInput answers the platform's text input query for a hosted page's fields.
func (a *App) hostedTextInput(ctx app.TextInputContext) *app.TextInput {
	for _, page := range a.pages.drawn {
		if input := page.TextInput(ctx); input != nil {
			return input
		}
	}
	return nil
}

// panelMessage declares a centered empty or progress message.
func (a *App) panelMessage(c ui.C, message string, color gfx.Color) {
	ui.Column(c).Fill().Center().PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, message, 3).TextCenter().Color(color)
	})
}
