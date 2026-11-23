package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// remoteHostTerminals stands in for the host's terminals (remote.runTerminal): a terminal starts
// at once and prints the prompt remoteHostPrompt, echoes what is typed, and runs until the test
// ends it or its request ends.
type remoteHostTerminals struct {
	mu   sync.Mutex
	runs []*remoteHostRun
	// busy is how many writes the host refuses as BUSY before it takes input again.
	busy int
	// refuse, when set, fails the next terminal before it starts.
	refuse error
	// resizes are the sizes the host was told, as "columns x rows"; writes are the lengths of
	// the writes it took.
	resizes []string
	writes  []int
	// changed is signalled after each change, for tests that do not run a window.
	changed chan struct{}
}

// remoteHostPrompt is what a host terminal prints when it starts.
const remoteHostPrompt = "host$"

// remoteHostRun is one terminal the host ran.
type remoteHostRun struct {
	session string
	open    core.RemoteTerminalOpen
	// typed is the input the host took, under remoteHostTerminals.mu.
	typed []byte
	echo  chan []byte
	end   chan remoteHostEnd
	// ended is closed when the request returned.
	ended chan struct{}
}

// remoteHostEnd is how the test ends a host terminal.
type remoteHostEnd struct {
	exit core.RemoteTerminalExit
	err  error
}

func (k *remoteHostKernel) RemoteRunTerminal(ctx context.Context, session string, open core.RemoteTerminalOpen, events core.RemoteTerminalEvents) (core.RemoteTerminalExit, error) {
	h := &k.terminals
	h.mu.Lock()
	if err := h.refuse; err != nil {
		h.refuse = nil
		h.mu.Unlock()
		return core.RemoteTerminalExit{}, err
	}
	run := &remoteHostRun{session: session, open: open, echo: make(chan []byte, 64), end: make(chan remoteHostEnd, 1), ended: make(chan struct{})}
	h.runs = append(h.runs, run)
	id := uint64(len(h.runs))
	h.mu.Unlock()
	defer func() {
		close(run.ended)
		h.signal()
	}()
	events.Started(id)
	events.Output([]byte(remoteHostPrompt + " "))
	h.signal()
	for {
		select {
		case data := <-run.echo:
			events.Output(data)
		case end := <-run.end:
			return end.exit, end.err
		case <-ctx.Done():
			// Core closes the terminal and answers with the context's error.
			return core.RemoteTerminalExit{}, ctx.Err()
		}
	}
}

func (k *remoteHostKernel) RemoteTerminalWrite(_ context.Context, session string, terminal uint64, data []byte) (bool, error) {
	h := &k.terminals
	h.mu.Lock()
	run, err := h.find(session, terminal)
	busy := err == nil && h.busy > 0
	switch {
	case busy:
		h.busy--
	case err == nil:
		run.typed = append(run.typed, data...)
		h.writes = append(h.writes, len(data))
	}
	h.mu.Unlock()
	h.signal()
	if err != nil || busy {
		return busy, err
	}
	select {
	case run.echo <- append([]byte(nil), data...):
	case <-run.ended:
	}
	return false, nil
}

func (k *remoteHostKernel) RemoteTerminalResize(_ context.Context, session string, terminal uint64, columns, rows uint16) error {
	h := &k.terminals
	h.mu.Lock()
	_, err := h.find(session, terminal)
	if err == nil {
		h.resizes = append(h.resizes, strconv.Itoa(int(columns))+"x"+strconv.Itoa(int(rows)))
	}
	h.mu.Unlock()
	h.signal()
	return err
}

// find is the running terminal of session numbered terminal, or the error the host answers a
// request for it with.
func (h *remoteHostTerminals) find(session string, terminal uint64) (*remoteHostRun, error) {
	if terminal == 0 || terminal > uint64(len(h.runs)) || h.runs[terminal-1].session != session {
		return nil, &core.Error{Command: "remote.hostRequest", Code: core.CodeConnectionClosed, Message: "no such session"}
	}
	run := h.runs[terminal-1]
	select {
	case <-run.ended:
		return nil, &core.Error{Command: "remote.hostRequest", Code: core.CodeProcessFailed, Message: "the terminal ended", Details: `{"remoteCode":"UNKNOWN_RESOURCE"}`}
	default:
		return run, nil
	}
}

