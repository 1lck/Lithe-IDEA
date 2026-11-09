package workbench

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
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

// debugAdapter is one installed plugin's stdio debug adapter declaration.
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
	adapterSelect   ui.SelectState
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
}

func (s *debugState) reset() { *s = debugState{} }

// debugSession owns one adapter process and the matching Core session.
var debugSessionSequence atomic.Uint64

type debugSession struct {
	id             string
	adapterID      string
	project        *project
	process        atomic.Pointer[buildprocess.Process]
	stdin          *os.File
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
	if s == nil || s.stdin == nil {
		return nil
	}
	// Closing the native pipe interrupts both a blocked write and a writer
	// waiting behind it. A native file also avoids exec.Cmd's stdin-copy goroutine.
	ctx, cancel := context.WithTimeout(s.ctx, debugOperationTimeout)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { _ = s.stdin.Close() })
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
		if _, err := s.stdin.Write(data); err != nil {
			return err
		}
	}
	return nil
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
		plugins, pluginErr := a.plugins.DebugPlugins(entries)
		var adapters []debugAdapter
		for _, plugin := range plugins {
			for _, declaration := range plugin.Adapters {
				if declaration.Transport != "stdio" {
					continue
				}
				if declaration.LaunchKind != pluginhost.LaunchPackaged && declaration.LaunchKind != pluginhost.LaunchSystemCommand && declaration.LaunchKind != pluginhost.LaunchRuntime {
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

// startDebug starts the first declared stdio adapter and a Core session. The
// Core session owns DAP state; the host owns the process and its bytes.
func (a *App) startDebug(p *project) {
	if p == nil || p.debug.session != nil || len(p.debug.adapters) == 0 {
		return
	}
	adapter := p.debug.adapters[p.debug.selectedAdapter]
	targetPath := ""
	if doc := p.selectedDocument(p.docs.group); doc != nil {
		targetPath = doc.path
	}
	pluginRoot := a.plugins.Root
	targetUnavailable := i18n.Shared(a.language(), "desktop.debug.targetUnavailable")
	p.debug.generation++
	generation := p.debug.generation
	p.debug.failure = ""
	p.debug.state = "initializing"
	p.debug.status = a.text.Debug.Starting
	p.debug.frames = nil
	p.debug.pausedThread = nil
	p.debug.output = nil
	breakpoints := make(map[string][]int64, len(p.debug.breakpoints))
	for path, lines := range p.debug.breakpoints {
		breakpoints[path] = append([]int64(nil), lines...)
	}
	ctx, cancel := context.WithCancel(p.ctx)
	session := &debugSession{
		id:           fmt.Sprintf("desktop-debug-%d", debugSessionSequence.Add(1)),
		adapterID:    adapter.Declaration.AdapterID,
		project:      p,
		cancel:       cancel,
		ctx:          ctx,
		startupDone:  make(chan struct{}),
		exitObserved: make(chan struct{}),
		generation:   generation,
	}
	stateRoot := filepath.Join(pluginRoot, ".state", adapter.PluginID, adapter.Version)
	stdinReader, stdinWriter, err := os.Pipe()
	if err != nil {
		cancel()
		p.debug.state = "failed"
		p.debug.failure = err.Error()
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("debug", err))
		return
	}
	session.stdin = stdinWriter
	p.debug.session = session
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "debug.start", "surface": "debug"})

	a.background(p, 0, func(_ context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		defer close(session.startupDone)
		ctx := session.ctx
		defer stdinReader.Close()
		// log-exempt: 用户取消：停止或关闭项目已接管会话清理。
		if err := ctx.Err(); err != nil {
			return nil
		}
		if err := os.MkdirAll(stateRoot, 0o700); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		stateDirectory, err := os.MkdirTemp(stateRoot, "desktop-debug-")
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		// Assigned only by startup; cleanup reads it after startupDone closes.
		session.stateDirectory = stateDirectory
		preparationContext, cancelPreparation := context.WithTimeout(ctx, debugOperationTimeout)
		prepared, err := a.prepareDebugLaunch(preparationContext, adapter, session.stateDirectory, p.root, targetPath, generation, targetUnavailable)
		cancelPreparation()
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		process, err := buildprocess.Start(ctx, buildprocess.Spec{
			Executable:       prepared.Executable,
			Arguments:        prepared.Arguments,
			Environment:      prepared.Environment,
			WorkingDirectory: p.root,
			Stdin:            stdinReader,
		}, func(stream buildprocess.Stream, text string) {
			if stream == buildprocess.Stderr {
				a.post(func(a *App) { a.appendDebugOutput(p, session, text) })
				return
			}
			a.receiveDebug(p, session, []byte(text))
		})
		_ = stdinReader.Close()
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		session.process.Store(process)
		// Observe native exit even when the adapter cannot send a DAP terminated event.
		go func() {
			defer close(session.exitObserved)
			err := process.Wait()
			session.cancel()
			_ = session.stdin.Close()
			a.post(func(a *App) {
				if a.project != p || p.debug.session != session {
					return
				}
				if err != nil {
					a.finishDebugError(p, session, err)
					return
				}
				p.debug.session = nil
				p.debug.frames = nil
				p.debug.pausedThread = nil
				p.debug.state = "terminated"
				p.debug.status = a.text.Debug.Terminated
				a.releaseDebugSession(p, session)
			})
		}()
		update, err := a.kernel.CreateDebugSession(ctx, core.DebugCreateSessionRequest{
			SessionID: session.id,
			AdapterID: session.adapterID,
			RootPath:  p.root,
		})
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		session.created = true
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		for path, lines := range breakpoints {
			points := make([]core.DebugSourceBreakpoint, 0, len(lines))
			for _, line := range lines {
				points = append(points, core.DebugSourceBreakpoint{Line: line, Enabled: true})
			}
			update, err := a.kernel.SetDebugBreakpoints(ctx, session.id, path, points)
			if err != nil {
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
			if err := session.writeFrames(update.OutboundFrames); err != nil {
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
			a.postDebugUpdate(p, session, update)
		}
		update, err = a.kernel.LaunchDebug(ctx, session.id, fmt.Sprintf("%s-launch", session.id), prepared.Configuration)
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
		_ = session.stdin.Close()
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
			if process := session.process.Load(); process != nil {
				_ = process.Wait()
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
	p.debug.failure = err.Error()
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
