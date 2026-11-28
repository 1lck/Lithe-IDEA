package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

type mergedLogRetryKernel struct {
	gitKernel
	pages         map[string][]core.GitCommit
	pageReads     []string
	closed        []string
	failedRoot    string
	failedMerge   bool
	failedGraph   bool
	mergeWithCore bool
}

func (k *mergedLogRetryKernel) GitHistoryPage(_ context.Context, root, _, cursor string, _, _ int) (core.GitHistoryPage, error) {
	k.pageReads = append(k.pageReads, cursor)
	if root == k.failedRoot {
		k.failedRoot = ""
		return core.GitHistoryPage{}, errors.New("transient repository read failure")
	}
	commits := k.pages[root]
	if len(commits) == 0 {
		return core.GitHistoryPage{}, errors.New("the test stream is exhausted")
	}
	k.pages[root] = commits[1:]
	page := core.GitHistoryPage{Commits: commits[:1]}
	if len(commits) > 1 {
		page.NextCursor, page.HasMore = cursor, true
	}
	return page, nil
}

func (k *mergedLogRetryKernel) CloseGitHistoryCursor(ctx context.Context, _, cursor string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	k.closed = append(k.closed, cursor)
	return true, nil
}

func (k *mergedLogRetryKernel) MergeWorkspaceHistories(ctx context.Context, histories []core.WorkspaceHistory) (core.WorkspaceHistoryMerge, error) {
	if k.mergeWithCore {
		return k.gitKernel.MergeWorkspaceHistories(ctx, histories)
	}
	if k.failedMerge {
		k.failedMerge = false
		return core.WorkspaceHistoryMerge{}, errors.New("transient merge failure")
	}
	var merged core.WorkspaceHistoryMerge
	for i := 0; i < max(len(histories[0].Commits), len(histories[1].Commits)); i++ {
		for repository, history := range histories {
			if i < len(history.Commits) {
				merged.Entries = append(merged.Entries, core.WorkspaceHistoryEntry{
					Repository: repository, Index: i, Key: history.Commits[i].Hash,
				})
			}
		}
	}
	return merged, nil
}

func (k *mergedLogRetryKernel) GitGraph(_ context.Context, request core.GraphRequest) (core.Graph, error) {
	if k.failedGraph {
		k.failedGraph = false
		return core.Graph{}, errors.New("transient graph projection failure")
	}
	rows := make([]core.GraphRow, len(request.Commits))
	for i, commit := range request.Commits {
		rows[i].CommitHash = commit.Hash
	}
	return core.Graph{Rows: rows}, nil
}

func TestMergedLogPublishesRowOriginsWithTheProjection(t *testing.T) {
	const sharedHash = "bbbbbbbb"
	k := &mergedLogRetryKernel{
		gitKernel: gitKernel{core.NewClient()},
		pages: map[string][]core.GitCommit{
			"/a": {{Hash: "cccccccc", ParentHashes: []string{sharedHash}}},
		},
		mergeWithCore: true,
	}
	p := &project{ctx: t.Context(), root: "/a"}
	a := &App{project: p, kernel: k, text: i18n.For(i18n.English), now: time.Now}
	t.Cleanup(func() { waitForLogCursorLifecycle(t, a) })
	l := &p.log
	newer, older := int64(2), int64(1)
	l.walks = []logWalk{
		{id: "a", root: "/a", commits: []core.GitCommit{{Hash: "aaaaaaaa", DateUnixSeconds: &older}}, cursor: "a-cursor"},
		{id: "b", root: "/b", commits: []core.GitCommit{{Hash: sharedHash, DateUnixSeconds: &newer}}, complete: true},
	}
	commits, origins, pending, err := mergeLogWalks(t.Context(), k, l.walks)
	if err != nil {
		t.Fatal(err)
	}
	l.setMerged(commits, origins, pending)
	graph, err := k.GitGraph(t.Context(), core.GraphRequest{Commits: graphInput(commits, origins)})
	if err != nil {
		t.Fatal(err)
	}
	l.setGraph(graph)
	row := l.visibleRow(sharedHash)
	if row < 0 {
		t.Fatal("the initial graph must contain the unsuffixed commit from repository B")
	}
	checkRow := func(row int, key string) {
		t.Helper()
		root, keys, hashes := a.logMenuTarget(p, row)
		if l.visibleRow(key) != row || root != "/b" || !slices.Equal(keys, []string{key}) || !slices.Equal(hashes, []string{sharedHash}) {
			t.Fatalf("row %d for %q targets %s %q %q, want repository B and hash %s", row, key, root, keys, hashes, sharedHash)
		}
	}
	checkRow(row, sharedHash)
	l.selected, l.filesState = sharedHash, logFilesReady
	l.files = []core.GitCommitFile{{Path: "changed-in-b.txt"}}
	rowKey := a.logCommitKey(row)

	k.failedGraph = true
	a.loadMoreLogRepos(p)
	waitForLogCursorLifecycle(t, a)
	a.drain()
	checkRow(row, sharedHash)
	waitForLogCursorLifecycle(t, a)
	a.drain()
	if !l.projFailed {
		t.Fatal("the replacement projection did not fail")
	}
	checkRow(row, sharedHash)

	a.reproject(p, 0)
	waitForLogCursorLifecycle(t, a)
	a.drain()
	disambiguated := sharedHash + "@b"
	checkRow(l.visibleRow(disambiguated), disambiguated)
	root, hash := p.logCommitAt(l.selected)
	if l.selected != disambiguated || root != "/b" || hash != sharedHash || len(l.files) != 1 || a.logCommitKey(l.visibleRow(disambiguated)) != rowKey {
		t.Fatalf("selection %q, files %v, and row key did not follow repository B, resolved %s %s", l.selected, l.files, root, hash)
	}
	if l.visibleRow(sharedHash) >= 0 || len(k.pageReads) != 1 {
		t.Fatalf("retry kept the previous key or consumed another page: reads %v", k.pageReads)
	}
}

