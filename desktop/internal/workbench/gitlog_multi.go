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

// mergedLogLimit is how many commits a log of several repositories reads in all: Core's
// git.workspaceHistoryMerge and git.graphProjection take at most 20,000 (rust-core-api.md). Once
// the walks hold that many, each ends where it is, so the merged list ends there the way one
// repository's log ends after the 5,000 commits git.historyPage returns.
const mergedLogLimit = 20000

// historyPager is the part of the kernel that reads a walk's pages.
type historyPager interface {
	GitHistoryPage(ctx context.Context, root, reference, cursor string, limit int) (core.GitHistoryPage, error)
	CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error)
}

// readWalkPage reads the next page of w, at most room commits of it. With no room left, w ends
// where it is: its cursor is closed, and the merged list places everything it holds.
func readWalkPage(ctx context.Context, pager historyPager, w *logWalk, room int) error {
	if room <= 0 {
		if w.cursor != "" {
			_, _ = pager.CloseGitHistoryCursor(ctx, w.root, w.cursor)
		}
		w.cursor, w.complete = "", true
		return nil
	}
	page, err := pager.GitHistoryPage(ctx, w.root, "", w.cursor, min(logPageSize, room))
	if err != nil {
		return err
	}
	w.commits = slices.Concat(w.commits, page.Commits)
	w.cursor, w.complete = page.NextCursor, !page.HasMore
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
	id, root string
	commits  []core.GitCommit
	cursor   string
	complete bool
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
	kernel, active, expanded := a.kernel, p.logRoot(), l.expanded
	walks := make([]logWalk, 0, len(p.nested.chosen))
	for _, id := range p.nested.chosen {
		if root := p.rootOf(id); root != "" {
			walks = append(walks, logWalk{id: id, root: root})
		}
	}
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		refs, sections, current, err := readReferences(ctx, kernel, active)
		for i := range walks {
			if err != nil {
				break
			}
			w := &walks[i]
			if err = readWalkPage(ctx, kernel, w, mergedLogLimit-walkCommits(walks)); err != nil {
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
			graph, err = kernel.GitGraph(ctx, core.GraphRequest{
				Commits: input, RemoteNames: walkRemotes(walks), RepositoryCommits: input, Expanded: expanded,
			})
		}
		return func(a *App) {
			if l.gen != gen {
				a.closeWalkCursors(p, walks)
				return
			}
			l.loading = false
			if err != nil {
				a.closeWalkCursors(p, walks)
				l.err = err
				l.refs, l.sections, l.current = core.GitReferences{}, [3]logSection{}, ""
				return
			}
			l.refs, l.sections, l.current = refs, sections, current
			l.walks = walks
			l.setMerged(commits, origins, pending)
			l.setGraph(graph)
			if l.filtered() {
				a.reproject(p, 0)
			}
		}
	})
}

// loadMoreLogRepos reads the next page of each repository the merged list waits on and merges
// again; the rows placed before stay where they were.
func (a *App) loadMoreLogRepos(p *project) {
	l := &p.log
	merger, ok := a.kernel.(historyMerger)
	if !ok || l.loading || !l.hasMore || l.loadingMore || l.moreFailed || len(l.pending) == 0 {
		return
	}
	l.loadingMore = true
	gen, kernel := l.gen, a.kernel
	walks := slices.Clone(l.walks)
	pending := slices.Clone(l.pending)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		var err error
		for _, i := range pending {
			w := &walks[i]
			if w.complete || w.cursor == "" {
				continue
			}
			if err = readWalkPage(ctx, kernel, w, mergedLogLimit-walkCommits(walks)); err != nil {
				break
			}
		}
		var commits []core.GitCommit
		var origins []logOrigin
		if err == nil {
			commits, origins, pending, err = mergeLogWalks(ctx, merger, walks)
		}
		return func(a *App) {
			if l.gen != gen {
				a.closeWalkCursors(p, walks)
				return
			}
			l.loadingMore = false
			if err != nil {
				l.moreFailed = true
				return
			}
			l.walks = walks
			l.setMerged(commits, origins, pending)
			a.reproject(p, 0)
		}
	})
}

// setMerged keeps the merged list of the walks and what it waits on.
func (l *gitLogState) setMerged(commits []core.GitCommit, origins []logOrigin, pending []int) {
	l.commits, l.origins, l.pending = commits, origins, pending
	l.byHash = make(map[string]int, len(origins))
	for i := range origins {
		l.byHash[origins[i].key] = i
	}
	l.cursor, l.hasMore = "", len(pending) > 0
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
func (l *gitLogState) logKeys() []string {
	if l.origins == nil {
		return nil
	}
	keys := make([]string, len(l.origins))
	for i := range l.origins {
		keys[i] = l.origins[i].key
	}
	return keys
}

// logRoots are the repository roots of the merged list's rows, nil while the log walks one
// repository.
func (l *gitLogState) logRoots() []string {
	if l.origins == nil {
		return nil
	}
	roots := make([]string, len(l.origins))
	for i := range l.origins {
		roots[i] = l.walks[l.origins[i].walk].root
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

// closeWalkCursors releases the history walks of walks the log no longer continues.
func (a *App) closeWalkCursors(p *project, walks []logWalk) {
	kernel := a.kernel
	type open struct{ root, cursor string }
	var cursors []open
	for _, w := range walks {
		if w.cursor != "" {
			cursors = append(cursors, open{w.root, w.cursor})
		}
	}
	if len(cursors) == 0 {
		return
	}
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		for _, c := range cursors {
			_, _ = kernel.CloseGitHistoryCursor(ctx, c.root, c.cursor)
		}
		return nil
	})
}

// chooseLogRepos makes the log walk the repositories with ids, in the order Core lists them, and
// reads it again. One repository walks it alone, as setLogRepo does.
func (a *App) chooseLogRepos(p *project, ids []string) {
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
