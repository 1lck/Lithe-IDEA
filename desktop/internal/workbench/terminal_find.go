package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// terminalFind is a terminal's Find bar: the query, what the last search found and
// whether the bar is shown.
type terminalFind struct {
	open           bool
	field          ui.Field
	query          string
	count, current int
	focus          bool
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
	t.find.open, t.find.focus = true, true
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
		field := ui.TextFieldID(c, id, &f.field, words.Find, words.Find).Icon(icons.Search).Grow(1).MinWidth(0)
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
		if ui.Button(c.Key("previous"), words.FindPrevious).Icon(icons.ChevronUp).IconOnly().Ghost().Disabled(f.count == 0).Clicked() {
			f.count, f.current = t.view.FindStep(-1)
		}
		if ui.Button(c.Key("next"), words.FindNext).Icon(icons.ChevronDown).IconOnly().Ghost().Disabled(f.count == 0).Clicked() {
			f.count, f.current = t.view.FindStep(1)
		}
		if ui.Button(c.Key("close"), words.FindClose).Icon(icons.X).IconOnly().Ghost().Clicked() {
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
	if !agentCardWebURL(target) {
		return
	}
	a.post(func(a *App) {
		if err := openURL(target); err != nil {
			a.notifyError(a.text.Terminal.OpenLinkFailed(err.Error()))
		}
		a.performed("terminal.link.open", surfaceButton)
	})
}
