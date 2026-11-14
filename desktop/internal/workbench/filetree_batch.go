package workbench

import (
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the batch side of the project tree (matrix id workspace-tree-batch-files): a
// Ctrl or Cmd click adds a row to the marked set, a Shift click marks the rows between the anchor
// and the clicked row, and the context menu of a marked row applies to every marked row: delete
// them, or move the changed files among them to a change list. A folder marked with a file inside
// it stands for its own contents, so the file is left out of the batch. Single-row behaviour is in
// filetree_menu.go and filetree_actions.go.
//
// Delete is one menu item for one item or many, as in the IDE: it opens a dialog that moves the
// items to the system trash, which is the default and can be undone, or deletes them for good.

// treeRemoval is the Delete dialog: open while the user chooses, paths the project-relative
// paths it removes. The project tree and the Git review both open it.
type treeRemoval struct {
	open  bool
	paths []string
}

// treeMoveToTrash moves a file or folder to the system trash; tests replace it, since the trash
// of the machine running them is not theirs to fill.
var treeMoveToTrash = moveToTrash

// treeModifiedClick applies a Ctrl, Cmd or Shift click on the row of n to the marked set, as
// Core says (filetree_rows.go).
func (a *App) treeModifiedClick(p *project, n *treeNode, mods gfx.Modifiers) {
	if n == nil {
		return
	}
	action := core.ExtendRow(n.path)
	if mods&ui.Primary != 0 {
		action = core.ToggleRow(n.path)
	}
	a.reduceTreeSelection(p, action)
}

// batchTargets are the nodes a batch operation acts on: the marked rows, without those inside
// another marked folder, in path order, as Core said. Without marks it is the selected row
// alone.
func (t *fileTree) batchTargets() []*treeNode {
	var nodes []*treeNode
	for _, at := range t.targets {
		if n := t.byPath[at]; n != nil && n != t.root {
			nodes = append(nodes, n)
		}
	}
	if len(nodes) == 0 && t.selected != nil && t.selected != t.root {
		nodes = []*treeNode{t.selected}
	}
	return nodes
}

// treeBatchMenu declares the batch items of the context menu of a marked row: how many rows the
// batch holds, then the operations that apply to all of them.
func (a *App) treeBatchMenu(c ui.C, p *project, menu *ui.MenuItems, nodes []*treeNode) {
	lang := a.language()
	count := strconv.Itoa(len(nodes))
	if menu.Item(i18n.SharedFormat(lang, "desktop.files.batchDelete", map[string]string{"count": count})).Clicked() {
		paths := make([]string, 0, len(nodes))
		for _, n := range nodes {
			paths = append(paths, n.path)
		}
		c.After(func() { a.openTreeRemoval(p, paths) })
	}
	changes := changesUnderNodes(p, nodes)
	if len(changes) > 0 {
		menu.Sub(i18n.Shared(lang, "native.moveToChangeList"), func(sub *ui.MenuItems) {
			for _, list := range p.lists.state.Lists {
				id := list.ID
				if sub.Item(a.changeListName(list)).Clicked() {
					c.After(func() { a.moveToChangeList(p, changes, id) })
				}
			}
		})
	}
}

// changesUnderNodes are the changes of the project's repository at or below the nodes.
func changesUnderNodes(p *project, nodes []*treeNode) []core.GitChange {
	var out []core.GitChange
	for _, change := range p.git.status.Changes {
		rel := strings.TrimSuffix(change.Path, "/")
		for _, n := range nodes {
			if rel == n.path || strings.HasPrefix(rel, n.path+"/") {
				out = append(out, change)
				break
			}
		}
	}
	return out
}

// removalPaths are the full paths of the project-relative paths and the open documents at or
// below any of them.
func (a *App) removalPaths(p *project, paths []string) (full []string, docs []*document) {
	seen := map[*document]bool{}
	for _, at := range paths {
		f := filepath.Join(p.root, filepath.FromSlash(at))
		full = append(full, f)
		for _, d := range a.documentsUnder(p, f) {
			if !seen[d] {
				seen[d] = true
				docs = append(docs, d)
			}
		}
	}
	return full, docs
}

// openTreeRemoval opens the Delete dialog for the project-relative paths. The project root is
// never removed, so a path that names it is left out.
func (a *App) openTreeRemoval(p *project, paths []string) {
	var kept []string
	for _, at := range paths {
		if at != "" && at != "." && !slices.Contains(kept, at) {
			kept = append(kept, at)
		}
	}
	if len(kept) == 0 {
		return
	}
	p.tree.removal = treeRemoval{open: true, paths: kept}
}

// removeTreeItems moves the project-relative paths to the system trash or, when permanent,
// deletes them from disk. The open files at or below them are saved and their tabs closed first,
// so neither loses an edit.
func (a *App) removeTreeItems(p *project, paths []string, permanent bool) {
	full, docs := a.removalPaths(p, paths)
	parents := treeParents(paths)
	remove, performed, failure := treeMoveToTrash, "workspace.file.trash", trashFailedText
	if permanent {
		remove, performed, failure = os.RemoveAll, "workspace.file.delete", deleteFailedText
	}
	if len(paths) > 1 {
		performed += "Batch"
	}
	a.saveDocumentsThen(p, docs, func() {
		a.closeOpenDocuments(p, docs)
		failed := 0
		var reason error
		for _, f := range full {
			if err := remove(f); err != nil {
				failed++
				reason = err
			}
		}
		a.finishRemoval(p, parents, performed, failed, reason, failure)
	})
}

// closeOpenDocuments closes the tabs of docs that are still open in the project.
func (a *App) closeOpenDocuments(p *project, docs []*document) {
	for _, d := range docs {
		if a.project == p && p.docs.find(d.id) == d {
			a.removeDocument(p, d)
		}
	}
}

// treeParents are the directories the project-relative paths sit in, each once, as the tree
// lists them again.
func treeParents(paths []string) []string {
	var out []string
	for _, at := range paths {
		dir := path.Dir(at)
		if !slices.Contains(out, dir) {
			out = append(out, dir)
		}
	}
	return out
}

// finishRemoval clears the marks, which may name removed rows, lists the directories again and
// reads the status. A failure is reported once, with the last reason, since the rest of a batch
// still ran; failure words it.
func (a *App) finishRemoval(p *project, parents []string, performed string, failed int, reason error, failure func(i18n.Language, string) string) {
	p.tree.marked, p.tree.anchor, p.tree.targets = nil, "", nil
	if failed > 0 && reason != nil {
		a.notifyError(failure(a.language(), treeErrorReason(reason)))
	}
	a.performed(performed, surfaceMenu)
	for _, dir := range parents {
		a.listTree(p, dir)
	}
	a.loadGit(p)
}

// treeRemovalDialog declares the open Delete dialog: what it removes, Cancel, Delete Permanently,
// and Move to Trash, the default, since the trash can give the items back.
func (a *App) treeRemovalDialog(c ui.C, p *project) {
	r := &p.tree.removal
	if !r.open || len(r.paths) == 0 {
		return
	}
	lang := a.language()
	open := true
	title := i18n.Shared(lang, "desktop.files.deleteTitle")
	description := i18n.SharedFormat(lang, "desktop.files.deleteMessage", map[string]string{"name": path.Base(r.paths[0])})
	if len(r.paths) > 1 {
		title = i18n.Shared(lang, "desktop.files.batchDeleteTitle")
		description = i18n.SharedFormat(lang, "desktop.files.batchDeletePrompt", map[string]string{"count": strconv.Itoa(len(r.paths))})
	}
	run := func(permanent bool) {
		paths := r.paths
		c.After(func() {
			p.tree.removal = treeRemoval{}
			a.removeTreeItems(p, paths, permanent)
		})
		open = false
	}
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Description: description, Width: 440}, nil, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.files.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.files.deletePermanently")).Destructive().Clicked() {
			run(true)
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.files.moveToTrash")).Clicked() {
			run(false)
		}
	})
	if closed || !open {
		c.After(func() { p.tree.removal = treeRemoval{} })
	}
}

// trashFailedText is the message of a trash an item of failed for reason.
func trashFailedText(lang i18n.Language, reason string) string {
	return i18n.SharedFormat(lang, "desktop.files.trashFailed", map[string]string{"reason": reason})
}

// deleteFailedText is the message of a delete an item of failed for reason.
func deleteFailedText(lang i18n.Language, reason string) string {
	return i18n.SharedFormat(lang, "desktop.files.deleteFailed", map[string]string{"reason": reason})
}
