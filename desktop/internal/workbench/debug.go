package workbench

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

const (
	// debugOutputLines bounds the adapter diagnostics the panel keeps.
	debugOutputLines = 200
	// debugMaxFrames bounds the call stack a panel row list can hold.
	debugMaxFrames = 200
	// debugOperationTimeout bounds one inspect or execute request when the
	// adapter never answers.
	debugOperationTimeout = 20 * time.Second
	// debugStopTimeout bounds the disconnect and process shutdown on Stop.
	debugStopTimeout = 10 * time.Second
)

// debugAdapter is one installed plugin's debug adapter declaration, reached over
// stdio or through its plugin's language server (tcpLanguageServer).
type debugAdapter struct {
	PluginID    string
	Directory   string
	Version     string
	Manifest    json.RawMessage
	Declaration pluginservice.DebugAdapterDeclaration
}

// debugState is the Debug tool window's state for one project. The window shows
// one session at a time: debugSessionView is the view of that session, and
// sessions[current] owns it. A session keeps its own view while it is not shown.
type debugState struct {
	loaded          bool
	loading         bool
	adapters        []debugAdapter
	selectedAdapter int
	// breakpoints maps an absolute source path to its breakpoints, sorted by line, and
	// breakpointEdit is the open editor of one of them (debug_breakpoints.go).
	breakpoints    map[string][]debugBreakpoint
	breakpointEdit debugBreakpointEdit
	// functionBreakpoints are the named method breakpoints of the session, and functionName the
	// text the user is typing for the next one.
	functionBreakpoints []core.DebugFunctionBreakpoint
	functionName        string
	// instructionBreakpoints are the machine-instruction breakpoints of the session, by address text.
	instructionBreakpoints []core.DebugInstructionBreakpoint
	// dataBreakpoints are the variables the session stops on when they change.
	dataBreakpoints []debugDataBreakpoint
	// sessions are the live sessions of the project in start order; a child session
	// follows the parent that started it. current indexes the one the window shows.
	sessions   []*debugSession
	current    int
	generation uint64
	// remote is the non-local attach the user has not yet confirmed.
	remote *debugRemotePrompt
	// pendingRemote is the start in flight, kept so a remote endpoint can be
	// confirmed and the same start repeated.
	pendingRemote *debugStart
	// debugSessionView is what the window shows for the current session.
	debugSessionView
}

// debugSessionView is what the Debug window shows for one session: its stop, stack,
// variables, output and the status of its own start.
type debugSessionView struct {
	state   string
	status  string
	failure string
	// output is the adapter's bounded stderr and console text.
	output    []string
	exception *core.DebugExceptionInfo
	frames    []core.DebugStackFrame
	// hideFiltered collapses the frames the session's stepping filters match into one
	// row per run; framesExpanded shows them again until the next stack arrives.
	hideFiltered   bool
	framesExpanded bool
	// frameRows is the call stack's rows of the last paint, kept to reuse its memory.
	frameRows []debugFrameRow
	// pausedThread is the thread the last stopped event named.
	pausedThread *int64
	// threads is the adapter's thread list for the current stop and selectedThread the
	// one its stack shows; both are cleared when the debuggee continues.
	threads        []core.DebugThread
	selectedThread int64
	threadsFailure string
	// threadSequence numbers the thread requests of this connection.
	threadSequence uint64
	// watch holds the expressions the user added and their last values, and
	// memory the read-only bytes of the selected frame.
	watch  debugWatch
	memory debugMemory
	// capabilities is what the adapter negotiated; nil until its capabilities
	// event arrives, and a UI treats nil as unknown rather than unsupported.
	capabilities *core.DebugCapabilities
	// vars, exceptions and disassembly are the sections under the call stack.
	vars        debugVariables
	exceptions  debugExceptions
	disassembly debugDisassembly
	section     string
}

func (s *debugState) reset() { *s = debugState{} }

// activeSession is the session the Debug window shows, or nil when none runs.
func (s *debugState) activeSession() *debugSession {
	if s.current < 0 || s.current >= len(s.sessions) {
		return nil
	}
	return s.sessions[s.current]
}