func TestMergedLogRetryKeepsConsumedPages(t *testing.T) {
	for _, tc := range []struct {
		name        string
		failedRoot  string
		failedMerge bool
		closed      bool
		wantReads   []string
	}{
		{name: "repository read", failedRoot: "/b", wantReads: []string{"a-cursor", "b-cursor", "b-cursor"}},
		{name: "merge", failedMerge: true, wantReads: []string{"a-cursor", "b-cursor"}},
		{name: "closed project", closed: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			k := &mergedLogRetryKernel{
				failedRoot: tc.failedRoot, failedMerge: tc.failedMerge,
				pages: map[string][]core.GitCommit{
					"/a": {{Hash: "a2"}, {Hash: "a3"}},
					"/b": {{Hash: "b2"}, {Hash: "b3"}},
				},
			}
			projectContext, cancelProject := context.WithCancel(context.Background())
			p := &project{ctx: projectContext}
			a := &App{project: p, kernel: k}
			wait := func() {
				t.Helper()
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				if err := a.tasks.running.WaitContext(ctx); err != nil {
					t.Fatalf("waiting for merged Git Log work: %v", err)
				}
			}
			t.Cleanup(func() {
				cancelProject()
				wait()
			})
			l := &p.log
			initial := []core.GitCommit{{Hash: "a1"}, {Hash: "b1"}}
			l.walks = []logWalk{
				{id: "a", root: "/a", commits: initial[:1:1], cursor: "a-cursor"},
				{id: "b", root: "/b", commits: initial[1:], cursor: "b-cursor"},
			}
			l.setMerged(initial, []logOrigin{{key: "a1"}, {walk: 1, key: "b1"}}, []int{0, 1})
			l.setGraph(core.Graph{Rows: []core.GraphRow{{CommitHash: "a1"}, {CommitHash: "b1"}}})

			a.loadMoreLog(p)
			wait()
			if tc.closed {
				// The successful read is queued when the window closes the project.
				cancelProject()
				a.project = nil
				a.drain()
				wait()
				if len(l.graph.Rows) != 2 || !slices.Equal(k.closed, []string{"a-cursor", "b-cursor"}) {
					t.Fatalf("discarding the continuation left %v and closed %v", l.graph.Rows, k.closed)
				}
				return
			}
			a.drain()
			if !l.moreFailed || len(l.graph.Rows) != 2 {
				t.Fatalf("failed continuation should leave the published graph available: %+v", l.graph.Rows)
			}

			l.moreFailed = false
			a.loadMoreLog(p)
			wait()
			a.drain()
			wait()
			a.drain()
			var hashes []string
			for _, row := range l.graph.Rows {
				hashes = append(hashes, row.CommitHash)
			}
			if !slices.Equal(hashes, []string{"a1", "b1", "a2", "b2"}) {
				t.Fatalf("retried graph contains %v, want both first continuation pages", hashes)
			}
			if !slices.Equal(k.pageReads, tc.wantReads) {
				t.Fatalf("read cursors %v, want %v", k.pageReads, tc.wantReads)
			}
		})
	}
}

