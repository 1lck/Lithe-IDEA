package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// This file is the find bar of the Diff tab (matrix id git-diff-review): it searches the text the
// two side editors show, without case where the case folds to the same length, and moves from
// one match to the next by selecting it in its editor, which reveals it. The toolbar opens the bar
// (difftab_view.go). Whitespace-insensitive comparison and word-level highlights are not here:
// Core's diff has no option for either.

// diffMatch is one occurrence of the query: the editor it is in and its byte range there.
type diffMatch struct {
	view       *editorview.View
	start, end int
}

// diffFind is the find bar of a Diff tab.
type diffFind struct {
	open  bool
	field ui.Field
	// query is the text the matches were computed for; computed says they were.
	query    string
	computed bool
	matches  []diffMatch
	current  int
}

// diffFindMatches finds every case-insensitive occurrence of query in the text of views.
func diffFindMatches(query string, views ...*editorview.View) []diffMatch {
	if query == "" {
		return nil
	}
	needle := strings.ToLower(query)
	var out []diffMatch
	for _, v := range views {
		if v == nil {
			continue
		}
		raw, _ := v.Text()
		haystack := string(raw)
		folded := strings.ToLower(haystack)
		if len(folded) != len(haystack) {
			folded = haystack
			needle = query
		}
		for at := 0; ; {
			i := strings.Index(folded[at:], needle)
			if i < 0 {
				break
			}
			start := at + i
			out = append(out, diffMatch{view: v, start: start, end: start + len(needle)})
			at = start + max(len(needle), 1)
		}
	}
	return out
}

// refreshDiffFind recomputes the matches when the typed query changed and selects the current one.
func (a *App) refreshDiffFind(t *diffTab) {
	q := t.find.field.Text()
	if t.find.computed && q == t.find.query {
		return
	}
	t.find.query, t.find.computed = q, true
	t.find.current = 0
	t.find.matches = nil
	if t.before != nil || t.after != nil {
		var views []*editorview.View
		if t.before != nil {
			views = append(views, t.before.view)
		}
		if t.after != nil {
			views = append(views, t.after.view)
		}
		t.find.matches = diffFindMatches(q, views...)
	}
	a.selectDiffMatch(t)
}

// selectDiffMatch selects the current match in its editor, so that the editor reveals it.
func (a *App) selectDiffMatch(t *diffTab) {
	if t.find.current < 0 || t.find.current >= len(t.find.matches) {
		return
	}
	m := t.find.matches[t.find.current]
	m.view.SetSelection(m.start, m.end)
}

// stepDiffFind moves the current match by by, wrapping around both ends.
func (a *App) stepDiffFind(t *diffTab, by int) {
	n := len(t.find.matches)
	if n == 0 {
		return
	}
	t.find.current = ((t.find.current+by)%n + n) % n
	a.selectDiffMatch(t)
}

// closeDiffFind closes the bar and forgets its matches.
func (t *diffTab) closeDiffFind() {
	t.find = diffFind{}
}

// diffFindBar declares the find bar over the Diff tab: the query field, how many matches there
// are and which one is current, and the previous, next and close buttons.
func (a *App) diffFindBar(c ui.C, t *diffTab) {
	a.refreshDiffFind(t)
	n := len(t.find.matches)
	lang := a.language()
	ui.Row(c).FillWidth().Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		ui.TextField(c, &t.find.field, i18n.Shared(lang, "desktop.diffFind.field"), i18n.Shared(lang, "desktop.diffFind.field")).Grow(1).FillWidth().AutoFocus()
		count := "0/0"
		if n > 0 {
			count = strconv.Itoa(t.find.current+1) + "/" + strconv.Itoa(n)
		}
		ui.Text(c, count).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.diffFind.previous"), icons.ArrowUp, false, n == 0) {
			c.After(func() { a.stepDiffFind(t, -1) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.diffFind.next"), icons.ArrowDown, false, n == 0) {
			c.After(func() { a.stepDiffFind(t, 1) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.diffFind.close"), icons.X, false, false) {
			c.After(t.closeDiffFind)
		}
	})
	ui.Divider(c)
}
