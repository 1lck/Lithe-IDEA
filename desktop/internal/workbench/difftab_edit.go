package workbench

import (
	"path/filepath"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/gfx"
)

// This file makes the right side of a Diff tab editable when it is the working copy of the file
// (matrix id git-diff-review). The document of the file owns the text, its undo, its save and its
// autosave: an edit on the side goes into the document, and the document's edits come back to the
// side. The side only shows what the document holds. A file that no document has open keeps its
// side read only, since a document is opened with a tab, and the side does not open one.

// diffTabPath is the absolute path of the file tab t shows.
func diffTabPath(t *diffTab) string {
	return filepath.Join(t.root, filepath.FromSlash(t.change.Path))
}

// diffWritable says the right side of tab t is the working copy of its file: the change of a
// checkout's file against the file on disk, not a commit, a stash, the index or a plan.
func diffWritable(t *diffTab) bool {
	return t.file != nil && t.saved == nil && t.commit == "" && !t.staged && t.plan == nil &&
		(t.compare == nil || t.compare.target == nil)
}

// diffDocument is the open document the right side of tab t mirrors, nil when the side is not
// editable: the tab is not a working copy, or no document of the file is open in the project.
func (a *App) diffDocument(t *diffTab) *document {
	p := a.project
	if p == nil || !diffWritable(t) {
		return nil
	}
	d := p.docs.byPath(diffTabPath(t))
	if d == nil || d.virtual {
		return nil
	}
	return d
}

// diffEdited mirrors an edit the user made on the right side of tab t into its document. The
// document records it as one undo step of its own.
func (a *App) diffEdited(t *diffTab, edit editorview.Edit) {
	p := a.project
	if p == nil || p.diffs.mirroring > 0 {
		return
	}
	d := a.diffDocument(t)
	if d == nil {
		return
	}
	if !a.editDocumentFrom(p, d, t.after.view, edit) {
		// The document and the side disagree on the text; the side shows the document again.
		a.rebuildDiff(t)
	}
}

// editDocumentFrom applies an edit the user made in from, a second view of document d (a Diff
// tab's side or the Problems preview), to the document as one undo step of its own. The
// document then mirrors it into its other second views, but not back into from. It reports
// false when the two disagree on the text, and the caller shows the document again.
func (a *App) editDocumentFrom(p *project, d *document, from *editorview.View, edit editorview.Edit) bool {
	origin := p.diffs.origin
	p.diffs.origin = from
	ok := d.view.ApplyEdit(edit, true)
	p.diffs.origin = origin
	return ok
}

// mirrorDocumentEdit mirrors an edit of document d into its second views: the right side of every
// Diff tab that shows its file and the editable preview that shows it, except the view the edit
// came from. The document's own undo already holds the edit, so a second view does not record it,
// and the report each view makes of the mirrored edit is not mirrored back.
func (a *App) mirrorDocumentEdit(p *project, d *document, edit editorview.Edit) {
	for _, t := range p.diffs.list {
		if t.after == nil || t.after.view == p.diffs.origin || !diffWritable(t) || diffTabPath(t) != d.path {
			continue
		}
		p.diffs.mirroring++
		ok := t.after.view.ApplyEdit(edit, false)
		p.diffs.mirroring--
		if !ok {
			a.rebuildDiff(t)
		}
	}
	a.mirrorPreviewEdit(p, d, edit)
}

// diffUndoChord takes the undo and redo chords of an editable side for its document, which owns
// the undo of the text both show, and reports whether event was one of them. The side's own undo
// is never used, so the two cannot disagree.
func (a *App) diffUndoChord(t *diffTab, event gfx.KeyEvent) bool {
	if event.Release || event.Key != gfx.KeyUnknown {
		return false
	}
	return documentUndoChord(a.diffDocument(t), event)
}

// documentUndoChord takes back or does again in document d the edit an undo or redo chord pressed
// in a second view of it asks for, as the document holds the undo of every edit made in its views:
// Command+Z and Shift+Command+Z on macOS, Control+Z, Shift+Control+Z and Control+Y elsewhere. It
// reports false for any other key.
func documentUndoChord(d *document, event gfx.KeyEvent) bool {
	if d == nil || event.Release || event.Key != gfx.KeyUnknown || event.Modifiers&^gfx.ModifierShift != primaryModifier() {
		return false
	}
	shift := event.Modifiers&gfx.ModifierShift != 0
	switch {
	case strings.EqualFold(event.Text, "z") && shift:
		d.view.Redo()
	case strings.EqualFold(event.Text, "z"):
		d.view.Undo()
	case runtime.GOOS != "darwin" && strings.EqualFold(event.Text, "y") && !shift:
		d.view.Redo()
	default:
		return false
	}
	return true
}

// reloadDiffsOfPath reads again every Diff tab of the file at path, after the document of it was
// saved, so the change the tabs show is the one on disk. The console records these reads only
// when it shows the diff refreshes after saving.
func (a *App) reloadDiffsOfPath(p *project, path string) {
	for _, t := range p.diffs.list {
		if t.saved == nil && diffTabPath(t) == path {
			a.loadDiffAs(p, t, core.GitQueryDiffRefresh)
		}
	}
}