// A folder holding repositories lists a node per repository in the Git Log's reference pane, each
// with its own sections, and a click on another repository's branch walks that branch there. The
// name after the filter chips lists the repositories: a second checked box merges both histories
// into one list by date, each commit in its repository's color, its details and its commit menu in
// its repository; unchecking a box walks the other repository alone again.
func TestWorkspaceLogWalksSeveralRepositoriesTogether(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openWorkspaceFolder(parent)
	alphaID, betaID := repositoryID(t, p, "alpha"), repositoryID(t, p, "beta")
	h.app.layout.gitTab = gitTabLog
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		h.click(center(h.button(itemGit)))
	}
	h.settleUntil("alpha's history and beta's references", func() bool {
		_, read := p.nested.references[betaID]
		return p.logRepoID() == alphaID && !p.log.loading && len(p.log.graph.Rows) == 1 && read
	})
	h.settle()

	v := &h.app.logView
	for _, id := range []string{alphaID, betaID} {
		node := slices.IndexFunc(v.refItems, func(r logRefRow) bool { return r.kind == logRefRepository && r.repo == id })
		if node < 0 || node+1 >= len(v.refItems) || v.refItems[node+1].kind != logRefSection || v.refItems[node+1].depth != 1 {
			t.Fatalf("repository %q has no node with its own sections in %+v", id, v.refItems)
		}
	}
	foreign := slices.IndexFunc(v.refItems, func(r logRefRow) bool {
		return r.kind == logRefForeign && r.repo == betaID && r.short == "main"
	})
	if foreign < 0 {
		t.Fatalf("beta's node lists no main branch in %+v", v.refItems)
	}
	h.click(center(h.topHit(v.refs.RowID(foreign))))
	h.settleUntil("beta's main", func() bool {
		return p.logRepoID() == betaID && p.log.reference == "refs/heads/main" && !p.log.loading && len(p.log.graph.Rows) == 1
	})

	lang, g := h.app.language(), h.app.text.Git.Repositories
	h.click(center(h.hitLabeled(g.Choose)))
	if p.log.popover != logPopoverRoots {
		t.Fatalf("popover %v after clicking the repository name, want the repository list", p.log.popover)
	}
	toggle := func(name string) {
		t.Helper()
		label := i18n.SharedFormat(lang, "desktop.nested.rootToggle", map[string]string{"name": name})
		h.click(center(h.hitLabeled(label)))
	}
	toggle("alpha")
	h.settleUntil("both histories in one list", func() bool {
		return p.walksSeveral() && !p.log.loading && len(p.log.graph.Rows) == 2
	})
	if p.log.reference != "" {
		t.Fatalf("the merged list walks reference %q, want every repository's HEAD", p.log.reference)
	}
	for _, subject := range []string{"initial alpha", "initial beta"} {
		if !h.shows(subject) {
			t.Fatalf("the merged list does not show %q", subject)
		}
	}
	if !h.shows(g.Several(2)) {
		t.Fatalf("the name after the chips is not %q", g.Several(2))
	}
	betaRow := -1
	repos := map[string]bool{}
	for i, row := range p.log.graph.Rows {
		id := p.logCommitRepo(row.CommitHash)
		repos[id] = true
		if id == betaID {
			betaRow = i
		}
	}
	if !repos[alphaID] || !repos[betaID] || betaRow < 0 {
		t.Fatalf("the merged rows belong to %v, want alpha and beta", repos)
	}
	// Each repository's checked-out branch has the current-branch background, as in IDEA, not only
	// the branch of the repository the log walked first.
	for _, row := range p.log.graph.Rows {
		if !p.log.currentRows[row.CommitHash] {
			t.Fatalf("commit %s of %s has no current-branch background in the merged list", row.CommitHash, p.logCommitRepo(row.CommitHash))
		}
	}

	root, _, hashes := h.app.logMenuTarget(p, betaRow)
	if filepath.Base(root) != "beta" || len(hashes) != 1 {
		t.Fatalf("beta's commit menu acts on %v in %q, want its commit in beta", hashes, root)
	}
	if want := gitRun(t, filepath.Join(parent, "beta"), "rev-parse", "HEAD"); hashes[0] != want {
		t.Fatalf("beta's commit menu acts on %q, want beta's HEAD %q", hashes[0], want)
	}
	h.app.selectCommit(p, p.log.graph.Rows[betaRow].CommitHash)
	h.settleUntil("beta's commit files", func() bool { return p.log.filesState == logFilesReady })
	if len(p.log.files) != 1 || p.log.files[0].Path != "beta.txt" {
		t.Fatalf("beta's commit lists %+v, want beta.txt read from beta", p.log.files)
	}

	toggle("alpha")
	h.settleUntil("beta alone again", func() bool {
		return !p.walksSeveral() && p.logRepoID() == betaID && !p.log.loading && len(p.log.graph.Rows) == 1
	})
	if !h.shows("initial beta") || h.shows("initial alpha") {
		t.Fatal("after unchecking alpha the log does not show beta's history alone")
	}
}

