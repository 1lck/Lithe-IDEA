package workbench

import (
	"context"
	"errors"
	"maps"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
)

// A terminal of a remote workspace runs on the host (#2231, R0, step 3): its program is the host
// account's login shell, started by the server in the host folder the terminal was opened in,
// and the terminal view draws what Core relays (remote.runTerminal). Nothing of it runs on this
// computer. The shell menu's programs are this computer's, so a remote workspace offers none of
// them, and a picture pasted into the terminal would be saved on this computer, so it is not
// offered either. A plugin's terminal still runs only in a local project.
//
// The terminal lives as long as its request. Closing the tab ends the request, and Core then hangs
// the program up and kills it soon after; a lost connection ends it too, and the workspace
// connects again (loseRemote). Enter starts a new shell once the workspace is connected again.

const (
	// remoteTerminalOutputLimit bounds the output a host terminal holds for its view. The view
	// takes everything at each frame; only a window that stops drawing lets output pile up, and
	// the oldest is then dropped rather than stalling Core's event stream, which would end the
	// terminal (core.RemoteTerminalEvents).
	remoteTerminalOutputLimit = 8 << 20
	// remoteTerminalInputLimit bounds what was typed and not yet taken by the host, as
	// localshell bounds its backlog.
	remoteTerminalInputLimit = 4 << 20
	// remoteTerminalWriteChunk is the most one terminal.write sends.
	remoteTerminalWriteChunk = 32 << 10
	// remoteTerminalRequestTimeout bounds one write or resize.
	remoteTerminalRequestTimeout = 10 * time.Second
	// The pause after the host refused input it could not take yet doubles from
	// remoteTerminalBusyFirstPause up to remoteTerminalBusyMaxPause.
	remoteTerminalBusyFirstPause = 10 * time.Millisecond
	remoteTerminalBusyMaxPause   = 250 * time.Millisecond
	// remoteSIGHUP and remoteSIGKILL are the Linux signals that end a host program Core closes.
	remoteSIGHUP  = 1
	remoteSIGKILL = 9
)

var (
	// errRemoteTerminalOutputDropped is logged once for a terminal whose view stopped taking
	// its output long enough that the oldest of it was dropped.
	errRemoteTerminalOutputDropped = errors.New("remote terminal: output dropped while the view did not read it")
	// errRemoteTerminalInputDropped is logged once for a terminal whose host refused input.
	errRemoteTerminalInputDropped = errors.New("remote terminal: input dropped")
)

// remoteTerminalStartError is why a host terminal did not start. Error is the reason the
// terminal shows; the cause is what the log keeps of it (remoteLogError).
type remoteTerminalStartError struct {
	reason string
	cause  error
}

func (e *remoteTerminalStartError) Error() string { return e.reason }
func (e *remoteTerminalStartError) Unwrap() error { return e.cause }

// remoteExitStatus is a host program's end that was not a clean exit, as termview reads it.
type remoteExitStatus int

func (s remoteExitStatus) Error() string {
	return "remote terminal: program ended with status " + strconv.Itoa(int(s))
}

// ExitStatus is the status the terminal reports: the exit code, or 128 plus the signal that
// ended the program, as a shell reports one.
func (s remoteExitStatus) ExitStatus() int { return int(s) }

// remoteTerminalHost is what a host terminal needs of the workbench, taken on the window thread
// when the terminal is made: every method runs off it.
type remoteTerminalHost struct {
	kernel  Kernel
	binding *core.RemoteWorkspace
	// ctx ends with the terminal's tab; each start's request runs under a child of it.
	ctx    context.Context
	open   core.RemoteTerminalOpen
	notify func()
	// notConnected is the reason shown when the workspace has no session.
	notConnected string
	// lost tells the window the session's connection closed; failed logs a failure.
	lost   func(session string, err error)
	failed func(operation string, err error)
}

// start runs the host terminal in a grid of cols by rows cells and returns once the host
// started it, or why it could not. It blocks, so termview runs it off the window thread.
func (h remoteTerminalHost) start(cols, rows int) (termview.Shell, error) {
	session := h.binding.SessionID()
	if session == "" {
		return nil, &remoteTerminalStartError{reason: h.notConnected, cause: errRemoteSessionClosed}
	}
	ctx, cancel := context.WithCancel(h.ctx)
	s := &remoteShell{
		host:    h,
		session: session,
		ctx:     ctx,
		cancel:  cancel,
		wake:    make(chan struct{}, 1),
		started: make(chan struct{}),
		done:    make(chan struct{}),
	}
	open := h.open
	open.Env = maps.Clone(h.open.Env)
	open.Columns, open.Rows = remoteCells(cols), remoteCells(rows)
	go s.run(open)
	select {
	case <-s.started:
	case <-s.done:
		if !s.hasStarted() {
			cancel()
			return nil, h.startError(s.err)
		}
		// It started and ended at once; the view shows its output and its end.
	}
	go s.send()
	return s, nil
}

