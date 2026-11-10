package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The workbench window still paints through a Frame, so every surface that is a Page is
// drawn into the window and the window routes the input the page owns to it. This file is
// the one place that knows which pages there are and in which order they see an event; the
// window's handlers in app.go and terminal.go call pagePointer, pageKey, pageShortcut,
// pageWheel and pageTextInput once each, before their own work, and a page leaves what it
// does not own to the window.
//
// Pages come in two kinds:
//
//   - A layer covers the window while something of it is open (the dialogs and toasts, the
//     New Project sheet, the branch popup and the sync dialogs). Layers are asked from the top
//     down, and while a layer is blocking nothing behind it gets a shortcut or the wheel, so
//     the workbench cannot change under a dialog. The Git overlay stays a layer of its own,
//     not part of the dialogs' page, because it is painted after the terminal and the editor
//     views (the branch popup hangs off the title bar and must lie over them) and the dialogs
//     are painted before them.
//   - A panel is a Page drawn into a region of the window (the start screen, Find in Files,
//     the Git log and Commit tool windows, the Run, Tests and Debug tool windows). It
//     registers when its slot is painted, so a tool window that is not shown receives
//     nothing. A panel takes a pointer event only where it declared a control (a Page
//     hit-tests itself; a rectangle test here would cut drags and popups that leave the
//     region), and a key, a shortcut or the wheel only while a control of it has the
//     keyboard or one of its popups or dialogs is open.

// panelPage is a panel as the page host knows it: the page and the hooks of the panels that
// need more than the page does.
type panelPage struct {
	page *ui.Page
	// key, when not nil, sees a key before the page does, for a control the page does not
	// declare (the splitters' arrow keys).
	key func(gfx.KeyEvent) gfx.EventResult
	// wheel, when not nil, adjusts a wheel turn before the page takes it.
	wheel func(*gfx.ScrollEvent)
}

// pageHost lists the panels the last paint drew into the window, in paint order.
type pageHost struct {
	panels []panelPage
}

// begin forgets the panels of the previous paint; each registers again as it is drawn.
func (h *pageHost) begin() {
	clear(h.panels)
	h.panels = h.panels[:0]
}

// register records a panel drawn in this paint.
func (h *pageHost) register(p panelPage) { h.panels = append(h.panels, p) }

// pageLayer is a page that covers the window, and whether it keeps the shortcuts and the
// wheel from what is behind it.
type pageLayer struct {
	page     *ui.Page
	blocking bool
}

// pageLayers returns the layers that are open, front-most first; a closed one has no page.
func (a *App) pageLayers() [3]pageLayer {
	var layers [3]pageLayer
	if p := a.overlay.page; p != nil {
		// The dialogs' page is always there; it blocks only while a dialog is open.
		layers[0] = pageLayer{p, p.Overlay()}
	}
	if n := &a.newProject; n.open && n.page != nil {
		layers[1] = pageLayer{n.page, true}
	}
	if a.gitOverlayOpen() {
		layers[2] = pageLayer{a.gitOverlay.host.page, true}
	}
	return layers
}

// newHostedPage makes a Page for a Frame slot. root names its top scope in the
// window's identity tree and must differ between the pages of one window.
func (a *App) newHostedPage(root string) *ui.Page {
	return ui.NewPage(ui.PageConfig{Tree: &tree, Root: root, Theme: &a.theme, Invalidator: &a.invalidator})
}

// embedPage fills the Frame element being declared with page, drawn with view, and
// registers it as a panel.
func (a *App) embedPage(f *ui.Frame, page *ui.Page, view func(ui.C)) {
	f.Slot().Fill().Draw(func(d *ui.DrawContext) {
		a.pages.register(panelPage{page: page})
		page.Draw(d.Canvas, d.Rect, view)
	})
}

// verticalWheel is the wheel hook of a panel whose lists scroll up and down: Viva's List
// scrolls sideways by any horizontal part of a swipe, so one that is mostly vertical loses
// its horizontal part, as the lists of the Git tool windows always did.
func verticalWheel(event *gfx.ScrollEvent) {
	if event.Modifiers&gfx.ModifierShift == 0 && max(event.DeltaX, -event.DeltaX) < max(event.DeltaY, -event.DeltaY) {
		event.DeltaX = 0
	}
}

// pagePointer gives a pointer event to the page that owns it.
func (a *App) pagePointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	for _, layer := range a.pageLayers() {
		if layer.page == nil {
			continue
		}
		if result, ok := layer.page.Pointer(event); ok {
			return result, true
		}
	}
	if a.drag.pressed || a.term.drag.pressed {
		// A tool button or a terminal tab being dragged keeps the pointer from the panels it
		// crosses, as it did when their controls were declared in the window's own Frame.
		return gfx.EventResult{}, false
	}
	for _, panel := range a.pages.panels {
		if result, ok := panel.page.Pointer(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// pageKey lets a page's list, menu, popup or dialog take keys first.
func (a *App) pageKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	if a.project != nil && a.everywhereView.open {
		// Search Everywhere's arrows and Enter move its own selection, which is not a
		// control of the page.
		if result := a.everywhereKey(a.project, event); result.Handled {
			return result, true
		}
	}
	for _, layer := range a.pageLayers() {
		if layer.page == nil {
			continue
		}
		if result, ok := layer.page.Key(event); ok {
			return result, true
		}
	}
	for _, panel := range a.pages.panels {
		if panel.key != nil {
			if result := panel.key(event); result.Handled {
				return result, true
			}
		}
		// A panel with a popover or a dialog open has the keyboard, whatever is focused.
		if !panel.page.Overlay() && !panel.page.Owns(event.Target) {
			continue
		}
		if result, ok := panel.page.Key(event); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// pageShortcut keeps the workbench's chords from acting behind a dialog, while the page's own
// fields keep copy, paste and select-all, and gives a panel's own chords to the panel.
func (a *App) pageShortcut(event gfx.KeyEvent) (gfx.EventResult, bool) {
	for _, layer := range a.pageLayers() {
		if layer.page == nil {
			continue
		}
		if result, ok := layer.page.Key(event); ok && result.Handled {
			return result, true
		}
		if layer.page.Owns(event.Target) {
			return gfx.EventResult{}, true
		}
		if layer.blocking {
			return gfx.EventResult{Handled: true}, true
		}
	}
	for _, panel := range a.pages.panels {
		page := panel.page
		if !page.Overlay() && !page.Owns(event.Target) {
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

// pageWheel scrolls the list or form of the page the wheel is over, and of a layer while it
// blocks.
func (a *App) pageWheel(event gfx.ScrollEvent) (gfx.EventResult, bool) {
	for _, layer := range a.pageLayers() {
		if layer.page != nil && (layer.blocking || layer.page.Owns(event.Target)) {
			return layer.page.Wheel(event), true
		}
	}
	for _, panel := range a.pages.panels {
		if panel.page.Overlay() || panel.page.Owns(event.Target) {
			if panel.wheel != nil {
				panel.wheel(&event)
			}
			return panel.page.Wheel(event), true
		}
	}
	return gfx.EventResult{}, false
}

// pageTextInput answers the platform's text input query for the fields of the pages.
func (a *App) pageTextInput(ctx app.TextInputContext) *app.TextInput {
	for _, layer := range a.pageLayers() {
		if layer.page == nil {
			continue
		}
		if input := layer.page.TextInput(ctx); input != nil {
			return input
		}
	}
	for _, panel := range a.pages.panels {
		if input := panel.page.TextInput(ctx); input != nil {
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
