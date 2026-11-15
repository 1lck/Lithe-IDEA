package termview

import (
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/gfx"
)

// findLimit bounds the matches one search keeps.
const findLimit = 2000

// findState is the terminal's Find: the query, its matches in buffer order and
// the one selected.
type findState struct {
	query     string
	matches   []term.SearchMatch
	current   int
	truncated bool
}

// Find searches the retained output for query, case-insensitively, and selects
// the match nearest the bottom, as a terminal's find starts from the newest
// output. It returns the number of matches and the selected one's index, or -1.
func (v *View) Find(query string) (count, current int) {
	f := &v.find
	f.query = query
	f.matches, f.truncated = v.screen.Search(f.matches, query, findLimit)
	f.current = len(f.matches) - 1
	v.showMatch()
	return len(f.matches), f.current
}

// FindStep moves to the next (delta 1) or previous (delta -1) match, wrapping.
func (v *View) FindStep(delta int) (count, current int) {
	f := &v.find
	if f.query != "" {
		// Output arrives while the bar is open; search again so the matches are current.
		f.matches, f.truncated = v.screen.Search(f.matches, f.query, findLimit)
	}
	if len(f.matches) == 0 {
		f.current = -1
		return 0, -1
	}
	f.current = ((f.current+delta)%len(f.matches) + len(f.matches)) % len(f.matches)
	v.showMatch()
	return len(f.matches), f.current
}

// FindClear ends Find, dropping the selection it made.
func (v *View) FindClear() {
	if v.find.query != "" {
		v.selection.clear()
	}
	v.find = findState{}
}

// showMatch selects the current match and scrolls it into view.
func (v *View) showMatch() {
	f := &v.find
	if f.current < 0 || f.current >= len(f.matches) {
		v.selection.clear()
		return
	}
	match := f.matches[f.current]
	end := match.End
	if end.Column > 0 {
		end.Column--
	}
	v.selection.clear()
	v.selection.anchor = v.screen.BufferPoint(match.Start)
	v.selection.focus = v.screen.BufferPoint(end)
	v.selection.selected = true
	v.screen.RevealLine(match.Start.Line)
}

// linkModifier is the modifier that turns a click on a link into opening it:
// Command on macOS, Control elsewhere.
func linkModifier() gfx.Modifiers {
	if runtime.GOOS == "darwin" {
		return gfx.ModifierMeta
	}
	return gfx.ModifierControl
}

// openLinkAt opens the link under a modified primary click and reports whether
// there was one.
func (v *View) openLinkAt(event gfx.PointerEvent, position term.Position) bool {
	if v.cfg.OpenLink == nil || event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary ||
		event.Modifiers&linkModifier() == 0 {
		return false
	}
	line := v.screen.ViewLine(position.Row)
	if line < 0 {
		return false
	}
	link, ok := v.screen.LinksAt(term.BufferPosition{Line: line, Column: position.Column})
	if !ok || link.Target == "" {
		return false
	}
	v.cfg.OpenLink(link.Target)
	return true
}

// IsFindChord reports the chord that opens a terminal's Find: Command-F on macOS,
// Control-Shift-F elsewhere, where Control-F belongs to the shell.
func IsFindChord(event gfx.KeyEvent) bool {
	if event.Release || event.Key != gfx.KeyUnknown || (event.Text != "f" && event.Text != "F") {
		return false
	}
	want := gfx.ModifierControl | gfx.ModifierShift
	if runtime.GOOS == "darwin" {
		want = gfx.ModifierMeta
	}
	return event.Modifiers == want
}
