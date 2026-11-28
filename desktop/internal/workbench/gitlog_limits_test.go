package workbench

import (
	"context"
	"errors"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

type pagingProjectionGate struct {
	gitKernel
	release context.Context
}

func (k *pagingProjectionGate) GitHistoryPage(_ context.Context, _, _, cursor string, _, _ int) (core.GitHistoryPage, error) {
	if cursor == "second" {
		return core.GitHistoryPage{Commits: []core.GitCommit{{Hash: "second"}}, HasMore: true, NextCursor: "third"}, nil
	}
	return core.GitHistoryPage{Commits: []core.GitCommit{{Hash: "third"}}}, nil
}

func (k *pagingProjectionGate) GitGraph(ctx context.Context, req core.GraphRequest) (core.Graph, error) {
	if len(req.Commits) == 2 {
		select {
		case <-k.release.Done():
		case <-ctx.Done():
			return core.Graph{}, ctx.Err()
		}
	}
	rows := make([]core.GraphRow, len(req.Commits))
	for i, commit := range req.Commits {
		rows[i].CommitHash = commit.Hash
	}
	return core.Graph{Rows: rows}, nil
}

func TestLogPagingWaitsForTheCurrentProjection(t *testing.T) {
	release, unblock := context.WithCancel(context.Background())
	defer unblock()
	k := &pagingProjectionGate{gitKernel: gitKernel{core.NewClient()}, release: release}
	projectCtx, cancelProject := context.WithCancel(context.Background())
	p := &project{ctx: projectCtx}
	a := &App{kernel: k, project: p}
	wait := func() {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := a.tasks.running.WaitContext(ctx); err != nil {
			t.Fatalf("waiting for the Git Log worker: %v", err)
		}
	}
	t.Cleanup(func() {
		cancelProject()
		wait()
	})
	l := &p.log
	l.started, l.hasMore, l.cursor = true, true, "second"
	l.commits = []core.GitCommit{{Hash: "first"}}
	l.byHash = indexCommits(l.commits)
	l.setGraph(core.Graph{Rows: []core.GraphRow{{CommitHash: "first"}}})

	a.loadMoreLog(p)
	wait()
	a.drain()
	if len(l.commits) != 2 || len(l.graph.Rows) != 1 {
		t.Fatal("the second page should be waiting for its projection")
	}
	a.loadMoreLog(p)
	if l.loadingMore {
		t.Fatal("started reading the third page before publishing the second")
	}
	unblock()
	wait()
	a.drain()
	if len(l.graph.Rows) != 2 {
		t.Fatal("the second page did not become visible")
	}
	a.loadMoreLog(p)
	wait()
	a.drain()
	wait()
	a.drain()
	if l.hasMore || l.visibleRow("third") != 2 {
		t.Fatalf("third page has more history or did not publish its row: %+v", l.graph.Rows)
	}
}

type filteredLogPagingKernel struct {
	gitKernel
	continuations atomic.Int32
	expireNext    atomic.Bool
	failGraph     atomic.Bool
}

func (k *filteredLogPagingKernel) GitHistoryPage(ctx context.Context, root, reference, cursor string, limit, maxCommits int) (core.GitHistoryPage, error) {
	if cursor != "" {
		k.continuations.Add(1)
		if k.expireNext.Swap(false) {
			if _, err := k.CloseGitHistoryCursor(ctx, root, cursor); err != nil {
				return core.GitHistoryPage{}, err
			}
			return core.GitHistoryPage{}, &core.Error{
				Command: "git.historyPage", Code: core.CodeInvalidRequest, Details: cursor,
			}
		}
	} else if limit == logPageSize {
		// Keep the first page short while letting the wider layout window see both commits.
		limit = 1
	}
	return k.gitKernel.GitHistoryPage(ctx, root, reference, cursor, limit, maxCommits)
}

func (k *filteredLogPagingKernel) GitGraph(ctx context.Context, request core.GraphRequest) (core.Graph, error) {
	if k.failGraph.Swap(false) {
		return core.Graph{}, errors.New("test graph projection failure")
	}
	return k.gitKernel.GitGraph(ctx, request)
}

func newFilteredLogPagingFixture(t *testing.T) (string, *filteredLogPagingKernel) {
	t.Helper()
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "newer commit")
	return dir, &filteredLogPagingKernel{gitKernel: gitKernel{core.NewClient()}}
}

