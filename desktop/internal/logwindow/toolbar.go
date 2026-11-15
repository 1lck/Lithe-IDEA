package logwindow

import (
	"fmt"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
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
	// toolbarSearchPad is the room before the field and after the ⌘F badge: the macOS
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
	// toolbarMenuGap is the space between a button and the editor under it.
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

// levelPart names the toggle of each level among the toolbar's controls.
var levelPart = func() map[core.LogLevel]string {
	parts := map[core.LogLevel]string{}
	for _, level := range core.LogLevels {
		parts[level] = "level-" + string(level)
	}
	return parts
}()

// toolbarTimeLayouts are the forms a time may be typed in the time range editor: the form
// the editor writes, the same with a T between date and time, and without seconds.
var toolbarTimeLayouts = []string{toolbarTimeFormat, "2006-01-02T15:04:05", "2006-01-02 15:04"}

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
func toolbarButtonWidth(canvas *gfx.Canvas, symbol, title string) float32 {
	width := 2*toolbarButtonPad + 2 + monoWidth(canvas, symbol, toolbarFont) + monoWidth(canvas, title, toolbarFont)
	if symbol != "" && title != "" {
		width += toolbarButtonGap
	}
	return width
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

// toolbarItem is one control of the toolbar: how wide it is, which decides where the line
// breaks, and the code that declares it.
type toolbarItem struct {
	width float32
	draw  func()
}

// toolbar is the band under the title bar: the filter field, the level toggles and the
// buttons for the session, the time range, the saved filters, the columns, the export, the
// display options and the log directory. The controls wrap onto further lines when the
// window is too narrow for one; only the filter field, always the first control, grows into
// the room a line has left. A one point line closes the band at the bottom.
func (w *window) toolbar(c ui.C) {
	// An editor or a menu that is not open will be seeded again the next time it opens.
	if !w.menus.timeRange {
		w.rangeSeeded = false
	}
	if !w.menus.maintenance {
		w.usedLoaded = false
	}
	lines := toolbarWrap(w.toolbarItems(c), c.Bounds().Width-2*toolbarPadX)
	ui.Stack(c).FillWidth().Shrink(0).Background(w.pal.bg3).Children(func() {
		ui.Column(c).FillWidth().PadSides(toolbarPadY, toolbarPadX, toolbarPadY, toolbarPadX).Gap(toolbarGap).Children(func() {
			for _, line := range lines {
				ui.Row(c).FillWidth().Gap(toolbarGap).Items(ui.Center).Children(func() {
					for _, item := range line {
						item.draw()
					}
				})
			}
		})
		ui.Row(c).Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	})
}

// toolbarItems lists the toolbar's controls in the order of the macOS client's toolbar,
// each with its width and the code that declares it. A control that depends on the model
// reads it when it is declared.
func (w *window) toolbarItems(c ui.C) []toolbarItem {
	logs := &w.text.Logs
	m := w.model
	levelCell, _ := c.Canvas().CellSize(toolbarLevelFont)

	items := []toolbarItem{{width: toolbarSearchMin, draw: func() { w.searchField(c) }}}
	add := func(width float32, draw func()) {
		items = append(items, toolbarItem{width: width, draw: draw})
	}
	// addButton adds a plain button that runs click, unless it is disabled.
	addButton := func(name, symbol, title string, o buttonOptions, click func()) {
		add(toolbarButtonWidth(c.Canvas(), symbol, title), func() {
			if w.button(c, name, symbol, title, o).Clicked() && !o.disabled {
				click()
			}
		})
	}
	// addMenu adds a button that opens a menu or the editor under itself; declare puts it
	// there, hanging off the button.
	addMenu := func(name string, open *bool, symbol, title string, o buttonOptions, declare func(anchor ui.Box)) {
		add(toolbarButtonWidth(c.Canvas(), symbol, title), func() {
			anchor := w.button(c, name, symbol, title, o)
			if anchor.Clicked() {
				*open = !*open
			}
			declare(anchor)
		})
	}

	for _, level := range core.LogLevels {
		add(float32(len(level))*levelCell+2*toolbarLevelPad, func() { w.levelToggle(c, level) })
	}
	session := w.sessionTitle(m.prefs.Query.Session)
	addMenu("session", &w.menus.session, session, "⌄", buttonOptions{label: session}, func(anchor ui.Box) {
		ui.Menu(c, anchor, &w.menus.session, w.sessionMenu)
	})
	addMenu("time-range", &w.menus.timeRange, logs.TimeRange, w.rangeLabel(), buttonOptions{}, func(anchor ui.Box) {
		w.rangeEditor(c, anchor)
	})
	addMenu("saved", &w.menus.saved, "★", logs.SavedFilters, buttonOptions{}, func(anchor ui.Box) {
		ui.Menu(c, anchor, &w.menus.saved, w.savedMenu)
	})
	addMenu("columns", &w.menus.columns, "▦", logs.Columns, buttonOptions{}, func(anchor ui.Box) {
		ui.Menu(c, anchor, &w.menus.columns, w.columnMenu)
	})
	addButton("export", "⇩", logs.Export, buttonOptions{label: logs.ExportLabel}, w.openExport)
	addButton("collapse", "⇊", logs.CollapseRepeats, buttonOptions{active: m.prefs.Collapse}, m.toggleCollapse)
	addButton("time", "⏱", w.timeModeTitle(), buttonOptions{}, m.cycleTime)
	followSymbol, followTitle := "❚❚", logs.Paused
	if m.follows {
		followSymbol, followTitle = "●", logs.LiveFollow
	}
	addButton("follow", followSymbol, followTitle, buttonOptions{recording: m.follows}, m.toggleFollow)
	add(toolbarInfoSize, func() { w.info(c, logs.FollowHelp) })
	addButton("clear-view", "⌫", logs.ClearView, buttonOptions{hint: logs.ClearViewHelp}, m.clearDisplay)
	addMenu("maintenance", &w.menus.maintenance, "⋯", "", buttonOptions{label: logs.Maintenance}, func(anchor ui.Box) {
		ui.Menu(c, anchor, &w.menus.maintenance, w.maintenanceMenu)
	})
	return items
}

// searchField is the filter field with the magnifier and the button that clears it inside
// its frame, and the ⓘ and the ⌘F badge beside it. Typing in it becomes the model's
// expression; an expression the model changed replaces the text.
func (w *window) searchField(c ui.C) {
	logs := &w.text.Logs
	m := w.model
	if w.filterRevision != m.expressionRevision {
		w.filterRevision = m.expressionRevision
		w.filterText = m.prefs.Query.Expression
	}
	ui.Row(c).Basis(toolbarSearchMin).MinWidth(toolbarSearchMin).Grow(1).Shrink(0).
		Height(toolbarSearchHeight).PadX(toolbarSearchPad).Gap(toolbarSearchGap).Items(ui.Center).Children(func() {
		field := ui.TextField(c, &w.filterText, logs.FilterPlaceholder, logs.FilterPlaceholder).
			Icon(icons.Search).Grow(1).MinWidth(0).Height(toolbarSearchField)
		if w.filterText != "" {
			field = field.Action(icons.X, logs.ClearSearch)
		}
		if w.focusFilter {
			// A request made while the shortcut is handled takes effect in the repaint
			// that follows it.
			w.focusFilter = false
			field.AutoFocus()
		}
		switch {
		case field.ActionClicked():
			w.filterText = ""
			m.replaceExpression("")
		case field.Changed():
			m.setExpression(w.filterText)
		}
		w.info(c, logs.FilterHelp)
		w.badge(c, "⌘F")
	})
}

// levelToggle is the button that shows or hides one level. A shown level is filled in its
// own color (gray for DEBUG); a hidden one is an outline on the window's background.
func (w *window) levelToggle(c ui.C, level core.LogLevel) {
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
	on := enabled
	toggle := ui.ToggleBase(c.Part(levelPart[level]), &on, string(level)).Height(toolbarLevelHeight).Shrink(0).
		PadX(toolbarLevelPad).Items(ui.Center).Background(fill).Radius(toolbarLevelRadius).Stroke(1, stroke).
		Children(func() {
			label := w.mono(c, string(level), toolbarLevelFont, textColor)
			if enabled {
				label.Weight(gfx.WeightSemibold)
			}
		})
	if toggle.Changed() {
		w.model.toggleLevel(level)
	}
}

// sessionMenu is the choice between the current, the previous and every session.
func (w *window) sessionMenu(menu *ui.MenuItems) {
	menu.WidthRange(170, 0)
	for _, session := range sessions {
		if menu.Item(w.sessionTitle(session)).Checked(w.model.prefs.Query.Session == session).Clicked() {
			w.model.setSession(session)
		}
	}
}

// columnMenu is the list of the table's columns, each checked while it is shown.
func (w *window) columnMenu(menu *ui.MenuItems) {
	menu.WidthRange(160, 0)
	for index, column := range columns {
		shown := !w.model.columnHidden(column)
		if menu.Item(w.tableColumnTitle(index)).Checked(shown).Clicked() {
			w.model.setColumnHidden(column, shown)
		}
	}
}

// savedMenu is the list of the saved filters, each opening a submenu that applies or
// deletes it, and the item that saves the current filter.
func (w *window) savedMenu(menu *ui.MenuItems) {
	logs := &w.text.Logs
	bookmarks := w.model.prefs.Bookmarks
	menu.WidthRange(200, 0)
	if len(bookmarks) == 0 {
		menu.Label(logs.NoSavedFilters)
	}
	for _, saved := range bookmarks {
		menu.Sub(saved.Name, func(sub *ui.MenuItems) {
			sub.WidthRange(110, 0)
			if sub.Item(logs.Apply).Clicked() {
				w.model.applyBookmark(saved.ID)
			}
			if sub.Item(logs.Delete).Clicked() {
				w.model.deleteBookmark(saved.ID)
			}
		})
	}
	menu.Separator()
	if menu.Item(logs.SaveCurrentFilter).Disabled(len(bookmarks) >= maxBookmarks).Clicked() {
		w.bookmarkOpen = true
	}
}

// maintenanceMenu is the menu of the log directory: its path, showing it in the file
// manager, changing it, restoring the default one, and clearing the logs with the space
// they use. The space is measured each time the menu opens.
func (w *window) maintenanceMenu(menu *ui.MenuItems) {
	logs := &w.text.Logs
	m := w.model
	if !w.usedLoaded {
		w.usedLoaded = true
		m.loadUsedBytes()
	}
	menu.WidthRange(240, toolbarPathMax)
	menu.Item(w.logDirectoryPath()).Disabled(true)
	if menu.Item(logs.RevealDirectory).Disabled(m.directory == "").Clicked() {
		m.revealDirectory()
	}
	if menu.Item(logs.ChangeDirectory).Disabled(m.busy).Clicked() {
		m.chooseDirectory()
	}
	if menu.Item(logs.RestoreDirectory).Disabled(!m.canRestoreDirectory()).Clicked() {
		m.restoreDirectory()
	}
	menu.Separator()
	if menu.Item(logs.ClearStorage(formatBytes(m.usedBytes))).Disabled(m.busy).Clicked() {
		w.clearOpen = true
	}
}

// rangeEditor is the editor of the time range, a popover under its button. The macOS client
// edits the two times with the system's calendar and clock controls; Viva has none, so each
// endpoint is a text field that holds the local time as YYYY-MM-DD HH:MM:SS. Apply is
// available while both times read and the end is not before the start.
func (w *window) rangeEditor(c ui.C, anchor ui.Box) {
	if !w.menus.timeRange {
		return
	}
	logs := &w.text.Logs
	if !w.rangeSeeded {
		w.rangeSeeded = true
		start, end := w.rangeDefaults()
		w.rangeStart = start.Format(toolbarTimeFormat)
		w.rangeEnd = end.Format(toolbarTimeFormat)
	}
	spec := ui.PopoverSpec{Width: toolbarRangeWidth, Align: ui.Start, Offset: toolbarMenuGap}
	ui.PopoverWith(c, anchor, spec, &w.menus.timeRange, func() {
		start, startOK := parseRangeTime(w.rangeStart)
		end, endOK := parseRangeTime(w.rangeEnd)
		readable := startOK && endOK
		reversed := readable && start.After(end)
		ui.Column(c).FillWidth().Gap(toolbarRangePad).Children(func() {
			ui.Row(c).Gap(toolbarGap).Items(ui.Center).Children(func() {
				ui.Text(c, logs.TimeRange).FontSize(toolbarFont).Color(w.pal.tx)
				w.info(c, logs.TimeHelp)
			})
			ui.Row(c).Gap(16).Children(func() {
				w.rangeEndpoint(c, &w.rangeStart, logs.StartTime)
				w.rangeEndpoint(c, &w.rangeEnd, logs.EndTime)
			})
			ui.Text(c, w.timeZoneLine()).FontSize(11).Color(w.pal.tx2)
			switch {
			case reversed:
				ui.Text(c, logs.ReversedTime).FontSize(toolbarFont).Color(w.pal.red)
			case !readable:
				ui.Text(c, logs.InvalidTime).FontSize(toolbarFont).Color(w.pal.red)
			}
			ui.Row(c).FillWidth().Items(ui.Center).Children(func() {
				if ui.Button(c, logs.ClearTimeRange).Outline().Clicked() {
					w.model.clearRange()
					w.menus.timeRange = false
				}
				ui.Spacer(c)
				valid := readable && !reversed
				if ui.Button(c, logs.Apply).Outline().Disabled(!valid).Clicked() && valid {
					// The range includes the whole of the last second, as the macOS client's does.
					w.model.setRange(start.Unix()*1000, end.Unix()*1000+999)
					w.menus.timeRange = false
				}
			})
		})
	})
}

// rangeEndpoint is one end of the time range: its title over a field for the time.
func (w *window) rangeEndpoint(c ui.C, value *string, title string) {
	ui.Column(c).Width(toolbarEndpointWidth).Shrink(0).Gap(toolbarGap).Children(func() {
		ui.Text(c, title).FontSize(toolbarFont).Color(w.pal.tx)
		ui.TextField(c, value, title, toolbarTimeHint).FillWidth().Height(toolbarSearchField)
	})
}

// openExport opens the export sheet.
func (w *window) openExport() {
	w.model.presentExport()
}
