package workbench

import (
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// This file moves and copies project items from the project tree (matrix id workspace-files):
// dragging a row onto a folder moves the item into it (Viva's drag source and drop target), and
// the context menu cuts, copies and pastes items through the tree's own clipboard. A moved item
// keeps its open tabs, and a name that is taken gets the copy suffix when it is pasted or copied.

// treeRowRef is what a tree row's hit identity names: the project-relative path and whether it is
// a folder.
type treeRowRef struct {
	path string
	dir  bool
}

// treeClipboard holds the items a cut or copy took; cut says a paste moves them.
type treeClipboard struct {
	paths []string
	cut   bool
}

// rememberRow records the node a row's hit identity names for the rest of this paint.
func (t *fileTree) rememberRow(id gfx.ID, n *treeNode) {
	if t.rowRefs == nil {
		t.rowRefs = map[gfx.ID]treeRowRef{}
	}
	t.rowRefs[id] = treeRowRef{path: n.path, dir: n.dir}
}

// treeDragAccept says whether the row of source can be dropped on the row of target: a folder
// other than the source itself, its own parent or one of its descendants.
func (a *App) treeDragAccept(source, target gfx.ID) bool {
	p := a.project
	if p == nil {
		return false
	}
	src, ok := p.tree.rowRefs[source]
	dst, ok2 := p.tree.rowRefs[target]
	if !ok || !ok2 || !dst.dir {
		return false
	}
	if dst.path == src.path || path.Dir(src.path) == dst.path || strings.HasPrefix(dst.path, src.path+"/") {
		return false
	}
	return true
}

// treeDragDrop moves the dragged item into the folder it was dropped on.
func (a *App) treeDragDrop(source, target gfx.ID) {
	p := a.project
	if p == nil {
		return
	}
	src, ok := p.tree.rowRefs[source]
	dst, ok2 := p.tree.rowRefs[target]
	if !ok || !ok2 || !dst.dir {
		return
	}
	a.performed("workspace.file.dragMove", surfaceMenu)
	a.moveTreeItem(p, src.path, dst.path)
}

// moveTreeItem moves the item at rel into the folder dir (project-relative). The open files below
// it are saved first and follow the new path; a name the folder already has is refused.
func (a *App) moveTreeItem(p *project, rel, dir string) {
	language := a.language()
	oldFull := filepath.Join(p.root, filepath.FromSlash(rel))
	newFull := filepath.Join(p.root, filepath.FromSlash(dir), filepath.Base(filepath.FromSlash(rel)))
	if _, err := os.Lstat(newFull); err == nil {
		a.notify(i18n.Shared(language, "desktop.files.nameExists"))
		return
	}
	docs := a.documentsUnder(p, oldFull)
	a.saveDocumentsThen(p, docs, func() {
		if err := os.Rename(oldFull, newFull); err != nil {
			a.notify(i18n.SharedFormat(language, "desktop.files.moveFailed", map[string]string{"reason": treeErrorReason(err)}))
			return
		}
		a.moveOpenDocuments(p, oldFull, newFull)
		a.listTree(p, path.Dir(rel))
		a.listTree(p, dir)
		a.loadGit(p)
	})
}

// treeCut and treeCopy put the item of n on the tree clipboard.
func (a *App) treeCut(p *project, n *treeNode) {
	p.tree.clip = treeClipboard{paths: []string{n.path}, cut: true}
	a.performed("workspace.file.cut", surfaceMenu)
}

func (a *App) treeCopy(p *project, n *treeNode) {
	p.tree.clip = treeClipboard{paths: []string{n.path}}
	a.performed("workspace.file.copy", surfaceMenu)
}

// treeClipboardHas reports that there is something to paste.
func (a *App) treeClipboardHas(p *project) bool {
	return len(p.tree.clip.paths) > 0
}

// treePaste puts the clipboard items into the folder n (or the folder of n when it is a file).
// A cut item moves; a copied item is copied under a free name in the folder.
func (a *App) treePaste(p *project, n *treeNode) {
	language := a.language()
	dir := n.path
	if !n.dir {
		dir = path.Dir(n.path)
	}
	clip := p.tree.clip
	var failed error
	for _, rel := range clip.paths {
		src := filepath.Join(p.root, filepath.FromSlash(rel))
		name := filepath.Base(filepath.FromSlash(rel))
		dst := filepath.Join(p.root, filepath.FromSlash(dir), name)
		if clip.cut {
			if path.Dir(rel) == dir {
				continue
			}
			if _, err := os.Lstat(dst); err == nil {
				dst = freeCopyName(dst)
			}
			if err := os.Rename(src, dst); err != nil {
				failed = err
			}
			continue
		}
		dst = freeCopyName(dst)
		if err := copyTreeEntry(src, dst); err != nil {
			failed = err
		}
	}
	if clip.cut {
		p.tree.clip = treeClipboard{}
	}
	if failed != nil {
		a.notify(i18n.SharedFormat(language, "desktop.files.pasteFailed", map[string]string{"reason": treeErrorReason(failed)}))
	}
	a.performed("workspace.file.paste", surfaceMenu)
	a.listTree(p, dir)
	for _, rel := range clip.paths {
		a.listTree(p, path.Dir(rel))
	}
	a.loadGit(p)
}

// freeCopyName is dst when nothing is there, else dst with the copy suffix that keeps its
// extension, "name copy.ext", "name copy 2.ext" and so on, the first free one.
func freeCopyName(dst string) string {
	if _, err := os.Lstat(dst); err != nil {
		return dst
	}
	dir, base := filepath.Split(dst)
	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	for i := 1; ; i++ {
		name := stem + " copy" + ext
		if i > 1 {
			name = stem + " copy " + strconv.Itoa(i) + ext
		}
		candidate := filepath.Join(dir, name)
		if _, err := os.Lstat(candidate); err != nil {
			return candidate
		}
	}
}