// hasSession reports whether the session is still one the project runs.
func (s *debugState) hasSession(session *debugSession) bool {
	return slices.Contains(s.sessions, session)
}

// addSession appends a started session and makes it the one the window shows. The
// session it replaces keeps the view it had.
func (s *debugState) addSession(session *debugSession) {
	if shown := s.activeSession(); shown != nil {
		shown.view = s.debugSessionView
	}
	s.sessions = append(s.sessions, session)
	s.current = len(s.sessions) - 1
	s.debugSessionView = session.view
}

// selectSession shows another live session and brings back the view it kept.
func (s *debugState) selectSession(index int) {
	if index == s.current || index < 0 || index >= len(s.sessions) {
		return
	}
	if shown := s.activeSession(); shown != nil {
		shown.view = s.debugSessionView
	}
	s.current = index
	s.debugSessionView = s.sessions[index].view
}

// removeSession drops an ended session. When it was the one shown, the window moves to
// the next live session; with none left, the last view stays as it was after Stop.
func (s *debugState) removeSession(session *debugSession) {
	index := slices.Index(s.sessions, session)
	if index < 0 {
		return
	}
	shown := index == s.current
	s.sessions = slices.Delete(s.sessions, index, index+1)
	switch {
	case len(s.sessions) == 0:
		s.current = 0
	case shown:
		if s.current >= len(s.sessions) {
			s.current = len(s.sessions) - 1
		}
		s.debugSessionView = s.sessions[s.current].view
	case s.current > index:
		s.current--
	}
}

// descendantsOf lists the live sessions that a session's adapter started, at any depth.
func (s *debugState) descendantsOf(session *debugSession) []*debugSession {
	var descendants []*debugSession
	for _, candidate := range s.sessions {
		for ancestor := candidate.parent; ancestor != nil; ancestor = ancestor.parent {
			if ancestor == session {
				descendants = append(descendants, candidate)
				break
			}
		}
	}
	return descendants
}

// bindSession makes session's view the one the state describes while one of its
// updates is applied, and returns the function that gives the shown session back. A
// session the window does not show keeps its events in its own view this way.
func (s *debugState) bindSession(session *debugSession) (restore func()) {
	shown := s.activeSession()
	if shown == nil || shown == session || !s.hasSession(session) {
		return func() {}
	}
	shownView := s.debugSessionView
	s.current = slices.Index(s.sessions, session)
	s.debugSessionView = session.view
	return func() {
		session.view = s.debugSessionView
		if index := slices.Index(s.sessions, shown); index >= 0 {
			s.current = index
			s.debugSessionView = shownView
			return
		}
		// The shown session ended inside this update, so the view of the update's
		// session stays as the window's last view.
		if index := slices.Index(s.sessions, session); index >= 0 {
			s.current = index
		} else {
			s.current = 0
		}
	}
}

// debugSession owns one adapter process and the matching Core session.
var debugSessionSequence atomic.Uint64

