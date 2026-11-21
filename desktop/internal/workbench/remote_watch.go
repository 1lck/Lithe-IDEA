package workbench

import (
	"context"
	"errors"
	"path"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file watches a remote workspace's folder on its host (remote.runWatch). The host watches
// the whole folder for as long as the session lasts, leaving out the folders the enabled plugins
// hide, and reports each batch of changes by host path. The Project tool window takes the
// changes as a local project's recursive watch hands them over: Core drops the hidden paths
// (workspace.filterChanges, which needs no session) and the folders holding the rest are listed
// again. An open document whose file, or a folder above it, changed is compared with the host's
// file, so a change made on the host reloads it or shows the conflict.
//
// The watch starts with each session and stops when the session is lost or the workspace closes.
// When it starts, and when the host lost changes or sent more than the window applies one by one,
// the tree lists its open folders again and every document is compared with the host. When the
// host runs out of watches, the part it could watch goes on and the user is told once that files
// may not update. The request runs on its own goroutine for the watch's whole life, outside the
// window's background tasks, which waits for none of them; it ends when the watch is cancelled.
//
// A folder removed while watched ends the watch, which starts again at once and finds the folder
// back or missing. A watch that finds its folder missing waits for the tree to list it again; when
// the tree had just listed it, it waits for the tree to find it missing too first, so the two never
// take turns over a folder one of them can read. Any other failure is logged by command and code,
// since Core's message may name a host path, and the watch waits for the next session.

// remoteWatchExcludes are the folder names the enabled plugins hide, as Core last answered them
// (hidden_directories.go). Core keeps one list for the process, so every workspace's host watch
// leaves out the same names.
var remoteWatchExcludes atomic.Pointer[[]string]

// setRemoteWatchExcludes keeps names, Core's sorted list, for the host watches started from now
// on, and reports whether it differs from the one kept before.
func setRemoteWatchExcludes(names []string) bool {
	names = slices.Clone(names)
	var before []string
	if previous := remoteWatchExcludes.Swap(&names); previous != nil {
		before = *previous
	}
	return !slices.Equal(before, names)
}

// remoteWatchExcludeNames is the list setRemoteWatchExcludes kept, nil before Core answered.
func remoteWatchExcludeNames() []string {
	if names := remoteWatchExcludes.Load(); names != nil {
		return *names
	}
	return nil
}

// errRemoteWatchLimit is what the log keeps when the host ran out of watches.
var errRemoteWatchLimit = errors.New("remote workspace watch limit reached on the host")

// remoteWatchWait is what a remote workspace's host watch waits for while it does not run.
type remoteWatchWait int

const (
	// remoteWatchReady: nothing; the watch runs, or starts with the session.
	remoteWatchReady remoteWatchWait = iota
	// remoteWatchRootListed: the watch found the folder missing; it starts once the tree lists
	// the folder.
	remoteWatchRootListed
	// remoteWatchRootMissed: the watch found the folder missing while the tree could list it; it
	// waits for the tree to find the folder missing, then for the tree to list it again.
	remoteWatchRootMissed
	// remoteWatchSession: the watch failed; it starts again with the next session.
	remoteWatchSession
)

// remoteWatch is one run of a remote workspace's host watch (remoteProject.watch).
type remoteWatch struct {
	// session is the session the watch runs over; cancel stops it.
	session string
	cancel  context.CancelFunc
	// watching is set once the host watches the folder, and partial once the host ran out of
	// watches, so some of its folders go unwatched; lostReported and excessReported once this
	// run's lost changes and too many changes were logged. They are the window thread's.
	watching       bool
	partial        bool
	lostReported   bool
	excessReported bool

	// mu guards what the request's goroutine hands the window thread until it drains it.
	mu sync.Mutex
	// started, overflow and limited are the start, a batch the host lost changes of, and the
	// host's running out of watches. excess is set when more than searchEventLimit paths came
	// before the window drained them, which are then dropped.
	started, overflow, limited, excess bool
	// paths are the host paths changed since the last drain.
	paths []string
	// woken is set while a drain is queued.
	woken bool
}

// record changes the watch's pending state on the request's goroutine and queues one drain.
func (w *remoteWatch) record(a *App, p *project, change func(w *remoteWatch)) {
	w.mu.Lock()
	change(w)
	wake := !w.woken
	w.woken = true
	w.mu.Unlock()
	if wake {
		a.post(func(a *App) { a.drainRemoteWatch(p, w) })
	}
}

// startRemoteWatch starts the host watch of p's folder over its session, unless one runs or the
// watch waits for something.
func (a *App) startRemoteWatch(p *project) {
	r := p.remote
	if r == nil || r.closed || r.session == "" || r.watch != nil || r.watchWait != remoteWatchReady {
		return
	}
	ctx, cancel := context.WithCancel(p.ctx)
	w := &remoteWatch{session: r.session, cancel: cancel}
	r.watch = w
	kernel, root, excludes := a.kernel, r.binding.RemoteRoot(), remoteWatchExcludeNames()
	events := core.RemoteWatchEvents{
		Started: func() { w.record(a, p, func(w *remoteWatch) { w.started = true }) },
		Changed: func(changes []core.RemoteWatchChange, overflow bool) {
			w.record(a, p, func(w *remoteWatch) {
				w.overflow = w.overflow || overflow
				if w.overflow || w.excess {
					// Everything is read again, which covers these changes too.
					w.paths = nil
					return
				}
				if len(w.paths)+len(changes) > searchEventLimit {
					w.excess, w.paths = true, nil
					return
				}
				for _, change := range changes {
					w.paths = append(w.paths, change.Path)
				}
			})
		},
		LimitReached: func() { w.record(a, p, func(w *remoteWatch) { w.limited = true }) },
	}
	go func() {
		err := kernel.RemoteRunWatch(ctx, w.session, root, excludes, events)
		a.post(func(a *App) { a.remoteWatchEnded(p, w, err) })
	}()
}

// stopRemoteWatch stops p's host watch. Changes it queued for the tree are dropped, and so is a
// drain or an end it already posted.
func (a *App) stopRemoteWatch(p *project) {
	r := p.remote
	if r == nil || r.watch == nil {
		return
	}
	r.watch.cancel()
	r.watch = nil
	p.tree.eventEpoch++
	p.tree.eventPending = nil
	a.remoteSearchUnwatched(p)
}

// restartRemoteWatch starts p's running host watch again, for a new list of hidden folders.
func (a *App) restartRemoteWatch(p *project) {
	if p.remote == nil || p.remote.watch == nil {
		return
	}
	a.stopRemoteWatch(p)
	a.startRemoteWatch(p)
}

// drainRemoteWatch applies what w handed over since the last drain.
func (a *App) drainRemoteWatch(p *project, w *remoteWatch) {
	w.mu.Lock()
	started, overflow, limited, excess, paths := w.started, w.overflow, w.limited, w.excess, w.paths
	w.started, w.overflow, w.limited, w.excess, w.paths, w.woken = false, false, false, false, nil, false
	w.mu.Unlock()
	r := p.remote
	if a.project != p || r == nil || r.watch != w {
		// log-exempt: 用户取消：工作区已关闭，或这次监听已停止（会话丢失、隐藏目录变化），它的变化不再适用。
		return
	}
	if limited {
		w.partial = true
		a.backgroundFailed("remote_watch", errRemoteWatchLimit)
		a.remoteWatchUnavailable(p)
		a.remoteSearchUnwatched(p)
	}
	if overflow && !w.lostReported {
		w.lostReported = true
		a.backgroundFailed("remote_watch", errWatchEventsLost)
	}
	if excess && !w.excessReported {
		w.excessReported = true
		a.backgroundFailed("remote_watch", errWatchEventLimit)
	}
	if started {
		w.watching = true
	}
	if started || overflow || excess {
		// A change before the start, or one the host or the window dropped, is found by reading
		// everything shown again.
		a.resyncRemoteWorkspace(p)
		return
	}
	a.applyRemoteChanges(p, paths)
}

// remoteWatchUnavailable tells the user, once for the workspace, that the host does not watch all
// of its folder.
func (a *App) remoteWatchUnavailable(p *project) {
	if p.remote.watchNotified {
		// log-exempt: 同一次失败已经记录过：每次失败都已记 remote_watch，提示对一个工作区只显示一次。
		return
	}
	p.remote.watchNotified = true
	a.notifyError(i18n.Shared(a.language(), "desktop.project.watchUnavailable"))
}

// resyncRemoteWorkspace reads again what p shows of its host folder: the tree's open folders, or
// its root when it could not be listed, every document and the search index.
func (a *App) resyncRemoteWorkspace(p *project) {
	p.tree.eventEpoch++
	p.tree.eventPending = nil
	if p.tree.root != nil {
		a.refreshRemoteTree(p)
	}
	a.recheckRemoteDocuments(p)
	a.remoteSearchChanged(p, nil, true)
}

// applyRemoteChanges hands the search index and the tree the changed host paths below p's folder
// and compares the documents they touch with the host.
func (a *App) applyRemoteChanges(p *project, hostPaths []string) {
	root := p.remote.binding.RemoteRoot()
	names := make([]string, 0, len(hostPaths))
	for _, host := range hostPaths {
		if name, ok := remoteRelativePath(root, host); ok {
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return
	}
	a.remoteSearchChanged(p, names, false)
	a.markRemoteDocuments(p, names)
	t := &p.tree
	if t.root == nil {
		return
	}
	if len(t.eventPending)+len(names) > searchEventLimit {
		t.eventEpoch++
		t.eventPending = nil
		a.backgroundFailed("remote_watch", errWatchEventLimit)
		a.resyncTreeListings(p)
		return
	}
	t.eventPending = append(t.eventPending, names...)
	a.filterTreeEvents(p)
}

// markRemoteDocuments compares with the host every document of p whose file, or a folder above
// it, is one of names, paths relative to the folder.
func (a *App) markRemoteDocuments(p *project, names []string) {
	changed := make(map[string]struct{}, len(names))
	for _, name := range names {
		changed[name] = struct{}{}
	}
	root, marked := p.remote.binding.RemoteRoot(), false
	for _, d := range p.docs.list {
		if d.virtual {
			continue
		}
		name, ok := remoteRelativePath(root, p.remoteHostPath(d.path))
		for ok {
			if _, hit := changed[name]; hit {
				d.checkPending, marked = true, true
				break
			}
			name = path.Dir(name)
			ok = name != "."
		}
	}
	if marked {
		a.scheduleDocumentChecks(p)
	}
}

// remoteRelativePath is host, an absolute host path, relative to root, the workspace's folder.
// ok is false for root itself and for a path outside it.
func remoteRelativePath(root, host string) (string, bool) {
	prefix := strings.TrimSuffix(root, "/") + "/"
	name, ok := strings.CutPrefix(host, prefix)
	return name, ok && name != ""
}

// remoteWatchEnded handles the end of w's request with err.
func (a *App) remoteWatchEnded(p *project, w *remoteWatch, err error) {
	r := p.remote
	if a.project != p || r == nil || r.closed || r.watch != w || p.ctx.Err() != nil {
		// log-exempt: 用户取消：工作区已关闭，或这次监听已停止（会话丢失、隐藏目录变化），结束是取消带来的。
		return
	}
	w.mu.Lock()
	// The drain of the start was queued before this end and ran first; a start still pending
	// counts too.
	started := w.watching || w.started
	w.mu.Unlock()
	a.stopRemoteWatch(p)
	var coreErr *core.Error
	switch {
	case err == nil && started:
		// log-exempt: 预期的缺失：主机上的文件夹在监听中被删除或移走，监听随即重新开始，找回或找不到它都另有处理。
		a.startRemoteWatch(p)
		a.resyncRemoteWorkspace(p)
	case err == nil, errors.As(err, &coreErr) && coreErr.Code == core.CodeWorkspaceNotFound:
		// A watch that ended without starting found no folder to watch either; starting it again
		// at once would only end it again.
		// log-exempt: 预期的缺失：主机上没有这个文件夹，项目树显示根目录不可用，监听等树重新列出它。
		if p.tree.root == nil || p.tree.failed != "" {
			// The tree shows no listing of the folder, so its next one finds the folder back.
			r.watchWait = remoteWatchRootListed
		} else {
			// The tree's listing may be older than the folder's removal; the one read below
			// tells.
			r.watchWait = remoteWatchRootMissed
		}
		a.resyncRemoteWorkspace(p)
	case remoteConnectionClosed(err):
		a.loseRemote(p, w.session, err)
	default:
		a.backgroundFailed("remote_watch", remoteLogError(err))
		r.watchWait = remoteWatchSession
		a.remoteWatchUnavailable(p)
		a.resyncRemoteWorkspace(p)
	}
}

// remoteTreeRootRead lets a waiting host watch know how the tree's listing of the root went:
// listed, or found missing.
func (a *App) remoteTreeRootRead(p *project, listed bool) {
	r := p.remote
	if r == nil {
		return
	}
	switch {
	case !listed && r.watchWait == remoteWatchRootMissed:
		r.watchWait = remoteWatchRootListed
	case listed && r.watchWait == remoteWatchRootListed:
		r.watchWait = remoteWatchReady
		a.startRemoteWatch(p)
	}
}
