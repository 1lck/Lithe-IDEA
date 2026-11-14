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
// and the clicked row, and the context menu of a marked row applies to every marked row: move to
// the trash, delete after a confirmation, or move the changed files among them to a change list.
// A folder marked with a file inside it stands for its own contents, so the file is left out of
// the batch. Single-row behaviour is in filetree_menu.go and filetree_actions.go.

// treeBatchDelete is the batch delete dialog: open while the user confirms, paths the batch holds.
type treeBatchDelete struct {
	open  bool
	paths []string
}

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
	if menu.Item(i18n.SharedFormat(lang, "desktop.files.batchTrash", map[string]string{"count": count})).Clicked() {
		c.After(func() { a.trashTreeItems(p, nodes) })
	}
	if menu.Item(i18n.SharedFormat(lang, "desktop.files.batchDelete", map[string]string{"count": count})).Destructive().Clicked() {
		paths := make([]string, 0, len(nodes))
		for _, n := range nodes {
			paths = append(paths, n.path)
		}
		c.After(func() { p.tree.batch = treeBatchDelete{open: true, paths: paths} })
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

// batchPaths are the full paths of nodes and the open documents below any of them.
func (a *App) batchPaths(p *project, nodes []*treeNode) (full []string, docs []*document) {
	seen := map[*document]bool{}
	for _, n := range nodes {
		f := filepath.Join(p.root, filepath.FromSlash(n.path))
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

// trashTreeItems moves every node to the system trash after the open files below them are saved
// and their tabs closed, as a single trash does.
func (a *App) trashTreeItems(p *project, nodes []*treeNode) {
	full, docs := a.batchPaths(p, nodes)
	parents := treeParents(nodes)
	a.saveDocumentsThen(p, docs, func() {
		a.closeOpenDocuments(p, docs)
		failed := 0
		var reason error
		for _, f := range full {
			if err := moveToTrash(f); err != nil {
				failed++
				reason = err
			}
		}
		a.finishBatch(p, parents, "workspace.file.trashBatch", failed, reason, trashFailedText)
	})
}

// deleteTreeItems removes every node after the open files below them are saved and closed.
func (a *App) deleteTreeItems(p *project, paths []string) {
	nodes := make([]*treeNode, 0, len(paths))
	for _, at := range paths {
		if n := p.tree.byPath[at]; n != nil {
			nodes = append(nodes, n)
		}
	}
	full, docs := a.batchPaths(p, nodes)
	parents := treeParents(nodes)
	a.saveDocumentsThen(p, docs, func() {
		a.closeOpenDocuments(p, docs)
		failed := 0
		var reason error
		for _, f := range full {
			if err := os.RemoveAll(f); err != nil {
				failed++
				reason = err
			}
		}
		a.finishBatch(p, parents, "workspace.file.deleteBatch", failed, reason, deleteFailedText)
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

// treeParents are the directories the nodes sit in, each once, as the tree lists them again.
func treeParents(nodes []*treeNode) []string {
	var out []string
	for _, n := range nodes {
		dir := path.Dir(n.path)
		if !slices.Contains(out, dir) {
			out = append(out, dir)
		}
	}
	return out
}

// finishBatch clears the marks, lists the directories again and reads the status. A failure is
// reported once, with the last reason, since the rest of the batch still ran; failure words it.
func (a *App) finishBatch(p *project, parents []string, performed string, failed int, reason error, failure func(i18n.Language, string) string) {
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

// treeBatchDialog declares the confirmation of a batch delete: how many items it removes, and
// the delete button that runs it.
func (a *App) treeBatchDialog(c ui.C, p *project) {
	b := &p.tree.batch
	if !b.open {
		return
	}
	lang := a.language()
	open := true
	description := i18n.SharedFormat(lang, "desktop.files.batchDeletePrompt", map[string]string{"count": strconv.Itoa(len(b.paths))})
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "desktop.files.batchDeleteTitle"), ui.ModalSpec{Description: description, Width: 420}, nil, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.files.batchDeleteConfirm")).Destructive().Clicked() {
			paths := b.paths
			c.After(func() {
				p.tree.batch = treeBatchDelete{}
				a.deleteTreeItems(p, paths)
			})
			open = false
		}
	})
	if closed || !open {
		c.After(func() { p.tree.batch = treeBatchDelete{} })
	}
}

// trashFailedText is the message of a batch trash an item of failed for reason.
func trashFailedText(lang i18n.Language, reason string) string {
	return i18n.SharedFormat(lang, "desktop.files.trashFailed", map[string]string{"reason": reason})
}

// deleteFailedText is the message of a batch delete an item of failed for reason.
func deleteFailedText(lang i18n.Language, reason string) string {
	return i18n.SharedFormat(lang, "desktop.files.deleteFailed", map[string]string{"reason": reason})
}
