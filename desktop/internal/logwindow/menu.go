package logwindow

import (
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// menuKind is the menu the window shows. At most one is open.
type menuKind int

const (
	menuNone menuKind = iota
	// The toolbar's menus, which open under their button.
	menuSession
	menuTimeRange
	menuSaved
	menuColumns
	menuMaintenance
	// The context menus of a table row and of the table's header, which open where the
	// secondary button was pressed.
	menuRow
	menuHeader
)

// menuState is the open menu.
type menuState struct {
	kind menuKind
	// at is where a context menu opens, in window coordinates.
	at ui.Point
	// row is the record a row menu is about.
	row string
	// sub is the index of the open submenu, or -1 when none is.
	sub int
}

// Menu metrics, after the macOS menus the client's menus look like.
const (
	menuRowHeight = 22
	menuPadY      = 5
	menuInset     = 5
	menuRadius    = 8
	menuItemRad   = 4
	menuCheckW    = 18
	menuFont      = 13
	menuGap       = 4
)

// openMenu opens the toolbar menu kind, or closes it when it is the one open.
func (w *window) openMenu(kind menuKind) {
	if w.menu.kind == kind {
		w.closeMenu()
		return
	}
	w.menu = menuState{kind: kind, sub: -1}
}

// openContextMenu opens a context menu at x, y about the record row.
func (w *window) openContextMenu(kind menuKind, x, y float32, row string) {
	w.menu = menuState{kind: kind, at: ui.Point{X: x, Y: y}, row: row, sub: -1}
}

func (w *window) closeMenu() {
	w.menu = menuState{sub: -1}
}

// menuSurface declares an open menu: a backdrop over the whole window that closes the menu
// when pressed, and the panel of items, placed by place. It returns the panel.
func (w *window) menuSurface(f *flex.Frame, place func(flex.Box) flex.Box, minWidth float32, items func()) flex.Box {
	backdrop := f.Popup().At(0, 0).Fill().HitWith(menuDismiss, "", ui.HitOptions{SkipFocus: true})
	if backdrop.Clicked() {
		w.closeMenu()
	}
	return w.menuPanel(f, place, minWidth, items)
}

// menuPanel declares the panel of a menu or a submenu, without a backdrop.
func (w *window) menuPanel(f *flex.Frame, place func(flex.Box) flex.Box, minWidth float32, items func()) flex.Box {
	return place(f.Popup()).MinWidth(minWidth).PadY(menuPadY).
		Background(w.pal.menu).Border(1, w.pal.bd).Radius(menuRadius).Shadow(ui.ShadowMD).
		Children(func() {
			// A popup lays its children in a row; the items stack in a column that takes
			// the panel's whole width.
			f.Column().Grow(1).Children(items)
		})
}

// itemOptions are the variations of a menu item.
type itemOptions struct {
	checked, disabled bool
	// top says the item is in the menu and not in a submenu: hovering it closes the open
	// submenu.
	top bool
	// shortcut is the key shown at the trailing end.
	shortcut string
}

// menuItem declares an item and reports whether it was chosen. Choosing it closes the menu.
func (w *window) menuItem(f *flex.Frame, id ui.ID, label string, o itemOptions) bool {
	row := f.Row().Height(menuRowHeight).MarginX(menuInset).PadSides(0, 10, 0, menuGap).
		Radius(menuItemRad).Items(flex.Center).
		HitWith(id, label, ui.HitOptions{Role: ui.RoleMenuItem, Disabled: o.disabled, Checked: o.checked})
	if !o.disabled {
		row = row.Hover(flex.Look{}.Background(w.pal.blu))
	}
	color := w.pal.tx
	if o.disabled {
		color = w.pal.tx3
	}
	row.Children(func() {
		check := ""
		if o.checked {
			check = "✓"
		}
		f.Row().Width(menuCheckW).Shrink(0).Children(func() {
			w.menuText(f, row, check, color, o.disabled)
		})
		w.menuText(f, row, label, color, o.disabled).Ellipsis()
		f.Spacer()
		if o.shortcut != "" {
			f.Row().PadSides(0, 0, 0, 16).Children(func() {
				w.menuText(f, row, o.shortcut, w.pal.tx2, o.disabled)
			})
		}
	})
	if o.top && !o.disabled && f.Canvas().Hovered() == id {
		w.menu.sub = -1
	}
	if !o.disabled && row.Clicked() {
		w.closeMenu()
		return true
	}
	return false
}

// menuText is the text of an item, which turns white while the item is hovered.
func (w *window) menuText(f *flex.Frame, row flex.Box, s string, color ui.Color, disabled bool) flex.Box {
	text := f.Text(s).FontSize(menuFont).Color(color)
	if !disabled {
		text = text.StateFrom(row).Hover(flex.Look{}.Color(w.pal.white))
	}
	return text
}

// menuSubmenu declares an item that opens the submenu index beside it, when hovered or
// clicked. It returns the item, the anchor of the submenu's panel.
func (w *window) menuSubmenu(f *flex.Frame, id ui.ID, label string, index int) flex.Box {
	open := w.menu.sub == index
	row := f.Row().Height(menuRowHeight).MarginX(menuInset).PadSides(0, 8, 0, menuGap).
		Radius(menuItemRad).Items(flex.Center).
		HitWith(id, label, ui.HitOptions{Role: ui.RoleMenuItem, Expandable: true, Expanded: open})
	color := w.pal.tx
	if open {
		row = row.Background(w.pal.blu)
		color = w.pal.white
	} else {
		row = row.Hover(flex.Look{}.Background(w.pal.blu))
	}
	row.Children(func() {
		f.Row().Width(menuCheckW).Shrink(0)
		w.menuText(f, row, label, color, false).Ellipsis()
		f.Spacer()
		w.menuText(f, row, "›", color, false)
	})
	if f.Canvas().Hovered() == id || row.Clicked() {
		w.menu.sub = index
	}
	return row
}

// menuSeparator declares the line between two groups of items.
func (w *window) menuSeparator(f *flex.Frame) {
	f.Row().Height(1).Shrink(0).MarginSides(menuInset, 10, menuInset, 10).Background(w.pal.line)
}

// menuHeading declares the title of a group of items.
func (w *window) menuHeading(f *flex.Frame, s string) {
	f.Row().Height(20).PadX(15).Items(flex.Center).Children(func() {
		f.Text(s).FontSize(11).Weight(ui.WeightSemibold).Color(w.pal.tx3)
	})
}

// drawMenus declares the open menu. The table owns its context menus; the toolbar the
// menus of its buttons.
func (w *window) drawMenus(f *flex.Frame) {
	switch w.menu.kind {
	case menuNone:
	case menuRow, menuHeader:
		w.drawRowMenu(f)
	default:
		w.drawToolbarMenu(f)
	}
}