type debugSession struct {
	id        string
	adapterID string
	project   *project
	process   atomic.Pointer[buildprocess.Process]
	// transport is the write side of the adapter's byte stream: the adapter
	// process's stdin, or the TCP connection of a tcpLanguageServer adapter.
	// Closing it interrupts a blocked write, so Stop and shutdown use that.
	transportMu sync.Mutex
	transport   io.WriteCloser
	// writeTimeout bounds one write against a stalled adapter.
	writeTimeout time.Duration
	// observing is set when a goroutine watches the stream or process end and
	// will close exitObserved.
	observing      atomic.Bool
	stateDirectory string
	ctx            context.Context
	startupDone    chan struct{}
	exitObserved   chan struct{}
	created        bool
	operationMu    sync.Mutex
	cleanupOnce    sync.Once
	writeMu        sync.Mutex
	cancel         context.CancelFunc
	// stopped is set when Stop or project close already took the session apart.
	stopped atomic.Bool
	// exitCode is the debuggee's exit code from the terminated event, when the
	// adapter reported one. ended, when set, receives it once the session is released.
	exitCode atomic.Pointer[int]
	ended    chan *int
	// hosted is the lifecycle-driven stream of a tcpLanguageServer adapter; nil
	// for a stdio adapter. It is also the session's transport.
	hosted *debugTransport
	// drainOnStop marks a user stop: a live hosted session sends its disconnect
	// and lets Core's drain flush it instead of closing the stream at once.
	drainOnStop atomic.Bool
	failureMu   sync.Mutex
	failure     error
	// generation matches debugState.generation so an old pump publishes nothing.
	generation uint64
	// adapter is the declaration the session runs, so a child session starts on the same adapter.
	adapter debugAdapter
	// parent is the session whose adapter asked for this one through startDebugging;
	// startRequestID is that reverse request, answered once with this session's outcome.
	parent         *debugSession
	startRequestID string
	startAnswered  atomic.Bool
	// coreGone is set once Core removed this session with its parent's tree, so the
	// release does not ask Core to destroy it again.
	coreGone bool
	// view is the window's view of this session while another session is shown.
	view debugSessionView
}

// writeFrames writes Core's framed bytes to the adapter. The mutex keeps two
// writers from interleaving a frame.
func (s *debugSession) writeFrames(frames []string) error {
	if s == nil {
		return nil
	}
	transport := s.currentTransport()
	if transport == nil {
		return nil
	}
	// Closing the stream interrupts both a blocked write and a writer waiting
	// behind it. A native file also avoids exec.Cmd's stdin-copy goroutine.
	timeout := s.writeTimeout
	if timeout <= 0 {
		timeout = debugOperationTimeout
	}
	ctx, cancel := context.WithTimeout(s.ctx, timeout)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { _ = transport.Close() })
	defer stop()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, frame := range frames {
		data, err := base64.StdEncoding.DecodeString(frame)
		if err != nil {
			return fmt.Errorf("debug frame: %w", err)
		}
		if _, err := transport.Write(data); err != nil {
			return err
		}
	}
	return nil
}

// recordFailure keeps the reason Core failed the stream so the termination that
// follows it can show that reason.
func (s *debugSession) recordFailure(err error) {
	s.failureMu.Lock()
	defer s.failureMu.Unlock()
	s.failure = err
}

func (s *debugSession) recordedFailure() error {
	s.failureMu.Lock()
	defer s.failureMu.Unlock()
	return s.failure
}

func (s *debugSession) currentTransport() io.WriteCloser {
	s.transportMu.Lock()
	defer s.transportMu.Unlock()
	return s.transport
}

// setTransport installs the write side of the adapter stream. A session that was
// already taken apart refuses it and the stream is closed at once, so a start
// that lost a race with Stop leaves no connection behind.
func (s *debugSession) setTransport(transport io.WriteCloser) bool {
	s.transportMu.Lock()
	defer s.transportMu.Unlock()
	if s.stopped.Load() {
		_ = transport.Close()
		return false
	}
	s.transport = transport
	return true
}

func (s *debugSession) closeTransport() {
	s.transportMu.Lock()
	transport := s.transport
	s.transportMu.Unlock()
	if transport != nil {
		_ = transport.Close()
	}
}

// appendDebugOutput keeps the adapter's diagnostics bounded and whole-line.
func appendDebugOutput(lines []string, text string) []string {
	if text == "" {
		return lines
	}
	lines = append(lines, strings.Split(strings.TrimSuffix(text, "\n"), "\n")...)
	if len(lines) > debugOutputLines {
		lines = lines[len(lines)-debugOutputLines:]
	}
	return lines
}

