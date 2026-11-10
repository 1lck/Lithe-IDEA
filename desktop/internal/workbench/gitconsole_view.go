package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Console tab is one Page: the toolbar with the search over the list of rows that
// gitconsole.go flattens. A row is one line of text in the proportional font, with a badge
// and the toggle of a fold after it; the fixed-pitch font is not used because it measures
// wide characters wrongly (vivaui/viva#187).

const (
	// consoleRowMin is the least height of a row, one line of the small font with room.
	consoleRowMin = 20
	// consoleMenuWidth is the width of a record's context menu.
	consoleMenuWidth = 220
)

// consolePageView declares the body of the Console tab: the toolbar over the rows, or the
// empty message when the console holds no command.
func (a *App) consolePageView(c ui.C) {
	v := &a.consoleView
	if v.drawRow == nil {
		v.list.Key, v.list.Label = v.rowKey, v.rowLabel
		v.drawRow = a.drawConsoleRow
	}
	a.syncConsole()
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.drawConsoleToolbar(c)
		ui.Divider(c)
		if len(v.snapshot.Records) == 0 {
			a.gitEmpty(c, a.text.Console.Empty)
			return
		}
		a.drawConsoleList(c)
	})
}

// drawConsoleToolbar declares the toolbar: the search with its count and the buttons that
// step through the hits, then the view and console actions.
func (a *App) drawConsoleToolbar(c ui.C) {
	v, t := &a.consoleView, &a.text.Console
	ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		ui.TextFieldID(c, consoleSearchID, &v.search, t.Find, t.Find).MinWidth(150).Grow(1).MaxWidth(320)
		if v.searchFor != "" && v.counted {
			if v.total == 0 {
				a.drawConsoleCount(c, t.NoMatches)
			} else {
				a.drawConsoleCount(c, t.Matches(v.total))
				if v.total > len(v.hits) {
					a.drawConsoleCount(c, t.SearchLimit(len(v.hits)))
				}
			}
		}
		noHits := len(v.hits) == 0
		if a.gitIconButton(c, t.PreviousMatch, icons.ChevronUp, false, noHits) {
			c.After(func() { a.stepConsoleMatch(-1) })
		}
		if a.gitIconButton(c, t.NextMatch, icons.ChevronDown, false, noHits) {
			c.After(func() { a.stepConsoleMatch(1) })
		}
		if a.gitIconButton(c, t.CloseSearch, icons.X, false, v.searchFor == "") {
			c.After(a.closeConsoleSearch)
		}
		ui.Spacer(c)
		empty := len(v.snapshot.Records) == 0
		if a.gitIconButton(c, t.Wrap, icons.WrapText, v.wrap, false) {
			c.After(a.toggleConsoleWrap)
		}
		if a.gitIconButton(c, t.ScrollToEnd, icons.ArrowDownToLine, false, empty) {
			c.After(a.consoleScrollToEnd)
		}
		if a.gitIconButton(c, t.Stop, icons.Square, false, !v.snapshot.Running) {
			c.After(a.stopConsole)
		}
		if a.gitIconButton(c, t.Clear, icons.Eraser, false, empty) {
			c.After(a.clearConsole)
		}
		if a.gitIconButton(c, t.CopyAll, icons.Copy, false, empty) {
			c.After(a.copyConsoleAll)
		}
	})
}

// drawConsoleCount declares a note of the search's count beside the search field.
func (a *App) drawConsoleCount(c ui.C, value string) {
	ui.Text(c, value).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
}

// drawConsoleList declares the rows. The list follows its end while the user leaves it
// there; a step to a hit scrolls it away from the end, which Follow would undo in the same
// layout, so the area is told it was left there.
func (a *App) drawConsoleList(c ui.C) {
	v := &a.consoleView
	area := ui.List(c, &v.list, len(v.rows), v.drawRow).Label(a.text.Git.Console).Grow(1).FillWidth().Follow(true)
	if v.detach {
		v.detach = false
		s := area.ScrollState()
		s.ScrollTo(s.Offset)
	}
}

// drawConsoleRow declares one row: its text in the row's tone, its badge and its fold's
// toggle, with the context menu of its record. The current hit's row is drawn selected and
// the other rows with a hit are tinted.
func (a *App) drawConsoleRow(row ui.ListRow) {
	v := &a.consoleView
	if row.Index < 0 || row.Index >= len(v.rows) {
		return
	}
	r := v.rows[row.Index]
	c := row.C
	item := row.Element.FillWidth().MinHeight(consoleRowMin).PadX(8).PadY(1).Gap(6).Items(ui.Center)
	switch {
	case row.Index == v.hitRow:
		item.Background(a.colors.Selection)
	case r.matched:
		item.Background(a.colors.Hover)
	}
	if r.record >= 0 {
		ui.ContextMenu(c, row.Element, a.consoleMenu(c, r.record))
	}
	item.Children(func() {
		var label ui.Box
		if v.wrap {
			label = ui.Wrap(c, r.text)
		} else {
			label = ui.Text(c, r.text).Ellipsis()
		}
		label.FontSize(a.theme.Metrics.FontSizeS).Color(a.consoleToneColor(r.tone)).Grow(1).Shrink(1).MinWidth(0)
		if r.badge != "" {
			ui.Text(c, r.badge).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		}
		if r.toggle == "" {
			return
		}
		// The toggle is named by the row's part, so each row's toggle is a control of its own.
		fc := c.Part("fold")
		id := ui.ID(fc)
		toggle := ui.Row(fc).Shrink(0).Items(ui.Center).
			HitWith(id, r.toggle, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
		toggle.Children(func() {
			ui.Text(fc, r.toggle).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Accent)
		})
		if toggle.Clicked() {
			fold, opening := r.fold, r.folded
			c.After(func() { a.toggleConsoleFold(fold, opening) })
		}
	})
}

// consoleToneColor is the color of a row's text in tone.
func (a *App) consoleToneColor(tone consoleTone) gfx.Color {
	switch tone {
	case consoleToneSubtle:
		return a.colors.Subtle
	case consoleToneError:
		return a.theme.Danger
	}
	return a.colors.Text
}

// consoleMenu declares the context menu of the record at index of the snapshot: copy its
// command, its output or the directory it ran in. The values are taken while the menu is
// declared, because the snapshot may change before the action runs.
func (a *App) consoleMenu(c ui.C, index int) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		v, t := &a.consoleView, &a.text.Console
		if index < 0 || index >= len(v.snapshot.Records) {
			return
		}
		r := &v.snapshot.Records[index]
		menu.WidthRange(consoleMenuWidth, consoleMenuWidth)
		if menu.Item(t.CopyCommand).Disabled(len(r.Arguments) == 0).Clicked() {
			command := consoleCommand(r)
			c.After(func() { a.copyConsoleRecord("copyCommand", command) })
		}
		if menu.Item(t.CopyOutput).Disabled(len(r.Lines) == 0).Clicked() {
			output := consoleOutput(r)
			c.After(func() { a.copyConsoleRecord("copyOutput", output) })
		}
		if menu.Item(t.CopyPath).Disabled(r.Root == "").Clicked() {
			root := r.Root
			c.After(func() { a.copyConsoleRecord("copyPath", root) })
		}
	}
}
