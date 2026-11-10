package workbench

import (
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// The buttons the Project tool window's header shows after its name: one brings the file the
// editor shows into view in the tree, one reads the tree's folders from disk again, and two
// open and close every folder. Locating and Expand All need listings the kernel reads away
// from the window thread, so they go on, a step at a time, as those listings arrive.

// The header buttons of the Project tool window, in the order they are shown; treeActions.At
// of one is its identity.
const (
	treeActionLocate = iota
	treeActionRefresh
	treeActionExpand
	treeActionCollapse
)

// treeExpandAllLimit is the most folders one Expand All opens. Each folder it opens is one more
// listing and more rows on every frame, so in a project with more folders it opens the ones
// nearest the root and says the rest stayed closed.
const treeExpandAllLimit = 512

// drawProjectTreeActions declares the buttons of the Project tool window's header. They wait
// for the root's listing, but refresh also asks again for a root that could not be listed.
func (a *App) drawProjectTreeActions(f *ui.Frame, p *project) {
	t := &p.tree
	language := a.language()
	ready := t.root != nil && t.root.listed && t.failed == ""
	f.Row().Shrink(0).Items(ui.Center).Gap(2).Children(func() {
		_, located := activeTreePath(p)
		if a.toolIconButton(f, treeActions.At(treeActionLocate), i18n.Shared(language, "native.revealActiveFileInProjectTree"), icons.Locate, false, !ready || !located, nil) {
			a.performed("workspace.tree.revealActiveFile", surfaceButton)
			a.revealActiveFile(p)
		}
		refreshable := t.failed != "" || ready && !t.refreshing
		if a.toolIconButton(f, treeActions.At(treeActionRefresh), i18n.Shared(language, "ui.refresh"), icons.RefreshCw, false, !refreshable, nil) {
			a.performed("workspace.tree.refresh", surfaceButton)
			a.refreshProjectTree(p)
		}
		if a.toolIconButton(f, treeActions.At(treeActionExpand), i18n.Shared(language, "outline.expandAll"), icons.ChevronsUpDown, false, !ready || t.expandingAll, nil) {
			a.performed("workspace.tree.expandAll", surfaceButton)
			a.expandProjectTree(p)
		}
		if a.toolIconButton(f, treeActions.At(treeActionCollapse), i18n.Shared(language, "files.collapseAll"), icons.ChevronsDownUp, false, !ready, nil) {
			a.performed("workspace.tree.collapseAll", surfaceButton)
			a.collapseProjectTree(p)
		}
	})
}

// activeTreePath is the path in the tree, relative to the root with "/" separators, of the
// file the editor shows, and false when it shows none or a file outside the project.
func activeTreePath(p *project) (string, bool) {
	doc := p.selectedDocument(p.docs.group)
	if doc == nil {
		return "", false
	}
	return projectRelativePath(p.root, doc.path)
}

// projectRelativePath is path relative to root with "/" separators, and false when path is
// root itself or not inside it.
func projectRelativePath(root, path string) (string, bool) {
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", false
	}
	return filepath.ToSlash(rel), true
}

// continueTreeActions goes on with the header buttons' work after a listing arrived: the walk
// to the file being located, Expand All, and the end of a refresh. A root that could not be
// listed ends them all.
func (a *App) continueTreeActions(p *project) {
	t := &p.tree
	if t.failed != "" {
		t.reveal, t.revealAsked = "", nil
		t.expandingAll, t.expandSeen = false, nil
	}
	a.stepTreeReveal(p)
	a.stepTreeExpandAll(p)
	if t.refreshing && !t.reading && len(t.pending) == 0 {
		t.refreshing = false
	}
}

// revealActiveFile starts bringing the file the editor shows into view: the folders above it
// open, listed first where they have not been, and then its row is selected and scrolled to.
func (a *App) revealActiveFile(p *project) {
	rel, ok := activeTreePath(p)
	if !ok {
		return
	}
	p.tree.reveal, p.tree.revealAsked = rel, nil
	a.stepTreeReveal(p)
}

// stepTreeReveal opens the folders on the way to the file being located as far as they are
// listed, and asks for the listing of the first one that is not, to go on when it arrives. A
// folder that was closed is listed again as it opens, as a click on its arrow lists it, for
// files made while nothing watched it. It gives up on a file the tree does not show: one the
// kernel hides, one that is gone, or one in a folder that could not be listed.
func (a *App) stepTreeReveal(p *project) {
	t := &p.tree
	if t.reveal == "" || t.root == nil {
		return
	}
	n, rest := t.root, t.reveal
	for {
		if !n.expanded || !n.listed {
			if n.expanded && n.loading {
				// Its listing is on the way; the walk goes on when it arrives.
				return
			}
			if n == t.revealAsked {
				// The listing asked for came back and the folder did not open with it.
				a.giveUpTreeReveal(p, "folder_unavailable")
				return
			}
			n.expanded, t.measureDirty, t.revealAsked = true, true, n
			a.listTree(p, n.path)
			return
		}
		var name string
		name, rest, _ = strings.Cut(rest, "/")
		child := t.find(childTreePath(n.path, name))
		if child == nil {
			if n.loading {
				// A fresher listing of the folder is on the way, and it may have the file.
				return
			}
			a.giveUpTreeReveal(p, "path_not_listed")
			return
		}
		if rest == "" {
			t.reveal, t.revealAsked = "", nil
			t.selected, t.show = child, child
			return
		}
		if !child.dir {
			a.giveUpTreeReveal(p, "path_not_listed")
			return
		}
		n = child
	}
}