// loadDebugAdapters reads installed plugin declarations in the background the
// first time the Debug panel needs them.
func (a *App) loadDebugAdapters(p *project) {
	if p == nil || p.debug.loading || p.debug.loaded {
		return
	}
	if a.plugins == nil || a.plugins.Backend == nil {
		p.debug.loaded = true
		p.debug.failure = a.text.Debug.PluginsUnavailable
		return
	}
	p.debug.loading = true
	p.debug.failure = ""
	a.background(p, 0, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.finishDebugAdapters(p, nil, err) }
		}
		plugins, pluginErr := a.plugins.DebugPlugins(ctx, entries)
		var adapters []debugAdapter
		for _, plugin := range plugins {
			for _, declaration := range plugin.Adapters {
				if !debugTransportServed(declaration) {
					continue
				}
				adapters = append(adapters, debugAdapter{
					PluginID:    plugin.PluginID,
					Directory:   plugin.Directory,
					Version:     plugin.Version,
					Manifest:    plugin.Manifest,
					Declaration: declaration,
				})
			}
		}
		return func(a *App) { a.finishDebugAdapters(p, adapters, pluginErr) }
	})
}

func (a *App) finishDebugAdapters(p *project, adapters []debugAdapter, err error) {
	if a.project != p {
		return
	}
	p.debug.loading = false
	p.debug.loaded = true
	p.debug.adapters = adapters
	if err != nil && len(adapters) == 0 {
		p.debug.failure = err.Error()
	}
}

// receiveDebug feeds one stdout chunk to Core and publishes what it answered.
// It runs on the transport's reader goroutine; Core buffers partial frames.
func (a *App) receiveDebug(p *project, session *debugSession, chunk []byte) {
	if p == nil || session == nil || session.stopped.Load() {
		return
	}
	session.operationMu.Lock()
	defer session.operationMu.Unlock()
	if session.stopped.Load() {
		return
	}
	update, err := a.kernel.ReceiveDebug(session.ctx, session.id, chunk)
	if err != nil {
		if session.stopped.Load() || p.ctx.Err() != nil {
			return
		}
		a.post(func(a *App) { a.finishDebugError(p, session, err) })
		return
	}
	if err := session.writeFrames(update.OutboundFrames); err != nil && !session.stopped.Load() {
		a.post(func(a *App) { a.finishDebugError(p, session, err) })
		return
	}
	a.postDebugUpdate(p, session, update)
}

// postDebugUpdate captures a value snapshot before startup reuses its local update.
func (a *App) postDebugUpdate(p *project, session *debugSession, update core.DebugUpdate) {
	a.post(func(a *App) { a.applyDebugUpdate(p, session, update) })
}

// debugStaleReference is Core's failure code for a reply that used a frame or variables
// reference from before the latest resume or stop.
const debugStaleReference = "staleReference"