func openLogWithUnmatchedPage(t *testing.T, h *harness, dir string) {
	t.Helper()
	h.app.delays = logDelays{}
	h.open(dir)
	h.app.logView.search.SetText("initial")
	h.app.layout.gitTab = gitTabLog
	h.settle()
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		h.click(center(h.button(itemGit)))
	}
	h.settleChain()
	if !h.showsWrapped(h.app.text.Git.NoMatches) {
		t.Fatal("the first page did not show the empty filter result")
	}
}

func TestLogLoadsTheNextPageWhenTheFilterHasNoMatches(t *testing.T) {
	dir, k := newFilteredLogPagingFixture(t)
	h := newHarness(t, k)
	openLogWithUnmatchedPage(t, h, dir)
	if got := k.continuations.Load(); got != 0 {
		t.Fatalf("the empty result requested %d continuation pages without a click", got)
	}

	g := h.app.text.Git
	h.clickNamed(g.LoadMore)
	h.settleChain()
	if got := k.continuations.Load(); got != 1 {
		t.Fatalf("one click requested %d continuation pages, want 1", got)
	}
	if _, ok := h.findPageHit("initial"); !ok || h.showsWrapped(g.NoMatches) {
		t.Fatal("the matching commit on the next page is not visible")
	}
}

func TestLogResumesAnExpiredHistoryCursor(t *testing.T) {
	dir, k := newFilteredLogPagingFixture(t)
	h := newHarness(t, k)
	openLogWithUnmatchedPage(t, h, dir)
	k.expireNext.Store(true)

	h.clickNamed(h.app.text.Git.LoadMore)
	h.settleChain()
	if _, ok := h.findPageHit("initial"); !ok || h.app.logView.search.Text() != "initial" {
		t.Fatal("reopening the history cursor did not publish the matching older commit")
	}
	if got := k.continuations.Load(); got != 2 {
		t.Fatalf("got %d continuation requests, want the expired request and one resumed page", got)
	}
	if got := len(h.app.project.log.commits); got != 2 {
		t.Fatalf("replayed history was appended to the existing page: got %d commits, want 2", got)
	}
}

type replacedHistoryPager struct {
	replacement core.GitCommit
	requests    []string
	closed      []string
}

func (p *replacedHistoryPager) GitHistoryPage(_ context.Context, _, _, cursor string, _, _ int) (core.GitHistoryPage, error) {
	p.requests = append(p.requests, cursor)
	switch cursor {
	case "expired":
		return core.GitHistoryPage{}, &core.Error{
			Command: "git.historyPage", Code: core.CodeInvalidRequest, Details: cursor,
		}
	case "":
		return core.GitHistoryPage{Commits: []core.GitCommit{p.replacement}, HasMore: true, NextCursor: "fresh"}, nil
	default:
		return core.GitHistoryPage{}, errors.New("unexpected continuation of changed history")
	}
}

func (p *replacedHistoryPager) CloseGitHistoryCursor(_ context.Context, _, cursor string) (bool, error) {
	p.closed = append(p.closed, cursor)
	return true, nil
}

func TestLogDoesNotAppendAfterTheExpiredHistoryChanged(t *testing.T) {
	for _, tc := range []struct {
		name        string
		replacement core.GitCommit
	}{
		{"commit changed", core.GitCommit{Hash: "replacement", Decorations: "tag: release"}},
		{"tag moved", core.GitCommit{Hash: "old"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pager := &replacedHistoryPager{replacement: tc.replacement}
			loaded := []core.GitCommit{{Hash: "old", Decorations: "tag: release"}}
			closeCursor := (&App{}).logCursorCloser(t.Context(), pager)
			page, err := readGitLogPage(t.Context(), pager, "repo", "refs/heads/main", "expired", logPageSize, logWindowSize, loaded, closeCursor)
			if !errors.Is(err, errLogHistoryChanged) || len(page.Commits) != 0 {
				t.Fatalf("got page %+v and error %v, want a history reload without an appended page", page, err)
			}
			if !slices.Equal(pager.requests, []string{"expired", ""}) || !slices.Equal(pager.closed, []string{"fresh"}) {
				t.Fatalf("changed history requests %v and closed cursors %v, want the fresh cursor closed without consuming its next page", pager.requests, pager.closed)
			}
		})
	}
}

