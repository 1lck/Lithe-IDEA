package workbench

import (
	"context"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type logProjectCloseCall struct {
	root, cursor, session string
	programs              core.RemoteClosePrograms
	bounded, active       bool
}

type logProjectCloseKernel struct {
	Kernel
	mu         sync.Mutex
	calls      []logProjectCloseCall
	page       func(context.Context, string) (core.GitHistoryPage, error)
	disconnect func(context.Context) error
	closeErr   error
}

func (k *logProjectCloseKernel) GitReferences(context.Context, string) (core.GitReferences, error) {
	return core.GitReferences{}, nil
}

func (k *logProjectCloseKernel) GitGraph(context.Context, core.GraphRequest) (core.Graph, error) {
	return core.Graph{}, nil
}

func (k *logProjectCloseKernel) GitHistoryPage(ctx context.Context, _, _, cursor string, _, _ int, _ ...string) (core.GitHistoryPage, error) {
	if k.page == nil {
		return core.GitHistoryPage{}, nil
	}
	return k.page(ctx, cursor)
}

func (k *logProjectCloseKernel) CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error) {
	session := ""
	if binding := core.RemoteWorkspaceOf(ctx); binding != nil {
		session = binding.SessionID()
	}
	_, bounded := ctx.Deadline()
	k.mu.Lock()
	k.calls = append(k.calls, logProjectCloseCall{
		root: root, cursor: cursor, session: session, bounded: bounded, active: ctx.Err() == nil,
	})
	k.mu.Unlock()
	return k.closeErr == nil, k.closeErr
}

func TestGitLogWindowCursorCloseFailureLogsRedactedRemoteError(t *testing.T) {
	const hostPath = "/private/remote/repository"
	binding := core.NewRemoteWorkspace("/placeholder", hostPath, nil)
	binding.Attach("original-session")
	owner, cancel := context.WithCancel(core.WithRemoteWorkspace(t.Context(), binding))
	defer cancel()
	k := &logProjectCloseKernel{
		page: func(context.Context, string) (core.GitHistoryPage, error) {
			cancel()
			return core.GitHistoryPage{NextCursor: "window"}, nil
		},
		closeErr: &core.Error{Command: "git.historyCursorClose", Code: core.CodePermissionDenied, Message: hostPath, Details: hostPath},
	}
	p := &project{ctx: owner, root: "/placeholder"}
	logger := &treeRecordingLog{}
	a := &App{kernel: k, project: p, logSink: logger}
	a.loadLogWindow(p, p.log.gen)
	waitForLogCursorLifecycle(t, a)

	want := []logProjectCloseCall{{root: p.root, cursor: "window", session: "original-session", bounded: true, active: true}}
	if !slices.Equal(k.calls, want) {
		t.Fatalf("window cursor cleanup made calls %+v, want %+v", k.calls, want)
	}
	if len(logger.events) != 1 {
		t.Fatalf("window cursor cleanup emitted %d log events, want 1", len(logger.events))
	}
	event := logger.events[0]
	message, _ := event.Fields["error"].(string)
	if event.Event != backgroundFailedEvent || event.Level != backgroundFailedLevel || event.Fields["operation"] != "git_log_cursor_close" ||
		event.Fields["error_code"] != string(core.CodePermissionDenied) || !strings.Contains(message, "remote request failed") || strings.Contains(message, hostPath) {
		t.Fatalf("window cursor cleanup emitted an unexpected event %+v", event)
	}
}

func TestGitLogClosesUnpublishedCursorBeforeKeepingRemote(t *testing.T) {
	h, _, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	k := &logProjectCloseKernel{Kernel: h.app.kernel, page: func(context.Context, string) (core.GitHistoryPage, error) {
		return core.GitHistoryPage{HasMore: true, NextCursor: "queued"}, nil
	}}
	h.app.kernel = k
	p.git.loaded, p.git.status.RepositoryRoot = true, p.root
	h.app.loadLog(p)
	// Let the page complete without delivering its result to the window.
	waitForLogCursorLifecycle(t, h.app)
	session := p.remote.session
	h.app.keepRemoteAndClose(p, 1, func() {})
	waitForLogCursorLifecycle(t, h.app)
	k.mu.Lock()
	calls := slices.Clone(k.calls)
	k.mu.Unlock()
	want := []logProjectCloseCall{
		{root: p.root, cursor: "queued", session: session, bounded: true, active: true},
		{session: session, programs: core.RemoteCloseKeep, bounded: true, active: true},
	}
	if !slices.Equal(calls, want) {
		t.Fatalf("keeping the session made calls %+v, want %+v", calls, want)
	}
}

