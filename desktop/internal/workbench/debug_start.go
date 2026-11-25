package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"maps"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

const (
	// debugHostedPollInterval is how often the wait for a language server to be
	// ready looks again.
	debugHostedPollInterval = 50 * time.Millisecond
	// debugReadChunk is the size of one read from the adapter's TCP stream.
	debugReadChunk = 32 << 10
	// debugLoopback is where a tcpLanguageServer adapter listens: the contract
	// allows loopback endpoints only for language-server-provided ports. A
	// tcpAnnounced adapter's loopback host is the one Core read from its output.
	debugLoopback = "127.0.0.1"
)

// debugStart is what one start of a debug session asks for.
type debugStart struct {
	adapter debugAdapter
	// request is the DAP request: "launch" or "attach".
	request string
	// target is the connection an attach binds; nil launches the open file.
	target *core.DebugTargetFacts
	// confirmed records that the user accepted a non-local endpoint.
	confirmed bool
	// configuration is the plugin backend's DAP launch or attach arguments, set
	// when a backend started the session through debug/start. They apply on top
	// of the adapter's declared arguments and no file or connection is planned.
	configuration map[string]any
	// launchTarget is a plugin run's process that the adapter starts itself
	// (`debug.target: {kind: "launch"}`); Core binds it through the adapter's
	// launch targetBindings.
	launchTarget *core.DebugTargetFacts
	// ended, when set, receives the debuggee's exit code once the session has been
	// released, so the run that stands for it can end.
	ended chan *int
	// stopRun owns only a process started by Run, never a user's external attach target.
	stopRun func()
	// parent and startRequestID mark a child session an adapter started through
	// startDebugging; its configuration is the adapter's, and parent answers the request.
	parent         *debugSession
	startRequestID string
	// targetPath is the file a launch of the open file debugs; empty means the file selected
	// when the session begins. A rerun keeps the file the first start debugged.
	targetPath string
	// rerun starts this session again the way it was first started, for the Debug window's
	// Rerun; nil for a start the window cannot repeat.
	rerun func()
}

// debugRemotePrompt is an attach to a non-local endpoint waiting for the user.
type debugRemotePrompt struct {
	start    debugStart
	endpoint string
}

// debugRemoteError stops a start whose endpoint Core classified as remote until
// the user confirms it. It is not a failure: the panel asks instead.
type debugRemoteError struct {
	host string
	port int
}

func (e *debugRemoteError) Error() string {
	return "debug attach to " + net.JoinHostPort(e.host, strconv.Itoa(e.port)) + " needs confirmation"
}

// debugAttachFields are the host and port the user types for an attach-only
// adapter.
type debugAttachFields struct {
	host, port ui.Field
}

// debugTransportServed reports whether this client can start the adapter: a
// process it launches over stdio, a process it launches that prints the
// loopback TCP endpoint it listens on (tcpAnnounced), or an adapter inside its
// plugin's language server reached over loopback TCP.
func debugTransportServed(declaration pluginservice.DebugAdapterDeclaration) bool {
	switch declaration.Transport {
	case "stdio", "tcpAnnounced":
		switch declaration.LaunchKind {
		case pluginhost.LaunchPackaged, pluginhost.LaunchSystemCommand, pluginhost.LaunchRuntime:
			return true
		}
	case "tcpLanguageServer":
		return declaration.Endpoint.LanguageID != "" && declaration.Endpoint.Command != ""
	}
	return false
}

// startDebug starts the selected adapter: it launches the open file when the
// adapter serves launch, and otherwise attaches to the host and port the user
// typed. The Core session owns DAP state; the host owns the process or stream.
func (a *App) startDebug(p *project) {
	if p == nil || p.debug.activeSession() != nil || len(p.debug.adapters) == 0 {
		return
	}
	adapter := p.debug.adapters[p.debug.selectedAdapter]
	p.debug.remote = nil
	start := debugStart{adapter: adapter, request: "launch"}
	if !adapter.Declaration.Serves("launch") {
		target, err := a.attachTargetFromFields()
		if err != nil {
			p.debug.failure = a.text.Debug.AttachInvalid
			return
		}
		start.request, start.target = "attach", target
	}
	if doc := p.selectedDocument(p.docs.group); doc != nil {
		start.targetPath = doc.path
	}
	start.rerun = func() { a.saveAndBeginDebug(p, start) }
	a.saveAndBeginDebug(p, start)
}