func (h *remoteHostTerminals) signal() {
	select {
	case h.changes() <- struct{}{}:
	default:
	}
}

func (h *remoteHostTerminals) changes() chan struct{} {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.changed == nil {
		h.changed = make(chan struct{}, 1)
	}
	return h.changed
}

// set changes how the host's terminals answer.
func (h *remoteHostTerminals) set(change func(h *remoteHostTerminals)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	change(h)
}

// started is every terminal the host ran.
func (h *remoteHostTerminals) started() []*remoteHostRun {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.runs)
}

// typedInto is the input the host took for run.
func (h *remoteHostTerminals) typedInto(run *remoteHostRun) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return string(run.typed)
}

// read is something of the host's terminals read under their lock.
func (h *remoteHostTerminals) read(read func(h *remoteHostTerminals) bool) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return read(h)
}

// await waits for condition, which the host's terminals make true, without a window.
func (h *remoteHostTerminals) await(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	for !condition() {
		select {
		case <-h.changes():
		case <-deadline.C:
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

// openRemoteTerminal shows the Terminal tool window of the remote workspace p, which opens a
// terminal on the host, and waits for the host's prompt.
func (h *harness) openRemoteTerminal(t *testing.T, k *remoteHostKernel, p *project) (*terminal, *remoteHostRun) {
	t.Helper()
	before := len(k.terminals.started())
	h.clickTerminalButton()
	h.await("a terminal to start on the host", func() bool { return len(k.terminals.started()) > before && len(p.terms.list) > 0 })
	term := p.terms.list[len(p.terms.list)-1]
	h.awaitTerminal(term, remoteHostPrompt)
	return term, k.terminals.started()[before]
}

// clickTerminalButton opens the Terminal tool window by its button, as a person does: the click
// shows the window, and the window's first paint starts the terminal the workspace opened with.
func (h *harness) clickTerminalButton() {
	h.t.Helper()
	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.click(center(h.button(itemTerminal)))
	}
	h.settle()
}

// awaitTerminal waits for term to show text, spaces aside, since a long line wraps in the grid.
func (h *harness) awaitTerminal(term *terminal, text string) {
	h.t.Helper()
	want := strings.Join(strings.Fields(text), "")
	h.await("the terminal's text", func() bool {
		term.view.Pump()
		return strings.Contains(strings.Join(strings.Fields(term.view.RetainedText(1<<16)), ""), want)
	})
}

// showsControl reports whether a control named label is shown.
func (h *harness) showsControl(label string) bool {
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel {
			return true
		}
	}
	return false
}

// The Terminal tool window of a remote workspace runs the host account's login shell in the host
// folder: the request carries the workspace's session, Lithe's own variables and a label of the
// connection's name, and the tab is named after the connection. What is typed reaches the host in
// order, also after the host asked to wait, and the size goes with it. There is no menu of this
// computer's shells, closing the tab ends the host terminal without anything failing, and
// neither the host nor its paths are logged.
func TestRemoteWorkspaceTerminalRunsOnTheHost(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)
	if len(p.terms.list) != 1 || len(k.terminals.started()) != 0 {
		t.Fatalf("the workspace opened with %d terminals, %d running before they were shown", len(p.terms.list), len(k.terminals.started()))
	}
	term, run := h.openRemoteTerminal(t, k, p)

	if run.session != p.remote.session || run.open.Cwd != remoteTestHome+"/project" || len(run.open.Argv) != 0 {
		t.Fatalf("the terminal ran in session %v, argv %d, cwd matched %v", run.session == p.remote.session, len(run.open.Argv), run.open.Cwd == remoteTestHome+"/project")
	}
	if run.open.Env["TERM_PROGRAM"] != "Lithe" || run.open.Columns == 0 || run.open.Rows == 0 {
		t.Fatalf("the terminal started with env %v and %dx%d cells", slices.Sorted(mapKeys(run.open.Env)), run.open.Columns, run.open.Rows)
	}
	if label := run.open.Label; label == nil || label.Kind != "terminal" || label.Name != remoteTestHost {
		t.Fatal("the host terminal is not labelled with the connection's name")
	}
	if got := h.app.terminalTitle(term); got != remoteTestHost {
		t.Fatal("the tab is not named after the connection")
	}
	h.redraw()
	if h.showsWrapped(i18n.Shared(lang, "desktop.remote.workspace.localOnly")) || h.showsControl(h.app.text.Terminal.ShellMenu) {
		t.Fatal("the Terminal tool window says it does not work here or offers this computer's shells")
	}

	k.terminals.set(func(h *remoteHostTerminals) { h.busy = 2 })
	if !term.view.SendLine("echo hi") {
		t.Fatal("the terminal did not take the line")
	}
	h.awaitTerminal(term, remoteHostPrompt+" echo hi")
	if got := k.terminals.typedInto(run); got != "echo hi\r" {
		t.Fatalf("the host took %q", got)
	}
	if k.terminals.read(func(h *remoteHostTerminals) bool { return h.busy != 0 }) {
		t.Fatal("the input was not offered again after the host asked to wait")
	}

	second := h.app.newTerminalWith(p, terminalOptions{activate: true})
	if second == nil || h.app.terminalTitle(second) != remoteTestHost+" (2)" {
		t.Fatal("the second terminal is not numbered after the connection's name")
	}
	h.app.closeTerminal(p, term.id)
	h.await("the host terminal to end", func() bool {
		select {
		case <-run.ended:
			return true
		default:
			return false
		}
	})
	h.settle()
	if p.remote.session == "" || countFailures(logger, "remote_terminal") != 0 || countFailures(logger, "remote_session_lost") != 0 {
		t.Fatal("closing the tab failed or ended the session")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A host terminal whose connection closes ends, and the workspace connects again. While it has no
// session, Enter says the workspace is not connected; once it is connected again, Enter starts a
// new shell on the new session.
func TestRemoteWorkspaceTerminalEndsWithTheConnection(t *testing.T) {
	h, k, timers, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)
	term, run := h.openRemoteTerminal(t, k, p)

	k.set(func(k *remoteHostKernel) { k.refuse = core.RemoteProbeUnreachable })
	run.end <- remoteHostEnd{err: &core.Error{Command: "remote.runTerminal", Code: core.CodeConnectionClosed, Message: "connection to " + remoteTestHost + " closed"}}
	h.await("the workspace to lose its session", func() bool { return p.remote.session == "" && p.remote.reconnecting == nil })
	h.awaitTerminal(term, h.app.text.Terminal.SessionEnded)
	if countFailures(logger, "remote_session_lost") != 1 || countFailures(logger, "remote_terminal") != 0 {
		t.Fatal("the lost connection was not logged once as the session's")
	}

	if !term.view.Restart() {
		t.Fatal("Enter did not start the terminal again")
	}
	h.awaitTerminal(term, i18n.Shared(lang, "desktop.remote.terminal.notConnected"))
	if len(k.terminals.started()) != 1 {
		t.Fatal("a terminal started without a session")
	}

	k.set(func(k *remoteHostKernel) { k.refuse = "" })
	h.fireReconnect(t, timers, p.remote)
	if p.remote.session == "" || p.remote.session == run.session {
		t.Fatal("the workspace did not connect again")
	}
	if !term.view.Restart() {
		t.Fatal("Enter did not start the terminal again")
	}
	h.await("a terminal on the new session", func() bool { return len(k.terminals.started()) == 2 })
	if again := k.terminals.started()[1]; again.session != p.remote.session {
		t.Fatal("the new terminal did not run on the new session")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A host terminal that cannot start shows Core's reason, and what is logged keeps only the
// command and its code.
func TestRemoteWorkspaceTerminalShowsWhyItDidNotStart(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	reason := "cannot change to " + remoteTestHome + "/project: no such directory"
	k.terminals.set(func(h *remoteHostTerminals) {
		h.refuse = &core.Error{Command: "remote.runTerminal", Code: core.CodeProcessFailed, Message: reason}
	})
	h.clickTerminalButton()
	h.await("a terminal tab", func() bool { return len(p.terms.list) == 1 })
	h.awaitTerminal(p.terms.list[0], reason)
	if len(k.terminals.started()) != 0 || p.remote.session == "" {
		t.Fatal("a refused terminal ran or ended the session")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// Paths dropped on a host terminal are pasted as the host's, quoted for a POSIX shell; a path of
// this computer outside the workspace is left out, and a drop of only such paths pastes nothing
// and says why.
func TestRemoteWorkspaceTerminalTakesTheHostPathsOfDroppedFiles(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)
	term, run := h.openRemoteTerminal(t, k, p)
	outside := filepath.Join(t.TempDir(), "local.txt")

	h.app.pasteTerminalPaths(term, []string{filepath.Join(p.root, "src", "it's.go"), outside, p.root})
	want := "'" + remoteTestHome + `/project/src/it'\''s.go' '` + remoteTestHome + "/project' "
	h.await("the host paths to reach the host", func() bool { return k.terminals.typedInto(run) == want })

	h.app.pasteTerminalPaths(term, []string{outside})
	h.settle()
	if k.terminals.typedInto(run) != want {
		t.Fatal("a path of this computer was pasted into the host terminal")
	}
	if !rejected(logger, "terminal_drop_path", "remote_workspace") {
		t.Fatal("the refused drop was not logged")
	}
	if !slices.ContainsFunc(h.app.notifications.list, func(n *notification) bool {
		return n.text == i18n.Shared(lang, "desktop.remote.terminal.dropOutside")
	}) {
		t.Fatal("the refused drop was not notified")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// remoteTestShell starts a host terminal of k over a binding attached to session-1, outside a
// window: lost and failed record what the window would be told.
func remoteTestShell(t *testing.T, k *remoteHostKernel) (*remoteShell, *remoteShellReports) {
	t.Helper()
	binding := core.NewRemoteWorkspace(filepath.Join(t.TempDir(), "project"), remoteTestHome+"/project", nil)
	binding.Attach("session-1")
	ctx, cancel := context.WithCancel(context.Background())
	reports := &remoteShellReports{}
	host := remoteTerminalHost{
		kernel:  k,
		binding: binding,
		ctx:     ctx,
		open:    core.RemoteTerminalOpen{Cwd: remoteTestHome + "/project"},
		notify:  func() {},
		lost: func(session string, err error) {
			reports.mu.Lock()
			defer reports.mu.Unlock()
			reports.lost = append(reports.lost, session)
		},
		failed: func(operation string, err error) {
			reports.mu.Lock()
			defer reports.mu.Unlock()
			reports.failed = append(reports.failed, operation)
		},
	}
	shell, err := host.start(80, 24)
	if err != nil {
		cancel()
		t.Fatalf("start: %v", err)
	}
	s := shell.(*remoteShell)
	t.Cleanup(func() {
		cancel()
		deadline := time.NewTimer(8 * time.Second)
		defer deadline.Stop()
		select {
		case <-s.Done():
		case <-deadline.C:
			t.Error("the host terminal did not end with its request")
		}
	})
	return s, reports
}

// remoteTestShellAlone is a host terminal with no request behind it, whose input and output a
// test drives by hand; failed records what it logged.
func remoteTestShellAlone(reports *remoteShellReports) *remoteShell {
	return &remoteShell{
		host: remoteTerminalHost{
			notify: func() {},
			failed: func(operation string, err error) {
				reports.mu.Lock()
				defer reports.mu.Unlock()
				reports.failed = append(reports.failed, operation)
			},
		},
		wake: make(chan struct{}, 1),
	}
}

// remoteShellReports are what a host terminal told the window.
type remoteShellReports struct {
	mu     sync.Mutex
	lost   []string
	failed []string
}

func (r *remoteShellReports) snapshot() (lost, failed []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.lost), slices.Clone(r.failed)
}

// The sender gives the host the size before input typed after it, and the input in order, in
// chunks no larger than one write takes, also after the host asked it to wait.
func TestRemoteShellSendsTheSizeAndChunkedInputInOrder(t *testing.T) {
	k := &remoteHostKernel{testKernel: &testKernel{Client: core.NewClient()}}
	s, reports := remoteTestShell(t, k)
	run := k.terminals.started()[0]

	k.terminals.set(func(h *remoteHostTerminals) { h.busy = 1 })
	s.Resize(120, 40)
	big := strings.Repeat("x", remoteTerminalWriteChunk+10)
	if !s.Write([]byte(big)) || !s.Write([]byte("tail")) {
		t.Fatal("the terminal did not take the input")
	}
	k.terminals.await(t, "the input to reach the host", func() bool { return k.terminals.typedInto(run) == big+"tail" })
	// The size was pending whenever input was, and the sender sends a pending size first, so
	// the host had it before the first chunk.
	if !k.terminals.read(func(h *remoteHostTerminals) bool {
		return slices.Equal(h.resizes, []string{"120x40"}) && len(h.writes) >= 2 && slices.Max(h.writes) <= remoteTerminalWriteChunk && h.busy == 0
	}) {
		t.Fatal("the host was not told the size once, or was given more than a chunk in a write")
	}
	if lost, failed := reports.snapshot(); len(lost) != 0 || len(failed) != 0 {
		t.Fatalf("lost %d, failed %q", len(lost), failed)
	}
}

type remoteTerminalExitBeforeWriteReply struct {
	Kernel
	exit func()
}

func (k remoteTerminalExitBeforeWriteReply) RemoteTerminalWrite(context.Context, string, uint64, []byte) (bool, error) {
	k.exit()
	return false, nil
}

func (remoteTerminalExitBeforeWriteReply) RemoteRunTerminal(context.Context, string, core.RemoteTerminalOpen, core.RemoteTerminalEvents) (core.RemoteTerminalExit, error) {
	return core.RemoteTerminalExit{}, nil
}

func TestRemoteShellStopsWhenWriteIsAcknowledgedAfterExit(t *testing.T) {
	reports := &remoteShellReports{}
	s := remoteTestShellAlone(reports)
	s.ctx, s.done = t.Context(), make(chan struct{})
	s.host.kernel = remoteTerminalExitBeforeWriteReply{exit: func() {
		// The terminal stream finishes before the independent write RPC answers.
		s.run(core.RemoteTerminalOpen{})
	}}
	if !s.Write([]byte("pending input\n")) {
		t.Fatal("the terminal did not queue the input")
	}
	if s.sendNext() {
		t.Fatal("the sender continued after the terminal exited")
	}
	if s.Write([]byte("after exit")) || s.Err() != nil {
		t.Fatalf("a clean exit did not close input: %v", s.Err())
	}
	if _, failed := reports.snapshot(); len(failed) != 0 {
		t.Fatalf("a clean exit reported failures: %v", failed)
	}
}

// A terminal holds at most remoteTerminalInputLimit of input the host has not taken: more is
// refused while that much waits, and nothing is taken once the program ended.
func TestRemoteShellBoundsTheInputItHolds(t *testing.T) {
	s := remoteTestShellAlone(&remoteShellReports{})
	if !s.Write(make([]byte, remoteTerminalInputLimit-1)) || !s.Write([]byte("x")) {
		t.Fatal("the terminal refused input within its limit")
	}
	if s.Write([]byte("y")) {
		t.Fatal("a terminal holding the most input it may took more")
	}
	s.mu.Lock()
	s.input, s.ended = nil, true
	s.mu.Unlock()
	if s.Write([]byte("z")) {
		t.Fatal("a terminal whose program ended took input")
	}
}

// Output the view does not read is bounded: the oldest is dropped and that is logged once.
func TestRemoteShellDropsTheOldestOutputPastItsLimit(t *testing.T) {
	reports := &remoteShellReports{}
	s := remoteTestShellAlone(reports)
	s.received([]byte(strings.Repeat("a", remoteTerminalOutputLimit)))
	s.received([]byte("bc"))
	s.received([]byte("d"))
	got := s.Drain(nil)
	if len(got) != remoteTerminalOutputLimit || !strings.HasSuffix(string(got), "bcd") {
		t.Fatalf("kept %d bytes", len(got))
	}
	if _, failed := reports.snapshot(); !slices.Equal(failed, []string{"remote_terminal_output"}) {
		t.Fatalf("failed %q, want the dropped output once", failed)
	}
}

// How a host terminal ended is what the view reads: an exit code or 128 plus the signal as the
// status, a hang-up of a terminal being closed as no failure, a closed connection told to the
// window, and another failure logged when the program ran and left to the view when it did not.
func TestRemoteShellReportsHowTheProgramEnded(t *testing.T) {
	code := func(n int) *int { return &n }
	closed := &core.Error{Command: "remote.runTerminal", Code: core.CodeConnectionClosed}
	broken := &core.Error{Command: "remote.runTerminal", Code: core.CodeProcessFailed}
	for _, c := range []struct {
		name    string
		exit    core.RemoteTerminalExit
		err     error
		closing bool
		status  int // -1: no status; 0: a clean end
		lost    bool
		failed  bool
		// unstarted is a request that ended before the host started the program.
		unstarted bool
	}{
		{name: "clean exit", exit: core.RemoteTerminalExit{ExitCode: code(0)}},
		{name: "exit code", exit: core.RemoteTerminalExit{ExitCode: code(3)}, status: 3},
		{name: "signal", exit: core.RemoteTerminalExit{Signal: code(15)}, status: 143},
		{name: "hang-up while closing", exit: core.RemoteTerminalExit{Signal: code(remoteSIGHUP)}, closing: true},
		{name: "kill while closing", exit: core.RemoteTerminalExit{Signal: code(remoteSIGKILL)}, closing: true},
		{name: "hang-up", exit: core.RemoteTerminalExit{Signal: code(remoteSIGHUP)}, status: 129},
		{name: "cancelled", err: context.Canceled, closing: true},
		{name: "connection closed", err: closed, status: -1, lost: true},
		{name: "failure", err: broken, status: -1, failed: true},
		// The view shows and logs why the program did not start.
		{name: "failure before the start", err: broken, status: -1, unstarted: true},
		{name: "connection closed before the start", err: closed, status: -1, lost: true, unstarted: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			var lost, failed bool
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if c.closing {
				cancel()
			}
			s := &remoteShell{
				host: remoteTerminalHost{
					lost:   func(string, error) { lost = true },
					failed: func(string, error) { failed = true },
				},
				ctx:     ctx,
				started: make(chan struct{}),
			}
			if !c.unstarted {
				close(s.started)
			}
			err := s.endError(c.exit, c.err)
			var exit interface{ ExitStatus() int }
			switch {
			case c.status == 0 && err != nil:
				t.Fatalf("err = %v, want a clean end", err)
			case c.status > 0 && (!errors.As(err, &exit) || exit.ExitStatus() != c.status):
				t.Fatalf("err = %v, want status %d", err, c.status)
			case c.status < 0 && (err == nil || errors.As(err, &exit)):
				t.Fatalf("err = %v, want the request's error", err)
			}
			if lost != c.lost || failed != c.failed {
				t.Fatalf("lost %v, failed %v", lost, failed)
			}
		})
	}
}

// A host terminal of a workspace without a session does not reach the host and says why.
func TestRemoteShellWithoutASessionSaysTheWorkspaceIsNotConnected(t *testing.T) {
	k := &remoteHostKernel{testKernel: &testKernel{Client: core.NewClient()}}
	host := remoteTerminalHost{kernel: k, binding: core.NewRemoteWorkspace(t.TempDir(), remoteTestHome, nil), ctx: context.Background(), notConnected: "not connected"}
	_, err := host.start(80, 24)
	if err == nil || err.Error() != "not connected" || !errors.Is(err, errRemoteSessionClosed) || len(k.terminals.started()) != 0 {
		t.Fatalf("start = %v, ran %d", err, len(k.terminals.started()))
	}
}

func mapKeys(m map[string]string) func(func(string) bool) {
	return func(yield func(string) bool) {
		for key := range m {
			if !yield(key) {
				return
			}
		}
	}
}