// startError is the failure to start a host terminal as the terminal shows it.
func (h remoteTerminalHost) startError(err error) error {
	if remoteConnectionClosed(err) {
		return &remoteTerminalStartError{reason: h.notConnected, cause: err}
	}
	reason := err.Error()
	var coreErr *core.Error
	if errors.As(err, &coreErr) && coreErr.Message != "" {
		// Core's message is the server's diagnostic, which the terminal shows as it is.
		reason = coreErr.Message
	}
	return &remoteTerminalStartError{reason: reason, cause: err}
}

// remoteCells is a grid dimension as a host terminal takes it: at least 1, at most 65535.
func remoteCells(n int) uint16 {
	return uint16(min(max(n, 1), 1<<16-1))
}

// remoteShell is a host terminal as termview drives it: a termview.Shell whose program runs on
// the workspace's host.
type remoteShell struct {
	host    remoteTerminalHost
	session string
	// ctx is the start's request; cancel ends it.
	ctx    context.Context
	cancel context.CancelFunc
	// started is closed when the host started the program, done when the request returned.
	started     chan struct{}
	startedOnce sync.Once
	done        chan struct{}
	// wake tells the sender there is input or a size to send.
	wake chan struct{}

	mu       sync.Mutex
	terminal uint64
	output   []byte
	dropped  bool
	input    []byte
	// cols and rows are the size to send once resized is set.
	cols, rows uint16
	resized    bool
	inputLost  bool
	ended      bool
	// err is why the program ended, set before done is closed.
	err error
}

// run is the start's request: it returns when the program ends or the terminal closes.
func (s *remoteShell) run(open core.RemoteTerminalOpen) {
	exit, err := s.host.kernel.RemoteRunTerminal(s.ctx, s.session, open, core.RemoteTerminalEvents{
		Started: func(terminalID uint64) {
			s.startedOnce.Do(func() {
				s.mu.Lock()
				s.terminal = terminalID
				s.mu.Unlock()
				close(s.started)
			})
		},
		Output: s.received,
	})
	end := s.endError(exit, err)
	s.mu.Lock()
	s.ended, s.input, s.err = true, nil, end
	s.mu.Unlock()
	close(s.done)
	s.host.notify()
}

// endError is why the program ended as termview reads it: nil for a clean exit and for a
// terminal that was closed, an ExitStatus for any other exit, and the request's error
// otherwise. A closed connection is reported to the window, which connects again; another
// failure of a terminal that ran is logged here, while one that kept it from starting is the
// view's to show and log.
func (s *remoteShell) endError(exit core.RemoteTerminalExit, err error) error {
	closing := s.ctx.Err() != nil
	switch {
	case err != nil && closing:
		return nil
	case err != nil:
		if remoteConnectionClosed(err) {
			s.host.lost(s.session, err)
		} else if s.hasStarted() {
			s.host.failed("remote_terminal", err)
		}
		return err
	case exit.ExitCode != nil && *exit.ExitCode != 0:
		return remoteExitStatus(*exit.ExitCode)
	case exit.Signal != nil:
		if closing && (*exit.Signal == remoteSIGHUP || *exit.Signal == remoteSIGKILL) {
			return nil
		}
		return remoteExitStatus(128 + *exit.Signal)
	}
	return nil
}

// hasStarted reports whether the host started the program.
func (s *remoteShell) hasStarted() bool {
	select {
	case <-s.started:
		return true
	default:
		return false
	}
}

// received keeps output for the view. It runs on the request's goroutine and never waits.
func (s *remoteShell) received(data []byte) {
	s.mu.Lock()
	s.output = append(s.output, data...)
	dropped := false
	if over := len(s.output) - remoteTerminalOutputLimit; over > 0 {
		s.output = s.output[:copy(s.output, s.output[over:])]
		dropped, s.dropped = !s.dropped, true
	}
	s.mu.Unlock()
	if dropped {
		s.host.failed("remote_terminal_output", errRemoteTerminalOutputDropped)
	}
	s.host.notify()
}

