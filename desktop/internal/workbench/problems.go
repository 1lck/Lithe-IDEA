package workbench

import (
	"context"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Problems tool window, laid out the way IntelliJ IDEA's Problems tool window lays out its
// diagnostics: the header's tabs choose the current file or the whole project, each with the
// number of problems it holds; a tree holds a node per file over its diagnostics; a column of
// actions left of the tree holds the view options, opening and closing every node, and the
// preview, a read-only source view beside the tree that shows the selected diagnostic's line.
//
// Core filters, orders and groups the diagnostics, lays the visible rows out under the nodes
// the user closed, moves a selection that a closed node hides or that the server withdrew, and
// says which diagnostic each row shows (lsp.problems.query). This file keeps which nodes are
// closed and which row is selected, collects the published diagnostics, and opens a
// diagnostic's file at its position.

// problemsView is the Problems tool window's cached Core answer and the tree state it was
// asked with.
//
// The tree is asked for in the background, because Core filters and sorts every submitted
// diagnostic and the window thread must not do that work. generation rises on every change to
// the published diagnostics and to the view's options or nodes, so an answer computed from an
// older state is dropped instead of replacing the current tree.
type problemsView struct {
	generation uint64
	// queried is the generation the cached answer was computed from.
	queried uint64
	// loaded says a query has completed at least once for the current project.
	loaded bool
	// querying says a background query is in flight.
	querying bool
	// diagnostics is the exact list submitted with result; result's indices point
	// into it.
	diagnostics []core.ProblemsDiagnostic
	result      core.ProblemsResult
	// file is the current file the cached answer was asked for, empty when no file was open.
	// fileCount and projectCount are how many problems the header's tabs count: the current
	// file's and the project's, under the severity options.
	file                    string
	fileCount, projectCount int
	// failure is a query Core refused, shown in place of the tree. It is cleared
	// by the next successful answer or by a project change.
	failure error
	// project says the Project tab is chosen; the File tab, the current file's problems, is
	// chosen until then, as IDEA opens the window on it.
	project bool
	// collapsed holds the keys of the nodes the user closed, as Core names them.
	collapsed map[string]bool
	// selected is the key of the selected row and selectedRow its place in the answer's rows, -1
	// for none; asked is the key sent with the query in flight, so a selection the user makes
	// meanwhile is kept over the one Core answers. reveal asks the next frame to scroll the
	// selection into view.
	selected    string
	selectedRow int
	asked       string
	reveal      bool
	// focus is the keyboard focus the last frame saw, so only a move of it selects a row.
	focus gfx.ID
	view  ui.TreeState
	// optionsOpen says the View Options menu is open.
	optionsOpen bool
	// show says the Show Editor Preview option is on: a read-only source view beside the tree
	// shows the selected diagnostic's line. preview is that view.
	show    bool
	preview sourcePreview
	// split is the width of the tree beside the preview; the user drags it.
	split ui.SplitterState
	// hideErrors, hideWarnings and hideInfo narrow the severities shown; a query sends them
	// as Core's severity filter. groupBy is Core's grouping: file, severity or none.
	hideErrors, hideWarnings, hideInfo bool
	groupBy                            string
}

// reset forgets the answer of the previous project. The view options and the chosen tab are
// preferences, so they survive the project change; the preview itself is released.
func (v *problemsView) reset() {
	options := problemsView{show: v.show, split: v.split, hideErrors: v.hideErrors, hideWarnings: v.hideWarnings,
		hideInfo: v.hideInfo, groupBy: v.groupBy, project: v.project, selectedRow: -1}
	v.preview.close()
	*v = options
}

// severityFilter is the severity filter Core receives: nil keeps every severity, which is
// also what unchecking all three options shows. Hint severities are shown with information.
func (v *problemsView) severityFilter() []int {
	if !v.hideErrors && !v.hideWarnings && !v.hideInfo || v.hideErrors && v.hideWarnings && v.hideInfo {
		return nil
	}
	var kept []int
	if !v.hideErrors {
		kept = append(kept, 1)
	}
	if !v.hideWarnings {
		kept = append(kept, 2)
	}
	if !v.hideInfo {
		kept = append(kept, 3, 4)
	}
	return kept
}

// grouping is the grouping the tree is asked with; Core's default, by file, until the user
// chooses another.
func (v *problemsView) grouping() string {
	if v.groupBy == "" {
		return core.ProblemsGroupByFile
	}
	return v.groupBy
}

// key is the Tree's key of visible row i: a node is its group's place, a diagnostic follows
// every node at its place in the submitted list, so a row keeps its key while the nodes above it
// open and close.
func (v *problemsView) key(i int) int {
	r := v.result.Rows[i]
	if r.Kind == core.ProblemsRowGroup {
		return r.Group
	}
	return len(v.result.Groups) + r.Shows
}

// node describes visible row i to the Tree.
func (v *problemsView) node(i int) ui.TreeNode {
	r := v.result.Rows[i]
	return ui.TreeNode{
		Depth:    r.Depth,
		Branch:   r.Kind == core.ProblemsRowGroup,
		Expanded: r.Expanded != nil && *r.Expanded,
		Selected: i == v.selectedRow,
	}
}

// rowOf is the visible row with key, or -1 when it does not show.
func (v *problemsView) rowOf(key string) int {
	return slices.IndexFunc(v.result.Rows, func(r core.ProblemsRow) bool { return r.Key == key })
}

// selectRow selects the visible row with key; it is false when that row does not show.
func (v *problemsView) selectRow(key string) bool {
	i := v.rowOf(key)
	if i < 0 {
		return false
	}
	v.selected, v.selectedRow = key, i
	return true
}

// shown is the diagnostic row i previews and opens: the diagnostic itself, or a node's first.
func (v *problemsView) shown(i int) (core.ProblemsDiagnostic, bool) {
	if i < 0 || i >= len(v.result.Rows) {
		return core.ProblemsDiagnostic{}, false
	}
	shows := v.result.Rows[i].Shows
	if shows < 0 || shows >= len(v.diagnostics) {
		return core.ProblemsDiagnostic{}, false
	}
	return v.diagnostics[shows], true
}

// toggleProblemsNode opens or closes the node with key. Core moves the selection to the node
// when it was under it.
func (a *App) toggleProblemsNode(key string) {
	v := &a.problems
	if v.collapsed[key] {
		delete(v.collapsed, key)
	} else {
		if v.collapsed == nil {
			v.collapsed = map[string]bool{}
		}
		v.collapsed[key] = true
	}
	a.markProblemsChanged()
}

// expandProblems opens or closes every node of the tree. A diagnostic that was selected hands
// the selection to its node when that node closes.
func (a *App) expandProblems(expanded bool) {
	v := &a.problems
	v.collapsed = nil
	if !expanded {
		v.collapsed = make(map[string]bool, len(v.result.Groups))
		for _, g := range v.result.Groups {
			v.collapsed[g.Key] = true
		}
	}
	v.reveal = true
	a.markProblemsChanged()
}

// chooseProblemsScope shows the current file's problems, or the project's when project is
// true. The nodes the user closed and the selection are kept where they still show.
func (a *App) chooseProblemsScope(project bool) {
	v := &a.problems
	if v.project == project {
		return
	}
	v.project, v.reveal = project, true
	a.markProblemsChanged()
}

// problemsCurrentFile is the file of the selected editor tab, whose problems the File tab
// shows, and empty when no file is open.
func (a *App) problemsCurrentFile() string {
	if d := a.selectedEditorDocument(); d != nil {
		return d.path
	}
	return ""
}

// markProblemsChanged records that the published diagnostics, or the options or nodes the
// tree is asked with, changed and asks for a repaint. The next Problems frame starts a query
// for the new state.
func (a *App) markProblemsChanged() {
	a.problems.generation++
	a.invalidator.Invalidate()
}

// requestProblemsQuery starts a background query when the cached answer is older than the
// published diagnostics and the tree's state, or was asked for another current file. At most
// one query runs at a time; a change that arrives meanwhile raises generation, and the next
// frame asks again.
func (a *App) requestProblemsQuery(p *project) {
	v := &a.problems
	if !a.chrome.isOpen(catalogIndex[itemProblems]) {
		// The frame may still be declaring a panel the same click just closed;
		// asking now would refill the cache that closing released.
		return
	}
	file := a.problemsCurrentFile()
	if v.querying || (v.loaded && v.queried == v.generation && v.file == file) {
		return
	}
	sets := a.pluginDiagnosticSets()
	generation := v.generation
	tree := core.ProblemsQuery{GroupBy: v.grouping(), Selected: v.selected}
	for key := range v.collapsed {
		tree.Collapsed = append(tree.Collapsed, key)
	}
	slices.Sort(tree.Collapsed)
	severities := v.severityFilter()
	projectScope := v.project
	v.querying, v.asked = true, v.selected
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		diagnostics := make([]core.ProblemsDiagnostic, 0, 64)
		for _, set := range sets {
			for _, record := range set.All() {
				diagnostics = append(diagnostics, core.ProblemsDiagnostic{
					FileKey:     record.FileKey,
					DisplayPath: record.DisplayPath,
					Line:        record.Line,
					Column:      record.Column,
					Severity:    int(record.Severity),
					Message:     record.Message,
					Source:      record.Source,
					Code:        record.Code,
				})
			}
		}
		answer := problemsAnswer{generation: generation, file: file, diagnostics: diagnostics}
		// The project's diagnostics under the severity options give both tabs their counts;
		// on the Project tab the same answer is the tree. On the File tab the tree is asked
		// for once more, narrowed to the current file, and there is none while no file is open.
		whole := core.ProblemsQuery{Diagnostics: diagnostics, GroupBy: core.ProblemsGroupByNone, Filter: problemsFilter(severities, "")}
		if projectScope {
			whole.GroupBy, whole.Collapsed, whole.Selected = tree.GroupBy, tree.Collapsed, tree.Selected
		}
		result, err := a.kernel.QueryProblems(ctx, whole)
		answer.err = err
		if err == nil {
			answer.projectCount = problemsTotal(result.VisibleCounts)
			if i := slices.IndexFunc(result.Files, func(f core.ProblemsFile) bool { return f.FileKey == file }); file != "" && i >= 0 {
				answer.fileCount = result.Files[i].Count
			}
			switch {
			case projectScope:
				answer.result = result
			case file != "":
				tree.Diagnostics, tree.Filter = diagnostics, problemsFilter(severities, file)
				answer.result, answer.err = a.kernel.QueryProblems(ctx, tree)
			}
		}
		return func(a *App) { a.applyProblemsQuery(p, answer) }
	})
}

