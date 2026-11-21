package workbench

import (
	"context"
	"errors"
	"io/fs"
	"path"
	"path/filepath"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// A trusted remote workspace runs Git on its host: Core runs every git.* request of the project
// there (core.RemoteWorkspace), so the status, the commit, the diffs, the log, the blame, stashes
// and shelves read and change the host's repository, and the paths Core answers name the
// workspace's placeholder (remoteplaceholder). What the window itself reads or writes of the
// repository goes to the host too: the blamed file's text and the info/exclude a file is excluded
// in. In safe mode Git stays off, as in a local project.
//
// The window learns of a change to the repository's metadata, made by a terminal or anything else
// on the host, from the host: next to the watch of the folder (remote_watch.go), the same server
// watches the repository's git directory, and the common directory when it lies elsewhere
// (remote.runWatch, recursive and with no folder left out). The changes it sends go to the same
// classification as a local project's (git_observation.go), which Core makes by path alone. The
// watches run over the session and stop when it is lost or the project closes; a new session, and
// trust, start them again.

// remoteGitWatch is one host watch of a remote workspace's Git metadata folder
// (gitObservation.remote).
type remoteGitWatch struct {
	// dir is the folder's placeholder path, as Core named it; session is the session the watch
	// runs over and cancel stops it.
	dir     string
	session string
	cancel  context.CancelFunc
	// limitReported is set once the host's running out of watches was logged; the window
	// thread's.
	limitReported bool

	// mu guards what the request's goroutine hands the window thread until it drains it.
	mu sync.Mutex
	// started, lost and limited are the start, a batch the host lost changes of, and the host's
	// running out of watches; watching is set once the watch started. paths are the placeholder
	// paths changed since the last drain.
	started, lost, limited, watching bool
	paths                            []string
	woken                            bool
}

// record changes the watch's pending state on the request's goroutine and queues one drain.
func (w *remoteGitWatch) record(a *App, p *project, change func(w *remoteGitWatch)) {
	w.mu.Lock()
	change(w)
	wake := !w.woken
	w.woken = true
	w.mu.Unlock()
	if wake {
		a.post(func(a *App) { a.drainRemoteGitWatch(p, w) })
	}
}

// remoteGitDirectories are the folders that hold the metadata of the repository watch names:
// its git directory, and its common directory unless one lies inside the other, since the host
// watches each one whole.
func remoteGitDirectories(watch core.GitWatchContext) []string {
	git, common := watch.GitDirectory, watch.GitCommonDirectory
	switch {
	case common == "" || common == git || within(git, common):
		return []string{git}
	case within(common, git):
		return []string{common}
	}
	return []string{git, common}
}

// within reports whether path lies below dir.
func within(dir, path string) bool {
	rel, err := filepath.Rel(dir, path)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// startRemoteGitWatches starts the host watches of p's metadata folders dirs, placeholder paths,
// over its session.
func (a *App) startRemoteGitWatches(p *project, dirs []string) {
	r := p.remote
	if r == nil || r.closed || r.session == "" {
		return
	}
	p.observe.remote = make(map[string]*remoteGitWatch, len(dirs))
	for _, dir := range dirs {
		host, ok := remoteplaceholder.HostPath(r.binding.LocalRoot(), r.binding.RemoteRoot(), dir)
		if !ok {
			// log-exempt: 预期的缺失：Core 给出的路径不在这个工作区的映射里，没有可监听的主机文件夹，状态仍在每次 Git 操作后刷新。
			continue
		}
		a.startRemoteGitWatch(p, dir, host)
	}
}

// startRemoteGitWatch starts the host watch of dir, whose host path is host.
func (a *App) startRemoteGitWatch(p *project, dir, host string) {
	r := p.remote
	ctx, cancel := context.WithCancel(p.ctx)
	w := &remoteGitWatch{dir: dir, session: r.session, cancel: cancel}
	p.observe.remote[dir] = w
	kernel, localRoot, remoteRoot := a.kernel, r.binding.LocalRoot(), r.binding.RemoteRoot()
	events := core.RemoteWatchEvents{
		Started: func() { w.record(a, p, func(w *remoteGitWatch) { w.started = true }) },
		Changed: func(changes []core.RemoteWatchChange, overflow bool) {
			w.record(a, p, func(w *remoteGitWatch) {
				w.lost = w.lost || overflow || len(w.paths)+len(changes) > gitObserveMaxPaths
				if w.lost {
					// The status is read again whole, which covers these changes too.
					w.paths = nil
					return
				}
				for _, change := range changes {
					if local, ok := remoteplaceholder.LocalPath(localRoot, remoteRoot, change.Path); ok {
						w.paths = append(w.paths, local)
					}
				}
			})
		},
		LimitReached: func() { w.record(a, p, func(w *remoteGitWatch) { w.limited = true }) },
	}
	// The request runs for the watch's whole life, outside the window's background tasks, as the
	// folder's watch does; it ends when the watch is cancelled.
	go func() {
		err := kernel.RemoteRunWatch(ctx, w.session, host, nil, events)
		a.post(func(a *App) { a.remoteGitWatchEnded(p, w, err) })
	}()
}

// stopRemoteGitWatches stops p's host watches of its Git metadata.
func stopRemoteGitWatches(p *project) {
	for _, w := range p.observe.remote {
		w.cancel()
	}
	p.observe.remote = nil
}

// drainRemoteGitWatch hands what w reported since the last drain to the classification.
func (a *App) drainRemoteGitWatch(p *project, w *remoteGitWatch) {
	w.mu.Lock()
	started, lost, limited, paths := w.started, w.lost, w.limited, w.paths
	w.started, w.lost, w.limited, w.paths, w.woken = false, false, false, nil, false
	w.watching = w.watching || started
	w.mu.Unlock()
	if a.project != p || p.observe.remote[w.dir] != w {
		// log-exempt: 用户取消：工作区已关闭，或这次监听已停止（会话丢失、失去信任、仓库重新解析），它的变化不再适用。
		return
	}
	if limited && !w.limitReported {
		// The part the host could watch goes on; the status is still read after every Git
		// command the window runs.
		w.limitReported = true
		a.backgroundFailed("git_metadata_watch", errRemoteWatchLimit)
	}
	if started || lost || limited {
		// The watch started after the last status, or missed changes: one rescan covers the gap.
		p.observe.full = true
	}
	for _, path := range paths {
		a.addGitPath(p, path)
	}
	a.scheduleGitObservation(p)
}

// remoteGitWatchEnded handles the end of w's request with err.
func (a *App) remoteGitWatchEnded(p *project, w *remoteGitWatch, err error) {
	if a.project != p || p.observe.remote[w.dir] != w || p.ctx.Err() != nil {
		// log-exempt: 用户取消：工作区已关闭，或这次监听已停止（会话丢失、失去信任、仓库重新解析），结束是取消带来的。
		return
	}
	w.mu.Lock()
	// The drain of the start was queued before this end and ran first; a start still pending
	// counts too.
	started := w.watching || w.started
	w.mu.Unlock()
	delete(p.observe.remote, w.dir)
	var coreErr *core.Error
	switch {
	case err == nil && started:
		// log-exempt: 预期的缺失：主机上的 Git 元数据文件夹在监听中被删除或移走，仓库随即重新解析。
		a.closeGitObservation(p)
		a.startGitObservation(p)
	case err == nil, errors.As(err, &coreErr) && coreErr.Code == core.CodeWorkspaceNotFound:
		// A watch that ended without starting found no folder to watch; resolving the repository
		// again at once would only end it again. The status read below tells what is there.
		// log-exempt: 预期的缺失：主机上没有这个 Git 元数据文件夹，状态重新读取一次，下一个会话再监听。
		p.observe.full = true
		a.scheduleGitObservation(p)
	case remoteConnectionClosed(err):
		a.loseRemote(p, w.session, err)
	default:
		// The status is still read after every Git command the window runs, and the next session
		// watches again.
		a.backgroundFailed("git_metadata_watch", remoteLogError(err))
		p.observe.full = true
		a.scheduleGitObservation(p)
	}
}

// remoteRepositoryAbove reports whether status, read for p, names a repository that starts above
// the folder of p, a remote workspace: Core names such a root outside the placeholder, where the
// paths of its changes do not meet the project tree's, so the Git views say why they stay empty
// rather than show them.
func remoteRepositoryAbove(p *project, status core.GitStatus) bool {
	if p.remote == nil || status.RepositoryRoot == "" {
		return false
	}
	root := filepath.Clean(gitState{status: status}.repositoryRoot(p.root))
	return root != filepath.Clean(p.root) && !within(p.root, root)
}

// resumeRemoteGit watches the Git metadata of p again over its new session, which rescans the
// status once it is found (startGitObservation).
func (a *App) resumeRemoteGit(p *project) {
	a.closeGitObservation(p)
	a.startGitObservation(p)
}

// remoteInfoExcludeLimit is the largest info/exclude a remote workspace adds a line to; the file
// is read whole to find the line, and one that large is not a list a person keeps.
const remoteInfoExcludeLimit = 1 << 20

// appendInfoExclude is appendInfoExclude on the host: commonDir is the placeholder path Core named
// for the repository's common directory, which may lie outside the folder, as a linked worktree's
// does. A file that changed between the read and the write is left as it is and the exclusion
// fails, so a line someone else added is not lost.
func (r *remoteDocuments) appendInfoExclude(ctx context.Context, commonDir, pattern string) error {
	host, ok := remoteplaceholder.HostPath(r.binding.LocalRoot(), r.binding.RemoteRoot(), filepath.Join(commonDir, "info", "exclude"))
	if !ok {
		return &remoteFileError{reason: errRemoteFileFailed, cause: errRemoteOutsideFolder}
	}
	session := r.binding.SessionID()
	if session == "" {
		return &remoteFileError{reason: errRemoteDisconnected}
	}
	existing, version, err := r.readHost(ctx, session, host, remoteInfoExcludeLimit)
	expected := &version
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// Git creates info/ from its template, which a repository may have done without.
		expected = nil
		dirCtx, cancel := context.WithTimeout(ctx, remoteDocumentTimeout)
		err = r.kernel.RemoteCreateDirectory(dirCtx, session, path.Dir(host))
		cancel()
		if err != nil {
			return r.failed(session, err)
		}
	case err != nil:
		return err
	}
	addition, ok := infoExcludeAddition(existing, pattern)
	if !ok {
		return nil
	}
	return r.write(ctx, session, host, append(existing, addition...), expected)
}
