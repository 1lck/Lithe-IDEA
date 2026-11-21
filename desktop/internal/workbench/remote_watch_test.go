package workbench

import (
	"context"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// remoteTestFolder is the host folder the tests open as the workspace.
const remoteTestFolder = remoteTestHome + "/project"

// remoteHostWatches stands in for the host's watches of the workspace's folder
// (remote.runWatch): a watch starts at once, unless the test refuses it or the folder is
// missing, and hands over what the test sends until the test ends it or its request ends.
type remoteHostWatches struct {
	mu   sync.Mutex
	runs []*remoteHostWatch
	// refuse, when set, fails the next watch before it starts.
	refuse error
}

// remoteHostWatch is one watch the host ran.
type remoteHostWatch struct {
	session, root string
	excludes      []string
	send          chan func(core.RemoteWatchEvents)
	end           chan error
	// ended is closed when the request returned.
	ended chan struct{}
}

// remoteWatchWaitLimit bounds how long a test waits for the host's watch to take an event or end.
const remoteWatchWaitLimit = 5 * time.Second

func (k *remoteHostKernel) RemoteRunWatch(ctx context.Context, session, root string, excludes []string, events core.RemoteWatchEvents) error {
	k.mu.Lock()
	missing := k.missing
	k.mu.Unlock()
	h := &k.watches
	h.mu.Lock()
	run := &remoteHostWatch{
		session: session, root: root, excludes: slices.Clone(excludes),
		send: make(chan func(core.RemoteWatchEvents)), end: make(chan error, 1), ended: make(chan struct{}),
	}
	h.runs = append(h.runs, run)
	refused := h.refuse
	h.refuse = nil
	h.mu.Unlock()
	defer close(run.ended)
	switch {
	case refused != nil:
		return refused
	case missing:
		return &core.Error{Command: "remote.runWatch", Code: core.CodeWorkspaceNotFound, Message: "no such folder: " + root}
	}
	events.Started()
	for {
		select {
		case deliver := <-run.send:
			deliver(events)
		case err := <-run.end:
			return err
		case <-ctx.Done():
			// Core stops the watch and answers with the context's error.
			return ctx.Err()
		}
	}
}

// watchRuns is how many watches the host ran.
func (k *remoteHostKernel) watchRuns() int {
	k.watches.mu.Lock()
	defer k.watches.mu.Unlock()
	return len(k.watches.runs)
}

// refuseWatch fails the next watch with err before it starts.
func (k *remoteHostKernel) refuseWatch(err error) {
	k.watches.mu.Lock()
	defer k.watches.mu.Unlock()
	k.watches.refuse = err
}

// lastWatch is the watch the host ran last.
func (k *remoteHostKernel) lastWatch(t *testing.T) *remoteHostWatch {
	t.Helper()
	k.watches.mu.Lock()
	defer k.watches.mu.Unlock()
	if len(k.watches.runs) == 0 {
		t.Fatal("the host ran no watch")
	}
	return k.watches.runs[len(k.watches.runs)-1]
}

// deliver hands events, as the host sends them, to the watch's request.
func (w *remoteHostWatch) deliver(t *testing.T, deliver func(core.RemoteWatchEvents)) {
	t.Helper()
	timer := time.NewTimer(remoteWatchWaitLimit)
	defer timer.Stop()
	select {
	case w.send <- deliver:
	case <-w.ended:
		t.Fatal("the watch ended before it took the events")
	case <-timer.C:
		t.Fatal("timed out handing the watch its events")
	}
}

// changed reports the host paths changed below the folder in one batch.
func (w *remoteHostWatch) changed(t *testing.T, names ...string) {
	t.Helper()
	changes := make([]core.RemoteWatchChange, 0, len(names))
	for _, name := range names {
		changes = append(changes, core.RemoteWatchChange{Path: remoteTestFolder + "/" + name, Kind: "modified"})
	}
	w.deliver(t, func(events core.RemoteWatchEvents) { events.Changed(changes, false) })
}

// finish ends the watch's request with err and waits for it to return.
func (w *remoteHostWatch) finish(t *testing.T, err error) {
	t.Helper()
	w.end <- err
	w.awaitEnd(t)
}

// awaitEnd waits for the watch's request to return.
func (w *remoteHostWatch) awaitEnd(t *testing.T) {
	t.Helper()
	timer := time.NewTimer(remoteWatchWaitLimit)
	defer timer.Stop()
	select {
	case <-w.ended:
	case <-timer.C:
		t.Fatal("timed out waiting for the watch to end")
	}
}

// awaitWatching waits until the workspace's host watch runs and the host watches the folder, and
// for the tree and the documents it reads again then.
func (h *harness) awaitWatching(p *project) {
	h.t.Helper()
	h.await("the host watch", func() bool {
		r := p.remote
		return r.watch != nil && r.watch.watching && !p.tree.reading && !remoteChecksPending(p)
	})
	h.settle()
}

// remoteChecksPending reports that a document of p is still being compared with the host.
func remoteChecksPending(p *project) bool {
	return slices.ContainsFunc(p.docs.list, func(d *document) bool { return d.checking || d.checkPending })
}

// remoteWatchFailures are the logged errors of the window's work on the host watch.
func remoteWatchFailures(logger *treeRecordingLog) []string {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	var errs []string
	for _, event := range logger.events {
		if event.Event == backgroundFailedEvent && event.Fields["operation"] == "remote_watch" {
			errs = append(errs, event.Fields["error"].(string))
		}
	}
	return errs
}

// countNotified counts the notifications that say text.
func (h *harness) countNotified(text string) int {
	n := 0
	for _, notice := range h.app.notifications.list {
		if notice.text == text {
			n++
		}
	}
	return n
}

// The host watches the workspace's folder over its session, leaving out no folder while no plugin
// hides one. A change made on the host shows in the tree, reloads an open document that has no
// edits and shows the conflict in one that has; a change of a folder Core hides and a path outside
// the folder change nothing. Neither the host nor its paths are logged.
func TestRemoteWorkspaceShowsChangesMadeOnTheHost(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	k.put(remoteTestReadme, "# Project\n")
	p := h.openRemoteTestProject(t)
	d := h.openRemoteFile(t, p, "README.md")
	if d == nil {
		t.Fatal("README.md did not open")
	}
	h.awaitWatching(p)
	w := k.lastWatch(t)
	if w.session != "session-1" || w.root != remoteTestFolder || len(w.excludes) != 0 || k.watchRuns() != 1 {
		t.Fatalf("watched over %q with %d excluded names in %d runs, want the workspace's folder over its session", w.session, len(w.excludes), k.watchRuns())
	}

	k.set(func(k *remoteHostKernel) {
		k.tree = map[string][]core.WorkspaceNode{"": append(slices.Clone(remoteTestTree[""]), core.WorkspaceNode{Path: "NOTES.md", Name: "NOTES.md"})}
	})
	k.put(remoteTestReadme, "changed on the host\n")
	w.changed(t, "NOTES.md", "README.md", ".git/index")
	h.await("the host's changes", func() bool {
		text, _ := d.view.Text()
		return p.tree.find("NOTES.md") != nil && string(text) == "changed on the host\n" && !p.tree.reading && !remoteChecksPending(p)
	})
	if d.dirty() || d.conflicted {
		t.Fatal("reloading the host's change left the document edited or in conflict")
	}

	// A change outside the folder, of the folder itself or of a folder Core hides lists nothing
	// again: of these changes, only the last lists the tree's root.
	listed := k.count(func(k *remoteHostKernel) int { return len(k.listings) })
	w.deliver(t, func(events core.RemoteWatchEvents) {
		events.Changed([]core.RemoteWatchChange{{Path: remoteTestHome + "/notes.txt", Kind: "modified"}, {Path: remoteTestFolder, Kind: "modified"}}, false)
	})
	w.changed(t, ".git/HEAD")
	w.changed(t, "README.md")
	h.await("the last change", func() bool {
		return k.count(func(k *remoteHostKernel) int { return len(k.listings) }) > listed && !p.tree.eventFiltering && !p.tree.reading && !remoteChecksPending(p)
	})
	h.settle()
	if got := k.count(func(k *remoteHostKernel) int { return len(k.listings) }); got != listed+1 {
		t.Fatalf("the changes listed the tree %d times, want once for the last", got-listed)
	}

	typeAtCaret(t, d, "local ")
	k.put(remoteTestReadme, "changed again\n")
	w.changed(t, "README.md")
	h.await("the conflict", func() bool { return d.conflicted && !remoteChecksPending(p) })
	if text, _ := d.view.Text(); string(text) == "changed again\n" || !d.dirty() {
		t.Fatal("the host's change replaced the edits")
	}
	if got := remoteWatchFailures(logger); len(got) != 0 {
		t.Fatalf("logged %q, want no failure", got)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// When the host lost changes, or sent more than the window applies one by one, the tree and every
// document are read again, and the log keeps it once for the watch. When the host runs out of
// watches, the watch goes on for the rest of the folder and the user is told once.
func TestRemoteWatchReadsEverythingAgainWhenChangesAreLost(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.put(remoteTestReadme, "# Project\n")
	p := h.openRemoteTestProject(t)
	d := h.openRemoteFile(t, p, "README.md")
	if d == nil {
		t.Fatal("README.md did not open")
	}
	h.awaitWatching(p)
	w := k.lastWatch(t)

	readAgain := func(what string, send func()) {
		t.Helper()
		listed := k.count(func(k *remoteHostKernel) int { return len(k.listings) })
		k.put(remoteTestReadme, what+"\n")
		send()
		h.await(what, func() bool {
			text, _ := d.view.Text()
			return string(text) == what+"\n" && !p.tree.reading && !remoteChecksPending(p) &&
				k.count(func(k *remoteHostKernel) int { return len(k.listings) }) > listed
		})
		h.settle()
	}
	for _, what := range []string{"lost once", "lost twice"} {
		readAgain(what, func() {
			w.deliver(t, func(events core.RemoteWatchEvents) { events.Changed(nil, true) })
		})
	}
	readAgain("too many", func() {
		names := make([]string, searchEventLimit+1)
		for i := range names {
			names[i] = "src/file" + strconv.Itoa(i)
		}
		w.changed(t, names...)
	})

	unavailable := i18n.Shared(lang, "desktop.project.watchUnavailable")
	for range 2 {
		before := len(remoteWatchFailures(logger))
		w.deliver(t, func(events core.RemoteWatchEvents) { events.LimitReached() })
		h.await("the watch limit", func() bool { return len(remoteWatchFailures(logger)) > before })
	}
	h.settle()
	if got := h.countNotified(unavailable); got != 1 {
		t.Fatalf("told the user %d times that files may not update, want once", got)
	}
	if p.remote.watch == nil || k.watchRuns() != 1 {
		t.Fatalf("the watch stopped after the host ran out of watches; %d runs", k.watchRuns())
	}
	want := []string{errWatchEventsLost.Error(), errWatchEventLimit.Error(), errRemoteWatchLimit.Error(), errRemoteWatchLimit.Error()}
	if got := remoteWatchFailures(logger); !slices.Equal(got, want) {
		t.Fatalf("logged %q, want %q", got, want)
	}
}

// The watch follows the workspace's session. One that fails is logged by command and code, tells
// the user once and waits for the next session; one that finds the connection closed ends the
// session, and the workspace connects again and watches over the new one. Closing the workspace
// ends the watch.
func TestRemoteWatchFollowsTheSession(t *testing.T) {
	h, k, timers, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)
	r := p.remote
	h.awaitWatching(p)

	k.lastWatch(t).finish(t, &core.Error{Command: "remote.runWatch", Code: core.CodeProcessFailed, Message: "cannot watch " + remoteTestFolder})
	h.await("the failed watch", func() bool { return r.watch == nil && r.watchWait == remoteWatchSession && !p.tree.reading })
	h.settle()
	if got := remoteWatchFailures(logger); len(got) != 1 || !h.notified(i18n.Shared(lang, "desktop.project.watchUnavailable")) || k.watchRuns() != 1 {
		t.Fatalf("logged %d failures in %d runs: the failed watch was not reported once and left waiting", len(got), k.watchRuns())
	}

	k.set(func(k *remoteHostKernel) {
		k.once = &core.Error{Command: "remote.serverState", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.fire(t, timers)
	h.fireReconnect(t, timers, r)
	h.await("the second session", func() bool { return r.session == "session-2" && !r.beating })
	h.awaitWatching(p)
	if w := k.lastWatch(t); w.session != "session-2" || k.watchRuns() != 2 {
		t.Fatalf("watched over %q in %d runs, want the new session", w.session, k.watchRuns())
	}

	k.lastWatch(t).finish(t, &core.Error{Command: "remote.runWatch", Code: core.CodeConnectionClosed, Message: "closed"})
	h.fireReconnect(t, timers, r)
	h.await("the third session", func() bool { return r.session == "session-3" && !r.beating })
	h.awaitWatching(p)
	if w := k.lastWatch(t); w.session != "session-3" || !slices.Contains(k.closed, "session-2") {
		t.Fatalf("watched over %q, closed %q: the closed connection was not replaced", w.session, k.closed)
	}
	if got := countFailures(logger, "remote_session_lost"); got != 2 {
		t.Fatalf("remote_session_lost logged %d times, want once per session", got)
	}

	w := k.lastWatch(t)
	h.app.closeProject()
	h.settle()
	w.awaitEnd(t)
	if got := len(remoteWatchFailures(logger)); got != 1 {
		t.Fatalf("logged %d watch failures, want only the first", got)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A folder removed while watched ends the watch, which starts again at once, finds the folder
// missing and waits: it starts again once the tree lists the folder, not before. A watch that
// finds the folder missing while the tree lists it waits too instead of trying again and again.
// None of it is logged as a failure of the watch.
func TestRemoteWatchWaitsForAMissingFolder(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	r := p.remote
	h.awaitWatching(p)

	k.set(func(k *remoteHostKernel) { k.missing = true })
	k.lastWatch(t).finish(t, nil)
	h.await("the missing folder", func() bool {
		return r.watch == nil && r.watchWait == remoteWatchRootListed && p.tree.failed != "" && !p.tree.reading && k.watchRuns() == 2
	})
	h.settle()
	h.app.retryProjectTree(p)
	h.settle()
	h.await("the tree to find the folder still missing", func() bool { return !p.tree.reading })
	h.settle()
	if k.watchRuns() != 2 || r.watch != nil {
		t.Fatalf("%d runs: the watch started again while the folder is missing", k.watchRuns())
	}

	k.set(func(k *remoteHostKernel) { k.missing = false })
	h.app.retryProjectTree(p)
	h.awaitWatching(p)
	if w := k.lastWatch(t); k.watchRuns() != 3 || w.session != "session-1" || p.tree.failed != "" {
		t.Fatalf("%d runs over %q: the watch did not start again once the folder was back", k.watchRuns(), w.session)
	}

	// The host finds the folder missing while the tree lists it.
	k.refuseWatch(&core.Error{Command: "remote.runWatch", Code: core.CodeWorkspaceNotFound, Message: "no such folder"})
	k.lastWatch(t).finish(t, nil)
	h.await("the watch to wait", func() bool {
		return r.watch == nil && r.watchWait == remoteWatchRootMissed && !p.tree.reading && k.watchRuns() == 4
	})
	h.settle()
	h.app.retryProjectTree(p)
	h.settle()
	h.await("the tree to list the folder", func() bool { return !p.tree.reading })
	h.settle()
	if k.watchRuns() != 4 || r.watch != nil {
		t.Fatalf("%d runs: the watch tried again while the host does not find the folder", k.watchRuns())
	}
	if got := remoteWatchFailures(logger); len(got) != 0 {
		t.Fatalf("logged %q, want no failure of the watch", got)
	}
}

// Other hidden folder names start the watch again leaving them out, as written; the same names
// leave it running.
func TestRemoteWatchLeavesOutTheHiddenFolders(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	clearHiddenFolders(t)
	p := h.openRemoteTestProject(t)
	h.awaitWatching(p)
	first := k.lastWatch(t)

	h.app.applyHiddenDirectories(hiddenDirectories{names: []string{"target"}, answered: true})
	first.awaitEnd(t)
	h.awaitWatching(p)
	if w := k.lastWatch(t); k.watchRuns() != 2 || !slices.Equal(w.excludes, []string{"target"}) {
		t.Fatalf("%d runs leaving out %q, want a new watch leaving out the hidden folders", k.watchRuns(), w.excludes)
	}
	h.app.applyHiddenDirectories(hiddenDirectories{names: []string{"target"}, answered: true})
	h.settle()
	h.app.applyHiddenDirectories(hiddenDirectories{names: []string{"Target"}, answered: true})
	h.awaitWatching(p)
	if w := k.lastWatch(t); k.watchRuns() != 3 || !slices.Equal(w.excludes, []string{"Target"}) {
		t.Fatalf("%d runs leaving out %q, want one more watch for the names in another case", k.watchRuns(), w.excludes)
	}
}
