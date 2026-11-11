package workbench

import (
	"context"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// problemsView is the Problems tool window's cached Core answer.
//
// The list is asked for in the background, because Core filters and sorts every
// submitted diagnostic and the window thread must not do that work. generation
// rises on every change to the published diagnostics, so an answer computed from
// an older set is dropped instead of replacing the current list.
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
	// starts holds the flat row index of each group. Group i spans starts[i] to
	// starts[i]+1+len(indices).
	starts []int
	rows   int
	// failure is a query Core refused, shown in place of the list. It is cleared
	// by the next successful answer or by a project change.
	failure error
	// show says the Show Editor Preview option is on: a read-only source view beside the list
	// shows the selected diagnostic's line. preview is that view.
	show    bool
	preview problemsPreview
	// split is the width of the list beside the preview; the user drags it.
	split ui.SplitterState
	// hideErrors, hideWarnings and hideInfo narrow the severities shown; a query sends them
	// as Core's severity filter. groupBy is Core's grouping: file, severity or none.
	hideErrors, hideWarnings, hideInfo bool
	groupBy                            string
	// list is the scrolling list of the rows, kept with the answer so a project switch
	// starts it at the top.
	list ui.ListState
}

// reset forgets the answer of the previous project. The view options are preferences, so they
// survive the project change; the preview itself is released.
func (v *problemsView) reset() {
	options := problemsView{show: v.show, split: v.split, hideErrors: v.hideErrors, hideWarnings: v.hideWarnings,
		hideInfo: v.hideInfo, groupBy: v.groupBy}
	v.preview.close()
	*v = options
}

// problemsSeverityFilter is the severity filter Core receives: nil keeps every severity, which is
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

// rowAt locates one flat row: a group header when header is true, otherwise the
// diagnostic at indices[index] of the group.
func (v *problemsView) rowAt(row int) (group, index int, header bool) {
	if row < 0 || row >= v.rows || len(v.starts) == 0 {
		return 0, 0, false
	}
	group = sort.Search(len(v.starts), func(i int) bool { return v.starts[i] > row }) - 1
	if group < 0 {
		return 0, 0, false
	}
	offset := row - v.starts[group]
	if offset == 0 {
		return group, 0, true
	}
	return group, offset - 1, false
}

// markProblemsChanged records that the published diagnostics changed and asks for
// a repaint. The next Problems frame starts a query for the new set.
func (a *App) markProblemsChanged() {
	a.problems.generation++
	a.invalidator.Invalidate()
}

// requestProblemsQuery starts a background query when the cached answer is older
// than the published diagnostics. At most one query runs at a time; a change
// that arrives meanwhile raises generation, and the next frame asks again.
func (a *App) requestProblemsQuery(p *project) {
	v := &a.problems
	if !a.chrome.isOpen(catalogIndex[itemProblems]) {
		// The frame may still be declaring a panel the same click just closed;
		// asking now would refill the cache that closing released.
		return
	}
	if v.querying || (v.loaded && v.queried == v.generation) {
		return
	}
	sets := a.pluginDiagnosticSets()
	generation := v.generation
	groupBy := v.groupBy
	if groupBy == "" {
		groupBy = core.ProblemsGroupByFile
	}
	severityFilter := v.severityFilter()
	v.querying = true
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
		query := core.ProblemsQuery{Diagnostics: diagnostics, GroupBy: groupBy}
		if severities := severityFilter; severities != nil {
			query.Filter = &core.ProblemsFilter{Severities: severities}
		}
		result, err := a.kernel.QueryProblems(ctx, query)
		return func(a *App) { a.applyProblemsQuery(p, generation, diagnostics, result, err) }
	})
}

// applyProblemsQuery takes one answer back on the window thread. An answer for
// a superseded generation is dropped, and a new frame asks for the newer set.
func (a *App) applyProblemsQuery(p *project, generation uint64, diagnostics []core.ProblemsDiagnostic, result core.ProblemsResult, err error) {
	v := &a.problems
	if a.project != p || !a.chrome.isOpen(catalogIndex[itemProblems]) {
		return
	}
	v.querying = false
	if generation != v.generation {
		return
	}
	v.loaded = true
	v.queried = generation
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_problems_query", err))
		v.failure = err
		v.diagnostics, v.result, v.starts, v.rows = nil, core.ProblemsResult{}, nil, 0
		a.invalidator.Invalidate()
		return
	}
	v.failure = nil
	v.diagnostics = diagnostics
	v.result = result
	v.starts = v.starts[:0]
	v.rows = 0
	for _, group := range result.Groups {
		v.starts = append(v.starts, v.rows)
		v.rows += 1 + len(group.Indices)
	}
	a.invalidator.Invalidate()
}
