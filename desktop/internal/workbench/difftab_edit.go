package workbench

import (
	"path/filepath"
	"runtime"

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
	return t.file != nil && t.stash == nil && t.commit == "" && !t.staged && t.plan == nil &&
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
	p.diffs.mirroring++
	ok := d.view.ApplyEdit(edit, true)
	p.diffs.mirroring--
	if !ok {
		// The document and the side disagree on the text; the side shows the document again.
		a.rebuildDiff(t)
	}
}

// mirrorDocumentEdit mirrors an edit of document d into the right side of every Diff tab that
// shows its file. The document's own undo already holds the edit, so the side does not record it.
func (a *App) mirrorDocumentEdit(p *project, d *document, edit editorview.Edit) {
	if p.diffs.mirroring > 0 {
		return
	}
	for _, t := range p.diffs.list {
		if t.after == nil || !diffWritable(t) || diffTabPath(t) != d.path {
			continue
		}
		p.diffs.mirroring++
		ok := t.after.view.ApplyEdit(edit, false)
		p.diffs.mirroring--
		if !ok {
			a.rebuildDiff(t)
		}
	}
}

// diffUndoChord takes the undo and redo chords of an editable side for its document, which owns
// the undo of the text both show, and reports whether event was one of them. The side's own undo
// is never used, so the two cannot disagree.
func (a *App) diffUndoChord(t *diffTab, event gfx.KeyEvent) bool {
	if event.Release || event.Key != gfx.KeyUnknown {
		return false
	}
	d := a.diffDocument(t)
	if d == nil {
		return false
	}
	modifier := gfx.ModifierControl
	if runtime.GOOS == "darwin" {
		modifier = gfx.ModifierMeta
	}
	if event.Modifiers&^gfx.ModifierShift != modifier || event.Text != "z" && event.Text != "Z" {
		return false
	}
	if event.Modifiers&gfx.ModifierShift != 0 {
		d.view.Redo()
	} else {
		d.view.Undo()
	}
	return true
}

// reloadDiffsOfPath reads again every Diff tab of the file at path, after the document of it was
// saved, so the change the tabs show is the one on disk.
func (a *App) reloadDiffsOfPath(p *project, path string) {
	for _, t := range p.diffs.list {
		if t.stash == nil && diffTabPath(t) == path {
			a.loadDiff(p, t)
		}
	}
}
