package workbench

import (
	"context"
	"errors"
	"runtime"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the find bar of the Diff tab (matrix id git-diff-review): it has Core search the
// text the two side editors show, without case, and moves from one match to the next by
// selecting it in its editor, which reveals it. Matching is Core's editor.find, the rule the
// editors' find bar uses, run on a worker over each side's immutable snapshot; the bar keeps the
// query, the matches of the snapshots they were found in and the current one. The toolbar opens
// the bar (difftab_view.go). Ignoring whitespace is a read option of the diff
// (difftab_whitespace.go), and the word ranges come with Core's diff (difftab_view.go).

// diffMatch is one occurrence of the query: the editor it is in and its byte range there.
type diffMatch struct {
	view       *editorview.View
	start, end int
}

// diffFind is the find bar of a Diff tab.
type diffFind struct {
	open  bool
	field ui.Field
	// query and snapshots are what the matches were asked for: the typed text and the text of
	// each searched editor, in the order of views; computed says they were asked for.
	query     string
	views     []*editorview.View
	snapshots []rope.Rope
	computed  bool
	// pending is set while Core searches; gen tells its answer from a later search's, and
	// cancel gives it up.
	pending bool
	gen     uint64
	cancel  context.CancelFunc
	matches []diffMatch
	// truncated says Core stopped at its bound of matches in a side.
	truncated bool
	current   int
}

// diffFindViews are the editors of t the bar searches, in the order their matches come.
func (t *diffTab) diffFindViews() []*editorview.View {
	var views []*editorview.View
	if t.before != nil {
		views = append(views, t.before.view)
	}
	if t.after != nil {
		views = append(views, t.after.view)
	}
	return views
}

// diffFindCurrent reports whether the matches were asked for query in the texts views show now.
func (f *diffFind) diffFindCurrent(query string, views []*editorview.View) bool {
	if !f.computed || query != f.query || len(views) != len(f.views) {
		return false
	}
	for i, v := range views {
		if v != f.views[i] || !v.TextSnapshot().Same(f.snapshots[i]) {
			return false
		}
	}
	return true
}

// refreshDiffFind has Core search the sides again when the typed query or the text they show
// changed. The search runs on a worker over the sides' snapshots; a newer one or closing the
// bar gives it up, and an answer for text the sides no longer show is dropped and asked again.
func (a *App) refreshDiffFind(p *project, t *diffTab) {
	f := &t.find
	query, views := f.field.Text(), t.diffFindViews()
	if f.diffFindCurrent(query, views) {
		return
	}
	f.stopDiffFind()
	f.query, f.views, f.computed = query, views, true
	f.snapshots = make([]rope.Rope, len(views))
	for i, v := range views {
		f.snapshots[i] = v.TextSnapshot()
	}
	f.matches, f.truncated, f.current = nil, false, 0
	kernel, ok := a.kernel.(editorFindKernel)
	if query == "" || len(views) == 0 || !ok {
		return
	}
	ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
	f.cancel, f.pending = cancel, true
	gen, snapshots := f.gen, f.snapshots
	a.background(p, kernelCallTimeout, func(context.Context) func(*App) {
		defer cancel()
		var found []diffMatch
		truncated := false
		var err error
		for i, v := range views {
			var result core.EditorFindResult
			if result, err = kernel.FindEditorText(ctx, snapshots[i].Bytes(), core.EditorFindRequest{Query: query}); err != nil {
				break
			}
			for _, m := range result.Matches {
				found = append(found, diffMatch{view: v, start: m.Start, end: m.End})
			}
			truncated = truncated || result.Truncated
		}
		return func(a *App) { a.applyDiffFind(t, gen, found, truncated, err) }
	})
}

// applyDiffFind shows the matches of the search gen when it is still the bar's own, marking
// them in their editors and selecting the first.
func (a *App) applyDiffFind(t *diffTab, gen uint64, found []diffMatch, truncated bool, err error) {
	f := &t.find
	if !f.open || f.gen != gen {
		return
	}
	f.pending, f.cancel = false, nil
	if !f.diffFindCurrent(f.field.Text(), t.diffFindViews()) {
		f.computed = false // the sides changed under the search; the next draw asks again
		return
	}
	if err != nil {
		if !errors.Is(err, context.Canceled) {
			a.gitOperationFailed("diff_find", err)
		}
		return
	}
	f.matches, f.truncated = found, truncated
	for _, v := range f.views {
		var ranges []editorview.Range
		for _, m := range found {
			if m.view == v {
				ranges = append(ranges, editorview.Range{Start: m.start, End: m.end})
			}
		}
		v.SetSearchMatches(ranges)
	}
	a.selectDiffMatch(t)
}

// stopDiffFind gives up the search under way and the marks of the last one.
func (f *diffFind) stopDiffFind() {
	f.gen++
	if f.cancel != nil {
		f.cancel()
		f.cancel = nil
	}
	f.pending = false
	for _, v := range f.views {
		v.ClearSearchMatches()
	}
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

// closeDiffFind closes the bar and forgets its matches, giving up a search under way.
func (t *diffTab) closeDiffFind() {
	t.find.stopDiffFind()
	t.find = diffFind{gen: t.find.gen}
}

// diffFindBar declares the find bar over the Diff tab: the query field, how many matches there
// are and which one is current, and the previous, next and close buttons.
func (a *App) diffFindBar(c ui.C, p *project, t *diffTab) {
	a.refreshDiffFind(p, t)
	n := len(t.find.matches)
	lang := a.language()
	ui.Row(c).FillWidth().Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if ui.TextField(c, &t.find.field, i18n.Shared(lang, "desktop.diffFind.field"), i18n.Shared(lang, "desktop.diffFind.field")).Grow(1).FillWidth().AutoFocus().Submitted() {
			c.After(func() { a.stepDiffFind(t, 1) })
		}
		count := "0/0"
		switch {
		case t.find.pending:
			count = i18n.Shared(lang, "desktop.editorFind.loading")
		case n > 0:
			count = strconv.Itoa(t.find.current+1) + "/" + strconv.Itoa(n)
			if t.find.truncated {
				count += "+" // Core stopped at its bound of matches in a side
			}
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

// diffFindChord opens the find bar of tab t on the find chord, Command+F on a Mac and Control+F
// elsewhere, as the editors take their own chords, and reports whether event was that chord. The
// chord is handled before the editor sees it, so the editor does not also take the letter.
func (a *App) diffFindChord(t *diffTab, event gfx.KeyEvent) bool {
	if event.Release || event.Key != gfx.KeyUnknown || t.file == nil {
		return false
	}
	modifier := gfx.ModifierControl
	if runtime.GOOS == "darwin" {
		modifier = gfx.ModifierMeta
	}
	if event.Modifiers&^gfx.ModifierShift != modifier || strings.ToLower(event.Text) != "f" {
		return false
	}
	t.find.open = true
	return true
}