// Drain appends the output received since the last call to dst.
func (s *remoteShell) Drain(dst []byte) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	dst = append(dst, s.output...)
	s.output = s.output[:0]
	if cap(s.output) > remoteTerminalWriteChunk {
		s.output = nil // do not keep a flood's buffer
	}
	return dst
}

// Write queues input for the host and reports whether it was taken: false once the program
// ended or while remoteTerminalInputLimit of earlier input waits.
func (s *remoteShell) Write(p []byte) bool {
	if len(p) == 0 {
		return true
	}
	s.mu.Lock()
	ok := !s.ended && len(s.input)+len(p) <= remoteTerminalInputLimit
	if ok {
		s.input = append(s.input, p...)
	}
	s.mu.Unlock()
	if ok {
		s.signal()
	}
	return ok
}

// Resize sends the host the terminal's size; a size sent later replaces one not sent yet.
func (s *remoteShell) Resize(cols, rows int) {
	s.mu.Lock()
	s.cols, s.rows, s.resized = remoteCells(cols), remoteCells(rows), true
	s.mu.Unlock()
	s.signal()
}

func (s *remoteShell) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *remoteShell) Done() <-chan struct{} { return s.done }

// Err says why the program ended, once Done is closed.
func (s *remoteShell) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

// Busy is false: the server does not report what the host shell runs.
func (s *remoteShell) Busy() bool { return false }

// Kind is Unknown: the host's login shell is not known by name.
func (s *remoteShell) Kind() shellkind.Kind { return shellkind.Unknown }

// Close ends the request, and Core closes the host terminal.
func (s *remoteShell) Close() { s.cancel() }

// send delivers the size and the input to the host, in the order they were given, until the
// terminal ends. A host that cannot take input yet takes it again after a pause; input the host
// refused for another reason is dropped, as a pty drops what is typed into a program that ended.
func (s *remoteShell) send() {
	for {
		select {
		case <-s.done:
			return
		case <-s.wake:
		}
		for s.sendNext() {
		}
	}
}

// sendNext sends the pending size, or else the next chunk of input, and reports whether it
// sent anything.
func (s *remoteShell) sendNext() bool {
	s.mu.Lock()
	terminal, ended := s.terminal, s.ended
	resize, cols, rows := s.resized, s.cols, s.rows
	s.resized = false
	var chunk []byte
	if !resize {
		chunk = append(chunk, s.input[:min(len(s.input), remoteTerminalWriteChunk)]...)
	}
	s.mu.Unlock()
	if ended || (!resize && len(chunk) == 0) {
		return false
	}
	if resize {
		err := s.request(func(ctx context.Context) error {
			return s.host.kernel.RemoteTerminalResize(ctx, s.session, terminal, cols, rows)
		})
		s.refused(err, false)
		return true
	}
	pause := remoteTerminalBusyFirstPause
	for {
		var busy bool
		err := s.request(func(ctx context.Context) error {
			var err error
			busy, err = s.host.kernel.RemoteTerminalWrite(ctx, s.session, terminal, chunk)
			return err
		})
		if err == nil && busy {
			if !s.wait(pause) {
				return false
			}
			pause = min(2*pause, remoteTerminalBusyMaxPause)
			continue
		}
		s.mu.Lock()
		// The terminal stream can clear the queue before a write is acknowledged.
		ended = s.ended
		if !ended {
			if err == nil {
				s.input = s.input[:copy(s.input, s.input[len(chunk):])]
			} else {
				s.input = nil
			}
		}
		s.mu.Unlock()
		s.refused(err, true)
		return !ended
	}
}

// request runs one host request of the terminal, bounded by remoteTerminalRequestTimeout.
func (s *remoteShell) request(do func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(s.ctx, remoteTerminalRequestTimeout)
	defer cancel()
	return do(ctx)
}

// refused handles a write or a resize the host did not take. A closed connection is the
// window's to handle; a terminal that ended or closed reports its end itself; anything else is
// logged once.
func (s *remoteShell) refused(err error, input bool) {
	if err == nil || s.ctx.Err() != nil {
		return
	}
	if remoteConnectionClosed(err) {
		s.host.lost(s.session, err)
		return
	}
	select {
	case <-s.done:
		return
	default:
	}
	s.mu.Lock()
	first := !s.inputLost
	s.inputLost = true
	s.mu.Unlock()
	if first {
		operation := "remote_terminal_resize"
		if input {
			operation = "remote_terminal_input"
		}
		s.host.failed(operation, errors.Join(errRemoteTerminalInputDropped, err))
	}
}