// problemsAnswer is one background query's answer: the tree for the chosen tab and the counts
// of both, computed from diagnostics at generation for the current file.
type problemsAnswer struct {
	generation              uint64
	file                    string
	diagnostics             []core.ProblemsDiagnostic
	result                  core.ProblemsResult
	fileCount, projectCount int
	err                     error
}

// problemsFilter is Core's filter for severities, nil for all, and file, empty for the whole
// project; nil when it keeps everything.
func problemsFilter(severities []int, file string) *core.ProblemsFilter {
	if severities == nil && file == "" {
		return nil
	}
	return &core.ProblemsFilter{Severities: severities, FileKey: file}
}

// problemsTotal is how many diagnostics counts holds over every severity.
func problemsTotal(counts core.ProblemsSeverityCounts) int {
	return counts.Error + counts.Warning + counts.Information + counts.Hint + counts.Unknown
}

// applyProblemsQuery takes one answer back on the window thread. An answer for a superseded
// generation is dropped, and a new frame asks for the newer state.
func (a *App) applyProblemsQuery(p *project, answer problemsAnswer) {
	v := &a.problems
	if a.project != p || !a.chrome.isOpen(catalogIndex[itemProblems]) {
		return
	}
	v.querying = false
	if answer.generation != v.generation {
		return
	}
	v.loaded = true
	v.queried = answer.generation
	v.file = answer.file
	if answer.err != nil {
		a.operationFailed("plugin_problems_query", answer.err)
		v.failure = answer.err
		v.diagnostics, v.result, v.selected, v.selectedRow, v.fileCount, v.projectCount = nil, core.ProblemsResult{}, "", -1, 0, 0
		a.invalidator.Invalidate()
		return
	}
	v.failure = nil
	v.diagnostics, v.result = answer.diagnostics, answer.result
	v.fileCount, v.projectCount = answer.fileCount, answer.projectCount
	// A row the user selected while the query was in flight stays selected where it still
	// shows; otherwise the selection is the one Core kept or moved.
	if v.selected == v.asked || !v.selectRow(v.selected) {
		v.selected, v.selectedRow = answer.result.Selected, -1
		if answer.result.SelectedRow != nil {
			v.selectedRow = *answer.result.SelectedRow
		}
	}
	a.invalidator.Invalidate()
}