type logCursorCloseCall struct {
	root, cursor string
	binding      *core.RemoteWorkspace
	bounded      bool
	err          error
}

type logCursorLifecycleKernel struct {
	gitKernel
	replayStarted chan struct{}
	windowStarted chan struct{}
	failGraph     bool
	mu            sync.Mutex
	closes        []logCursorCloseCall
}

func (k *logCursorLifecycleKernel) GitReferences(context.Context, string) (core.GitReferences, error) {
	return core.GitReferences{}, nil
}

func (k *logCursorLifecycleKernel) GitGraph(_ context.Context, request core.GraphRequest) (core.Graph, error) {
	if k.failGraph {
		return core.Graph{}, errors.New("initial graph projection failed")
	}
	rows := make([]core.GraphRow, len(request.Commits))
	for i, commit := range request.Commits {
		rows[i].CommitHash = commit.Hash
	}
	return core.Graph{Rows: rows}, nil
}

func (k *logCursorLifecycleKernel) GitHistoryPage(ctx context.Context, _, reference, cursor string, limit, _ int) (core.GitHistoryPage, error) {
	switch cursor {
	case "expired":
		return core.GitHistoryPage{}, &core.Error{Command: "git.historyPage", Code: core.CodeInvalidRequest, Details: cursor}
	case "":
		if reference == "HEAD" {
			return core.GitHistoryPage{Commits: []core.GitCommit{{Hash: "replacement"}}}, nil
		}
		if limit == logWindowSize && k.windowStarted != nil {
			close(k.windowStarted)
			<-ctx.Done()
			return core.GitHistoryPage{NextCursor: "window"}, nil
		}
		if k.replayStarted != nil {
			close(k.replayStarted)
			<-ctx.Done()
		}
		// A read can return a cursor after cancellation if Core already prepared the result.
		return core.GitHistoryPage{Commits: []core.GitCommit{{Hash: "loaded"}}, HasMore: true, NextCursor: "fresh"}, nil
	default:
		if err := ctx.Err(); err != nil {
			return core.GitHistoryPage{}, err
		}
		return core.GitHistoryPage{}, errors.New("unexpected continuation")
	}
}

func (k *logCursorLifecycleKernel) CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error) {
	_, bounded := ctx.Deadline()
	k.mu.Lock()
	defer k.mu.Unlock()
	k.closes = append(k.closes, logCursorCloseCall{
		root: root, cursor: cursor, binding: core.RemoteWorkspaceOf(ctx), bounded: bounded, err: ctx.Err(),
	})
	return true, nil
}

func (k *logCursorLifecycleKernel) closed(name string) (logCursorCloseCall, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	for _, call := range k.closes {
		if call.cursor == name {
			return call, true
		}
	}
	return logCursorCloseCall{}, false
}

func waitForLogCursorLifecycle(t *testing.T, a *App) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := a.tasks.running.WaitContext(ctx); err != nil {
		t.Fatalf("waiting for Git Log lifecycle tasks: %v", err)
	}
}

func TestLogCursorCleanupKeepsRemoteBinding(t *testing.T) {
	binding := core.NewRemoteWorkspace("/placeholder", "/remote", nil)
	binding.Attach("test-session")
	owner, cancel := context.WithCancel(core.WithRemoteWorkspace(t.Context(), binding))
	cancel()
	k := &logCursorLifecycleKernel{}
	p := &project{ctx: owner, root: "/current"}
	p.log.cursorRoot, p.log.cursor = "/original", "remote-cursor"
	a := &App{kernel: k, project: p}
	a.releaseLogCursor(p)
	waitForLogCursorLifecycle(t, a)
	got, ok := k.closed("remote-cursor")
	if !ok || got.root != "/original" || got.binding == nil || got.binding.SessionID() != binding.SessionID() || !got.bounded || got.err != nil {
		t.Fatalf("remote cursor cleanup used %+v, want the owning workspace and a fresh deadline", got)
	}
}

