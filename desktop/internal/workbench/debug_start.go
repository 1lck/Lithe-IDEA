package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
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
	// allows loopback endpoints only for language-server-provided ports.
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
// process it launches over stdio, or an adapter inside its plugin's language
// server reached over loopback TCP.
func debugTransportServed(declaration pluginservice.DebugAdapterDeclaration) bool {
	switch declaration.Transport {
	case "stdio":
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
	if p == nil || p.debug.session != nil || len(p.debug.adapters) == 0 {
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
	a.beginDebug(p, start)
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
	if p == nil || p.debug.remote == nil || p.debug.session != nil {
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
		if !p.debug.loaded {
			result <- outcome{err: errors.New("the debug adapters are still loading")}
			return
		}
		if p.debug.session != nil {
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
				a.beginDebug(p, debugStart{
					adapter: adapter, request: "attach", confirmed: true,
					target: &core.DebugTargetFacts{Kind: "connection", Host: request.Host, Port: request.Port},
				})
				result <- outcome{id: p.debug.session.id}
				return
			}
		}
		result <- outcome{err: fmt.Errorf("no debug adapter answers to %q", request.ConfigurationType)}
	})
	select {
	case r := <-result:
		return r.id, r.err
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

// beginDebug creates the session and starts its transport in the background.
func (a *App) beginDebug(p *project, start debugStart) {
	if p == nil || p.debug.session != nil {
		return
	}
	adapter := start.adapter
	targetPath := ""
	if doc := p.selectedDocument(p.docs.group); doc != nil {
		targetPath = doc.path
	}
	pluginRoot := a.plugins.Root
	targetUnavailable := i18n.Shared(a.language(), "desktop.debug.targetUnavailable")
	hosted := adapter.Declaration.Transport == "tcpLanguageServer"
	// Background work reads this copy, never a.text, which the window thread owns.
	messages := a.text.Debug
	p.debug.generation++
	generation := p.debug.generation
	pending := start
	p.debug.pendingRemote = &pending
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
	var stdinReader *os.File
	if !hosted {
		reader, writer, err := os.Pipe()
		if err != nil {
			cancel()
			p.debug.state = "failed"
			p.debug.failure = err.Error()
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("debug", err))
			return
		}
		stdinReader = reader
		session.setTransport(writer)
	}
	p.debug.session = session
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "debug.start", "surface": "debug"})

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
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		stateDirectory, err := os.MkdirTemp(stateRoot, "desktop-debug-")
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		// Assigned only by startup; cleanup reads it after startupDone closes.
		session.stateDirectory = stateDirectory
		preparationContext, cancelPreparation := context.WithTimeout(ctx, debugOperationTimeout)
		prepared, err := a.prepareDebugLaunch(preparationContext, start, session.stateDirectory, p.root, targetPath, generation, targetUnavailable)
		cancelPreparation()
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		policy, err := a.kernel.DebugTransportPolicy(ctx)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if hosted {
			if err := a.openHostedTransport(p, session, adapter, messages); err != nil {
				return func(a *App) { a.finishDebugError(p, session, err) }
			}
		} else if err := a.startAdapterProcess(ctx, p, session, prepared, stdinReader); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		update, err := a.kernel.CreateDebugSession(ctx, core.DebugCreateSessionRequest{
			SessionID:            session.id,
			AdapterID:            session.adapterID,
			RootPath:             p.root,
			DisabledCapabilities: prepared.DisabledCapabilities,
			Features:             prepared.Features,
			Defaults:             prepared.Defaults,
		})
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		session.created = true
		window := time.Duration(policy.InitializationMilliseconds) * time.Millisecond
		if hosted {
			// The session clock starts before discovery here, so it also covers
			// the language-server start the discovery limit was raised for.
			window += pluginServerStartTimeout
		}
		if override := a.debugInitializeWindow; override > 0 {
			window = override
		}
		a.watchDebugInitialize(p, session, window)
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

// watchDebugInitialize ends a session whose adapter never answers initialize.
// Core owns the length of the window (the transport policy's initialization
// deadline); the host only runs the clock.
func (a *App) watchDebugInitialize(p *project, session *debugSession, window time.Duration) {
	timer := time.AfterFunc(window, func() {
		a.post(func(a *App) {
			if a.project == p && p.debug.session == session && p.debug.state == "initializing" {
				a.finishDebugError(p, session, errors.New(a.text.Debug.TimedOut))
			}
		})
	})
	// The timer must not outlive the session: Stop and shutdown cancel its context.
	context.AfterFunc(session.ctx, func() { timer.Stop() })
}

// startAdapterProcess starts a stdio adapter and watches for its exit, so an
// adapter that dies without a DAP terminated event still ends the session.
func (a *App) startAdapterProcess(ctx context.Context, p *project, session *debugSession, prepared preparedDebugLaunch, stdin *os.File) error {
	process, err := buildprocess.Start(ctx, buildprocess.Spec{
		Executable:       prepared.Executable,
		Arguments:        prepared.Arguments,
		Environment:      prepared.Environment,
		WorkingDirectory: p.root,
		Stdin:            stdin,
	}, func(stream buildprocess.Stream, text string) {
		if stream == buildprocess.Stderr {
			a.post(func(a *App) { a.appendDebugOutput(p, session, text) })
			return
		}
		a.receiveDebug(p, session, []byte(text))
	})
	_ = stdin.Close()
	if err != nil {
		return err
	}
	session.process.Store(process)
	// Observe native exit even when the adapter cannot send a DAP terminated event.
	go func() {
		defer close(session.exitObserved)
		err := process.Wait()
		session.cancel()
		session.closeTransport()
		a.debugStreamEnded(p, session, err)
	}()
	return nil
}

// debugStreamEnded finishes a session whose adapter process or stream ended on
// its own. A clean end is a terminated session; anything else is a failure.
func (a *App) debugStreamEnded(p *project, session *debugSession, err error) {
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
		if a.project == p && p.debug.session == session {
			p.debug.status = a.text.Debug.WaitingServer
		}
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
	hooks := debugTransportHooks{
		Discover: discover,
		Deliver:  func(data []byte) { a.receiveDebug(p, session, data) },
		Failure: func(reason, message string) {
			session.recordFailure(debugTransportFailureText(messages, reason, message))
		},
		Terminated: func(exitCode int) {
			if session.stopped.Load() {
				return
			}
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
		a.pluginServerMu.Unlock()
		switch {
		case server != nil && server.project == p && server.isReady():
			return server, nil
		case server == nil && !starting:
			idle++
			if idle >= 3 {
				return nil, fmt.Errorf("the %s language server of %s is not running", languageID, pluginID)
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
