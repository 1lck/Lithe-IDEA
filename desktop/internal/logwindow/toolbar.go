package logwindow

import (
	"fmt"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// The toolbar's measures, after the macOS client's toolbar: a band with 10 points of room
// at its sides and 7 above and below, whose controls are 6 points apart.
const (
	toolbarPadX = 10
	toolbarPadY = 7
	toolbarGap  = 6
	// toolbarSearchHeight is the height of the filter field's line, and toolbarSearchMin the
	// least width it gets. The field takes whatever the first line has left over.
	toolbarSearchHeight = 36
	toolbarSearchMin    = 320
	// toolbarSearchField is the height of the field itself: the 36 point control minus the 3
	// points of room the macOS client leaves around its chrome.
	toolbarSearchField = 30
	toolbarSearchGap   = 7
	toolbarSearchIcon  = 16
	// toolbarSearchPad is the room before the magnifier and after the ⌘F badge: the macOS
	// client's 3 points around its chrome plus the 10 points inside it.
	toolbarSearchPad = 13
	// toolbarButtonPad is the room at each side of a button's label, and toolbarButtonGap the
	// space between its symbol and its title. toolbarFont is the size of its text.
	toolbarButtonPad = 9
	toolbarButtonGap = 5
	toolbarFont      = 12
	// A level toggle is a little shorter than a button and its text a little smaller.
	toolbarLevelHeight = 24
	toolbarLevelPad    = 8
	toolbarLevelFont   = 11.5
	toolbarLevelRadius = 5
	// toolbarInfoSize is the side of the ⓘ that explains a control.
	toolbarInfoSize = 18
	// The time range editor: 12 points of room around two 248 point endpoints 16 points apart,
	// which is 536 points in the macOS client. The panel's one point border at each side
	// takes room too, so the panel is two points wider.
	toolbarRangeWidth    = 538
	toolbarRangePad      = 12
	toolbarEndpointWidth = 248
	// toolbarMenuGap is the space between a button and the menu under it.
	toolbarMenuGap = 4
	// toolbarPathMax bounds the width of the maintenance menu, whose first item is the path of
	// the log directory.
	toolbarPathMax = 480
	// toolbarTimeFormat is how the time range editor writes and reads a time, and
	// toolbarLabelFormat how the range is written on its button. Both are in the local zone.
	toolbarTimeFormat  = "2006-01-02 15:04:05"
	toolbarLabelFormat = "01/02 15:04:05"
	// toolbarTimeHint is the placeholder of an empty time field.
	toolbarTimeHint = "YYYY-MM-DD HH:MM:SS"
)

// The identities of the toolbar's controls and of the items of its menus.
var (
	toolbarScope = tree.Sub(page, tree.Name("toolbar"))

	toolbarLevelScope       = tree.Sub(toolbarScope, tree.Name("levels"))
	toolbarSessionScope     = tree.Sub(toolbarScope, tree.Name("session-items"))
	toolbarColumnScope      = tree.Sub(toolbarScope, tree.Name("column-items"))
	toolbarSavedScope       = tree.Sub(toolbarScope, tree.Name("saved-items"))
	toolbarMaintenanceScope = tree.Sub(toolbarScope, tree.Name("maintenance-items"))

	toolbarClearSearchID = tree.ID(toolbarScope, "clear-search")
	toolbarFilterInfoID  = tree.ID(toolbarScope, "filter-info")
	toolbarSessionID     = tree.ID(toolbarScope, "session")
	toolbarRangeID       = tree.ID(toolbarScope, "time-range")
	toolbarSavedID       = tree.ID(toolbarScope, "saved")
	toolbarColumnsID     = tree.ID(toolbarScope, "columns")
	toolbarExportID      = tree.ID(toolbarScope, "export")
	toolbarCollapseID    = tree.ID(toolbarScope, "collapse")
	toolbarTimeID        = tree.ID(toolbarScope, "time")
	toolbarFollowID      = tree.ID(toolbarScope, "follow")
	toolbarFollowInfoID  = tree.ID(toolbarScope, "follow-info")
	toolbarClearViewID   = tree.ID(toolbarScope, "clear-view")
	toolbarMaintenanceID = tree.ID(toolbarScope, "maintenance")

	toolbarSaveID       = tree.ID(toolbarScope, "save-filter")
	toolbarSavedPanelID = tree.ID(toolbarScope, "saved-panel")
	toolbarApplyID      = tree.ID(toolbarScope, "apply-filter")
	toolbarDeleteID     = tree.ID(toolbarScope, "delete-filter")
	toolbarRangePanelID = tree.ID(toolbarScope, "range-panel")
	toolbarRangeInfoID  = tree.ID(toolbarScope, "range-info")
	toolbarRangeClearID = tree.ID(toolbarScope, "range-clear")
	toolbarRangeApplyID = tree.ID(toolbarScope, "range-apply")
)

// toolbarTimeLayouts are the forms a time may be typed in the time range editor: the form
// the editor writes, the same with a T between date and time, and without seconds.
var toolbarTimeLayouts = []string{toolbarTimeFormat, "2006-01-02T15:04:05", "2006-01-02 15:04"}

// toolbarState is what the toolbar keeps between frames.
type toolbarState struct {
	// rangeSeeded says the time range editor's fields were filled for the editor that is open.
	// The fields are filled once when the editor opens, so typing in them is not overwritten.
	rangeSeeded bool
	// usedLoaded says the size of the log directory was measured for the maintenance menu that
	// is open, so the menu shows a fresh size each time it opens but measures only once.
	usedLoaded bool
}

// toolbarItem is one control of the toolbar: how wide it is, which decides where the line
// breaks, and the code that declares it.
type toolbarItem struct {
	width float32
	draw  func()
}

// drawToolbar is the band under the title bar: the filter field, the level toggles and the
// buttons for the session, the time range, the saved filters, the columns, the export, the
// display options and the log directory. The controls wrap onto further lines when the
// window is too narrow for one; only the filter field, always the first control, grows into
// the room a line has left. A one point line closes the band at the bottom.
func (w *window) drawToolbar(f *flex.Frame) {
	// An editor or a menu that is not open will be seeded again the next time it opens.
	if w.menu.kind != menuTimeRange {
		w.toolbar.rangeSeeded = false
	}
	if w.menu.kind != menuMaintenance {
		w.toolbar.usedLoaded = false
	}
	lines := toolbarWrap(w.toolbarItems(f), f.Bounds().Width-2*toolbarPadX)
	f.Stack().FillWidth().Shrink(0).Background(w.pal.bg3).Children(func() {
		f.Column().FillWidth().PadSides(toolbarPadY, toolbarPadX, toolbarPadY, toolbarPadX).Gap(toolbarGap).Children(func() {
			for _, line := range lines {
				f.Row().FillWidth().Gap(toolbarGap).Items(flex.Center).Children(func() {
					for _, item := range line {
						item.draw()
					}
				})
			}
		})
		f.Row().Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	})
}

// toolbarWrap breaks the controls into lines no wider than width, the way the macOS
// client's toolbar layout does: a control goes on the current line unless the line already
// holds one and this one would not fit after a gap.
func toolbarWrap(items []toolbarItem, width float32) [][]toolbarItem {
	lines := [][]toolbarItem{{}}
	var used float32
	for _, item := range items {
		last := len(lines) - 1
		if used > 0 && used+toolbarGap+item.width > width {
			lines = append(lines, nil)
			last++
			used = 0
		}
		if used > 0 {
			used += toolbarGap
		}
		lines[last] = append(lines[last], item)
		used += item.width
	}
	return lines
}

// toolbarButtonWidth is the width of the button w.button declares for a symbol and a title:
// the room at the sides, the border, the text and, when it has both, the space between them.
func toolbarButtonWidth(canvas *ui.Canvas, symbol, title string) float32 {
	width := 2*toolbarButtonPad + 2 + monoWidth(canvas, symbol, toolbarFont) + monoWidth(canvas, title, toolbarFont)
	if symbol != "" && title != "" {
		width += toolbarButtonGap
	}
	return width
}

// toolbarItems lists the toolbar's controls in the order of the macOS client's toolbar,
// each with its width and the code that declares it. A control that depends on the model
// reads it when it is declared.
func (w *window) toolbarItems(f *flex.Frame) []toolbarItem {
	logs := &w.text.Logs
	m := w.model
	levelCell, _ := f.Canvas().CellSize(toolbarLevelFont)

	items := []toolbarItem{{width: toolbarSearchMin, draw: func() { w.drawToolbarSearch(f) }}}
	add := func(width float32, draw func()) {
		items = append(items, toolbarItem{width: width, draw: draw})
	}
	// addButton adds a plain button that runs click, unless it is disabled.
	addButton := func(id ui.ID, symbol, title string, o buttonOptions, click func()) {
		add(toolbarButtonWidth(f.Canvas(), symbol, title), func() {
			if w.button(f, id, symbol, title, o).Clicked() && !o.disabled {
				click()
			}
		})
	}
	// addMenu adds a button that opens the menu kind under itself.
	addMenu := func(kind menuKind, id ui.ID, symbol, title string, o buttonOptions) {
		add(toolbarButtonWidth(f.Canvas(), symbol, title), func() {
			w.toolbarMenuButton(f, kind, id, symbol, title, o)
		})
	}

	for index, level := range core.LogLevels {
		add(float32(len(level))*levelCell+2*toolbarLevelPad, func() { w.drawLevelToggle(f, index, level) })
	}
	session := w.sessionTitle(m.prefs.Query.Session)
	addMenu(menuSession, toolbarSessionID, session, "⌄", buttonOptions{label: session})
	addMenu(menuTimeRange, toolbarRangeID, logs.TimeRange, w.rangeLabel(), buttonOptions{})
	addMenu(menuSaved, toolbarSavedID, "★", logs.SavedFilters, buttonOptions{})
	addMenu(menuColumns, toolbarColumnsID, "▦", logs.Columns, buttonOptions{})
	addButton(toolbarExportID, "⇩", logs.Export, buttonOptions{label: logs.ExportLabel}, w.openExport)
	addButton(toolbarCollapseID, "⇊", logs.CollapseRepeats, buttonOptions{active: m.prefs.Collapse}, m.toggleCollapse)
	addButton(toolbarTimeID, "⏱", w.timeModeTitle(), buttonOptions{}, m.cycleTime)
	followSymbol, followTitle := "❚❚", logs.Paused
	if m.follows {
		followSymbol, followTitle = "●", logs.LiveFollow
	}
	addButton(toolbarFollowID, followSymbol, followTitle, buttonOptions{recording: m.follows}, m.toggleFollow)
	add(toolbarInfoSize, func() { w.info(f, toolbarFollowInfoID, logs.FollowHelp) })
	addButton(toolbarClearViewID, "⌫", logs.ClearView, buttonOptions{hint: logs.ClearViewHelp}, m.clearDisplay)
	addMenu(menuMaintenance, toolbarMaintenanceID, "⋯", "", buttonOptions{label: logs.Maintenance})
	return items
}

// toolbarMenuButton declares a button that opens the menu kind under itself, and registers
// it as the anchor the menu is placed by.
func (w *window) toolbarMenuButton(f *flex.Frame, kind menuKind, id ui.ID, symbol, title string, o buttonOptions) {
	box := w.button(f, id, symbol, title, o)
	w.anchors[kind] = box
	if box.Clicked() {
		w.openMenu(kind)
	}
}

// drawToolbarSearch is the filter field. Viva's field paints its own frame, so the
// magnifier, the button that clears the text, the ⓘ and the ⌘F badge sit beside the frame
// and not inside it as they do in the macOS client.
func (w *window) drawToolbarSearch(f *flex.Frame) {
	logs := &w.text.Logs
	f.Row().Basis(toolbarSearchMin).MinWidth(toolbarSearchMin).Grow(1).Shrink(0).
		Height(toolbarSearchHeight).PadX(toolbarSearchPad).Gap(toolbarSearchGap).Items(flex.Center).Children(func() {
		f.Icon(icons.Search).Size(toolbarSearchIcon, toolbarSearchIcon).Color(w.pal.tx2).Shrink(0)
		f.Field(&w.filter, filterID, logs.FilterPlaceholder, logs.FilterPlaceholder).Grow(1).MinWidth(0).Height(toolbarSearchField)
		if w.filter.Text() != "" {
			erase := f.Row().Size(toolbarSearchIcon, toolbarSearchIcon).Shrink(0).Center().Radius(4).
				Hover(flex.Look{}.Background(w.pal.bg)).
				HitWith(toolbarClearSearchID, logs.ClearSearch, ui.HitOptions{Role: ui.RoleButton, Hint: logs.ClearSearch, SkipFocus: true})
			erase.Children(func() {
				f.Icon(icons.X).Size(14, 14).Color(w.pal.tx2)
			})
			if erase.Clicked() {
				// The field is emptied here and the model told too: the window compares the
				// field with the text it had after the last paint, which this paint's end
				// overwrites, so the field alone would not reach the model.
				w.filter.SetText("")
				w.model.replaceExpression("")
			}
		}
		w.info(f, toolbarFilterInfoID, logs.FilterHelp)
		w.badge(f, "⌘F")
	})
}

// drawLevelToggle is the button that shows or hides one level. A shown level is filled in
// its own color (gray for DEBUG); a hidden one is an outline on the window's background.
func (w *window) drawLevelToggle(f *flex.Frame, index int, level core.LogLevel) {
	enabled := w.model.levelEnabled(level)
	fill, stroke, textColor := w.pal.bg, w.pal.bd, w.pal.tx2
	if enabled {
		fill = w.pal.levelColor(level)
		if level == core.LevelDebug {
			fill = w.pal.tx2
		}
		stroke = fill
		textColor = w.pal.white
		if w.pal.dark {
			textColor = w.pal.bg
		}
	}
	box := f.Row().Height(toolbarLevelHeight).Shrink(0).PadX(toolbarLevelPad).Items(flex.Center).
		Background(fill).Radius(toolbarLevelRadius).Stroke(1, stroke).
		HitWith(toolbarLevelScope.At(index), string(level), ui.HitOptions{Role: ui.RoleButton, Checked: enabled})
	box.Children(func() {
		label := w.mono(f, string(level), toolbarLevelFont, textColor)
		if enabled {
			label.Weight(ui.WeightSemibold)
		}
	})
	if box.Clicked() {
		w.model.toggleLevel(level)
	}
}

// sessionTitle is the session button's text for a session.
func (w *window) sessionTitle(session string) string {
	switch session {
	case sessionPrevious:
		return w.text.Logs.SessionPrevious
	case sessionAll:
		return w.text.Logs.SessionAll
	}
	return w.text.Logs.SessionCurrent
}

// timeModeTitle is the text of the button that cycles how the table writes times.
func (w *window) timeModeTitle() string {
	switch w.model.prefs.TimeMode {
	case 1:
		return w.text.Logs.RelativePrevious
	case 2:
		return w.text.Logs.RelativeSelected
	}
	return w.text.Logs.AbsoluteTime
}

// rangeLabel is the time range written on its button, in the local zone, or empty when the
// query has no complete range.
func (w *window) rangeLabel() string {
	since, sinceOK := parseInstant(w.model.prefs.Query.Since)
	until, untilOK := parseInstant(w.model.prefs.Query.Until)
	if !sinceOK || !untilOK {
		return ""
	}
	return time.UnixMilli(since).Local().Format(toolbarLabelFormat) + " – " + time.UnixMilli(until).Local().Format(toolbarLabelFormat)
}

// logDirectoryPath is the path of the log directory with the home directory abbreviated, or
// the words for it while the directory is not known.
func (w *window) logDirectoryPath() string {
	if w.model.directory == "" {
		return w.text.Logs.LogDirectory
	}
	return abbreviateHome(w.model.directory)
}

// rangeDefaults are the times the time range editor starts with: the limits of the range
// the query has, else the times of the oldest and the newest record the window holds, else
// now. Both are in the local zone.
func (w *window) rangeDefaults() (start, end time.Time) {
	m := w.model
	start = m.now()
	end = start
	if len(m.records) > 0 {
		start = time.UnixMilli(m.records[0].EpochMs)
		end = time.UnixMilli(m.records[len(m.records)-1].EpochMs)
	}
	if ms, ok := parseInstant(m.prefs.Query.Since); ok {
		start = time.UnixMilli(ms)
	}
	if ms, ok := parseInstant(m.prefs.Query.Until); ok {
		end = time.UnixMilli(ms)
	}
	return start.Local(), end.Local()
}

// parseRangeTime reads a time the user typed into the time range editor, in the local zone.
// Seconds may be left out.
func parseRangeTime(text string) (time.Time, bool) {
	text = strings.TrimSpace(text)
	for _, layout := range toolbarTimeLayouts {
		if at, err := time.ParseInLocation(layout, text, time.Local); err == nil {
			return at, true
		}
	}
	return time.Time{}, false
}

// timeZoneLine names the local zone and its offset from UTC, for example "CST (UTC+08:00)".
// A zone without an abbreviation, whose name is its offset such as "+08", is the offset alone.
func (w *window) timeZoneLine() string {
	name, offset := w.model.now().Zone()
	sign := '+'
	if offset < 0 {
		sign = '-'
		offset = -offset
	}
	utc := fmt.Sprintf("UTC%c%02d:%02d", sign, offset/3600, offset%3600/60)
	if name == "" || name[0] == '+' || name[0] == '-' {
		return utc
	}
	return name + " (" + utc + ")"
}

// drawToolbarMenu declares the open menu of a toolbar button, under the button. A menu whose
// button was not declared in this frame is not drawn.
func (w *window) drawToolbarMenu(f *flex.Frame) {
	anchor, ok := w.anchors[w.menu.kind]
	if !ok {
		return
	}
	below := func(b flex.Box) flex.Box { return b.BelowBox(anchor, toolbarMenuGap, flex.Start) }
	switch w.menu.kind {
	case menuSession:
		w.drawSessionMenu(f, below)
	case menuTimeRange:
		w.drawRangeMenu(f, below)
	case menuSaved:
		w.drawSavedMenu(f, below)
	case menuColumns:
		w.drawColumnMenu(f, below)
	case menuMaintenance:
		w.drawMaintenanceMenu(f, below)
	}
}

// drawSessionMenu is the choice between the current, the previous and every session.
func (w *window) drawSessionMenu(f *flex.Frame, place func(flex.Box) flex.Box) {
	w.menuSurface(f, place, 170, func() {
		for index, session := range sessions {
			chosen := w.menuItem(f, toolbarSessionScope.At(index), w.sessionTitle(session),
				itemOptions{checked: w.model.prefs.Query.Session == session, top: true})
			if chosen {
				w.model.setSession(session)
			}
		}
	})
}

// drawColumnMenu is the list of the table's columns, each checked while it is shown.
func (w *window) drawColumnMenu(f *flex.Frame, place func(flex.Box) flex.Box) {
	w.menuSurface(f, place, 160, func() {
		for index, column := range columns {
			shown := !w.model.columnHidden(column)
			if w.menuItem(f, toolbarColumnScope.At(index), w.tableColumnTitle(index), itemOptions{checked: shown, top: true}) {
				w.model.setColumnHidden(column, shown)
			}
		}
	})
}

// drawSavedMenu is the list of the saved filters, each opening a submenu that applies or
// deletes it, and the item that saves the current filter. The submenu is a panel of its own
// beside the item, declared after the menu so it is painted over it.
func (w *window) drawSavedMenu(f *flex.Frame, place func(flex.Box) flex.Box) {
	logs := &w.text.Logs
	bookmarks := w.model.prefs.Bookmarks
	rows := make([]flex.Box, len(bookmarks))
	w.menuSurface(f, place, 200, func() {
		if len(bookmarks) == 0 {
			w.menuHeading(f, logs.NoSavedFilters)
		}
		for index, saved := range bookmarks {
			rows[index] = w.menuSubmenu(f, toolbarSavedScope.At(index), saved.Name, index)
		}
		w.menuSeparator(f)
		if w.menuItem(f, toolbarSaveID, logs.SaveCurrentFilter, itemOptions{disabled: len(bookmarks) >= maxBookmarks, top: true}) {
			w.dialog = dialogBookmark
		}
	})
	sub := w.menu.sub
	if w.menu.kind != menuSaved || sub < 0 || sub >= len(bookmarks) {
		return
	}
	id := bookmarks[sub].ID
	beside := func(b flex.Box) flex.Box {
		return b.BesideBox(rows[sub], 2, flex.Start).
			HitWith(toolbarSavedPanelID, "", ui.HitOptions{Role: ui.RoleGroup, SkipFocus: true})
	}
	w.menuPanel(f, beside, 110, func() {
		if w.menuItem(f, toolbarApplyID, logs.Apply, itemOptions{}) {
			w.model.applyBookmark(id)
		}
		if w.menuItem(f, toolbarDeleteID, logs.Delete, itemOptions{}) {
			w.model.deleteBookmark(id)
		}
	})
}

// drawMaintenanceMenu is the menu of the log directory: its path, showing it in the file
// manager, changing it, restoring the default one, and clearing the logs with the space
// they use. The space is measured each time the menu opens.
func (w *window) drawMaintenanceMenu(f *flex.Frame, place func(flex.Box) flex.Box) {
	logs := &w.text.Logs
	m := w.model
	if !w.toolbar.usedLoaded {
		w.toolbar.usedLoaded = true
		m.loadUsedBytes()
	}
	bounded := func(b flex.Box) flex.Box { return place(b).MaxWidth(toolbarPathMax) }
	w.menuSurface(f, bounded, 240, func() {
		w.menuItem(f, toolbarMaintenanceScope.At(0), w.logDirectoryPath(), itemOptions{disabled: true})
		if w.menuItem(f, toolbarMaintenanceScope.At(1), logs.RevealDirectory, itemOptions{disabled: m.directory == ""}) {
			m.revealDirectory()
		}
		if w.menuItem(f, toolbarMaintenanceScope.At(2), logs.ChangeDirectory, itemOptions{disabled: m.busy}) {
			m.chooseDirectory()
		}
		if w.menuItem(f, toolbarMaintenanceScope.At(3), logs.RestoreDirectory, itemOptions{disabled: !m.canRestoreDirectory()}) {
			m.restoreDirectory()
		}
		w.menuSeparator(f)
		if w.menuItem(f, toolbarMaintenanceScope.At(4), logs.ClearStorage(formatBytes(m.usedBytes)), itemOptions{disabled: m.busy}) {
			w.dialog = dialogClear
		}
	})
}

// drawRangeMenu is the editor of the time range. The macOS client edits the two times with
// the system's calendar and clock controls; Viva has none, so each endpoint is a text field
// that holds the local time as YYYY-MM-DD HH:MM:SS. Apply is available while both times
// read and the end is not before the start.
func (w *window) drawRangeMenu(f *flex.Frame, place func(flex.Box) flex.Box) {
	logs := &w.text.Logs
	if !w.toolbar.rangeSeeded {
		w.toolbar.rangeSeeded = true
		start, end := w.rangeDefaults()
		w.rangeStart.SetText(start.Format(toolbarTimeFormat))
		w.rangeEnd.SetText(end.Format(toolbarTimeFormat))
	}
	start, startOK := parseRangeTime(w.rangeStart.Text())
	end, endOK := parseRangeTime(w.rangeEnd.Text())
	readable := startOK && endOK
	reversed := readable && start.After(end)
	// The panel takes presses on its own room, so only a press outside it closes the menu.
	panel := func(b flex.Box) flex.Box {
		return place(b).HitWith(toolbarRangePanelID, "", ui.HitOptions{Role: ui.RoleGroup, SkipFocus: true})
	}
	// The menu panel adds 5 points above and below the items; the editor makes up the rest of
	// its 12.
	pad := float32(toolbarRangePad - menuPadY)
	w.menuSurface(f, panel, toolbarRangeWidth, func() {
		f.Column().FillWidth().PadSides(pad, toolbarRangePad, pad, toolbarRangePad).Gap(toolbarRangePad).Children(func() {
			f.Row().Gap(toolbarGap).Items(flex.Center).Children(func() {
				f.Text(logs.TimeRange).FontSize(toolbarFont).Color(w.pal.tx)
				w.info(f, toolbarRangeInfoID, logs.TimeHelp)
			})
			f.Row().Gap(16).Children(func() {
				w.drawRangeEndpoint(f, &w.rangeStart, rangeStartID, logs.StartTime)
				w.drawRangeEndpoint(f, &w.rangeEnd, rangeEndID, logs.EndTime)
			})
			f.Text(w.timeZoneLine()).FontSize(11).Color(w.pal.tx2)
			switch {
			case reversed:
				f.Text(logs.ReversedTime).FontSize(toolbarFont).Color(w.pal.red)
			case !readable:
				f.Text(logs.InvalidTime).FontSize(toolbarFont).Color(w.pal.red)
			}
			f.Row().FillWidth().Items(flex.Center).Children(func() {
				if f.Button(toolbarRangeClearID, logs.ClearTimeRange).Outline().Clicked() {
					w.model.clearRange()
					w.closeMenu()
				}
				f.Spacer()
				valid := readable && !reversed
				if f.Button(toolbarRangeApplyID, logs.Apply).Outline().Disabled(!valid).Clicked() && valid {
					// The range includes the whole of the last second, as the macOS client's does.
					w.model.setRange(start.Unix()*1000, end.Unix()*1000+999)
					w.closeMenu()
				}
			})
		})
	})
}

// drawRangeEndpoint is one end of the time range: its title over a field for the time.
func (w *window) drawRangeEndpoint(f *flex.Frame, field *flex.Field, id ui.ID, title string) {
	f.Column().Width(toolbarEndpointWidth).Shrink(0).Gap(toolbarGap).Children(func() {
		f.Text(title).FontSize(toolbarFont).Color(w.pal.tx)
		f.Field(field, id, title, toolbarTimeHint).FillWidth().Height(toolbarSearchField)
	})
}