func TestGitLogClosesCursorReturnedByReplayDuringRemoteClose(t *testing.T) {
	h, _, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	replayStarted := make(chan struct{})
	wait, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	k := &logProjectCloseKernel{Kernel: h.app.kernel, page: func(ctx context.Context, cursor string) (core.GitHistoryPage, error) {
		switch cursor {
		case "expired":
			close(replayStarted)
			select {
			case <-ctx.Done():
				// The host completed the request while cancellation was being delivered.
				return core.GitHistoryPage{HasMore: true, NextCursor: "reopened"}, nil
			case <-wait.Done():
				return core.GitHistoryPage{}, wait.Err()
			}
		default:
			return core.GitHistoryPage{}, &core.Error{Code: core.CodeInvalidRequest, Details: cursor}
		}
	}}
	h.app.kernel = k
	l := &p.log
	l.commits, l.cursor, l.cursorRoot, l.hasMore = []core.GitCommit{{Hash: "loaded"}}, "expired", p.root, true
	h.app.loadMoreLog(p)
	select {
	case <-replayStarted:
	case <-wait.Done():
		t.Fatal("history replay did not reach its continuation")
	}
	session := p.remote.session
	h.app.keepRemoteAndClose(p, 1, func() {})
	waitForLogCursorLifecycle(t, h.app)
	k.mu.Lock()
	calls := slices.Clone(k.calls)
	k.mu.Unlock()
	want := []logProjectCloseCall{
		{root: p.root, cursor: "reopened", session: session, bounded: true, active: true},
		{root: p.root, cursor: "expired", session: session, bounded: true, active: true},
		{session: session, programs: core.RemoteCloseKeep, bounded: true, active: true},
	}
	if !slices.Equal(calls, want) {
		t.Fatalf("keeping the session during history replay made calls %+v, want %+v", calls, want)
	}
}

func TestGitLogDiscardsPageFromReplacedRemoteSession(t *testing.T) {
	h, _, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	k := &logProjectCloseKernel{Kernel: h.app.kernel, page: func(context.Context, string) (core.GitHistoryPage, error) {
		return core.GitHistoryPage{Commits: []core.GitCommit{{Hash: "old-session"}}, HasMore: true, NextCursor: "old-cursor"}, nil
	}}
	h.app.kernel = k
	p.git.loaded, p.git.status.RepositoryRoot = true, p.root
	h.app.loadLog(p)
	waitForLogCursorLifecycle(t, h.app)

	// Replace the binding before a page already waiting for the window can publish.
	binding := p.remote.binding
	session := binding.SessionID()
	defer binding.Attach(session)
	binding.Detach()
	binding.Attach("replacement-session")
	h.app.drain()
	waitForLogCursorLifecycle(t, h.app)

	if len(p.log.commits) != 0 || p.log.cursor != "" {
		t.Fatal("the page from a replaced session was published")
	}
	k.mu.Lock()
	calls := slices.Clone(k.calls)
	k.mu.Unlock()
	want := []logProjectCloseCall{{root: p.root, cursor: "old-cursor", session: session, bounded: true, active: true}}
	if !slices.Equal(calls, want) {
		t.Fatalf("discarding an old page made calls %+v, want %+v", calls, want)
	}
}

func TestGitLogClosesQueuedCursorAfterReadWaitDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		binding := core.NewRemoteWorkspace("/placeholder", "/remote", nil)
		binding.Attach("original-session")
		owner := core.WithRemoteWorkspace(t.Context(), binding)
		p := &project{ctx: owner}
		k := &logProjectCloseKernel{}
		a := &App{kernel: k}
		reads := &p.logReads
		// One read returns a cursor during close. Another remains active through the deadline.
		reads.running.Add(2)
		defer reads.running.Done()
		finish := a.prepareLogClose(p, 2*time.Second)
		go func() {
			defer reads.running.Done()
			<-time.After(time.Second)
			reads.store(&logCursorRead{owner: owner}, logPageCursor("/placeholder", "queued"))
		}()
		finish(t.Context())

		want := []logProjectCloseCall{{root: "/placeholder", cursor: "queued", session: "original-session", bounded: true, active: true}}
		if !slices.Equal(k.calls, want) {
			t.Fatalf("closing after the read deadline made calls %+v, want %+v", k.calls, want)
		}
	})
}

func (k *logProjectCloseKernel) RemoteDisconnect(ctx context.Context, session string, programs core.RemoteClosePrograms) (core.RemoteDisconnectResult, error) {
	_, bounded := ctx.Deadline()
	k.mu.Lock()
	k.calls = append(k.calls, logProjectCloseCall{
		session: session, programs: programs, bounded: bounded, active: ctx.Err() == nil,
	})
	k.mu.Unlock()
	if k.disconnect != nil {
		if err := k.disconnect(ctx); err != nil {
			return core.RemoteDisconnectResult{}, err
		}
	}
	return k.Kernel.RemoteDisconnect(ctx, session, programs)
}

