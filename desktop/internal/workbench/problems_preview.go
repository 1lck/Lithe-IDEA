package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The Problems list's preview is the shared read-only source view (sourcePreview): it shows the
// file of the selected diagnostic and reveals its line, never takes the keyboard focus of the
// window or writes the file, and shows an open document's text, unsaved edits included.

// selectedProblemLocation is the file and zero-based line of the selected diagnostic, and false
// when no diagnostic row is selected.
func (v *problemsView) selectedProblemLocation() (string, int, bool) {
	row := v.list.Selected()
	if row < 0 {
		return "", 0, false
	}
	group, index, header := v.rowAt(row)
	if header {
		return "", 0, false
	}
	item, ok := v.diagnostic(group, index)
	if !ok || item.FileKey == "" {
		return "", 0, false
	}
	return item.FileKey, item.Line, true
}

// syncProblemsPreview follows the selection while the preview is on. A new file starts a load; the
// same file only moves the reveal. A selection that is not a diagnostic keeps the last preview.
func (a *App) syncProblemsPreview(p *project) {
	v := &a.problems
	if !v.show {
		return
	}
	path, line, ok := v.selectedProblemLocation()
	if !ok {
		return
	}
	a.showSourcePreview(p, &v.preview, path, line+1, func(a *App) bool { return a.problems.show })
}

// problemsPreviewPane declares the preview beside the list, or the reason there is none.
func (a *App) problemsPreviewPane(c ui.C) {
	a.sourcePreviewPane(c, &a.problems.preview, "problemsPreview", i18n.Shared(a.language(), "desktop.problems.previewEmpty"))
}