func TestLogClosesCursorAfterInitialProjectionFailure(t *testing.T) {
	k := &logCursorLifecycleKernel{failGraph: true}
	p := &project{ctx: t.Context(), root: "/repo"}
	p.git.loaded, p.git.status.RepositoryRoot = true, p.root
	a := &App{kernel: k, project: p}
	a.loadLog(p)
	waitForLogCursorLifecycle(t, a)
	a.drain()
	waitForLogCursorLifecycle(t, a)
	if p.log.err == nil || p.log.cursor != "" {
		t.Fatal("a failed first graph should report an error and publish no cursor")
	}
	got, ok := k.closed("fresh")
	if !ok || got.root != p.root || !got.bounded || got.err != nil {
		t.Fatalf("closed %+v after the first graph failed, want the fresh cursor", got)
	}
}

func TestLogReloadCancelsCursorReplay(t *testing.T) {
	for _, merged := range []bool{false, true} {
		name := "single repository"
		if merged {
			name = "merged repositories"
		}
		t.Run(name, func(t *testing.T) {
			k := &logCursorLifecycleKernel{replayStarted: make(chan struct{})}
			owner, cancel := context.WithCancel(t.Context())
			p := &project{ctx: owner, root: "/repo"}
			p.git.loaded, p.git.status.RepositoryRoot = true, p.root
			a := &App{kernel: k, project: p}
			t.Cleanup(func() {
				cancel()
				waitForLogCursorLifecycle(t, a)
			})
			l := &p.log
			l.started = true
			loaded := []core.GitCommit{{Hash: "loaded"}}
			if merged {
				l.walks = []logWalk{{id: "repo", root: p.root, cursor: "expired", commits: loaded}}
				l.setMerged(loaded, []logOrigin{{key: "loaded"}}, []int{0})
			} else {
				l.commits = loaded
				l.cursorRoot, l.cursor, l.hasMore = p.root, "expired", true
				k.windowStarted = make(chan struct{})
				a.loadLogWindow(p, l.gen)
			}
			a.loadMoreLog(p)
			wait, stop := context.WithTimeout(t.Context(), 5*time.Second)
			defer stop()
			select {
			case <-k.replayStarted:
			case <-wait.Done():
				t.Fatal("the expired cursor did not start a replacement read")
			}
			if k.windowStarted != nil {
				select {
				case <-k.windowStarted:
				case <-wait.Done():
					t.Fatal("the wider graph window did not start")
				}
			}

			a.setLogReference(p, "HEAD", "HEAD")
			waitForLogCursorLifecycle(t, a)
			a.drain()
			waitForLogCursorLifecycle(t, a)
			if l.reference != "HEAD" || l.loadingMore || l.moreFailed || l.visibleRow("replacement") != 0 || l.cursor != "" {
				t.Fatal("a canceled continuation changed the new log")
			}
			cursorNames := []string{"fresh"}
			if k.windowStarted != nil {
				cursorNames = append(cursorNames, "window")
			}
			for _, cursor := range cursorNames {
				got, ok := k.closed(cursor)
				if !ok || got.root != p.root || !got.bounded || got.err != nil {
					t.Fatalf("switching the log left the %s cursor without valid cleanup", cursor)
				}
			}
		})
	}
}