// applyDebugUpdate publishes one Core update on the window thread. It can ask
// for the next inspection; it never writes adapter bytes there.
func (a *App) applyDebugUpdate(p *project, session *debugSession, update core.DebugUpdate) {
	if a.project != p || !p.debug.hasSession(session) || p.debug.generation != session.generation {
		return
	}
	defer p.debug.bindSession(session)()
	p.debug.state = update.State
	for _, event := range update.Events {
		switch event.Type {
		case "capabilities":
			p.debug.capabilities = event.Capabilities
			a.sendDebugExceptions(p)
		case "initialized":
			p.debug.status = a.text.Debug.Initialized
		case "stateChanged":
			p.debug.state = event.State
		case "stopped":
			p.debug.vars.reset()
			p.debug.disassembly.reset()
			p.debug.memory.reset()
			p.debug.pausedThread = event.ThreadID
			p.debug.threads, p.debug.selectedThread, p.debug.threadsFailure = nil, 0, ""
			p.debug.watch.valuesCleared()
			p.debug.status = a.text.Debug.Paused
			if event.ThreadID != nil {
				p.debug.selectedThread = *event.ThreadID
				a.inspectDebugStack(p, session, *event.ThreadID)
			}
			a.inspectDebugThreads(p, session)
		case "continued":
			p.debug.vars.reset()
			p.debug.disassembly.reset()
			p.debug.memory.reset()
			p.debug.frames = nil
			p.debug.pausedThread = nil
			p.debug.threads, p.debug.selectedThread, p.debug.threadsFailure = nil, 0, ""
			p.debug.watch.valuesCleared()
			p.debug.state = "running"
			p.debug.exception = nil
			p.debug.status = a.text.Debug.Running
		case "terminated":
			if event.ExitCode != nil {
				code := int(*event.ExitCode)
				session.exitCode.Store(&code)
			}
			p.debug.vars.reset()
			p.debug.disassembly.reset()
			p.debug.memory.reset()
			p.debug.frames = nil
			p.debug.pausedThread = nil
			p.debug.threads, p.debug.selectedThread, p.debug.threadsFailure = nil, 0, ""
			p.debug.watch.valuesCleared()
			p.debug.state = "terminated"
			p.debug.status = a.text.Debug.Terminated
			// The adapter ended the session itself, so the host releases the
			// process and Core record without waiting for the user to press Stop.
			p.debug.removeSession(session)
			a.releaseDebugSession(p, session)
			if p.debug.activeSession() == nil {
				p.debug.state = "terminated"
				p.debug.status = a.text.Debug.Terminated
			}
			return
		case "operationFailed":
			if a.completeDebugOperation(p, event) {
				continue
			}
			// A reply to an inspection the debuggee outran (it resumed or stopped again
			// before the adapter answered) is about a stop that is gone. The new stop
			// asks again, so stepping quickly is not a failure to show.
			if event.Code == debugStaleReference {
				continue
			}
			p.debug.failure = event.Message
			p.debug.status = a.text.Debug.Failed
		case "operationCompleted":
			if a.completeDebugOperation(p, event) {
				continue
			}
			if event.Result != nil && event.Result.Kind == "threads" {
				a.applyDebugThreads(p, session, event.Result.Threads)
				continue
			}
			if event.Result != nil && event.Result.Kind == "stackTrace" {
				frames := event.Result.StackFrames
				if len(frames) > debugMaxFrames {
					frames = frames[:debugMaxFrames]
				}
				p.debug.frames = frames
				p.debug.framesExpanded = false
				a.selectDebugFrame(p, 0)
				// Watches belong to the stop: the first frame of the new stack evaluates
				// them again without the user pressing anything.
				a.refreshDebugWatches(p)
			}
		case "startDebuggingRequested":
			// Opening the child changes the sessions, so it runs after this update.
			a.post(func(a *App) { a.startChildDebug(p, session, event) })
		case "output":
			p.debug.output = appendDebugOutput(p.debug.output, event.Output)
		}
	}
}

// inspectDebugStack asks Core for the paused thread's stack frames.
func (a *App) inspectDebugStack(p *project, session *debugSession, threadID int64) {
	thread := threadID
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID:   session.id,
			OperationID: fmt.Sprintf("%s-stack-%d", session.id, thread),
			Kind:        "stackTrace",
			ThreadID:    &thread,
		})
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// continueDebug asks the debuggee to resume.
func (a *App) continueDebug(p *project) {
	a.executeDebug(p, "continue")
}

// pauseDebug asks the debuggee to pause on the adapter's current thread.
func (a *App) pauseDebug(p *project) {
	a.executeDebug(p, "pause")
}

func (a *App) executeDebug(p *project, command string) {
	a.executeDebugWithGranularity(p, command, "")
}

// executeDebugWithGranularity asks for one control command at an explicit step
// granularity, so the disassembly view can step one instruction at a time.
func (a *App) executeDebugWithGranularity(p *project, command, granularity string) {
	if p == nil || p.debug.activeSession() == nil {
		return
	}
	session := p.debug.activeSession()
	thread := p.debug.pausedThread
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.ExecuteDebug(ctx, session.id, fmt.Sprintf("%s-%s", session.id, command), command, thread, granularity)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// toggleBreakpoint adds or removes the caret line of the selected document.
func (a *App) toggleBreakpoint(p *project) {
	if p == nil {
		return
	}
	doc := p.selectedDocument(p.docs.group)
	if doc == nil {
		a.notify(a.text.Debug.NoDocument)
		return
	}
	caretLine, _ := doc.view.Caret()
	line := int64(caretLine + 1)
	lines := p.debug.breakpoints[doc.path]
	index, found := breakpointIndex(lines, line)
	if found {
		lines = slices.Delete(lines, index, index+1)
	} else {
		lines = slices.Insert(lines, index, debugBreakpoint{line: line})
	}
	if p.debug.breakpoints == nil {
		p.debug.breakpoints = make(map[string][]debugBreakpoint)
	}
	if len(lines) == 0 {
		delete(p.debug.breakpoints, doc.path)
	} else {
		p.debug.breakpoints[doc.path] = lines
	}
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "debug.toggleBreakpoint", "surface": "debug"})
	if p.debug.activeSession() != nil {
		a.sendDebugBreakpoints(p, doc.path)
	}
}

