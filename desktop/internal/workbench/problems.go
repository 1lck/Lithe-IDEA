package workbench

import (
	"context"
	"sort"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	// problemsListID is the Problems tool window's scrolling list.
	problemsListID = tree.ID(shellPage, "problems-list")
	// problemsRows identifies the diagnostic rows of the list:
	// problemsRows.At(flat) is a row in the flattened group list.
	problemsRows = tree.Sub(shellPage, tree.Name("problems-rows"))
)

const (
	// problemsRowHeight is the height of a file header and of a diagnostic row.
	// Both use the same height so the visible window can be computed from the
	// scroll offset without measuring each row, which is what keeps a long list
	// to the rows that are on screen.
	problemsRowHeight = 22
	// problemsOverscan is how many rows beyond the viewport are declared, so a
	// small scroll does not show an empty strip before the next frame.
	problemsOverscan = 3
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
}

// reset drops the cached answer, for a project switch or close.
func (v *problemsView) reset() { *v = problemsView{} }

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

// drawProblemsPanel declares the Problems tool window of an open project.
func (a *App) drawProblemsPanel(f *ui.Frame, p *project) {
	a.requestProblemsQuery(p)
	v := &a.problems
	switch {
	case v.failure != nil:
		f.Row().Fill().Center().PadX(shellContentPad).Children(func() {
			f.Paragraph(a.text.Errors.Core(v.failure.Error()), 3).Grow(1).TextCenter().Color(a.theme.Danger)
		})
		return
	case v.rows == 0:
		f.Row().Fill().Center().PadX(shellContentPad).Children(func() {
			message := i18n.SharedFormat(a.language(), "native.noProblemsIn", map[string]string{"arg1": p.name})
			f.Paragraph(message, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
		})
		return
	}

	scroll := a.view.ScrollState(problemsListID)
	height := scroll.Viewport
	if height <= 0 {
		height = 500
	}
	first := max(0, int(scroll.Offset/problemsRowHeight)-problemsOverscan)
	last := min(v.rows, int((scroll.Offset+height)/problemsRowHeight)+problemsOverscan)
	first = min(first, last)

	f.ScrollArea(problemsListID).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		// The spacers stand in for the rows outside the window, so the scrollbar's
		// range is the whole list while only the visible rows exist.
		if first > 0 {
			f.Row().Height(float32(first) * problemsRowHeight).Shrink(0)
		}
		for row := first; row < last; row++ {
			group, index, header := v.rowAt(row)
			if header {
				a.drawProblemsGroupHeader(f, v.result.Groups[group])
			} else {
				a.drawProblemsRow(f, p, v, row, v.result.Groups[group], index)
			}
		}
		if rest := v.rows - last; rest > 0 {
			f.Row().Height(float32(rest) * problemsRowHeight).Shrink(0)
		}
	})
}

// drawProblemsGroupHeader declares one file's heading. It is not clickable:
// opening a file happens on one of its diagnostics.
func (a *App) drawProblemsGroupHeader(f *ui.Frame, group core.ProblemsGroup) {
	f.Row().FillWidth().Height(problemsRowHeight).Shrink(0).PadX(10).Items(ui.Center).Gap(6).Children(func() {
		f.Text(group.DisplayPath).Grow(1).Shrink(1).FontSize(12.5).Bold().Color(a.colors.Text).Ellipsis()
		f.Text(a.text.Status.Problems(len(group.Indices))).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
	})
}

// drawProblemsRow declares one diagnostic of a group and opens its document at
// the reported position when clicked.
func (a *App) drawProblemsRow(f *ui.Frame, p *project, v *problemsView, row int, group core.ProblemsGroup, index int) {
	if index < 0 || index >= len(group.Indices) {
		return
	}
	diagnostic := group.Indices[index]
	if diagnostic < 0 || diagnostic >= len(v.diagnostics) {
		return
	}
	item := v.diagnostics[diagnostic]
	icon, tint := a.problemSeverityMark(item.Severity)
	position := strconv.Itoa(item.Line+1) + ":" + strconv.Itoa(item.Column+1)
	hit := gfx.HitOptions{
		Role:   gfx.RoleButton,
		Cursor: gfx.PointerCursorHand,
		Hint:   i18n.Shared(a.language(), "diagnostics.goToProblem"),
		Value:  position,
	}
	rowBox := f.Row().FillWidth().Height(problemsRowHeight).Shrink(0).PadX(10).Items(ui.Center).Gap(6).
		HitWith(problemsRows.At(row), item.Message, hit).Hover(ui.Look{}.Background(a.colors.Hover))
	rowBox.Children(func() {
		f.Icon(icon).Size(14, 14).Shrink(0).Color(tint)
		f.Text(item.Message).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
		if item.Source != "" {
			f.Text(item.Source).Shrink(1).FontSize(11.5).Color(a.colors.Subtle).Ellipsis().MaxWidth(80)
		}
		f.Text(position).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
	})
	if rowBox.Clicked() && item.FileKey != "" {
		a.performed("workspace.problems.open", surfaceButton)
		a.openFileAtPosition(p, item.FileKey, item.Line, item.Column)
	}
}

// problemSeverityMark is the icon and tint of an LSP severity. Unknown
// severities read as information, as Core ranks them.
func (a *App) problemSeverityMark(severity int) (gfx.Icon, gfx.Color) {
	switch severity {
	case 1:
		return icons.CircleX, a.theme.Danger
	case 2:
		return icons.CircleAlert, a.colors.Warning
	default:
		return icons.Info, a.colors.Subtle
	}
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
		result, err := a.kernel.QueryProblems(ctx, core.ProblemsQuery{Diagnostics: diagnostics})
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
