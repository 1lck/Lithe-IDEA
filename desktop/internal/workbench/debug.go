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
	"sort"
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

// debugState is the Debug tool window's state for one project.
type debugState struct {
	loaded          bool
	loading         bool
	adapters        []debugAdapter
	selectedAdapter int
	failure         string
	status          string
	// output is the adapter's bounded stderr and console text.
	output []string
	state  string
	// breakpoints maps an absolute source path to sorted one-based lines.
	breakpoints map[string][]int64
	frames      []core.DebugStackFrame
	// pausedThread is the thread the last stopped event named.
	pausedThread *int64
	session      *debugSession
	generation   uint64
	// remote is the non-local attach the user has not yet confirmed.
	remote *debugRemotePrompt
	// pendingRemote is the start in flight, kept so a remote endpoint can be
	// confirmed and the same start repeated.
	pendingRemote *debugStart
}

func (s *debugState) reset() { *s = debugState{} }

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
	// generation matches debugState.generation so an old pump publishes nothing.
	generation uint64
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

// applyDebugUpdate publishes one Core update on the window thread. It can ask
// for the next inspection; it never writes adapter bytes there.
func (a *App) applyDebugUpdate(p *project, session *debugSession, update core.DebugUpdate) {
	if a.project != p || p.debug.session != session || p.debug.generation != session.generation {
		return
	}
	p.debug.state = update.State
	for _, event := range update.Events {
		switch event.Type {
		case "initialized":
			p.debug.status = a.text.Debug.Initialized
		case "stateChanged":
			p.debug.state = event.State
		case "stopped":
			p.debug.pausedThread = event.ThreadID
			p.debug.status = a.text.Debug.Paused
			if event.ThreadID != nil {
				a.inspectDebugStack(p, session, *event.ThreadID)
			}
		case "continued":
			p.debug.frames = nil
			p.debug.pausedThread = nil
			p.debug.state = "running"
			p.debug.status = a.text.Debug.Running
		case "terminated":
			p.debug.frames = nil
			p.debug.pausedThread = nil
			p.debug.state = "terminated"
			p.debug.status = a.text.Debug.Terminated
			// The adapter ended the session itself, so the host releases the
			// process and Core record without waiting for the user to press Stop.
			p.debug.session = nil
			a.releaseDebugSession(p, session)
		case "operationFailed":
			p.debug.failure = event.Message
			p.debug.status = a.text.Debug.Failed
		case "operationCompleted":
			if event.Result != nil && event.Result.Kind == "stackTrace" {
				frames := event.Result.StackFrames
				if len(frames) > debugMaxFrames {
					frames = frames[:debugMaxFrames]
				}
				p.debug.frames = frames
			}
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
	if p == nil || p.debug.session == nil {
		return
	}
	session := p.debug.session
	thread := p.debug.pausedThread
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.ExecuteDebug(ctx, session.id, fmt.Sprintf("%s-%s", session.id, command), command, thread)
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
	index := sort.Search(len(lines), func(i int) bool { return lines[i] >= line })
	if index < len(lines) && lines[index] == line {
		lines = slices.Delete(lines, index, index+1)
	} else {
		lines = slices.Insert(lines, index, line)
	}
	if p.debug.breakpoints == nil {
		p.debug.breakpoints = make(map[string][]int64)
	}
	if len(lines) == 0 {
		delete(p.debug.breakpoints, doc.path)
	} else {
		p.debug.breakpoints[doc.path] = lines
	}
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "debug.toggleBreakpoint", "surface": "debug"})
	if p.debug.session != nil {
		a.sendDebugBreakpoints(p, doc.path)
	}
}

// sendDebugBreakpoints replaces one file's adapter breakpoints.
func (a *App) sendDebugBreakpoints(p *project, path string) {
	if p == nil || p.debug.session == nil {
		return
	}
	session := p.debug.session
	lines := append([]int64(nil), p.debug.breakpoints[path]...)
	points := make([]core.DebugSourceBreakpoint, 0, len(lines))
	for _, line := range lines {
		points = append(points, core.DebugSourceBreakpoint{Line: line, Enabled: true})
	}
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
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
	if p == nil || p.debug.session == nil {
		return
	}
	session := p.debug.session
	p.debug.session = nil
	p.debug.frames = nil
	p.debug.pausedThread = nil
	p.debug.state = "idle"
	p.debug.status = ""
	a.releaseDebugSession(p, session)
}

// releaseDebugSession closes transport immediately and destroys Core state only
// after startup returned, so cancellation cannot race a late session creation.
func (a *App) releaseDebugSession(_ *project, session *debugSession) {
	session.cleanupOnce.Do(func() {
		session.stopped.Store(true)
		session.cancel()
		session.closeTransport()
		if process := session.process.Load(); process != nil {
			process.Stop()
		}
		// Cleanup belongs to the app, not the now-cancelled project.
		a.background(nil, 0, func(_ context.Context) func(*App) {
			<-session.startupDone
			ctx, cancel := context.WithTimeout(context.Background(), debugStopTimeout)
			defer cancel()
			var cleanupErr error
			if session.created {
				_, cleanupErr = a.kernel.DestroyDebugSession(ctx, session.id)
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
			if session.stateDirectory != "" {
				cleanupErr = errors.Join(cleanupErr, os.RemoveAll(session.stateDirectory))
			}
			if cleanupErr != nil {
				return func(a *App) { a.emit(core.LevelWarn, operationFailedEvent, operationFailedFields("debug", cleanupErr)) }
			}
			return nil
		})
	})
}

func (a *App) stopDebugForProject(p *project) {
	if p == nil {
		return
	}
	session := p.debug.session
	p.debug.reset()
	if session != nil {
		a.releaseDebugSession(p, session)
	}
}

// finishDebugError records a start or transport failure and stops the process.
func (a *App) finishDebugError(p *project, session *debugSession, err error) {
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	if a.project != p || p.debug.session != session || p.debug.generation != session.generation {
		return
	}
	var remote *debugRemoteError
	if errors.As(err, &remote) {
		// Not a failure: Core classified the endpoint as non-local, so the panel
		// asks before connecting. Nothing was started yet.
		endpoint := net.JoinHostPort(remote.host, strconv.Itoa(remote.port))
		start := p.debug.pendingRemote
		if start != nil {
			p.debug.remote = &debugRemotePrompt{start: *start, endpoint: endpoint}
		}
		p.debug.pendingRemote = nil
		p.debug.status = ""
		if p.debug.session == session {
			a.stopDebug(p)
		}
		return
	}
	p.debug.failure = err.Error()
	var settingsError *debugSettingsError
	if errors.As(err, &settingsError) {
		p.debug.failure = i18n.Shared(a.language(), "desktop.debug.settingsUnreadable")
	}
	p.debug.status = a.text.Debug.Failed
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("debug", err))
	if p.debug.session == session {
		a.stopDebug(p)
	}
}

func (a *App) appendDebugOutput(p *project, session *debugSession, text string) {
	if a.project != p || p.debug.session != session {
		return
	}
	p.debug.output = appendDebugOutput(p.debug.output, text)
}

// debugFileName is the label of a breakpoint row.
func debugFileName(path string) string {
	return filepath.Base(path)
}
