package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The Problems tree's preview is the shared read-only source view (sourcePreview): it shows the
// file of the selected row's diagnostic and reveals its line, never takes the keyboard focus of
// the window or writes the file, and shows an open document's text, unsaved edits included.

// selectedProblemLocation is the file and zero-based line the selected row shows: its
// diagnostic's, or a node's first diagnostic's; false when nothing with a file is selected.
func (v *problemsView) selectedProblemLocation() (string, int, bool) {
	item, ok := v.shown(v.selectedRow)
	if !ok || item.FileKey == "" {
		return "", 0, false
	}
	return item.FileKey, item.Line, true
}

// syncProblemsPreview follows the selection while the preview is on. A new file starts a load; the
// same file only moves the reveal. With nothing selected the last preview stays.
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

// problemsPreviewPane declares the preview beside the tree, or the reason there is none.
func (a *App) problemsPreviewPane(c ui.C) {
	a.sourcePreviewPane(c, &a.problems.preview, "problemsPreview", i18n.Shared(a.language(), "desktop.problems.previewEmpty"))
}