// sendDebugBreakpoints replaces one file's adapter breakpoints.
func (a *App) sendDebugBreakpoints(p *project, path string) {
	if p == nil {
		return
	}
	// Every running session gets the change, the parent and the children it started
	// alike: a breakpoint belongs to the file, not to the session shown.
	for _, session := range p.debug.sessions {
		a.sendSessionBreakpoints(p, session, path)
	}
}

// sendSessionBreakpoints replaces one session's breakpoints in the file at path.
func (a *App) sendSessionBreakpoints(p *project, session *debugSession, path string) {
	if session == nil || session.stopped.Load() {
		return
	}
	points := sourceBreakpoints(p.debug.breakpoints[path])
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		// A session still starting takes the change once Core has it; one that never
		// got that far has no breakpoints to replace.
		select {
		case <-session.startupDone:
		case <-ctx.Done():
			return nil
		}
		if !session.created {
			return nil
		}
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.SetDebugBreakpoints(ctx, session.id, path, points)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// stopDebug ends the adapter process and the Core session. It never blocks the
// window thread; the transport and process are released with bounded waits.
func (a *App) stopDebug(p *project) {
	if p == nil || p.debug.activeSession() == nil {
		return
	}
	session := p.debug.activeSession()
	p.debug.removeSession(session)
	a.releaseDebugSession(p, session)
	if p.debug.activeSession() == nil {
		p.debug.frames = nil
		p.debug.pausedThread = nil
		p.debug.state = "idle"
		p.debug.status = ""
	}
}

// endDebugSession ends one session of the project, shown or not. The shown one stops
// the way the Stop button does; another one is released in place.
func (a *App) endDebugSession(p *project, session *debugSession) {
	if p.debug.activeSession() == session {
		a.stopDebug(p)
		return
	}
	p.debug.removeSession(session)
	a.releaseDebugSession(p, session)
}

// stopDebugByUser is the Stop button: like stopDebug, but a live hosted session
// first sends its DAP disconnect and lets Core's bounded drain flush it, so a
// shared language server learns the session ended.
func (a *App) stopDebugByUser(p *project) {
	if p != nil && p.debug.activeSession() != nil {
		p.debug.activeSession().drainOnStop.Store(true)
	}
	a.stopDebug(p)
}

// releaseDebugSession closes transport immediately and destroys Core state only
// after startup returned, so cancellation cannot race a late session creation.
func (a *App) releaseDebugSession(p *project, session *debugSession) {
	session.cleanupOnce.Do(func() {
		// A child that ends before its start was answered fails the parent's request.
		a.answerChildStart(p, session, false, a.text.Debug.Child.Stopped)
		// The children go with this session: they leave the list now and their
		// transports close once Core has removed the tree.
		children := p.debug.descendantsOf(session)
		for _, child := range children {
			p.debug.removeSession(child)
		}
		session.stopped.Store(true)
		session.cancel()
		drain := session.drainOnStop.Load() && session.hosted != nil
		if !drain {
			session.closeTransport()
		}
		if process := session.process.Load(); process != nil {
			process.Stop()
		}
		// Cleanup belongs to the app, not the now-cancelled project.
		a.background(nil, 0, func(_ context.Context) func(*App) {
			if session.ended != nil {
				// The run that stands for the session ends once it is fully released.
				defer func() { session.ended <- session.exitCode.Load() }()
			}
			<-session.startupDone
			ctx, cancel := context.WithTimeout(context.Background(), debugStopTimeout)
			defer cancel()
			var cleanupErr error
			var destroyed []string
			if session.hosted != nil {
				if drain && session.created {
					a.drainHostedSession(ctx, session)
				}
				// Stop is a no-op once the drain finished; it also covers a
				// session that never got to send a disconnect.
				_ = session.hosted.Close()
			}
			if session.created && !session.coreGone {
				destroyed, cleanupErr = a.kernel.DestroyDebugSession(ctx, session.id)
			}
			process := session.process.Load()
			if process != nil {
				_ = process.Wait()
			}
			// The goroutine that watches the process or the TCP stream closes
			// exitObserved once it is done with the session.
			if process != nil || session.observing.Load() {
				<-session.exitObserved
			}
			if session.hosted != nil {
				session.hosted.Release()
			}
			if session.stateDirectory != "" {
				cleanupErr = errors.Join(cleanupErr, os.RemoveAll(session.stateDirectory))
			}
			return func(a *App) {
				a.releaseChildSessions(p, children, destroyed)
				if cleanupErr != nil {
					a.emit(core.LevelWarn, operationFailedEvent, operationFailedFields("debug", cleanupErr))
				}
			}
		})
	})
}

// drainHostedSession sends the DAP disconnect through the stream's write queue
// and asks Core to flush it: local write completion for at most the drain
// budget, never a remote acknowledgement.
func (a *App) drainHostedSession(ctx context.Context, session *debugSession) {
	update, err := a.kernel.DisconnectDebug(ctx, session.id)
	if err == nil {
		for _, frame := range update.OutboundFrames {
			data, decodeErr := base64.StdEncoding.DecodeString(frame)
			if decodeErr != nil {
				break
			}
			if _, writeErr := session.hosted.Write(data); writeErr != nil {
				break
			}
		}
	}
	if err := session.hosted.FinishSendingAndStop(); err != nil {
		return
	}
	select {
	case <-session.hosted.Done():
	case <-ctx.Done():
	}
}

func (a *App) stopDebugForProject(p *project) {
	if p == nil {
		return
	}
	// Roots first: releasing one also releases the children it started.
	for _, session := range slices.Clone(p.debug.sessions) {
		if session.parent == nil && p.debug.hasSession(session) {
			p.debug.removeSession(session)
			a.releaseDebugSession(p, session)
		}
	}
	p.debug.reset()
}

// finishDebugError records a start or transport failure and stops the process.
func (a *App) finishDebugError(p *project, session *debugSession, err error) {
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	if session.parent != nil {
		a.failChildDebug(p, session, err)
		return
	}
	if a.project != p || !p.debug.hasSession(session) || p.debug.generation != session.generation {
		return
	}
	var remote *debugRemoteError
	if errors.As(err, &remote) {
		// Not a failure: Core classified the endpoint as non-local, so the panel
		// asks before connecting. Nothing was started yet.
		endpoint := net.JoinHostPort(remote.host, strconv.Itoa(remote.port))
		if start := p.debug.pendingRemote; start != nil {
			p.debug.remote = &debugRemotePrompt{start: *start, endpoint: endpoint}
		}
		p.debug.pendingRemote = nil
		a.endDebugSession(p, session)
		return
	}
	message := err.Error()
	var settingsError *debugSettingsError
	if errors.As(err, &settingsError) {
		message = i18n.Shared(a.language(), "desktop.debug.settingsUnreadable")
	}
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("debug", err))
	a.endDebugSession(p, session)
	p.debug.failure = message
	if p.debug.activeSession() != nil {
		p.debug.status = a.text.Debug.Failed
	}
}

func (a *App) appendDebugOutput(p *project, session *debugSession, text string) {
	if a.project != p || !p.debug.hasSession(session) {
		return
	}
	defer p.debug.bindSession(session)()
	p.debug.output = appendDebugOutput(p.debug.output, text)
}

// debugFileName is the label of a breakpoint row.
func debugFileName(path string) string {
	return filepath.Base(path)
}