// wait pauses for d and reports false when the terminal ended or closed meanwhile.
func (s *remoteShell) wait(d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-s.done:
		return false
	case <-s.ctx.Done():
		return false
	}
}

// remoteTerminalConfig makes config start terminal t of the remote workspace p on the host, in
// dir, with env added to the server's environment. It returns what cancels the terminal's
// requests when its tab closes.
func (a *App) remoteTerminalConfig(p *project, t *terminal, config *termview.Config, dir string, env []string) context.CancelFunc {
	r := p.remote
	ctx, cancel := context.WithCancel(p.ctx)
	host := remoteTerminalHost{
		kernel:  a.kernel,
		binding: r.binding,
		ctx:     ctx,
		open: core.RemoteTerminalOpen{
			Cwd:   p.remoteTerminalDir(dir),
			Env:   environmentMap(env),
			Label: core.NewRemoteResourceLabel("terminal", a.terminalTitle(t)),
		},
		notify:       a.invalidator.Invalidate,
		notConnected: i18n.Shared(a.language(), "desktop.remote.terminal.notConnected"),
		lost: func(session string, err error) {
			a.post(func(a *App) {
				if a.project == p {
					a.loseRemote(p, session, err)
				}
			})
		},
		failed: func(operation string, err error) { a.backgroundFailedIn(ctx, operation, remoteLogError(err)) },
	}
	config.Open = host.start
	config.Shell, config.Args, config.Unset = "", nil, nil
	// A picture pasted into the terminal would be saved on this computer, where the host's
	// shell cannot read it.
	config.PasteImage = nil
	// The reason a host terminal did not start may name a host path, which the log does not
	// keep.
	failed := config.Failed
	config.Failed = func(f termview.Failure) {
		if f.Err != nil {
			f.Err = remoteLogError(f.Err)
		}
		failed(f)
	}
	return cancel
}

// remoteTerminalDir is the host folder a terminal of the remote workspace p opened in dir starts
// in: dir's host path, or the workspace's host folder when dir is not in the project.
func (p *project) remoteTerminalDir(dir string) string {
	if host, ok := p.remoteHostPathWithin(dir); ok {
		return host
	}
	return p.remote.binding.RemoteRoot()
}

// remoteHostPathWithin is the host path of full when full is the remote workspace's root or a
// path below it; ok is false for any other path, which names nothing on the host.
func (p *project) remoteHostPathWithin(full string) (string, bool) {
	if p.remote == nil || full == "" {
		return "", false
	}
	rel, err := filepath.Rel(p.root, full)
	if err != nil || filepath.IsAbs(rel) || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	return p.remoteHostPath(full), true
}

// environmentMap is env, a list of NAME=value, as a map; a later entry replaces an earlier one.
func environmentMap(env []string) map[string]string {
	if len(env) == 0 {
		return nil
	}
	m := make(map[string]string, len(env))
	for _, entry := range env {
		if name, value, ok := strings.Cut(entry, "="); ok && name != "" {
			m[name] = value
		}
	}
	return m
}

// remoteTerminalTitle is the tab title of the number-th terminal of a remote workspace whose
// connection is named name: the name alone for the first, then the name with its number.
func remoteTerminalTitle(language i18n.Language, name string, number int) string {
	if number <= 1 {
		return name
	}
	return i18n.SharedFormat(language, "desktop.remote.terminal.tabNumber", map[string]string{"name": name, "number": strconv.Itoa(number)})
}

// pasteRemoteTerminalPaths pastes the host paths of paths into terminal t of the remote
// workspace p, quoted for a POSIX shell. A path outside the project names nothing on the host and
// is left out; nothing is pasted when none is left.
func (a *App) pasteRemoteTerminalPaths(p *project, t *terminal, paths []string) {
	quoted := make([]string, 0, len(paths))
	for _, full := range paths {
		if host, ok := p.remoteHostPathWithin(full); ok {
			quoted = append(quoted, quoteShellPath(shellkind.POSIX, host))
		}
	}
	if len(quoted) == 0 {
		a.operationRejected("terminal_drop_path", "remote_workspace")
		a.notifyInfo(i18n.Shared(a.language(), "desktop.remote.terminal.dropOutside"))
		return
	}
	if t.view.Paste(strings.Join(quoted, " ") + " ") {
		a.focusTerminal(t.id)
	}
}
