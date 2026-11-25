package workbench

import (
	"net/url"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// terminalFindMaxQuery bounds, in characters, the query a selection fills Find with, so a
// whole selected screen costs no more than a selected word.
const terminalFindMaxQuery = 256

// terminalFind is a terminal's Find bar: the query, what the last search found and
// whether the bar is shown.
type terminalFind struct {
	open  bool
	field ui.Field
	// editor is the field's text, bound once the bar first opens so that opening it can
	// select the query.
	editor         *text.Editor
	query          string
	count, current int
	focus          bool
}

// show opens the bar with the keyboard on its field. A first open takes a selection of
// one line as the query; either way the field's text ends up selected, so typing or
// pasting a new query replaces it.
func (f *terminalFind) show(selection string) {
	if f.editor == nil {
		f.editor = text.NewEditor("")
		f.field.Bind(f.editor)
	}
	if !f.open {
		if query := terminalFindQuery(selection); query != "" {
			f.field.SetText(query)
		}
	}
	f.editor.SetSelection(text.Range{Start: 0, End: f.editor.RuneCount()})
	f.open, f.focus = true, true
}

// terminalFindQuery is a terminal selection as a Find query, or "" when it is not one
// that can be searched: Find matches within a line, so a selection crossing a line
// break finds nothing and is left out, as Windows Terminal leaves it out. The query is
// cut to terminalFindMaxQuery characters, with trailing blanks dropped.
func terminalFindQuery(selected string) string {
	if strings.ContainsAny(selected, "\r\n") {
		return ""
	}
	end, kept := len(selected), 0
	for index := range selected {
		if kept == terminalFindMaxQuery {
			end = index
			break
		}
		kept++
	}
	return strings.TrimRight(selected[:end], " \t")
}

// focusedTerminalTab is the terminal whose grid has the keyboard.
func (a *App) focusedTerminalTab(id gfx.ID) *terminal {
	if p := a.project; p != nil {
		for _, t := range p.terms.list {
			if t.view.Owns(id) {
				return t
			}
		}
	}
	return nil
}

// terminalFindShortcut opens the Find bar of the focused terminal on its chord.
func (a *App) terminalFindShortcut(event gfx.KeyEvent) gfx.EventResult {
	if !termview.IsFindChord(event) {
		return gfx.EventResult{}
	}
	t := a.focusedTerminalTab(event.Target)
	if t == nil {
		return gfx.EventResult{}
	}
	selection := ""
	if !t.find.open && t.view.HasSelection() {
		selection = t.view.SelectionText()
	}
	t.find.show(selection)
	a.performed("terminal.find.open", surfaceShortcut)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// terminalFindBar declares the Find bar over a terminal while it is open: the query,
// the match count, previous and next, and close. Typing searches again.
func (a *App) terminalFindBar(c ui.C, t *terminal) {
	f := &t.find
	if !f.open {
		return
	}
	words := a.text.Terminal
	id := ui.ID(c.Part("term-find" + strconv.Itoa(t.id)))
	if f.focus {
		c.Canvas().RequestFocus(id)
		f.focus = false
	}
	if query := f.field.Text(); query != f.query {
		f.query = query
		f.count, f.current = t.view.Find(query)
	}
	ui.Row(c.Part("term-find-row" + strconv.Itoa(t.id))).FillWidth().PadX(8).PadY(4).Items(ui.Center).Gap(6).Background(a.colors.Panel).Children(func() {
		field := ui.TextField(c, &f.field, words.Find, words.Find, ui.WithID(id)).Icon(icons.Search).Grow(1).MinWidth(0)
		if field.Submitted() {
			f.count, f.current = t.view.FindStep(-1)
		}
		label := words.FindNone
		if f.count > 0 {
			label = words.FindCount(strconv.Itoa(f.current+1), strconv.Itoa(f.count))
		}
		if f.query != "" {
			ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		}
		if ui.Button(c.Key("previous"), words.FindPrevious).Icon(icons.ChevronUp).IconOnly().Ghost().Disabled(f.count == 0).
			Tooltip(words.FindPrevious).Clicked() {
			f.count, f.current = t.view.FindStep(-1)
		}
		if ui.Button(c.Key("next"), words.FindNext).Icon(icons.ChevronDown).IconOnly().Ghost().Disabled(f.count == 0).
			Tooltip(words.FindNext).Clicked() {
			f.count, f.current = t.view.FindStep(1)
		}
		if ui.Button(c.Key("close"), words.FindClose).Icon(icons.X).IconOnly().Ghost().Tooltip(words.FindClose).Clicked() {
			c.After(func() { a.closeTerminalFind(t) })
		}
	})
}

// closeTerminalFind hides the bar, drops its selection and gives the keyboard back
// to the terminal.
func (a *App) closeTerminalFind(t *terminal) {
	t.view.FindClear()
	t.find = terminalFind{}
	a.focusTerminal(t.id)
}

// openTerminalLink opens a link clicked in a terminal: a web address in the system
// browser. Other schemes a program may emit through OSC 8 are not opened.
func (a *App) openTerminalLink(target string) {
	if !isWebURL(target) {
		return
	}
	a.post(func(a *App) {
		a.performed("terminal.link.open", surfaceButton)
		if err := openURL(target); err != nil {
			a.operationFailed("open_url", err)
			a.notifyError(a.text.Terminal.OpenLinkFailed(err.Error()))
		}
	})
}

// isWebURL reports whether address is an http or https address with a host.
func isWebURL(address string) bool {
	parsed, err := url.Parse(address)
	return err == nil && (parsed.Scheme == "https" || parsed.Scheme == "http") && parsed.Host != ""
}
