package workbench

import (
	"context"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

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
		if err := readWalkPage(ctx, pager, &walks[i], limit-walkCommits(walks), limit); err != nil {
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
	if err := readWalkPage(ctx, pager, &w, 500, 500); err != nil {
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