// saveAndBeginDebug begins start once the open documents are on disk. A debuggee reads the
// files on disk, so pending writes settle before the adapter launches; a failed save keeps the
// session from starting. Nothing to settle when every document is already on disk, which also
// keeps the session from waiting on a save batch that has no work.
func (a *App) saveAndBeginDebug(p *project, start debugStart) {
	if !a.projectHasPendingWrites(p) {
		a.beginDebug(p, start)
		return
	}
	a.saveProjectDocuments(p, func(ok bool) {
		if ok {
			a.beginDebug(p, start)
		}
	})
}

// rerunDebug is the Debug window's Rerun: it stops the sessions the project runs, the one the
// window shows and the children it started, and starts the shown one again the way it was
// first started. A provider's program is prepared again, so the rerun debugs a fresh build.
func (a *App) rerunDebug(p *project) {
	if p == nil || p.debug.rerun == nil || p.debug.preparing {
		return
	}
	a.performed("debug.rerun", surfaceButton)
	rerun := p.debug.rerun
	// Each stop removes one session; the bound keeps a session that will not leave from
	// holding the window thread.
	for range len(p.debug.sessions) {
		if p.debug.activeSession() == nil {
			break
		}
		a.stopDebugByUser(p)
	}
	rerun()
}

// projectHasPendingWrites reports whether some open document has content the debuggee would
// not see on disk yet.
func (a *App) projectHasPendingWrites(p *project) bool {
	for _, d := range p.docs.list {
		if d.saving || d.dirty() || d.conflicted || d.checkPending || d.checking || d.view.IsComposing() {
			return true
		}
	}
	return false
}

// attachTargetFromFields reads the attach form. The host is only checked for
// being present here; Core validates the endpoint and classifies it as remote.
func (a *App) attachTargetFromFields() (*core.DebugTargetFacts, error) {
	host := strings.TrimSpace(a.debugAttach.host.Text())
	if host == "" {
		host = debugLoopback
	}
	port, err := strconv.Atoi(strings.TrimSpace(a.debugAttach.port.Text()))
	if err != nil {
		return nil, err
	}
	return &core.DebugTargetFacts{Kind: "connection", Host: host, Port: port}, nil
}

// confirmRemoteDebug attaches to the endpoint the user accepted.
func (a *App) confirmRemoteDebug(p *project) {
	if p == nil || p.debug.remote == nil || p.debug.activeSession() != nil {
		return
	}
	start := p.debug.remote.start
	p.debug.remote = nil
	start.confirmed = true
	a.beginDebug(p, start)
}

