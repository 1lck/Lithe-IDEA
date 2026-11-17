package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Problems tree's preview is the shared source view (sourcePreview), editable: it shows the
// document of the selected row's diagnostic file, reveals its line and colors that line by the
// diagnostic's severity. The user fixes the problem there as in the editor; an edit reaches the
// file's tab at once and the other way round, and the language features work at its caret.

// problemsLineTint is how much of a severity's color the preview lays under its diagnostic's
// line: enough to tell an error from a warning at a glance, little enough to keep the code
// readable in both themes.
const problemsLineTint = 0.22

// selectedProblem is the diagnostic the selected row shows: its own, or a node's first one;
// false when nothing with a file is selected.
func (v *problemsView) selectedProblem() (core.ProblemsDiagnostic, bool) {
	item, ok := v.shown(v.selectedRow)
	if !ok || item.FileKey == "" {
		return core.ProblemsDiagnostic{}, false
	}
	return item, true
}

// problemLineColor is the tint the preview gives the line of a diagnostic of severity: the
// severity's mark color, red for errors, yellow for warnings and blue for the rest.
func (a *App) problemLineColor(severity int) gfx.Color {
	_, color := a.problemSeverityMark(severity)
	color.Alpha *= problemsLineTint
	return color
}

// syncProblemsPreview follows the selection while the preview is on. A new file starts a load; the
// same file only moves the reveal and the line's color. With nothing selected the last preview
// stays. While the preview has the keyboard (focused) the user works in it: an edit that moves or
// fixes the selected diagnostic changes only the line's color, not the caret or the file shown.
func (a *App) syncProblemsPreview(p *project, focused gfx.ID) {
	v := &a.problems
	if !v.show {
		return
	}
	item, ok := v.selectedProblem()
	if !ok {
		return
	}
	sp := &v.preview
	if sp.view != nil && sp.view.Owns(focused) {
		if item.FileKey == sp.path {
			sp.markLine(item.Line+1, a.problemLineColor(item.Severity))
		} else {
			sp.markLine(0, gfx.Color{})
		}
		return
	}
	a.showSourcePreview(p, sp, item.FileKey, item.Line+1, func(a *App) bool { return a.problems.show })
	sp.markLine(item.Line+1, a.problemLineColor(item.Severity))
}

// problemsPreviewPane declares the preview beside the tree, or the reason there is none.
func (a *App) problemsPreviewPane(c ui.C) {
	a.sourcePreviewPane(c, &a.problems.preview, "problemsPreview", i18n.Shared(a.language(), "desktop.problems.previewEmpty"))
}
