package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
	"github.com/vivaui/viva/ui/textview"
)

// The Console tab is one Page: the toolbar with the search over the rows that gitconsole.go
// flattens, shown as read-only text the user selects and copies (textview), as the Run console
// is: a drag, across rows too, a double click for a word, a triple click for a row, Shift with
// a click, Primary+A and Primary+C. The rows are drawn in the run output's font (fonts.go), so
// the console reads like the run output beside it and, with the default fonts, like the editor.
// A header's stamp is subtle, its repository is in the accent color, and its temporary
// configuration is the toggle of its fold: a click on it opens or closes it. Other folds have
// their toggle after the row, and a header its running badge, at the right edge, where a
// selection never takes them. A long row ends in an ellipsis, or breaks onto more lines when
// the console wraps.

const (
	// consoleRowPadX is the room on either side of a row.
	consoleRowPadX = 8
	// consoleMenuWidth is the width of the console's context menu.
	consoleMenuWidth = 220
)

// consolePageView declares the body of the Console tab: the toolbar over the rows, or the
// empty message when the console holds no command.
func (a *App) consolePageView(c ui.C) {
	v := &a.consoleView
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
		ui.TextField(c, &v.search, t.Find, t.Find, ui.WithID(consoleSearchID)).MinWidth(150).Grow(1).MaxWidth(320)
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
		if a.gitIconButton(c, t.Settings, icons.Settings, false, false) {
			c.After(a.openGitConsoleSettings)
		}
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

// consoleSource is the console's rows as the text of its view, numbered from 0.
type consoleSource struct{ v *consoleView }

func (s consoleSource) First() int        { return 0 }
func (s consoleSource) Count() int        { return len(s.v.rows) }
func (s consoleSource) Line(n int) string { return s.v.rows[n].text }

// drawConsoleList declares the rows as read-only text that scrolls and follows its end while
// the user leaves it there. The current hit's row is drawn selected and the other rows with a
// hit are tinted; a header's configuration is a link that opens or closes its fold, and the
// toggle of another fold, after its row, a button.
func (a *App) drawConsoleList(c ui.C) {
	v := &a.consoleView
	font := a.outputFont()
	small := gfx.TextStyle{Size: a.theme.Metrics.FontSizeS, Weight: gfx.WeightRegular, Color: a.colors.Subtle}
	toggle := small
	toggle.Color = a.colors.Accent
	spec := textview.Spec{
		Label:      a.text.Git.Console,
		Source:     consoleSource{v},
		Font:       font.textStyle(),
		LineHeight: font.lineHeight(c.Canvas()),
		PadX:       consoleRowPadX,
		Selection:  a.terminalLook().Selection,
		Scroll:     true,
		Follow:     true,
		Wrap:       v.wrap,
		Ellipsis:   true,
		Revision:   v.revision,
		Spans: func(n int, text string, dst []textview.Span) []textview.Span {
			return a.consoleTextSpans(&v.rows[n], dst)
		},
		Open: func(n int, _ textview.Span) {
			if r := &v.rows[n]; r.inline && r.toggle != "" {
				a.toggleConsoleFold(r.fold, r.folded)
			}
		},
		LineBackground: func(n int) gfx.Color {
			switch {
			case n == v.hitRow:
				return a.colors.Selection
			case v.rows[n].matched:
				return a.colors.Hover
			}
			return gfx.Color{}
		},
		// A header's toggle is its configuration, inline; only a header has a badge.
		Trail: func(n int) textview.Trail {
			switch r := &v.rows[n]; {
			case r.badge != "":
				return textview.Trail{Text: r.badge, Style: small}
			case r.toggle != "" && !r.inline:
				return textview.Trail{Text: r.toggle, Style: toggle, Button: true}
			}
			return textview.Trail{}
		},
		PressTrail: func(n int) {
			if r := &v.rows[n]; r.toggle != "" {
				a.toggleConsoleFold(r.fold, r.folded)
			}
		},
		Copy: func(text string) {
			a.performed("git.console.copySelection", surfaceShortcut)
			a.copyConsoleText(text)
		},
		Menu: a.consoleMenu(c),
	}
	spec.Font.Color = a.colors.Text
	v.text.Declare(c.Key("rows"), spec).Grow(1).FillWidth()
}

// consoleTextSpans appends to dst the spans of row r, each in the color of its kind. The
// configuration of a header is the toggle of its fold, a link named by what a click does that
// takes the accent color under the pointer.
func (a *App) consoleTextSpans(r *consoleRow, dst []textview.Span) []textview.Span {
	if len(r.spans) == 0 {
		return append(dst, textview.Span{From: 0, To: len(r.text), Color: a.consoleToneColor(r.tone)})
	}
	from := 0
	for _, span := range r.spans {
		end := min(span.end, len(r.text))
		if end <= from {
			continue
		}
		s := textview.Span{From: from, To: end, Color: a.consoleSpanColor(r.tone, span.kind)}
		if span.kind == consoleSpanFold && r.inline {
			s.Link, s.Hover, s.Label = true, a.colors.Accent, r.toggle
		}
		dst = append(dst, s)
		from = end
	}
	return dst
}

// consoleSpanColor is the color of a stretch of kind in a row of tone: the stamp and the
// configuration are subtle and the repository in the accent color whatever the tone, the
// command green, so that it stands apart from its output, red when it failed and subtle for a
// query that answered the workflow, and the rest takes the tone's.
func (a *App) consoleSpanColor(tone consoleTone, kind consoleSpanKind) gfx.Color {
	switch kind {
	case consoleSpanStamp, consoleSpanFold:
		return a.colors.Subtle
	case consoleSpanRepository:
		return a.colors.Accent
	case consoleSpanCommand:
		switch tone {
		case consoleToneError:
			return a.theme.Danger
		case consoleToneSubtle:
			return a.colors.Subtle
		}
		return a.colors.Success
	}
	return a.consoleToneColor(tone)
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

// consoleMenu declares the console's context menu: Copy takes the selection, or the row
// right-clicked when nothing is selected, and Select All every row; then copy the command, the
// output or the directory of the record the row right-clicked is of. The values are taken
// while the menu is declared, because the snapshot may change before the action runs.
func (a *App) consoleMenu(c ui.C) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		v, t := &a.consoleView, &a.text.Console
		lang := a.language()
		menu.WidthRange(consoleMenuWidth, consoleMenuWidth)
		n, onRow := v.text.MenuLine()
		onRow = onRow && n >= 0 && n < len(v.rows)
		text, action, copyable := v.text.Text(), "copySelection", v.text.Has()
		if !copyable && onRow {
			text, action, copyable = v.rows[n].text, "copyLine", true
		}
		if menu.Item(i18n.Shared(lang, "menu.copy")).Disabled(!copyable).Clicked() {
			c.After(func() { a.copyConsoleRecord(action, text) })
		}
		if menu.Item(i18n.Shared(lang, "menu.selectAll")).Disabled(len(v.rows) == 0).Clicked() {
			c.After(func() {
				a.performed("git.console.selectAll", surfaceContextMenu)
				v.text.SelectAll()
			})
		}
		menu.Separator()
		var r *core.GitConsoleRecord
		if onRow {
			if index := v.rows[n].record; index >= 0 && index < len(v.snapshot.Records) {
				r = &v.snapshot.Records[index]
			}
		}
		if menu.Item(t.CopyCommand).Disabled(r == nil || len(r.Arguments) == 0).Clicked() {
			command := consoleCommand(r)
			c.After(func() { a.copyConsoleRecord("copyCommand", command) })
		}
		if menu.Item(t.CopyOutput).Disabled(r == nil || len(r.Lines) == 0).Clicked() {
			output := consoleOutput(r)
			c.After(func() { a.copyConsoleRecord("copyOutput", output) })
		}
		if menu.Item(t.CopyPath).Disabled(r == nil || r.Root == "").Clicked() {
			root := r.Root
			c.After(func() { a.copyConsoleRecord("copyPath", root) })
		}
	}
}