func TestGitLogIgnoresFiltersAndRepositorySwitchWhileKeepingRemote(t *testing.T) {
	h, _, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	disconnectStarted := make(chan struct{})
	release, unblock := context.WithCancel(t.Context())
	defer unblock()
	k := &logProjectCloseKernel{
		Kernel: h.app.kernel,
		disconnect: func(ctx context.Context) error {
			close(disconnectStarted)
			select {
			case <-release.Done():
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	}
	h.app.kernel = k
	p.nested.logRepo = "original"
	p.nested.chosen = []string{"original", "other"}
	p.log.walks = []logWalk{{id: "original", root: p.root}}
	p.log.origins = []logOrigin{{key: "commit"}, {key: "target"}}
	p.log.commits = []core.GitCommit{{Hash: "commit"}, {Hash: "target"}}
	p.log.byHash = indexCommits(p.log.commits)
	p.log.setGraph(core.Graph{Rows: []core.GraphRow{
		{CommitHash: "commit", Labels: []core.GraphLabel{{Title: "current"}}},
		{CommitHash: "target", Labels: []core.GraphLabel{{Title: "other"}}},
	}})
	p.log.selected = "commit"
	h.app.jumpLogGraphArrow(p, "commit")
	if p.log.reveal != logRevealWithFocus {
		t.Fatal("an arrow to the selected commit did not request focus before closing")
	}
	h.app.locateReference(p, "current")
	if p.log.reveal != logRevealSelection {
		t.Fatal("locating a reference on the selected commit did not request scrolling before closing")
	}
	p.log.reveal = logRevealNone
	details := make(chan struct{})
	oldSelectionGen := p.log.selGen
	p.log.selStop = details
	h.app.keepRemoteAndClose(p, 1, func() { h.app.finishCloseProject(p, nil) })
	wait, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	select {
	case <-disconnectStarted:
	case <-wait.Done():
		t.Fatal("keeping the remote session did not reach disconnect")
	}
	select {
	case <-details:
	default:
		t.Error("remote disconnect left the earlier Git Log detail request running")
	}
	if p.log.selGen == oldSelectionGen {
		t.Error("remote disconnect can still publish the earlier Git Log detail result")
	}

	gen, projGen := p.log.gen, p.log.projGen
	h.app.jumpLogGraphArrow(p, "target")
	if p.log.reveal != logRevealNone || p.log.selected != "commit" {
		t.Error("an arrow changed Git Log navigation during remote disconnect")
	}
	p.log.reveal = logRevealNone
	h.app.locateReference(p, "other")
	if p.log.reveal != logRevealNone || p.log.selected != "commit" {
		t.Error("locating a reference changed Git Log navigation during remote disconnect")
	}
	h.app.logView.search.SetText("filtered")
	h.app.syncLogFilters(p)
	h.app.setLogReference(p, "refs/heads/other", "other")
	h.app.setLogRepo(p, "other", "", "")
	h.app.selectCommit(p, "")
	if p.log.gen != gen || p.log.projGen != projGen || p.log.projStop != nil {
		t.Error("Git Log started a read or projection during remote disconnect")
	}
	if p.nested.logRepo != "original" || len(p.log.origins) != 2 || p.log.reference != "" || p.log.selected != "commit" {
		t.Error("Git Log changed the published repository, reference or selection during remote disconnect")
	}

	unblock()
	h.awaitClosed(t)
}

func TestGitLogClosesPublishedCursorsWithProject(t *testing.T) {
	for _, programs := range []core.RemoteClosePrograms{"", core.RemoteCloseEnd, core.RemoteCloseKeep} {
		name := string(programs)
		if name == "" {
			name = "local"
		}
		t.Run(name, func(t *testing.T) {
			var h *harness
			if programs == "" {
				h = newHarness(t, &testKernel{Client: core.NewClient()})
				h.open(t.TempDir())
			} else {
				var host *remoteHostKernel
				h, host, _, _ = remoteWorkspaceHarness(t)
				h.openRemoteTestProject(t)
				if programs == core.RemoteCloseKeep {
					host.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })
				}
			}
			p := h.app.project
			k := &logProjectCloseKernel{Kernel: h.app.kernel}
			h.app.kernel = k
			original := filepath.Join(p.root, "original")
			other := filepath.Join(p.root, "another")
			session := ""
			if p.remote != nil {
				session = p.remote.session
			}
			want := []logProjectCloseCall{
				{root: original, cursor: "published", session: session, bounded: true, active: true},
			}
			if programs == core.RemoteCloseEnd {
				p.log.walks = []logWalk{{root: original, cursor: "published"}, {root: other, cursor: "merged"}}
				want = append(want, logProjectCloseCall{root: other, cursor: "merged", session: session, bounded: true, active: true})
			} else {
				p.log.cursorRoot, p.log.cursor = original, "published"
			}
			gen := p.log.gen
			read, cancelRead := context.WithCancel(t.Context())
			window, cancelWindow := context.WithCancel(t.Context())
			t.Cleanup(cancelRead)
			t.Cleanup(cancelWindow)
			p.log.readCancel, p.log.windowCancel = cancelRead, cancelWindow

			if programs == core.RemoteCloseKeep {
				h.closeQuestion(t)
				h.answer(1)
			} else {
				h.app.closeProject()
			}
			h.awaitClosed(t)

			if programs != "" {
				want = append(want, logProjectCloseCall{session: session, programs: programs, bounded: true, active: true})
			}
			k.mu.Lock()
			calls := slices.Clone(k.calls)
			k.mu.Unlock()
			if !slices.Equal(calls, want) {
				t.Fatalf("project close made calls %+v, want %+v", calls, want)
			}
			if read.Err() == nil || window.Err() == nil || p.log.gen == gen {
				t.Fatal("project close left old Git Log work or results active")
			}
		})
	}
}
