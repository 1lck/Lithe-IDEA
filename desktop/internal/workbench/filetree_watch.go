package workbench

import (
	"context"
	"errors"
	"path"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// The Linux fallback gives each observed directory a registration and a
// goroutine. Its cap prevents an expanded tree exhausting platform handles.
const treeWatchLimit = 128

func (a *App) watchTreeNode(p *project, n *treeNode) {
	if treeUsesRecursiveWatch() {
		if !p.tree.recursiveWatch {
			p.tree.recursiveWatch = true
			if p.search.watch != nil && p.search.watchReady && !p.search.watchAvailable {
				p.search.watch.close()
				p.search.watch = nil
			}
			if p.search.watch == nil {
				a.startProjectSearchWatch(p)
			} else if p.search.watchReady && p.search.watchAvailable {
				// The search may have kept this stream alive while the tree was
				// detached. Refresh loaded descendants to cover that interval.
				p.tree.resyncOnAttach = true
			}
		}
		return
	}
	if n != p.tree.root && !n.expanded && !n.empty {
		return
	}
	t := &p.tree
	if t.watches == nil {
		t.watches = make(map[string]*documentWatch)
	}
	if t.watches[n.path] != nil {
		return
	}
	if len(t.watches) >= treeWatchLimit {
		// A directory the user expanded takes precedence over an empty child
		// whose disclosure can be refreshed when its parent is reopened.
		if n.expanded {
			for watched, slot := range t.watches {
				candidate := t.find(watched)
				if candidate != nil && candidate.empty && !candidate.expanded {
					slot.close()
					delete(t.watches, watched)
					if !t.watchLimitHit {
						t.watchLimitHit = true
						a.treeWatchFailed(errors.New("project tree directory watch limit reached"))
					}
					break
				}
			}
		}
	}
	if len(t.watches) >= treeWatchLimit {
		if !t.watchLimitHit {
			t.watchLimitHit = true
			a.treeWatchFailed(errors.New("project tree directory watch limit reached"))
		}
		return
	}
	path := n.path
	slot := &documentWatch{}
	t.watches[path] = slot
	a.tasks.running.Add(1)
	wake := func() { a.post(func(a *App) { a.drainTreeWatch(p, path, slot) }) }
	go func() {
		defer a.tasks.running.Done()
		watch, err := app.WatchDirectory(filepath.Join(p.root, filepath.FromSlash(path)), wake)
		var observed documentDirectoryWatch
		if watch != nil {
			observed = watch
		}
		slot.finish(observed, err)
		wake()
	}()
}

// macOS and Windows provide an efficient recursive native stream. Linux's
// recursive implementation walks and registers every directory, so it keeps
// the bounded, lazy per-directory adapter instead.
func treeUsesRecursiveWatch() bool { return runtime.GOOS == "darwin" || runtime.GOOS == "windows" }

func (a *App) applyTreeRecursiveWatch(p *project, ready, available bool, err error, changes app.DirectoryChanges) {
	if ready && err != nil {
		if p.search.watchAttached || p.everywhere.watchAttached {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_watch", err))
		} else {
			a.treeWatchFailed(err)
		}
	}
	if changes.Resync || ready && available {
		p.tree.eventEpoch++
		p.tree.eventPending = nil
		a.resyncTreeListings(p)
		return
	}
	if len(changes.Names) == 0 || p.tree.root == nil {
		return
	}
	if len(p.tree.eventPending)+len(changes.Names) > searchEventLimit {
		p.tree.eventEpoch++
		p.tree.eventPending = nil
		a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "project_tree_watch", "reason": "event_limit_exceeded"})
		a.resyncTreeListings(p)
		return
	}
	p.tree.eventPending = append(p.tree.eventPending, changes.Names...)
	a.filterTreeEvents(p)
}

// Filter off the window thread and keep a bounded, coalesced queue. Core owns
// hidden-path rules, including built-in build and dependency directories.
func (a *App) filterTreeEvents(p *project) {
	t := &p.tree
	if t.eventFiltering || !t.recursiveWatch || len(t.eventPending) == 0 {
		return
	}
	paths := t.eventPending
	t.eventPending = nil
	t.eventFiltering = true
	epoch := t.eventEpoch
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		filtered, err := a.kernel.FilterWorkspaceChanges(ctx, paths)
		return func(a *App) {
			t.eventFiltering = false
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_filter_changes", err))
				if t.recursiveWatch {
					a.resyncTreeListings(p)
				}
			} else if t.recursiveWatch && epoch == t.eventEpoch {
				a.applyFilteredTreeEvents(p, filtered)
			}
			a.filterTreeEvents(p)
		}
	})
}