// endlessPager reads pages of a history that never ends and records the limits and the most
// commits it is asked for and the cursors it closes. With bound set, a walk ends there: the page
// that reaches it says LimitReached.
type endlessPager struct {
	limits     []int
	maxCommits []int
	closed     []string
	bound      bool
}

func (f *endlessPager) GitHistoryPage(_ context.Context, _, _, _ string, limit, maxCommits int) (core.GitHistoryPage, error) {
	f.limits, f.maxCommits = append(f.limits, limit), append(f.maxCommits, maxCommits)
	if f.bound {
		return core.GitHistoryPage{Commits: make([]core.GitCommit, limit), LimitReached: true}, nil
	}
	return core.GitHistoryPage{Commits: make([]core.GitCommit, limit), NextCursor: "next", HasMore: true}, nil
}

func (f *endlessPager) CloseGitHistoryCursor(_ context.Context, _, cursor string) (bool, error) {
	f.closed = append(f.closed, cursor)
	return true, nil
}

// A log of several repositories reads no more commits than its limit: the last page takes the
// room that is left, and a walk with none left ends where it is, its cursor closed and marked
// capped, so the merged list ends with a note instead of failing the next merge.
func TestMergedLogReadsNoMoreThanItsLimit(t *testing.T) {
	const limit = 20000
	ctx, pager := context.Background(), &endlessPager{}
	walks := []logWalk{
		{id: "a", root: "/a", commits: make([]core.GitCommit, limit-30), cursor: "a1"},
		{id: "b", root: "/b", cursor: "b1"},
		{id: "c", root: "/c"},
	}
	read := func(i int) {
		t.Helper()
		if err := readWalkPage(ctx, pager, &walks[i], limit-walkCommits(walks), limit, (&App{}).logCursorCloser(ctx, pager)); err != nil {
			t.Fatalf("walk %q: %v", walks[i].id, err)
		}
	}
	read(1)
	if len(walks[1].commits) != 30 || walks[1].complete || walks[1].cursor != "next" {
		t.Fatalf("the last page is %d commits, complete %v, cursor %q; want the 30 left and more to come",
			len(walks[1].commits), walks[1].complete, walks[1].cursor)
	}
	read(0)
	read(1)
	read(2)
	if !slices.Equal(pager.limits, []int{30}) || !slices.Equal(pager.maxCommits, []int{0}) {
		t.Fatalf("pages asked for %v up to %v, want one of the 30 left that goes on with its walk", pager.limits, pager.maxCommits)
	}
	if !slices.Equal(pager.closed, []string{"a1", "next"}) {
		t.Fatalf("closed cursors %v, want a's and b's and none for c, which read no page", pager.closed)
	}
	for _, w := range walks {
		if !w.complete || w.cursor != "" || !w.capped {
			t.Fatalf("walk %q is complete %v, capped %v, with cursor %q after the room ran out", w.id, w.complete, w.capped, w.cursor)
		}
	}
	if n := walkCommits(walks); n != limit {
		t.Fatalf("the walks hold %d commits, want %d", n, limit)
	}
	var l gitLogState
	l.walks = walks
	l.setMerged(nil, nil, nil)
	if !l.limitReached || l.hasMore {
		t.Fatalf("the merged log says limit reached %v, more %v; want the limit note and no more", l.limitReached, l.hasMore)
	}
}

// A walk's first page asks Core to read it as far as the log's limit, and a walk Core ends there
// is capped, while one that read its whole history is not.
func TestMergedLogWalkEndsAtCoresBound(t *testing.T) {
	ctx, pager := context.Background(), &endlessPager{bound: true}
	w := logWalk{id: "a", root: "/a"}
	if err := readWalkPage(ctx, pager, &w, 500, 500, (&App{}).logCursorCloser(ctx, pager)); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(pager.maxCommits, []int{500}) || !w.complete || !w.capped {
		t.Fatalf("first page asked up to %v; walk complete %v, capped %v; want 500, complete and capped", pager.maxCommits, w.complete, w.capped)
	}
	var l gitLogState
	l.walks = []logWalk{{id: "b", complete: true}}
	l.setMerged(nil, nil, nil)
	if l.limitReached {
		t.Fatal("a log whose walks read their whole histories says it reached its limit")
	}
}
