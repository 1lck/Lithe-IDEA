package workbench

import (
	"context"
	"errors"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// treeNode is a file or a folder of the project tree. A folder's children are listed by the
// kernel the first time it is expanded.
type treeNode struct {
	// id identifies the node's row; it is never reused.
	id int
	// path is relative to the project root with "/" separators; empty for the root.
	path     string
	name     string
	dir      bool
	expanded bool
	// listed says children is the kernel's listing; loading says the listing was asked for.
	listed, loading bool
	// revision advances as native notifications arrive, invalidating older reads.
	revision uint64
	// empty says the kernel knows the folder shows nothing, before or after it is listed.
	empty    bool
	children []*treeNode
	depth    int
}

// fileTree is the state of the Project tool window's tree of the project folder. The zero
// value is a tree that has not been asked for yet.
type fileTree struct {
	root *treeNode
	// byPath indexes only already loaded nodes; it never enumerates disk.
	byPath map[string]*treeNode
	// selected is the node whose row is highlighted, which the arrow keys move.
	selected *treeNode
	// marked are the paths a Ctrl or Shift click selected for a batch; anchor is the path a
	// Shift click extends from, and targets what a batch acts on, as Core last said
	// (filetree_batch.go).
	marked  map[string]bool
	anchor  string
	targets []string
	// batch is the batch delete dialog, open while the user confirms it.
	batch treeBatchDelete
	// rowRefs maps the hit identity of each row the last paint declared to its node, so a drag
	// or drop finds the paths it names (filetree_dnd.go); clip is the cut or copied items.
	rowRefs map[gfx.ID]treeRowRef
	clip    treeClipboard
	// failed is why the root could not be listed; empty otherwise.
	failed string
	next   int
	// rows are the nodes the tree shows, top to bottom, as Core laid them out when the shape of
	// the tree last changed, and rowsDirty says it changed since (filetree_rows.go); view is the
	// Tree that shows them, which declares only the ones in view and scrolls sideways when the
	// widest row is wider than it, by view.RowWidth.
	rows      []*treeNode
	rowsDirty bool
	view      ui.TreeState
	// area is where the tree was laid out in the last paint, read by its draw hook.
	area     gfx.Rect
	areaDraw func(*ui.DrawContext)
	// focusNode is the node whose row takes the keyboard once it is declared.
	focusNode *treeNode
	// wake asks for a paint.
	wake func()
	// measureDirty says the rows were laid out again since the width of the widest row was
	// measured, and measureFont the font size it was measured with.
	measureDirty bool
	measureFont  float32
	// pending and reading coalesce native events into one bounded Core request.
	pending map[string]*treeNode
	reading bool
	// failureReported says the current run of listing failures was already logged. A
	// user action can need several requests — a frame that paints while the first one
	// is in flight adds more paths — and each of them failing is one error to the user,
	// not one per request.
	failureReported bool
	watches         map[string]*documentWatch
	watchLimitHit   bool
	recursiveWatch  bool
	resyncOnAttach  bool
	eventPending    []string
	eventFiltering  bool
	eventEpoch      uint64
	// reveal is the path of the file the locate button is bringing into view while the
	// folders above it are still being listed, and empty otherwise; revealAsked is the
	// folder whose listing it waits for. show is a row the next frame scrolls to the middle
	// of the list, unless it is in view already.
	reveal      string
	revealAsked *treeNode
	show        *treeNode
	// expandingAll says Expand All is still opening folders as their listings arrive.
	// expandSeen is the ids of the folders it opened, each of them once and no more than
	// treeExpandAllLimit of them. refreshing says the refresh button is reading the
	// listings again.
	expandingAll bool
	expandSeen   map[int]bool
	refreshing   bool
	// prompt is the open New File, New Directory, Rename or Delete dialog of a row
	// (see filetree_menu.go).
	prompt treePrompt
}

// node makes a node of the tree from what the kernel listed.
func (t *fileTree) node(entry core.WorkspaceNode, depth int) *treeNode {
	t.next++
	return &treeNode{id: t.next, path: entry.Path, name: entry.Name, dir: entry.IsDirectory, empty: entry.Leaf, depth: depth}
}

// find is the node at path among the nodes that are listed, and nil when there is none.
func (t *fileTree) find(path string) *treeNode {
	if t.root == nil {
		return nil
	}
	if t.byPath == nil {
		t.byPath = make(map[string]*treeNode)
		var walk func(*treeNode)
		walk = func(n *treeNode) {
			t.byPath[n.path] = n
			for _, child := range n.children {
				walk(child)
			}
		}
		walk(t.root)
	}
	return t.byPath[path]
}

func (t *fileTree) forgetNode(n *treeNode) {
	if t.byPath == nil {
		return
	}
	delete(t.byPath, n.path)
	for _, child := range n.children {
		t.forgetNode(child)
	}
}

// replaceChildren keeps the identities and loaded descendants of entries that still exist.
// The rows are laid out again after it, which moves a selection whose node went away.
func (t *fileTree) replaceChildren(parent *treeNode, entries []core.WorkspaceNode) {
	old := make(map[string]*treeNode, len(parent.children))
	for _, child := range parent.children {
		old[child.path] = child
	}
	children := make([]*treeNode, 0, len(entries))
	for _, entry := range entries {
		child := old[entry.Path]
		delete(old, entry.Path)
		if child == nil || child.dir != entry.IsDirectory {
			if child != nil {
				t.forgetNode(child)
			}
			child = t.node(entry, parent.depth+1)
		} else {
			child.name, child.empty = entry.Name, entry.Leaf
			if child.empty {
				child.listed = true
				for _, descendant := range child.children {
					t.forgetNode(descendant)
				}
				child.children = nil
			}
		}
		if t.byPath != nil {
			t.byPath[child.path] = child
		}
		children = append(children, child)
	}
	for _, removed := range old {
		t.forgetNode(removed)
	}
	parent.children = children
	t.rowsDirty = true
}

// listTree asks the kernel for the children of the folders at paths, away from the window
// thread, and puts them into the tree when they arrive. A folder that cannot be listed stays
// collapsed; the root that cannot be listed shows why.
func (a *App) listTree(p *project, paths ...string) {
	t := &p.tree
	if t.pending == nil {
		t.pending = make(map[string]*treeNode)
	}
	for _, path := range paths {
		n := t.find(path)
		if n == nil || !n.dir {
			continue
		}
		a.watchTreeNode(p, n)
		n.revision++
		n.loading = true
		t.pending[path] = n
	}
	if t.resyncOnAttach {
		t.resyncOnAttach = false
		a.resyncTreeListings(p)
	}
	a.pumpTreeListings(p)
}

const treeListingBatch = 64

// pumpTreeListings keeps only one bounded request in flight. A notification
// during a read advances its node's revision, so that read cannot publish stale
// children; the queued replacement will use the latest disk state.
func (a *App) pumpTreeListings(p *project) {
	t := &p.tree
	if t.reading || len(t.pending) == 0 {
		return
	}
	type requested struct {
		node     *treeNode
		revision uint64
	}
	batch := make(map[string]requested, treeListingBatch)
	paths := make([]string, 0, treeListingBatch)
	for path, node := range t.pending {
		delete(t.pending, path)
		if t.find(path) != node {
			continue
		}
		batch[path] = requested{node, node.revision}
		paths = append(paths, path)
		if len(paths) == treeListingBatch {
			break
		}
	}
	if len(paths) == 0 {
		return
	}
	t.reading = true
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		listings, err := a.kernel.ListDirectories(ctx, p.root, paths)
		return func(a *App) {
			t.reading = false
			if err == nil {
				// The tree listed again, so a later failure is a new one to report.
				t.failureReported = false
			}
			top := treeTopPath(t)
			loggedFailure := t.failureReported
			byPath := make(map[string]core.DirectoryListing, len(listings))
			for _, listing := range listings {
				byPath[listing.Path] = listing
			}
			for _, path := range paths {
				req := batch[path]
				n := req.node
				if t.find(path) != n || n.revision != req.revision {
					continue
				}
				n.loading = false
				if err != nil {
					if !loggedFailure {
						a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_list", err))
						loggedFailure = true
						t.failureReported = true
					}
					if n == t.root {
						t.failed = i18n.Shared(a.language(), "desktop.project.rootUnavailable")
					} else if !n.listed {
						n.expanded, t.rowsDirty = false, true
					}
					continue
				}
				if listing, ok := byPath[path]; ok {
					t.replaceChildren(n, listing.Children)
					n.listed, n.empty = true, len(n.children) == 0
					if n == t.root {
						t.failed = ""
					}
				} else {
					if n == t.root {
						a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_list", errors.New("workspace root unavailable")))
						t.failed = i18n.Shared(a.language(), "desktop.project.rootUnavailable")
					} else {
						// log-exempt: 目标已消失：目录可能已被外部删除或隐藏。
						n.expanded, t.rowsDirty = false, true
					}
				}
			}
			if t.rowsDirty {
				// Rows inserted or removed above the top of the view leave the same row at its top.
				a.refreshTreeRows(p, top)
			}
			a.pruneTreeWatches(p)
			if t.failed == "" {
				for _, path := range paths {
					if parent := t.find(path); parent != nil && parent.expanded {
						for _, child := range parent.children {
							if child.dir && child.empty {
								a.watchTreeNode(p, child)
							}
						}
					}
				}
			}
			a.pumpTreeListings(p)
			a.continueTreeActions(p)
		}
	})
}

// toggleFolder expands a collapsed folder, listing it the first time, and collapses an
// expanded one.
func (a *App) toggleFolder(p *project, n *treeNode) {
	if n.empty {
		return
	}
	if n.expanded {
		n.expanded = false
		p.tree.rowsDirty = true
		a.pruneTreeWatches(p)
		return
	}
	n.expanded = true
	p.tree.rowsDirty = true
	// The directory may have changed while collapsed and unobserved.
	a.listTree(p, n.path)
}

// activateTreeNode does what a click or Enter on a row asks for: a folder opens or closes,
// and a file opens in the editor.
func (a *App) activateTreeNode(p *project, n *treeNode) {
	p.tree.selected = n
	if n.dir {
		a.toggleFolder(p, n)
		return
	}
	a.openFile(p, filepath.Join(p.root, filepath.FromSlash(n.path)))
}
