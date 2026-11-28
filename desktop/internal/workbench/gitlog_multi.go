package workbench

import (
	"context"
	"errors"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file is the Git log that walks several repositories of the project folder at once (matrix
// id git-multi-repository-references), as IntelliJ IDEA's log shows the roots of a project with
// several. The roots list, under the Paths filter and behind the repository name after the filter
// chips, chooses them (gitlog_popover_view.go, git_log_repo.go). Each repository's
// history is read a page at a time; Core interleaves what is loaded by date, each repository in its
// own order (git.workspaceHistoryMerge), and lays the merged list out as one graph whose keys keep
// the repositories apart. Each row is marked in its repository's color, and what a row does, its
// files, details and commit menu, acts on its own repository.

// historyMerger is the part of the kernel a log of several repositories uses. Core's client
// implements it; a kernel that does not walks one repository at a time.
type historyMerger interface {
	SelectWorkspaceRepositories(ctx context.Context, repositories []core.WorkspaceRepository, chosen []string) (core.WorkspaceRepositorySelection, error)
	MergeWorkspaceHistories(ctx context.Context, histories []core.WorkspaceHistory) (core.WorkspaceHistoryMerge, error)
}

// errNoHistoryMerge is the failure of a log of several repositories with a kernel that cannot
// merge their histories.
var errNoHistoryMerge = errors.New("the kernel cannot merge repository histories")

// historyPager is the part of the kernel that reads a walk's pages.
type historyPager interface {
	GitHistoryPage(ctx context.Context, root, reference, cursor string, limit, maxCommits int, resumeToken ...string) (core.GitHistoryPage, error)
	CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error)
}

// readWalkPage reads the next page of w, at most room of the limit commits the log reads in all
// (the Git Log settings' limit for several repositories, which Core's git.workspaceHistoryMerge
// and git.graphProjection take). A first page asks Core to read the walk as far as that limit,
// so no walk stops at Core's own bound first. With no room left, a walk that was not complete
// ends where it is, its cursor closed and marked capped, and the merged list places everything
// it holds and says the log reached its limit.
func readWalkPage(ctx context.Context, pager historyPager, w *logWalk, room, limit int, closeCursor func(root, cursor string)) error {
	if room <= 0 {
		if w.cursor != "" {
			closeCursor(w.root, w.cursor)
		}
		w.capped = w.capped || !w.complete
		w.cursor, w.resumeToken, w.complete = "", "", true
		return nil
	}
	var page core.GitHistoryPage
	var err error
	pageSize := min(logPageSize, room)
	if w.cursor == "" {
		page, err = pager.GitHistoryPage(ctx, w.root, "", "", pageSize, limit, "")
	} else {
		page, err = readGitLogPage(ctx, pager, w.root, "", w.cursor, pageSize, w.resumeToken)
	}
	if err != nil {
		return err
	}
	w.commits = slices.Concat(w.commits, page.Commits)
	w.cursor, w.complete, w.capped = page.NextCursor, !page.HasMore, page.LimitReached
	w.resumeToken = page.ResumeToken
	return nil
}

// walkCommits is how many commits walks hold in all.
func walkCommits(walks []logWalk) int {
	n := 0
	for _, w := range walks {
		n += len(w.commits)
	}
	return n
}

// logWalk is the history of one repository the log walks with others, as far as it is loaded.
type logWalk struct {
	id, root    string
	commits     []core.GitCommit
	cursor      string
	resumeToken string
	complete    bool
	// own keeps the containing repository's UI identity when discovery gives it a relative ID.
	own bool
	// capped says the walk ended at the log's limit while its history goes on.
	capped bool
	// remotes are the names of the repository's remote branches, which the graph tells from its
	// local ones.
	remotes []string
}

// logOrigin is where a row of a log of several repositories comes from: the walk, the key the
// merged graph knows the commit by, and its parents' keys. A key is the hash unless two of the
// repositories name the same hash.
type logOrigin struct {
	walk    int
	key     string
	parents []string
}

// walksSeveral reports that the log walks several repositories at once.
func (p *project) walksSeveral() bool { return len(p.nested.chosen) > 1 }

// logChosen reports that the log walks the repository with ID, alone or among several.
func (p *project) logChosen(id string) bool {
	if p.walksSeveral() {
		return slices.Contains(p.nested.chosen, id)
	}
	return id == p.logRepoID()
}

// logCommitAt is the repository root and the hash of the loaded commit the log knows by key: the
// commit's own repository while the log walks several, the repository it walks otherwise.
func (p *project) logCommitAt(key string) (root, hash string) {
	l := &p.log
	if l.origins != nil {
		if i, ok := l.byHash[key]; ok && i < len(l.origins) {
			return l.walks[l.origins[i].walk].root, l.commits[i].Hash
		}
	}
	return p.logRepositoryRoot(), key
}

// logCommitRepo is the Core ID of the repository of the loaded commit the log knows by key.
func (p *project) logCommitRepo(key string) string {
	l := &p.log
	if l.origins != nil {
		if i, ok := l.byHash[key]; ok && i < len(l.origins) {
			return l.walks[l.origins[i].walk].id
		}
	}
	return p.logRepoID()
}

// logCommitIdentity is stable when Core gives a commit a repository-qualified key.
type logCommitIdentity struct {
	repository, hash string
}

func (p *project) logCommitIdentity(key string) logCommitIdentity {
	l := &p.log
	if l.origins != nil {
		if i, ok := l.byHash[key]; ok && i < len(l.origins) {
			walk := &l.walks[l.origins[i].walk]
			if walk.own {
				return logCommitIdentity{commitRepositoryID, l.commits[i].Hash}
			}
			return logCommitIdentity{walk.id, l.commits[i].Hash}
		}
	}
	if repo := p.nested.logRepo; repo != "" {
		return logCommitIdentity{repo, key}
	}
	return logCommitIdentity{commitRepositoryID, key}
}

// referencesAt is the references of the repository at root as the reference pane last read them,
// for a branch dialog that acts in a repository other than the one the log reads its references
// with.
func (p *project) referencesAt(root string) core.GitReferences {
	var out core.GitReferences
	for _, repo := range p.workspaceRepositories() {
		if repo.root == root {
			for _, s := range p.nested.references[repo.id].sections {
				out.References = append(out.References, s.refs...)
			}
			break
		}
	}
	return out
}

// logBranchRepoAt is what the branch dialogs act on for a commit of root: the nested repository's
// root, or empty for the project's own repository.
func (p *project) logBranchRepoAt(root string) string {
	if root == p.git.repositoryRoot(p.root) {
		return ""
	}
	return root
}

// loadLogRepos reads the first page of each repository the log walks, has Core merge them and lay
// the merged list out, and reads the references of the first one for the reference pane.
func (a *App) loadLogRepos(p *project, gen int) {
	l := &p.log
	merger, ok := a.kernel.(historyMerger)
	if !ok {
		l.loading, l.err = false, errNoHistoryMerge
		return
	}
	kernel, active, expanded, limit := a.kernel, p.logRoot(), l.expanded, a.gitLogMergedLimit()
	walks := make([]logWalk, 0, len(p.nested.chosen))
	for _, id := range p.nested.chosen {
		if root := p.rootOf(id); root != "" {
			walks = append(walks, logWalk{id: id, root: root, own: p.isOwnID(id)})
		}
	}
	owner := p.ctx
	l.readCancel = a.backgroundLogRead(p, func(ctx context.Context) logReadResult {
		closeCursor := a.logCursorCloser(ctx, kernel)
		refs, sections, current, err := readReferences(ctx, kernel, active)
		for i := range walks {
			if err != nil {
				break
			}
			w := &walks[i]
			if err = readWalkPage(ctx, kernel, w, limit-walkCommits(walks), limit, closeCursor); err != nil {
				break
			}
			if i == 0 {
				w.remotes = remoteNames(sections)
			} else if theirs, rerr := kernel.GitReferences(ctx, w.root); rerr == nil {
				w.remotes = remoteRefNames(theirs.References)
			}
		}
		var commits []core.GitCommit
		var origins []logOrigin
		var pending []int
		var graph core.Graph
		if err == nil {
			commits, origins, pending, err = mergeLogWalks(ctx, merger, walks)
		}
		if err == nil {
			input := graphInput(commits, origins)
			// Each repository's own current branch gets the background, as IDEA reads the branch of
			// each commit's root.
			graph, err = kernel.GitGraph(ctx, core.GraphRequest{
				Commits: input, RemoteNames: walkRemotes(walks), RepositoryCommits: input, Expanded: expanded,
				CheckedOutHeads: true,
			})
		}
		return logReadResult{logWalkCursors(walks), func(a *App) bool {
			if a.project != p || l.gen != gen || owner.Err() != nil {
				return false
			}
			l.stopGitLogRead()
			l.loading = false
			if err != nil {
				l.err = err
				l.refs, l.sections, l.current = core.GitReferences{}, [3]logSection{}, ""
				return false
			}
			l.refs, l.sections, l.current = refs, sections, current
			l.walks = walks
			l.setMerged(commits, origins, pending)
			l.setGraph(graph)
			if l.filtered() {
				a.reproject(p, 0)
			}
			return true
		}}
	})
}

// loadMoreLogRepos reads the pages still needed for this merge and keeps any
// consumed pages if a later read or merge fails.
func (a *App) loadMoreLogRepos(p *project) {
	l := &p.log
	merger, ok := a.kernel.(historyMerger)
	if !ok || l.loading || !l.hasMore || l.loadingMore || l.moreFailed {
		return
	}
	l.loadingMore = true
	gen, kernel, limit := l.gen, a.kernel, a.gitLogMergedLimit()
	walks := slices.Clone(l.walks)
	pending := l.pending
	owner := p.ctx
	l.readCancel = a.backgroundLogRead(p, func(ctx context.Context) logReadResult {
		closeCursor := a.logCursorCloser(ctx, kernel)
		var err error
		for len(pending) > 0 {
			w := &walks[pending[0]]
			if !w.complete && w.cursor != "" {
				if err = readWalkPage(ctx, kernel, w, limit-walkCommits(walks), limit, closeCursor); err != nil {
					break
				}
			}
			pending = pending[1:]
		}
		var commits []core.GitCommit
		var origins []logOrigin
		var nextPending []int
		var merged *logMergedPage
		if err == nil {
			commits, origins, nextPending, err = mergeLogWalks(ctx, merger, walks)
			if err == nil {
				merged = newLogMergedPage(commits, origins)
			}
		}
		return logReadResult{logWalkCursors(walks), func(a *App) bool {
			if a.project != p || l.gen != gen || owner.Err() != nil {
				return false
			}
			l.stopGitLogRead()
			l.loadingMore = false
			l.walks = walks
			if errors.Is(err, errLogHistoryChanged) {
				a.loadLog(p)
				return true
			}
			if err != nil {
				l.pending = pending
				l.moreFailed = true
				return true
			}
			l.setMergedPaging(nextPending)
			l.stagedMerge = merged
			a.reproject(p, 0)
			return true
		}}
	})
}

// setMerged keeps the merged list of the walks and what it waits on, and whether a walk ended at
// the log's limit.
func (l *gitLogState) setMerged(commits []core.GitCommit, origins []logOrigin, pending []int) {
	l.publishMerged(newLogMergedPage(commits, origins))
	l.setMergedPaging(pending)
}

// A later page can cause Core to disambiguate a previously published hash with
// its repository ID. Keep these identities with the graph that uses them.
type logMergedPage struct {
	commits []core.GitCommit
	origins []logOrigin
	byHash  map[string]int
}

func newLogMergedPage(commits []core.GitCommit, origins []logOrigin) *logMergedPage {
	byHash := make(map[string]int, len(origins))
	for i, origin := range origins {
		byHash[origin.key] = i
	}
	return &logMergedPage{commits: commits, origins: origins, byHash: byHash}
}

func (l *gitLogState) publishMerged(page *logMergedPage) {
	l.commits, l.origins, l.byHash = page.commits, page.origins, page.byHash
	l.stagedMerge = nil
}

// selectedMergedKey follows the selected repository and commit when Core
// qualifies its key. The merge keeps previously placed commits in order.
func (l *gitLogState) selectedMergedKey(page *logMergedPage) string {
	if _, ok := page.byHash[l.selected]; ok {
		return l.selected
	}
	i, ok := l.byHash[l.selected]
	if !ok || i >= len(page.origins) || l.origins[i].walk != page.origins[i].walk || l.commits[i].Hash != page.commits[i].Hash {
		return ""
	}
	return page.origins[i].key
}

func (l *gitLogState) setMergedPaging(pending []int) {
	l.pending = pending
	l.cursor, l.resumeToken, l.hasMore = "", "", len(pending) > 0
	l.limitReached = slices.ContainsFunc(l.walks, func(w logWalk) bool { return w.capped })
}

// mergeLogWalks has Core merge the loaded commits of walks and returns the merged list, where
// each of its rows comes from, and the walks whose next page the list waits on.
func mergeLogWalks(ctx context.Context, merger historyMerger, walks []logWalk) ([]core.GitCommit, []logOrigin, []int, error) {
	histories := make([]core.WorkspaceHistory, len(walks))
	for i, w := range walks {
		commits := make([]core.WorkspaceHistoryCommit, len(w.commits))
		for j, c := range w.commits {
			commits[j] = core.WorkspaceHistoryCommit{Hash: c.Hash, ParentHashes: c.ParentHashes, Timestamp: c.DateUnixSeconds}
		}
		histories[i] = core.WorkspaceHistory{ID: w.id, Commits: commits, Complete: w.complete}
	}
	merged, err := merger.MergeWorkspaceHistories(ctx, histories)
	if err != nil {
		return nil, nil, nil, err
	}
	commits := make([]core.GitCommit, 0, len(merged.Entries))
	origins := make([]logOrigin, 0, len(merged.Entries))
	for _, e := range merged.Entries {
		if e.Repository < 0 || e.Repository >= len(walks) || e.Index < 0 || e.Index >= len(walks[e.Repository].commits) {
			continue
		}
		commits = append(commits, walks[e.Repository].commits[e.Index])
		origins = append(origins, logOrigin{walk: e.Repository, key: e.Key, parents: e.ParentKeys})
	}
	return commits, origins, merged.Pending, nil
}

// graphInput is what the graph is laid out from: the commits, under their merged keys when
// origins are given.
func graphInput(commits []core.GitCommit, origins []logOrigin) []core.GraphCommit {
	out := graphCommits(commits)
	if origins == nil {
		return out
	}
	for i := range out {
		out[i].Hash, out[i].ParentHashes = origins[i].key, origins[i].parents
	}
	return out
}

// logKeys are the keys of the merged list's rows, nil while the log walks one repository.
func logKeys(origins []logOrigin) []string {
	if origins == nil {
		return nil
	}
	keys := make([]string, len(origins))
	for i, origin := range origins {
		keys[i] = origin.key
	}
	return keys
}

// logRoots are the repository roots of the merged list's rows, nil while the log walks one
// repository.
func logRoots(walks []logWalk, origins []logOrigin) []string {
	if origins == nil {
		return nil
	}
	roots := make([]string, len(origins))
	for i, origin := range origins {
		roots[i] = walks[origin.walk].root
	}
	return roots
}

// logRemoteNames are the remote branch names the graph tells from local ones: those of every
// repository the log walks.
func (l *gitLogState) logRemoteNames() []string {
	if l.walks != nil {
		return walkRemotes(l.walks)
	}
	return remoteNames(l.sections)
}

// walkRemotes are the remote branch names of walks, each once.
func walkRemotes(walks []logWalk) []string {
	var names []string
	for _, w := range walks {
		for _, name := range w.remotes {
			if !slices.Contains(names, name) {
				names = append(names, name)
			}
		}
	}
	return names
}

// remoteRefNames are the short names of the remote branches among refs.
func remoteRefNames(refs []core.GitReference) []string {
	var names []string
	for _, r := range refs {
		if r.Kind == "remote" {
			names = append(names, r.ShortName)
		}
	}
	return names
}

func logWalkCursors(walks []logWalk) []logCursor {
	var cursors []logCursor
	for _, w := range walks {
		if w.cursor != "" {
			cursors = append(cursors, logCursor{w.root, w.cursor})
		}
	}
	return cursors
}

// chooseLogRepos makes the log walk the repositories with ids, in the order Core lists them, and
// reads it again. One repository walks it alone, as setLogRepo does.
func (a *App) chooseLogRepos(p *project, ids []string) {
	if p.logReads.retired {
		return
	}
	if len(ids) == 1 {
		a.setLogRepo(p, ids[0], "", "")
		return
	}
	if len(ids) == 0 {
		return
	}
	selection, ok := a.workspaceRepositories(p, ids)
	if !ok {
		return
	}
	a.applyLogRepos(p, selection)
	a.loadLog(p)
}

// toggleLogRoot adds the repository with ID to the ones the log walks, or takes it out, and
// reads the log again. The last repository stays.
func (a *App) toggleLogRoot(p *project, id string) {
	chosen := p.nested.chosen
	if !p.walksSeveral() {
		chosen = []string{p.logRepoID()}
	}
	if i := slices.Index(chosen, id); i >= 0 {
		if len(chosen) == 1 {
			return
		}
		chosen = slices.Delete(slices.Clone(chosen), i, i+1)
	} else {
		chosen = append(slices.Clone(chosen), id)
	}
	a.chooseLogRepos(p, chosen)
}

// workspaceRepositories asks Core which of the repositories with ids the log walks, in its order.
// It reports false, after logging why, when Core cannot answer.
func (a *App) workspaceRepositories(p *project, ids []string) (core.WorkspaceRepositorySelection, bool) {
	merger, ok := a.kernel.(historyMerger)
	if !ok {
		return core.WorkspaceRepositorySelection{}, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	selection, err := merger.SelectWorkspaceRepositories(ctx, p.nested.discovered, ids)
	if err != nil {
		a.backgroundFailed("workspace_repository_selection", err)
		return core.WorkspaceRepositorySelection{}, false
	}
	return selection, true
}

// applyLogRepos makes Core's selection of several repositories the ones the log walks. It closes
// the history walks of the repositories it walked before and drops the reference it walked, which
// belonged to one repository.
func (a *App) applyLogRepos(p *project, selection core.WorkspaceRepositorySelection) {
	a.releaseLogCursor(p)
	n := &p.nested
	n.others = selection.Others
	n.chosen = nil
	if len(selection.Chosen) > 1 {
		n.chosen = selection.Chosen
	}
	active := selection.Active
	if _, nested := n.repo(active); !nested {
		active = ""
	}
	n.logRepo = active
	p.log.reference, p.log.referenceLabel, p.log.refSelected = "", "", ""
}
