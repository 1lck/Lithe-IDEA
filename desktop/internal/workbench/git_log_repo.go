package workbench

import (
	"context"
	"path/filepath"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file keeps which repository the Git log walks (matrix id git-multi-repository-references).
// Core picks it from the repositories of the folder: the one the user picked while it is listed,
// otherwise the project's own, otherwise the first nested one, so a folder that is no repository
// itself walks its first nested repository. A click on a root of the Paths filter, or on a group or
// a reference of another repository in the reference pane, picks that repository: its history,
// commit details, comparisons, fetches and branch writes then act on it, and the log's header names
// it. The roots list chooses several repositories too, and the log then shows their commits
// together (gitlog_multi.go). The other repositories' references are read in nested_refs.go.

// logHasRepository reports whether the log already has a repository to walk. Until the project's
// Git status confirms p.root is a repository or Core selects a nested one, querying references at
// p.root would fail on non-repository folders and pollute the Git console.
func (p *project) logHasRepository() bool {
	return p.walksSeveral() || p.logRepo() != nil || p.git.isRepository()
}

// logRepo is the nested repository the log walks, nil while it walks the project's own.
func (p *project) logRepo() *nestedRepo {
	repo, ok := p.nested.repo(p.nested.logRepo)
	if !ok {
		return nil
	}
	return repo
}

// logRepoID is Core's ID of the repository the log walks.
func (p *project) logRepoID() string {
	if repo := p.logRepo(); repo != nil {
		return repo.id
	}
	return p.ownID()
}

// logRoot is the root the log reads the repository it walks from: the project folder for the
// project's own repository, as the log always read it, and the nested repository's root otherwise.
func (p *project) logRoot() string {
	if repo := p.logRepo(); repo != nil {
		return repo.root
	}
	return p.root
}

// logRepositoryRoot is the root of the repository the log walks, where Git writes act.
func (p *project) logRepositoryRoot() string {
	if repo := p.logRepo(); repo != nil {
		return repo.root
	}
	return p.git.repositoryRoot(p.root)
}

// logBranchRepo is what the branch dialogs act on when the log opened them: the nested repository's
// root, or empty for the project's own repository, which the branch popup uses too.
func (p *project) logBranchRepo() string {
	if repo := p.logRepo(); repo != nil {
		return repo.root
	}
	return ""
}

// repositoryName is the name a repository shows, Core's name for it: the folder name of the
// project's own repository and the path in the project folder of a nested one. The empty ID and
// commitRepositoryID are the own one.
func (p *project) repositoryName(id string) string {
	if p.isOwnID(id) {
		if own, ok := p.nested.own(); ok {
			return own.Name
		}
		return filepath.Base(p.git.repositoryRoot(p.root))
	}
	if repo, ok := p.nested.repo(id); ok && repo.name != "" {
		return repo.name
	}
	return id
}

// selectLogRepo asks Core which repository the log walks now that the repositories were read
// again, and the ones its reference pane lists besides. When Core falls back from the one walked,
// or picks a nested one because the folder is no repository, the log walks that one from its start.
func (a *App) selectLogRepo(p *project) {
	if p.logReads.retired {
		return
	}
	n := &p.nested
	if p.walksSeveral() {
		a.selectLogRepos(p)
		return
	}
	selection, ok := a.workspaceSelection(p, n.logRepo)
	if !ok {
		return
	}
	n.others = selection.Others
	active := selection.Active
	if _, nested := n.repo(active); !nested {
		active = ""
	}
	changed := active != n.logRepo
	if changed {
		a.releaseLogCursor(p)
		n.logRepo = active
		p.log.reference, p.log.referenceLabel, p.log.refSelected = "", "", ""
	}
	a.refreshSelectedLogRepo(p, changed)
}

// refreshSelectedLogRepo refreshes after applying current discovery and Core's root selection.
func (a *App) refreshSelectedLogRepo(p *project, changed bool) {
	reload := false
	if r := p.remote; r != nil && r.logNeedsReload {
		r.logNeedsReload = false
		reload = p.walksSeveral() || p.logRepo() != nil
	}
	// The reference pane lists the other repositories' references, so they are read again once the
	// repositories are.
	if p.log.started {
		if changed || reload {
			a.loadLog(p)
		} else {
			a.loadNestedReferences(p)
		}
	}
}

// setLogRepo makes the repository with ID the one the log walks, "" or the project's own ID for the
// project's own repository, and reads its log once. full, when given, is the reference the log then
// walks in it, short its name.
func (a *App) setLogRepo(p *project, id, full, short string) {
	if p.logReads.retired {
		return
	}
	if p.isOwnID(id) {
		id = ""
	}
	if p.nested.logRepo == id && full == "" && !p.walksSeveral() {
		return
	}
	// The history walk belongs to the repository it was opened in, so it is closed before the switch.
	a.releaseLogCursor(p)
	p.nested.logRepo, p.nested.chosen = id, nil
	if selection, ok := a.workspaceSelection(p, id); ok {
		p.nested.others = selection.Others
	}
	l := &p.log
	l.reference, l.referenceLabel, l.refSelected = full, short, full
	a.loadLog(p)
}

// workspaceSelection asks Core which repository a view acts on, given the ID of the one the log
// walks, "" for the project's own. It reports false, after logging why, when Core cannot answer.
func (a *App) workspaceSelection(p *project, picked string) (core.WorkspaceRepositorySelection, bool) {
	discoverer, ok := a.kernel.(repositoryDiscoverer)
	if !ok {
		return core.WorkspaceRepositorySelection{}, false
	}
	n := &p.nested
	if picked == "" {
		if own, ok := n.own(); ok {
			picked = own.ID
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	selection, err := discoverer.SelectWorkspaceRepository(ctx, n.discovered, picked)
	if err != nil {
		a.backgroundFailed("workspace_repository_selection", err)
		return core.WorkspaceRepositorySelection{}, false
	}
	return selection, true
}

// selectLogRepos asks Core which of the repositories the log walks together are still listed once
// the repositories were read again. When some are gone the log walks the ones left, or the one Core
// falls back to, from its start.
func (a *App) selectLogRepos(p *project) {
	n := &p.nested
	selection, ok := a.workspaceRepositories(p, n.chosen)
	if !ok {
		return
	}
	changed := !slices.Equal(selection.Chosen, n.chosen)
	if changed {
		a.applyLogRepos(p, selection)
	} else {
		n.others = selection.Others
	}
	a.refreshSelectedLogRepo(p, changed)
}

// releaseLogCursor closes the history walks of the log, when they are open, in the repositories
// they were opened in.
func (a *App) releaseLogCursor(p *project) {
	owner, cursors := a.takeOwnedLogCursors(p)
	p.log.walks, p.log.origins, p.log.pending = nil, nil, nil
	a.queueLogCursorClose(p, owner, cursors)
}

type logCursor struct{ root, token string }

func (a *App) takeOwnedLogCursors(p *project) (context.Context, []logCursor) {
	cursors := p.log.takeLogCursors()
	owner := p.log.cursorOwner
	p.log.cursorOwner = nil
	if len(cursors) != 0 && owner == nil {
		owner = core.SnapshotRemoteWorkspace(p.ctx)
	}
	if owner != nil {
		owner = a.operationContext(owner)
	}
	return owner, cursors
}

func (l *gitLogState) takeLogCursors() []logCursor {
	l.stopGitLogRead()
	if l.windowCancel != nil {
		l.windowCancel()
		l.windowCancel = nil
	}
	var cursors []logCursor
	if l.cursor != "" {
		cursors = append(cursors, logCursor{l.cursorRoot, l.cursor})
	}
	for i := range l.walks {
		walk := &l.walks[i]
		if walk.cursor != "" {
			cursors = append(cursors, logCursor{walk.root, walk.cursor})
			walk.cursor, walk.resumeToken = "", ""
		}
	}
	l.cursor, l.resumeToken, l.cursorRoot, l.hasMore = "", "", "", false
	return cursors
}

func (a *App) closeLogCursors(ctx context.Context, kernel historyPager, cursors []logCursor) {
	remote := core.RemoteWorkspaceOf(ctx) != nil
	for _, cursor := range cursors {
		if _, err := kernel.CloseGitHistoryCursor(ctx, cursor.root, cursor.token); err != nil {
			if remote {
				err = remoteLogError(err)
			}
			a.backgroundFailedIn(ctx, "git_log_cursor_close", err)
			if ctx.Err() != nil {
				return
			}
		}
	}
}

const remoteLogCloseTimeout = 3 * time.Second

func (a *App) logCursorCloser(owner context.Context, pager historyPager) func(root, cursor string) {
	return func(root, cursor string) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(owner), remoteLogCloseTimeout)
		defer cancel()
		a.closeLogCursors(ctx, pager, []logCursor{{root, cursor}})
	}
}

func (l *gitLogState) stopLogPublication() {
	l.gen++
	l.loading, l.loadingMore = false, false
	l.projGen++
	if l.projStop != nil {
		close(l.projStop)
		l.projStop = nil
	}
}

// prepareLogClose stops publication and returns the background cleanup of published and pending
// results. A remote workspace runs the cleanup before disconnecting its session.
func (a *App) prepareLogClose(p *project, waitTimeout time.Duration) func(context.Context) {
	reads := &p.logReads
	if reads.retired {
		return nil
	}
	reads.retired = true
	p.log.stopLogPublication()
	p.log.stopLogSelection()
	owner, cursors := a.takeOwnedLogCursors(p)
	kernel := a.kernel
	return func(ctx context.Context) {
		wait, stopWaiting := context.WithTimeout(ctx, waitTimeout)
		err := reads.running.WaitContext(wait)
		stopWaiting()
		if err != nil {
			a.backgroundFailedIn(ctx, "git_log_reads_close", err)
		}
		// A read can still have returned a cursor when the wait expired. Give cleanup
		// its own deadline before taking ownership of those results.
		cleanup, cancel := context.WithTimeout(ctx, remoteLogCloseTimeout)
		defer cancel()
		for read, cursors := range reads.takeForClose() {
			a.closeLogCursors(core.WithRemoteWorkspace(cleanup, core.RemoteWorkspaceOf(read.owner)), kernel, cursors)
		}
		if len(cursors) != 0 {
			a.closeLogCursors(core.WithRemoteWorkspace(cleanup, core.RemoteWorkspaceOf(owner)), kernel, cursors)
		}
	}
}