func (a *App) resyncTreeListings(p *project) {
	// The stream may have lost names or begun after a listing. Re-read only
	// directories already loaded and expanded, not the whole filesystem.
	var paths []string
	var collect func(*treeNode)
	collect = func(n *treeNode) {
		if n == nil || !n.dir || !n.expanded {
			return
		}
		paths = append(paths, n.path)
		for _, child := range n.children {
			collect(child)
		}
	}
	collect(p.tree.root)
	a.listTree(p, paths...)
}

func (a *App) applyFilteredTreeEvents(p *project, names []string) {
	if len(names) == 0 || p.tree.root == nil {
		return
	}
	// The event paths are native notifications. Look up only nodes already
	// represented by the tree; Core owns visibility and the actual listing.
	// Reuse the loaded-node index. Only build a folded lookup if a Windows
	// notification actually differs in case from the listing.
	p.tree.find("")
	var folded map[string]*treeNode
	lookup := func(name string) *treeNode {
		if node := p.tree.byPath[name]; node != nil && node.dir {
			return node
		}
		if runtime.GOOS != "windows" {
			return nil
		}
		if folded == nil {
			folded = make(map[string]*treeNode)
			for path, node := range p.tree.byPath {
				if node.dir {
					folded[strings.ToLower(path)] = node
				}
			}
		}
		return folded[strings.ToLower(name)]
	}
	selected := make(map[string]struct{})
	for _, name := range names {
		parent := treeParentPath(name)
		for {
			n := lookup(parent)
			if n != nil && n.dir {
				if n != p.tree.root && !n.expanded {
					parent = treeParentPath(n.path)
				} else {
					parent = n.path
				}
				selected[parent] = struct{}{}
				break
			}
			if parent == "" {
				break
			}
			parent = treeParentPath(parent)
		}
	}
	paths := make([]string, 0, len(selected))
	for name := range selected {
		paths = append(paths, name)
	}
	if len(paths) != 0 {
		a.listTree(p, paths...)
	}
}

func (a *App) detachTreeRecursiveWatch(p *project) {
	p.tree.recursiveWatch = false
	p.tree.resyncOnAttach = false
	p.tree.eventEpoch++
	p.tree.eventPending = nil
	if !p.search.watchAttached && !p.everywhere.watchAttached && p.search.watch != nil {
		p.search.watch.close()
		p.search.watch = nil
		p.search.watchReady, p.search.watchAvailable = false, false
	}
}

func (a *App) treeWatchFailed(err error) {
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_watch", err))
	a.notify(i18n.Shared(a.language(), "desktop.project.watchUnavailable"))
}

func (a *App) drainTreeWatch(p *project, path string, slot *documentWatch) {
	if a.project != p || p.tree.watches[path] != slot {
		return
	}
	watch, ready, err := slot.state()
	if ready && err != nil {
		a.treeWatchFailed(err)
	}
	changed := ready && watch != nil // Covers the registration/listing gap.
	if watch != nil {
		changes := watch.Changes(nil)
		changed = changed || changes.Resync || len(changes.Names) != 0
		if changes.Resync {
			a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "project_tree_watch", "reason": "watch_events_lost"})
			slot.close()
			delete(p.tree.watches, path)
			if n := p.tree.find(path); n != nil {
				a.watchTreeNode(p, n)
			}
		}
	}
	if changed {
		refresh := path
		if n := p.tree.find(path); n != nil && n.empty && !n.expanded {
			refresh = treeParentPath(path)
		}
		a.listTree(p, refresh)
	}
}

func treeParentPath(name string) string {
	parent := path.Dir(name)
	if parent == "." {
		return ""
	}
	return parent
}

// Watches for hidden descendants are released when an ancestor collapses or a
// refresh removes them. Re-expansion registers again before a fresh listing.
func (a *App) pruneTreeWatches(p *project) {
	t := &p.tree
	if t.failed != "" {
		if t.recursiveWatch {
			a.detachTreeRecursiveWatch(p)
		}
		// A missing root makes every descendant registration stale. Stop them
		// together and let the explicit retry establish a fresh root watch.
		for _, slot := range t.watches {
			slot.close()
		}
		clear(t.watches)
		for _, node := range t.pending {
			node.loading = false
		}
		clear(t.pending)
		t.watchLimitHit = false
		return
	}
	active := make(map[string]bool)
	var visit func(*treeNode)
	visit = func(n *treeNode) {
		if n == nil || !n.dir || !n.expanded {
			return
		}
		active[n.path] = true
		for _, child := range n.children {
			if child.dir && child.empty {
				active[child.path] = true
			}
			visit(child)
		}
	}
	visit(t.root)
	for path, slot := range t.watches {
		if !active[path] {
			slot.close()
			delete(t.watches, path)
		}
	}
	if len(t.watches) < treeWatchLimit {
		t.watchLimitHit = false
	}
}

func (a *App) closeTree(p *project) {
	if p.tree.recursiveWatch {
		a.detachTreeRecursiveWatch(p)
	}
	for _, slot := range p.tree.watches {
		slot.close()
	}
	p.tree.watches = nil
	p.tree.pending = nil
}