func TestLogRetriesTheProjectionOfAnAlreadyReadPage(t *testing.T) {
	dir, k := newFilteredLogPagingFixture(t)
	h := newHarness(t, k)
	openLogWithUnmatchedPage(t, h, dir)
	k.failGraph.Store(true)

	h.clickNamed(h.app.text.Git.LoadMore)
	h.settleChain()
	if _, ok := h.findPageHit("initial"); ok {
		t.Fatal("the failed projection published the new row")
	}
	h.clickNamed(h.app.text.Git.Retry)
	h.settleChain()
	if _, ok := h.findPageHit("initial"); !ok {
		t.Fatal("reprojection did not publish the matching commit from the already loaded page")
	}
	if got := k.continuations.Load(); got != 1 {
		t.Fatalf("retry requested another history page: got %d continuation requests, want 1", got)
	}
}

// cappedHistoryKernel reads the history as gitKernel does but says every walk stopped at its
// limit while the history goes on, and records the most commits each page asked Core to read.
type cappedHistoryKernel struct {
	gitKernel
	mu  sync.Mutex
	max []int
}

func (k *cappedHistoryKernel) GitHistoryPage(ctx context.Context, root, reference, cursor string, limit, maxCommits int) (core.GitHistoryPage, error) {
	k.mu.Lock()
	k.max = append(k.max, maxCommits)
	k.mu.Unlock()
	page, err := k.gitKernel.GitHistoryPage(ctx, root, reference, cursor, limit, maxCommits)
	page.HasMore, page.NextCursor, page.LimitReached = false, "", true
	return page, err
}

// asked is the most commits each page so far asked Core to read.
func (k *cappedHistoryKernel) asked() []int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return slices.Clone(k.max)
}

// The log of one repository asks Core to read as many commits as the Git Log settings let it.
// When the history goes on past them, the list ends in a note that older commits are beyond the
// read limit and a button that opens those settings, never a failure and a retry. A changed limit
// is stored, the default as zero, and reads the log again with the new one.
func TestLogEndsAtItsLimitWithANoteThatOpensTheSettings(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	k := &cappedHistoryKernel{gitKernel: gitKernel{core.NewClient()}}
	h := newHarness(t, k)
	h.app.settings.GitLogLimit = 2000
	p := h.openLog(t, dir)
	if got := k.asked(); len(got) == 0 || got[0] != 2000 {
		t.Fatalf("the first page asked Core for at most %v commits, want 2000", got)
	}
	if !p.log.limitReached || p.log.hasMore {
		t.Fatalf("the log says limit reached %v, more %v; want the limit note and no more", p.log.limitReached, p.log.hasMore)
	}
	g := h.app.text.Git
	if !h.shows(g.LimitReached(2)) || h.shows(g.LoadMoreFailed) || h.shows(g.Retry) {
		t.Fatalf("the end of the log does not say %q alone", g.LimitReached(2))
	}

	log := &treeRecordingLog{}
	h.app.logSink = log
	t.Cleanup(func() { h.app.logSink = nil })
	h.clickNamed(g.AdjustLimit)
	h.settle()
	if n := countPerformed(log, "settings.open"); n != 1 {
		t.Fatalf("%q opened the settings %d times, want once", g.AdjustLimit, n)
	}

	h.app.setGitLogLimits(10000, settingswindow.DefaultGitLogMergedLimit)
	h.settleUntil("the log read again", func() bool {
		got := k.asked()
		return !p.log.loading && got[len(got)-1] == 10000
	})
	if h.app.settings.GitLogLimit != 10000 || h.app.settings.GitLogMergedLimit != 0 {
		t.Fatalf("stored limits %d and %d, want 10000 and the default as zero", h.app.settings.GitLogLimit, h.app.settings.GitLogMergedLimit)
	}
	h.app.setGitLogLimits(settingswindow.DefaultGitLogLimit, 30000)
	h.settle()
	if h.app.settings.GitLogLimit != 0 || h.app.settings.GitLogMergedLimit != 30000 {
		t.Fatalf("stored limits %d and %d, want the default as zero and 30000", h.app.settings.GitLogLimit, h.app.settings.GitLogMergedLimit)
	}
	if got := k.asked(); got[len(got)-1] != settingswindow.DefaultGitLogLimit {
		t.Fatalf("the log of one repository read again with %d, want the default %d", got[len(got)-1], settingswindow.DefaultGitLogLimit)
	}
}