// attachDebugForRun starts a debug session on the adapter a run's configuration
// type names and attaches it to the debuggee the run started. It runs on a
// background goroutine, waits for the window thread to create the session and
// returns its ID. The endpoint is the loopback port of the run's own process, so
// it needs no confirmation.
func (a *App) attachDebugForRun(ctx context.Context, request pluginservice.RunDebugRequest) (string, error) {
	type outcome struct {
		id  string
		err error
	}
	result := make(chan outcome, 1)
	a.post(func(a *App) {
		p := a.project
		if p == nil || filepath.Clean(p.root) != filepath.Clean(request.WorkspaceRoot) {
			result <- outcome{err: errors.New("the run's workspace is not open")}
			return
		}
		a.whenDebugAdaptersLoaded(p, func() {
			if err := ctx.Err(); err != nil {
				result <- outcome{err: err}
				return
			}
			if p.debug.activeSession() != nil {
				result <- outcome{err: errors.New("a debug session is already running")}
				return
			}
			for _, adapter := range p.debug.adapters {
				if adapter.PluginID != request.PluginID || !adapter.Declaration.Serves("attach") || !adapter.Declaration.AcceptsConnection {
					continue
				}
				for _, configurationType := range adapter.Declaration.ConfigurationTypes {
					if configurationType != request.ConfigurationType {
						continue
					}
					a.performed("debug.start", surfacePlugin)
					a.beginDebug(p, debugStart{
						adapter: adapter, request: "attach", confirmed: true,
						target:  &core.DebugTargetFacts{Kind: "connection", Host: request.Host, Port: request.Port},
						stopRun: request.StopRun,
					})
					session := p.debug.activeSession()
					if session == nil {
						result <- outcome{err: errors.New("the debug session did not start")}
						return
					}
					a.openToolWindow(itemDebug)
					result <- outcome{id: session.id}
					return
				}
			}
			result <- outcome{err: fmt.Errorf("no debug adapter answers to %q", request.ConfigurationType)}
		})
	})
	select {
	case r := <-result:
		return r.id, r.err
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

// launchDebugForRun has the adapter a run's configuration type names start the run's
// process itself, for a run with a launch debug target. It runs on a background
// goroutine, waits for the window thread to create the session and returns it with
// the channel that reports its end.
func (a *App) launchDebugForRun(ctx context.Context, request pluginservice.RunDebugLaunchRequest) (pluginservice.RunDebugSession, error) {
	type outcome struct {
		session pluginservice.RunDebugSession
		err     error
	}
	result := make(chan outcome, 1)
	a.post(func(a *App) {
		p := a.project
		if p == nil || filepath.Clean(p.root) != filepath.Clean(request.WorkspaceRoot) {
			result <- outcome{err: errors.New("the run's workspace is not open")}
			return
		}
		a.whenDebugAdaptersLoaded(p, func() {
			if err := ctx.Err(); err != nil {
				result <- outcome{err: err}
				return
			}
			if p.debug.activeSession() != nil {
				result <- outcome{err: errors.New("a debug session is already running")}
				return
			}
			for _, adapter := range p.debug.adapters {
				if adapter.PluginID != request.PluginID || !adapter.Declaration.Serves("launch") ||
					!slices.Contains(adapter.Declaration.ConfigurationTypes, request.ConfigurationType) {
					continue
				}
				ended := make(chan *int, 1)
				arguments := slices.Clone(request.Arguments)
				if arguments == nil {
					arguments = []string{}
				}
				environment := maps.Clone(request.Environment)
				if environment == nil {
					environment = map[string]string{}
				}
				a.performed("debug.start", surfacePlugin)
				a.beginDebug(p, debugStart{
					adapter: adapter, request: "launch", ended: ended,
					launchTarget: &core.DebugTargetFacts{
						Kind: "executable", Path: request.Executable, Executable: request.Executable,
						WorkingDirectory: request.WorkingDirectory, Arguments: arguments, Environment: environment,
					},
				})
				if p.debug.activeSession() == nil || p.debug.activeSession().ended != ended {
					result <- outcome{err: fmt.Errorf("the debug session did not start: %s", p.debug.failure)}
					return
				}
				result <- outcome{session: pluginservice.RunDebugSession{ID: p.debug.activeSession().id, Ended: ended}}
				return
			}
			result <- outcome{err: fmt.Errorf("no debug adapter launches %q", request.ConfigurationType)}
		})
	})
	select {
	case r := <-result:
		return r.session, r.err
	case <-ctx.Done():
		return pluginservice.RunDebugSession{}, ctx.Err()
	}
}

// startDebugForBackend starts the plugin's own adapter for a backend's
// debug/start. It runs on a background goroutine, asks the window thread to
// create the session and returns its ID. The workspace must be the open project
// and no other session may run: one project has one Debug session.
func (a *App) startDebugForBackend(ctx context.Context, request pluginservice.DebugSessionRequest) (string, error) {
	type outcome struct {
		id  string
		err error
	}
	result := make(chan outcome, 1)
	a.post(func(a *App) {
		p := a.project
		switch {
		case p == nil || filepath.Clean(p.root) != filepath.Clean(request.WorkspaceRoot):
			result <- outcome{err: errors.New("the workspace is not open")}
			return
		case !p.debug.loaded:
			result <- outcome{err: errors.New("the debug adapters are still loading")}
			return
		case p.debug.activeSession() != nil:
			result <- outcome{err: errors.New("a debug session is already running")}
			return
		}
		for _, adapter := range p.debug.adapters {
			if adapter.PluginID+"/"+adapter.Declaration.ID != request.AdapterID {
				continue
			}
			a.performed("debug.start", surfacePlugin)
			a.beginDebug(p, debugStart{adapter: adapter, request: request.Request, confirmed: true, configuration: request.Configuration})
			if p.debug.activeSession() == nil {
				result <- outcome{err: errors.New("the debug session could not start")}
				return
			}
			result <- outcome{id: p.debug.activeSession().id}
			return
		}
		result <- outcome{err: fmt.Errorf("this client cannot start the debug adapter %q", request.AdapterID)}
	})
	select {
	case r := <-result:
		return r.id, r.err
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

// stopDebugForBackend ends the session a backend started, when it is still the
// window's current one.
func (a *App) stopDebugForBackend(sessionID string) {
	a.post(func(a *App) {
		if p := a.project; p != nil && p.debug.activeSession() != nil && p.debug.activeSession().id == sessionID {
			a.stopDebugByUser(p)
		}
	})
}

// beginDebug creates the session and starts its transport in the background.
func (a *App) beginDebug(p *project, start debugStart) {
	if p == nil || (start.parent == nil && p.debug.activeSession() != nil) {
		return
	}
	adapter := start.adapter
	a.pluginServerMu.Lock()
	suppressed := a.pluginServerSuppressed[adapter.PluginID]
	a.pluginServerMu.Unlock()
	if suppressed {
		return
	}
	targetPath := start.targetPath
	if doc := p.selectedDocument(p.docs.group); targetPath == "" && doc != nil {
		targetPath = doc.path
	}
	pluginRoot := a.plugins.Root
	targetUnavailable := i18n.Shared(a.language(), "desktop.debug.targetUnavailable")
	hosted := adapter.Declaration.Transport == "tcpLanguageServer"
	announced := adapter.Declaration.Transport == "tcpAnnounced"
	// Background work reads this copy, never a.text, which the window thread owns.
	messages := a.text.Debug
	// A child shares its parent's generation, so the parent's replies stay current.
	if start.parent == nil {
		p.debug.generation++
		// Rerun repeats the session the window shows; a start it cannot repeat leaves it off.
		p.debug.rerun = start.rerun
	}
	generation := p.debug.generation
	pending := start
	// The user's stepping policy goes with the launch; without one Core applies the
	// adapter's declared defaults. Either decides whether the call stack collapses
	// the frames it filters.
	stepping := a.steppingFiltersFor(adapter.Declaration.AdapterID)
	hideFiltered := false
	if stepping != nil {
		hideFiltered = stepping.HideFilteredStackFrames
	} else if declared, ok := core.DeclaredSteppingFilters(adapter.Declaration.Features, adapter.Declaration.Defaults); ok {
		hideFiltered = declared.HideFilteredStackFrames
	}
	functionBreakpoints := slices.Clone(p.debug.functionBreakpoints)
	// A data breakpoint whose identity does not persist ends with the session that resolved it.
	dataBreakpoints := make([]core.DebugDataBreakpoint, 0, len(p.debug.dataBreakpoints))
	for _, breakpoint := range p.debug.dataBreakpoints {
		if breakpoint.persist {
			dataBreakpoints = append(dataBreakpoints, breakpoint.DebugDataBreakpoint)
		}
	}
	breakpoints := make(map[string][]debugBreakpoint, len(p.debug.breakpoints))
	for path, lines := range p.debug.breakpoints {
		breakpoints[path] = append([]debugBreakpoint(nil), lines...)
	}
	ctx, cancel := context.WithCancel(p.ctx)
	id := fmt.Sprintf("desktop-debug-%d", debugSessionSequence.Add(1))
	session := &debugSession{
		id:             id,
		adapterID:      adapter.Declaration.AdapterID,
		project:        p,
		cancel:         cancel,
		ctx:            ctx,
		startupDone:    make(chan struct{}),
		exitObserved:   make(chan struct{}),
		generation:     generation,
		ended:          start.ended,
		stopRun:        start.stopRun,
		adapter:        adapter,
		parent:         start.parent,
		startRequestID: start.startRequestID,
		// The debug session ID is the start's operation ID, so its result sits with the
		// session's own debug records.
		adapterStart: core.StartPluginAttempt(adapter.PluginID, core.OperationDebugAdapterStart, id),
	}
	// A session started while the breakpoints are muted starts muted.
	session.muted.Store(p.debug.muted)
	parentSessionID := ""
	if start.parent != nil {
		parentSessionID = start.parent.id
	}
	stateRoot := pluginpkg.VersionStateRoot(pluginRoot, adapter.PluginID, adapter.Version)
	// Only a stdio adapter is written through its standard input; the other
	// transports are written through their TCP stream.
	var stdinReader *os.File
	if !hosted && !announced {
		reader, writer, err := os.Pipe()
		if err != nil {
			cancel()
			a.answerChildStart(p, session, false, err.Error())
			if start.parent == nil {
				p.debug.state = "failed"
				p.debug.failure = err.Error()
			}
			a.operationFailed("debug", err)
			return
		}
		stdinReader = reader
		session.setTransport(writer)
	}
	// The session is listed before the window state of the start is written, so the
	// start writes the new session's view and never the one it interrupts.
	p.debug.addSession(session)
	p.debug.pendingRemote = &pending
	p.debug.failure = ""
	p.debug.state = "initializing"
	p.debug.status = a.text.Debug.Starting
	p.debug.frames = nil
	p.debug.pausedThread = nil
	p.debug.output = nil
	// Instruction addresses are valid for one run of one process: the set is not replayed.
	p.debug.instructionBreakpoints = nil
	p.debug.hideFiltered = hideFiltered

	a.background(p, 0, func(_ context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		defer close(session.startupDone)
		ctx := session.ctx
		if stdinReader != nil {
			defer stdinReader.Close()
		}
		// log-exempt: 用户取消：停止或关闭项目已接管会话清理。
		if err := ctx.Err(); err != nil {
			return nil
		}
		if err := os.MkdirAll(stateRoot, 0o700); err != nil {
			a.recordDebugStart(ctx, session, core.StageResolve, err)
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		stateDirectory, err := os.MkdirTemp(stateRoot, "desktop-debug-")
		if err != nil {
			a.recordDebugStart(ctx, session, core.StageResolve, err)
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		// Assigned only by startup; cleanup reads it after startupDone closes.
		session.stateDirectory = stateDirectory
		preparationContext, cancelPreparation := context.WithTimeout(ctx, debugOperationTimeout)
		prepared, err := a.prepareDebugLaunch(preparationContext, start, session.stateDirectory, p, targetPath, generation, targetUnavailable)
		if err != nil {
			// Only the adapter's own launch is the plugin's start; a debuggee that cannot be
			// found or a remote endpoint waiting for the user is not. The preparation's
			// context says whether its deadline stopped it, so it is read before release.
			var unresolved *debugAdapterUnresolved
			if errors.As(err, &unresolved) || errors.Is(preparationContext.Err(), context.DeadlineExceeded) {
				a.recordDebugStart(preparationContext, session, core.StageResolve, err)
			}
		}
		cancelPreparation()
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		prepared.Configuration.SteppingFilters = stepping
		policy, err := a.kernel.DebugTransportPolicy(ctx)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if hosted {
			if err := a.openHostedTransport(p, session, adapter, messages); err != nil {
				a.recordDebugStart(ctx, session, core.StageLaunch, err)
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
		} else if announced {
			if err := a.openAnnouncedTransport(ctx, p, session, prepared, messages); err != nil {
				a.recordDebugStart(ctx, session, core.StageLaunch, err)
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
		} else if err := a.startAdapterProcess(ctx, p, session, prepared, stdinReader, a.stdioDebugOutput(p, session), nil); err != nil {
			a.recordDebugStart(ctx, session, core.StageLaunch, err)
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		update, err := a.kernel.CreateDebugSession(ctx, core.DebugCreateSessionRequest{
			SessionID:                     session.id,
			AdapterID:                     session.adapterID,
			RootPath:                      p.root,
			SupportsStartDebuggingRequest: true,
			ParentSessionID:               parentSessionID,
			DisabledCapabilities:          prepared.DisabledCapabilities,
			Features:                      prepared.Features,
			Defaults:                      prepared.Defaults,
		})
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		session.created = true
		if session.parent != nil {
			a.post(func(a *App) { a.answerChildStart(p, session, true, "") })
		}
		window := time.Duration(policy.InitializationMilliseconds) * time.Millisecond
		if hosted {
			// The session clock starts before discovery here, so it also covers
			// the language-server start the discovery limit was raised for.
			window += pluginServerStartTimeout
		} else if announced {
			// Likewise it covers the wait for the adapter to print its endpoint,
			// which Core's default discovery limit bounds.
			window += time.Duration(policy.Limits.DiscoveryMilliseconds) * time.Millisecond
		}
		if override := a.debugInitializeWindow; override > 0 {
			window = override
		}
		a.watchDebugInitialize(p, session, window)
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return a.debugWriteFailed(p, session, err)
		}
		a.postDebugUpdate(p, session, update)
		// Muting comes before the first breakpoint set, so a muted session never stops on
		// one; a later toggle is applied once this startup is done.
		if session.muted.Load() {
			update, err := a.kernel.SetDebugBreakpointsMuted(ctx, session.id, true)
			if err != nil {
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
			if err := session.writeFrames(update.OutboundFrames); err != nil {
				return a.debugWriteFailed(p, session, err)
			}
			a.postDebugUpdate(p, session, update)
		}
		if len(dataBreakpoints) > 0 {
			update, err := a.kernel.SetDebugDataBreakpoints(ctx, session.id, dataBreakpoints)
			if err != nil {
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
			if err := session.writeFrames(update.OutboundFrames); err != nil {
				return a.debugWriteFailed(p, session, err)
			}
			a.postDebugUpdate(p, session, update)
		}
		if len(functionBreakpoints) > 0 {
			update, err := a.kernel.SetDebugFunctionBreakpoints(ctx, session.id, functionBreakpoints)
			if err != nil {
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
			if err := session.writeFrames(update.OutboundFrames); err != nil {
				return a.debugWriteFailed(p, session, err)
			}
			a.postDebugUpdate(p, session, update)
		}
		for path, lines := range breakpoints {
			update, err := a.kernel.SetDebugBreakpoints(ctx, session.id, path, sourceBreakpoints(lines))
			if err != nil {
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
			if err := session.writeFrames(update.OutboundFrames); err != nil {
				return a.debugWriteFailed(p, session, err)
			}
			a.postDebugUpdate(p, session, update)
		}
		update, err = a.kernel.LaunchDebug(ctx, session.id, fmt.Sprintf("%s-launch", session.id), prepared.Configuration)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return a.debugWriteFailed(p, session, err)
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// watchDebugInitialize ends a session whose adapter never answers initialize.
// Core owns the length of the window (the transport policy's initialization
// deadline); the host only runs the clock.
func (a *App) watchDebugInitialize(p *project, session *debugSession, window time.Duration) {
	timeout := func() {
		// The window is the start's deadline: an adapter start that has no result by now
		// timed out. A start that already ended keeps its result.
		a.recordDebugStart(session.ctx, session, core.StageTimeout, context.DeadlineExceeded)
		a.post(func(a *App) {
			if a.project != p || !p.debug.hasSession(session) {
				return
			}
			restore := p.debug.bindSession(session)
			initializing := p.debug.state == "initializing"
			restore()
			if initializing {
				a.finishDebugError(p, session, errors.New(a.text.Debug.TimedOut))
			}
		})
	}
	if a.debugInitializeTrigger != nil {
		trigger := a.debugInitializeTrigger
		go func() {
			select {
			case <-trigger:
				timeout()
			case <-session.ctx.Done():
			}
		}()
		return
	}
	timer := time.AfterFunc(window, timeout)
	// The timer must not outlive the session: Stop and shutdown cancel its context.
	context.AfterFunc(session.ctx, func() { timer.Stop() })
}

// stdioDebugOutput routes a stdio adapter's output: standard output is its DAP
// stream, standard error goes to the debug console.
func (a *App) stdioDebugOutput(p *project, session *debugSession) func(buildprocess.Stream, string) {
	return func(stream buildprocess.Stream, text string) {
		if stream == buildprocess.Stderr {
			a.post(func(a *App) { a.appendDebugOutput(p, session, text) })
			return
		}
		a.receiveDebug(p, session, []byte(text))
	}
}

// startAdapterProcess starts an adapter process and watches for its exit, so
// an adapter that dies without a DAP terminated event still ends the session.
// A stdio adapter (stdin set) is reached once it runs. A tcpAnnounced adapter
// (stdin nil) is reached once its socket connects, and it outlives the
// session's context: a user stop first drains its DAP disconnect through the
// stream, and the session's release stops the process after that. unreached is
// what an exit before the stream connected reports when nothing failed first.
func (a *App) startAdapterProcess(ctx context.Context, p *project, session *debugSession, prepared preparedDebugLaunch, stdin *os.File, observe func(buildprocess.Stream, string), unreached error) error {
	spec := buildprocess.Spec{
		Kind:             processledger.KindDebug,
		Executable:       prepared.Executable,
		Arguments:        prepared.Arguments,
		Environment:      prepared.Environment,
		WorkingDirectory: p.root,
	}
	processContext := context.WithoutCancel(ctx)
	if stdin != nil {
		// A nil *os.File would be a non-nil reader, so the field is set only here.
		spec.Stdin = stdin
		processContext = ctx
	}
	process, err := buildprocess.Start(processContext, spec, observe)
	if stdin != nil {
		_ = stdin.Close()
	}
	if err != nil {
		return err
	}
	session.process.Store(process)
	if stdin != nil {
		session.reached.Store(true)
	}
	// Observe native exit even when the adapter cannot send a DAP terminated event.
	go func() {
		defer close(session.exitObserved)
		err := process.Wait()
		// An exit before initialize was answered ends the start, whatever its status. It is
		// read before the session's context ends, which would make it a stop by the user.
		stage := core.StageExit
		if !session.reached.Load() {
			stage = core.StageLaunch
		}
		a.recordDebugStart(session.ctx, session, stage, errDebugAdapterExited)
		session.cancel()
		session.closeTransport()
		if err == nil && !session.reached.Load() {
			// A tcpAnnounced adapter that ends before its stream connected never
			// served the session, whatever its exit status.
			err = session.recordedFailure()
			if err == nil {
				err = unreached
			}
		}
		a.debugStreamEnded(p, session, err)
	}()
	return nil
}

// debugStreamEnded finishes a session whose adapter process or stream ended on
// its own. A clean end is a terminated session; anything else is a failure.
func (a *App) debugStreamEnded(p *project, session *debugSession, err error) {
	a.post(func(a *App) {
		if a.project != p || !p.debug.hasSession(session) {
			return
		}
		if err != nil {
			a.finishDebugError(p, session, err)
			return
		}
		// The adapter's stream ended on its own: the session leaves the list, and the
		// window shows the terminated state only when nothing else runs.
		p.debug.removeSession(session)
		a.releaseDebugSession(p, session)
		if p.debug.activeSession() == nil {
			p.debug.state = "terminated"
			p.debug.status = a.text.Debug.Terminated
		}
	})
}

// openHostedTransport reaches a tcpLanguageServer adapter. Core's transport
// lifecycle owns the rules (the discovery, connect and write deadlines as timers
// it arms, the write queue and its budget, the bounded drain of a user stop);
// this host keeps the socket and runs the effects Core returns. It only starts
// the stream: frames written before the socket is ready are queued and flushed
// by Core's rule, and every failure arrives as a reportFailure effect followed
// by a termination.
func (a *App) openHostedTransport(p *project, session *debugSession, adapter debugAdapter, messages i18n.DebugMessages) error {
	a.post(func(a *App) {
		if a.project != p || !p.debug.hasSession(session) {
			return
		}
		defer p.debug.bindSession(session)()
		p.debug.status = a.text.Debug.WaitingServer
	})
	discover := func(ctx context.Context) (string, int, error) {
		var port int
		var err error
		if a.debugHostedPort != nil {
			port, err = a.debugHostedPort(ctx, p, adapter)
		} else {
			port, err = a.discoverHostedPort(ctx, p, adapter, messages)
		}
		return debugLoopback, port, err
	}
	hooks := a.debugStreamHooks(p, session, messages)
	hooks.Discover = discover
	transport := newDebugTransport(a.kernel, session.id+"-transport", hooks)
	if !session.setTransport(transport) {
		return context.Canceled
	}
	session.hosted = transport
	// Core's default discovery budget is a cold-start allowance; the language
	// server's own start budget is the one this host already owns, so it raises
	// only the discovery limit (an override the contract allows).
	discovery := int(pluginServerStartTimeout / time.Millisecond)
	return transport.Start(&core.DebugTransportLimitOverrides{DiscoveryMilliseconds: &discovery})
}

// debugStreamHooks are a TCP-reached session's side of its stream, for every
// transport but Discover, which the caller sets: the socket connecting reaches
// the adapter, its bytes are DAP, and a failure or the peer closing ends the
// session.
func (a *App) debugStreamHooks(p *project, session *debugSession, messages i18n.DebugMessages) debugTransportHooks {
	return debugTransportHooks{
		Connected: func() { session.reached.Store(true) },
		Deliver:   func(data []byte) { a.receiveDebug(p, session, data) },
		Failure: func(reason, message string) {
			failure := debugTransportFailureText(messages, reason, message)
			session.recordFailure(failure)
			a.recordDebugStart(session.ctx, session, hostedFailureStage(session.reached.Load(), reason), failure)
		},
		Terminated: func(exitCode int) {
			if session.stopped.Load() {
				return
			}
			// A failure already ended the start; a clean close of a reached socket before
			// initialize was answered is the adapter leaving.
			stage := core.StageExit
			if !session.reached.Load() {
				stage = core.StageLaunch
			}
			a.recordDebugStart(session.ctx, session, stage, errDebugAdapterExited)
			if exitCode == 0 {
				a.debugStreamEnded(p, session, nil)
				return
			}
			failure := session.recordedFailure()
			if failure == nil {
				failure = errors.New(messages.ConnectionClosed)
			}
			a.debugStreamEnded(p, session, failure)
		},
	}
}

// debugTransportFailureText turns Core's failure reason into the words shown.
// The first four reasons are the platform's text; for "host" the message is the
// host's own upstream diagnostic and is shown unchanged.
func debugTransportFailureText(messages i18n.DebugMessages, reason, message string) error {
	switch reason {
	case "startupTimedOut":
		return errors.New(messages.TimedOut)
	case "writeTimedOut":
		return errors.New(messages.WriteTimedOut)
	case "bufferLimit":
		return errors.New(messages.BufferLimit)
	case "invalidEndpoint":
		return errors.New(messages.InvalidEndpoint)
	}
	return errors.New(message)
}

// discoverHostedPort asks the adapter's language server for the port of a new
// debug session.
func (a *App) discoverHostedPort(ctx context.Context, p *project, adapter debugAdapter, messages i18n.DebugMessages) (int, error) {
	endpoint := adapter.Declaration.Endpoint
	posted := make(chan struct{})
	a.post(func(a *App) {
		if a.project == p {
			a.startPluginServer(endpoint.LanguageID)
		}
		close(posted)
	})
	select {
	case <-posted:
	case <-ctx.Done():
		return 0, ctx.Err()
	}
	server, err := a.waitReadyPluginServer(ctx, p, adapter.PluginID, endpoint.LanguageID)
	if err != nil {
		return 0, err
	}
	// A server may offer its commands only after it is ready, by registering them (JDT LS
	// does): Core refuses the command until then.
	if err := a.waitPluginServerFeature(ctx, server, featureExecuteCommand, pluginServerStartTimeout); err != nil {
		return 0, err
	}
	// Core's discovery timer bounds the whole wait; the command itself only
	// needs a ceiling so a stuck server cannot outlive the stream.
	answer, err := a.plugins.ExecuteLanguageCommand(ctx, server.session, endpoint.Command, nil, pluginServerStartTimeout)
	if err != nil {
		return 0, err
	}
	port, err := parseDebugPort(answer)
	if err != nil {
		return 0, errors.New(messages.NoEndpoint)
	}
	return port, nil
}

// waitReadyPluginServer waits for the plugin's language server of this project to
// be ready. A start that is not under way and produced no server twice in a row
// is a failure, not a reason to wait out the whole start timeout.
func (a *App) waitReadyPluginServer(ctx context.Context, p *project, pluginID, languageID string) (*pluginServer, error) {
	deadline := time.NewTimer(pluginServerStartTimeout)
	defer deadline.Stop()
	ticker := time.NewTicker(debugHostedPollInterval)
	defer ticker.Stop()
	idle := 0
	for {
		a.pluginServerMu.Lock()
		server := a.pluginServers[pluginID]
		starting := a.pluginServerStarting[languageID]
		failed := a.pluginServerFailed[languageID]
		a.pluginServerMu.Unlock()
		switch {
		case server != nil && server.project == p && server.isReady():
			return server, nil
		case server == nil && !starting:
			idle++
			if idle >= 3 {
				detail := ""
				if failed != nil && failed.project == p {
					detail = failed.message
				}
				return nil, &pluginbackend.SessionUnavailableError{
					PluginID:   pluginID,
					LanguageID: languageID,
					Detail:     detail,
				}
			}
		default:
			idle = 0
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-deadline.C:
			return nil, errors.New("the language server did not become ready in time")
		case <-ticker.C:
		}
	}
}

// errPluginServerFeatureMissing is a ready language server that did not offer a feature the
// host needs within the wait.
var errPluginServerFeatureMissing = errors.New("the language server does not offer the feature")

// waitPluginServerFeature waits until the ready server offers feature, as Core's
// featuresChanged event reports it, or at most timeout. The features belong to the window
// thread, so each look is posted there.
func (a *App) waitPluginServerFeature(ctx context.Context, server *pluginServer, feature string, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(debugHostedPollInterval)
	defer ticker.Stop()
	for {
		offered := make(chan bool, 1)
		a.post(func(a *App) { offered <- server.features[feature] })
		select {
		case ok := <-offered:
			if ok {
				return nil
			}
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return fmt.Errorf("%w: %s", errPluginServerFeatureMissing, feature)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return fmt.Errorf("%w: %s", errPluginServerFeatureMissing, feature)
		case <-ticker.C:
		}
	}
}

// parseDebugPort reads the loopback port a language server answered: an integer
// or a numeric string from 1 to 65535, as the contract defines.
func parseDebugPort(raw json.RawMessage) (int, error) {
	var number json.Number
	var text string
	switch {
	case json.Unmarshal(raw, &text) == nil:
		number = json.Number(strings.TrimSpace(text))
	case json.Unmarshal(raw, &number) == nil:
	default:
		return 0, errors.New("the answer is not a port")
	}
	port, err := strconv.Atoi(number.String())
	if err != nil || port < 1 || port > 65535 {
		return 0, errors.New("the port is outside 1-65535")
	}
	return port, nil
}