// childTreePath is the path in the tree of the entry name in the folder at parent.
func childTreePath(parent, name string) string {
	if parent == "" {
		return name
	}
	return parent + "/" + name
}

// giveUpTreeReveal ends locating a file the tree cannot show, for reason.
func (a *App) giveUpTreeReveal(p *project, reason string) {
	a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "project_tree_reveal", "reason": reason})
	p.tree.reveal, p.tree.revealAsked = "", nil
}

// refreshProjectTree reads the folders the tree shows from disk again, for changes the watches
// missed, keeping what is open and selected. A root that could not be listed is asked for
// again.
func (a *App) refreshProjectTree(p *project) {
	t := &p.tree
	if t.failed != "" {
		a.retryProjectTree(p)
		return
	}
	t.refreshing = true
	a.resyncTreeListings(p)
	// With nothing to read, the refresh is already over.
	a.continueTreeActions(p)
}

// retryProjectTree asks again for the listing of a root that could not be listed, with a fresh
// watch on it.
func (a *App) retryProjectTree(p *project) {
	t := &p.tree
	if slot := t.watches[""]; slot != nil {
		slot.close()
		delete(t.watches, "")
	}
	t.failed, t.root.listed, t.root.expanded = "", false, true
	a.listTree(p, "")
}

// expandProjectTree starts opening every folder of the tree, the ones nearest the root first,
// as their listings arrive.
func (a *App) expandProjectTree(p *project) {
	t := &p.tree
	t.expandingAll, t.expandSeen = true, make(map[int]bool)
	a.stepTreeExpandAll(p)
}

// stepTreeExpandAll opens the folders of the tree that are closed, nearest the root first, and
// asks for their listings, to open the folders in them when those arrive. It ends when there is
// nothing left to open, or once treeExpandAllLimit folders were opened. A folder it opened that
// closed again, because its listing failed or the user closed it, stays closed.
func (a *App) stepTreeExpandAll(p *project) {
	t := &p.tree
	if !t.expandingAll || t.root == nil {
		return
	}
	var ask []string
	limited := false
	for queue := []*treeNode{t.root}; len(queue) > 0; queue = queue[1:] {
		n := queue[0]
		if !n.dir || n.empty {
			continue
		}
		if !n.expanded {
			if t.expandSeen[n.id] {
				continue
			}
			if len(t.expandSeen) >= treeExpandAllLimit {
				limited = true
				continue
			}
			t.expandSeen[n.id] = true
			n.expanded, t.measureDirty = true, true
			ask = append(ask, n.path)
		}
		if n.listed {
			queue = append(queue, n.children...)
		}
	}
	if len(ask) != 0 {
		a.listTree(p, ask...)
	}
	switch {
	case limited:
		t.expandingAll, t.expandSeen = false, nil
		a.notify(i18n.Shared(a.language(), "desktop.project.expandAllIncomplete"))
	case len(ask) == 0 && !t.reading && len(t.pending) == 0:
		t.expandingAll, t.expandSeen = false, nil
	}
}

// collapseProjectTree closes every folder under the root, ending Expand All and locating a
// file. A selected row the collapse hides gives the selection to the row it is now hidden
// under; the focus stays on the button that asked for the collapse.
func (a *App) collapseProjectTree(p *project) {
	t := &p.tree
	if t.root == nil {
		return
	}
	t.expandingAll, t.expandSeen = false, nil
	t.reveal, t.revealAsked = "", nil
	var collapse func(*treeNode)
	collapse = func(n *treeNode) {
		for _, child := range n.children {
			if child.dir {
				child.expanded = false
				collapse(child)
			}
		}
	}
	collapse(t.root)
	t.measureDirty = true
	if s := t.selected; s != nil && s != t.root && (s.depth > 1 || !t.root.expanded) {
		shown := t.root
		if t.root.expanded {
			top, _, _ := strings.Cut(s.path, "/")
			if n := t.find(top); n != nil {
				shown = n
			}
		}
		t.selected, t.show = shown, shown
	}
	a.pruneTreeWatches(p)
}
