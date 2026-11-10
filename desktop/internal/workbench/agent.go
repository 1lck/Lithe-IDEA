// Note: ACP 连接与 provider 发现的决策见 .agents/notes/implemented/architecture/2026-11-08-viva-agent-core-bridge.md
package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// AgentSession is one Core-owned ACP connection as the workbench uses it. The
// production implementation is core.AgentSession; tests replace it with a
// scripted connection.
type AgentSession interface {
	Send(json.RawMessage) error
	Next(context.Context) (json.RawMessage, error)
	Close()
}

// AgentKernel is what the Agent panel asks the kernel: adapter detection,
// credential-free provider discovery, and opening the ACP connection. Core
// owns the protocol, process tree and session lifecycle.
type AgentKernel interface {
	ReadAgentManagementStatus(ctx context.Context, dataDirectory string) (core.AgentManagementStatus, error)
	AIConfigurationSources(ctx context.Context, source, home string, environment map[string]string) ([]core.AIConfigurationFile, error)
	ParseAIConfiguration(ctx context.Context, request core.AIConfigurationParseRequest) (*core.AIConfiguration, error)
	InstallAgentAdapter(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error)
	OpenAgentSession(launch json.RawMessage) (AgentSession, error)
}

// CoreAgentKernel adapts the typed Core client to AgentKernel. The interface
// keeps the workbench independent of the concrete C ABI session type.
type CoreAgentKernel struct{ Client *core.Client }

func (k CoreAgentKernel) ReadAgentManagementStatus(ctx context.Context, dataDirectory string) (core.AgentManagementStatus, error) {
	return k.Client.ReadAgentManagementStatus(ctx, dataDirectory)
}

func (k CoreAgentKernel) AIConfigurationSources(ctx context.Context, source, home string, environment map[string]string) ([]core.AIConfigurationFile, error) {
	return k.Client.AIConfigurationSources(ctx, source, home, environment)
}

func (k CoreAgentKernel) ParseAIConfiguration(ctx context.Context, request core.AIConfigurationParseRequest) (*core.AIConfiguration, error) {
	return k.Client.ParseAIConfiguration(ctx, request)
}

func (k CoreAgentKernel) InstallAgentAdapter(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error) {
	return k.Client.InstallAgentAdapter(ctx, dataDirectory, agentID, progress)
}

func (k CoreAgentKernel) OpenAgentSession(launch json.RawMessage) (AgentSession, error) {
	session, err := core.OpenAgentSession(launch)
	if err != nil {
		return nil, err
	}
	return session, nil
}

const (
	// agentLoadTimeout bounds adapter detection and local configuration reads.
	agentLoadTimeout = 30 * time.Second
	// agentInstallTimeout bounds one explicit adapter install. The user can
	// cancel it; the deadline only stops a wedged installer.
	agentInstallTimeout = 10 * time.Minute
	// agentMessageLimit and agentMessageBytesLimit bound the transcript. Older
	// messages are dropped so a long conversation cannot grow without limit.
	agentMessageLimit      = 200
	agentMessageBytesLimit = 1 << 20
	// agentMessageTextLimit bounds one streamed message. A single reply is
	// still one paragraph, so a smaller per-message bound keeps painting cheap.
	agentMessageTextLimit = 64 << 10
)

// agentMessage is one line of the transcript.
type agentMessage struct {
	Role      agentRole
	Text      string
	Streaming bool
}

type agentRole uint8

const (
	agentRoleUser agentRole = iota
	agentRoleAssistant
)

type agentPermissionOption struct {
	OptionID string
	Name     string
	Kind     string
}

// agentPermission is one pending permission request. It is answered only by an
// explicit user choice; the panel never selects an option automatically.
type agentPermission struct {
	RequestID string
	Title     string
	Options   []agentPermissionOption
}

// agentConnection is one open Core connection and the goroutine reading it.
type agentConnection struct {
	session AgentSession
	ctx     context.Context
	cancel  context.CancelFunc
}

type agentPhase uint8

const (
	agentPhaseIdle agentPhase = iota
	agentPhaseLoading
	agentPhaseStarting
	agentPhaseReady
	agentPhaseBusy
	agentPhaseCancelling
	agentPhaseFailed
)

// agentState is one project's Agent panel. It is created with the project and
// dropped with it; no Agent process starts until the panel is first painted.
type agentState struct {
	statusLoaded     bool
	statusErr        string
	agents           []core.AgentCatalogStatus
	providers        map[string][]agentProvider
	providerErr      map[string]string
	selected         int
	selectedProvider int

	connecting bool
	conn       *agentConnection
	// installing is the adapter id of an explicit install in flight, empty
	// otherwise. installCancel cancels that install; the panel never starts one
	// on its own.
	installing        string
	installCancelling bool
	installCancel     context.CancelFunc
	installProgress   core.AgentInstallProgress
	// installRelay coalesces the progress a background install reports. It is
	// a pointer so the install goroutine never reads the project's mutable
	// state; closing the project replaces the relay and the stale posts are
	// ignored on the window thread.
	installRelay   *agentInstallProgressRelay
	installErr     string
	installWarning string
	lastInstall    string
	sessionID      string
	pending        string
	nextToken      uint64
	phase          agentPhase
	err            string
	permission     *agentPermission
	messages       []agentMessage
	bytes          int
	// history is this project connection's Agent-owned conversation list;
	// config is the adapter-declared session settings; auth is Core's sign-in
	// state. All three are dropped with the project or the connection.
	history agentHistoryState
	config  agentSessionConfig
	auth    agentAuthState

	// editor is the composer's text, input the Field that shows it in the panel. The
	// panel keeps the editor so Core-facing code reads the committed draft without the
	// page; resetComposer gives both a fresh history after a send.
	editor *text.Editor
	input  ui.Field

	// transcript and historyList are the lists of the conversation and of the
	// history panel. follow keeps the transcript at its end while a reply streams in,
	// until the user scrolls away; seen is the transcript's size at the last paint.
	transcript  ui.ListState
	historyList ui.ListState
	follow      bool
	seen        int
}

type agentInstallProgressRelay struct {
	mu         sync.Mutex
	generation uint64
	pending    bool
	latest     core.AgentInstallProgress
}

func newAgentState() agentState {
	state := agentState{
		providers:    map[string][]agentProvider{},
		providerErr:  map[string]string{},
		follow:       true,
		installRelay: new(agentInstallProgressRelay),
		history:      newAgentHistoryState(),
		config:       newAgentSessionConfig(),
	}
	state.resetComposer()
	return state
}

// resetComposer empties the composer with an editor of its own, so the draft that
// was sent cannot be undone into the next one.
func (s *agentState) resetComposer() {
	s.editor = text.NewEditor("")
	s.input = ui.Field{}
	s.input.Bind(s.editor)
}

func (a *App) agentKernelReady() bool { return a.agentKernel != nil }

// ensureAgentState loads adapter detection and local provider metadata once per
// project, on a background goroutine. Painting only asks; it never waits.
func (a *App) ensureAgentState(p *project) {
	if p == nil || !a.agentKernelReady() || p.agent.statusLoaded || p.agent.connecting {
		return
	}
	p.agent.statusLoaded = true
	p.agent.phase = agentPhaseLoading
	p.agent.statusErr = ""
	p.agent.providerErr = map[string]string{}
	a.background(p, agentLoadTimeout, func(ctx context.Context) func(*App) {
		status, statusErr := a.agentKernel.ReadAgentManagementStatus(ctx, a.store.Dir())
		providers, providerErrs := a.discoverAgentProviders(ctx)
		return func(a *App) {
			if a.project != p {
				return
			}
			if statusErr != nil {
				p.agent.statusErr = a.agentStatusError(statusErr)
				p.agent.phase = agentPhaseFailed
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_status", statusErr))
				return
			}
			p.agent.agents = status.Agents
			p.agent.providers = providers
			p.agent.providerErr = providerErrs
			for source, issue := range providerErrs {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_provider_"+source, errors.New(issue)))
			}
			p.agent.phase = agentPhaseIdle
			p.agent.selected = clampIndex(p.agent.selected, len(p.agent.agents))
			p.agent.selectedProvider = 0
		}
	})
}

func clampIndex(index, length int) int {
	if length <= 0 || index < 0 {
		return 0
	}
	if index >= length {
		return length - 1
	}
	return index
}

// selectedAgent returns the selected catalog entry, if any.
func (p *project) selectedAgent() (core.AgentCatalogStatus, bool) {
	if p == nil || len(p.agent.agents) == 0 {
		return core.AgentCatalogStatus{}, false
	}
	return p.agent.agents[clampIndex(p.agent.selected, len(p.agent.agents))], true
}

// selectedProvider returns the provider selected for the selected agent.
func (p *project) selectedProvider() (agentProvider, bool) {
	agent, ok := p.selectedAgent()
	if !ok {
		return agentProvider{}, false
	}
	list := p.providersForAgent(agent)
	if len(list) == 0 {
		return agentProvider{}, false
	}
	return list[clampIndex(p.agent.selectedProvider, len(list))], true
}

// providersForAgent returns the discovered providers whose Core-reported API
// protocol matches the selected agent's Core-reported protocol. It does not
// branch on Codex or Claude names.
func (p *project) providersForAgent(agent core.AgentCatalogStatus) []agentProvider {
	var list []agentProvider
	for _, source := range agentProviderSources() {
		for _, provider := range p.agent.providers[source] {
			if provider.Protocol == agent.Protocol {
				list = append(list, provider)
			}
		}
	}
	return list
}

// canStartAgent reports that the selected adapter is installed and its provider
// has everything Core needs to launch.
func (p *project) canStartAgent() bool {
	agent, ok := p.selectedAgent()
	if !ok || agent.InstalledVersion == nil {
		return false
	}
	provider, ok := p.selectedProvider()
	return ok && provider.Issue == "" && !provider.MissingKey && provider.APIKey != "" && provider.Protocol != ""
}

// startAgent opens one Core ACP connection for the selected agent and provider.
// The launch JSON carries the API key; it is never logged or persisted.
func (a *App) startAgent(p *project) {
	if p == nil || p.agent.connecting || p.agent.conn != nil || !p.canStartAgent() {
		return
	}
	agent, _ := p.selectedAgent()
	provider, _ := p.selectedProvider()
	launch, err := json.Marshal(map[string]any{
		"agentId":       agent.ID,
		"cwd":           p.root,
		"dataDirectory": a.store.Dir(),
		"provider": map[string]any{
			"protocol": provider.Protocol,
			"baseUrl":  provider.Endpoint,
			"apiKey":   provider.APIKey,
			"model":    provider.Model,
		},
	})
	if err != nil {
		p.agent.err = a.text.Agent.ErrorConnection
		p.agent.phase = agentPhaseFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_launch_encode", err))
		return
	}
	p.agent.connecting = true
	p.agent.phase = agentPhaseStarting
	p.agent.err = ""
	p.agent.messages = nil
	p.agent.bytes = 0
	p.agent.sessionID = ""
	p.agent.pending = ""
	p.agent.permission = nil
	a.performed("agent.connect", surfaceButton)
	a.agentClosing.Add(1)
	go func() {
		defer a.agentClosing.Done()
		session, err := a.agentKernel.OpenAgentSession(launch)
		if session != nil && p.ctx.Err() != nil {
			session.Close()
			return
		}
		a.post(func(a *App) {
			if a.project != p {
				if session != nil {
					a.closeAgentSession(session)
				}
				return
			}
			if p.agent.conn != nil || !p.agent.connecting {
				if session != nil {
					a.closeAgentSession(session)
				}
				return
			}
			if err != nil {
				p.agent.connecting = false
				p.agent.phase = agentPhaseFailed
				p.agent.err = a.text.Agent.ErrorConnection
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_start", err))
				return
			}
			ctx, cancel := context.WithCancel(context.Background())
			conn := &agentConnection{session: session, ctx: ctx, cancel: cancel}
			p.agent.conn = conn
			a.readAgentEvents(p, conn)
		})
	}()
}

// installAgent runs one explicit adapter install. Opening the panel never
// calls it; only the Install button does. Progress is posted from Core's
// synchronous observer, and the result refreshes the real adapter state.
func (a *App) installAgent(p *project, agentID string) {
	if p == nil || !a.agentKernelReady() || p.agent.installing != "" || agentID == "" {
		return
	}
	ctx, cancel := context.WithTimeout(p.ctx, agentInstallTimeout)
	p.agent.installing = agentID
	p.agent.lastInstall = agentID
	p.agent.installCancelling = false
	p.agent.installCancel = cancel
	p.agent.installProgress = core.AgentInstallProgress{}
	relay := p.agent.installRelay
	if relay == nil {
		relay = new(agentInstallProgressRelay)
		p.agent.installRelay = relay
	}
	relay.mu.Lock()
	relay.generation++
	generation := relay.generation
	relay.pending = false
	relay.latest = core.AgentInstallProgress{}
	relay.mu.Unlock()
	p.agent.installErr = ""
	p.agent.installWarning = ""
	a.performed("agent.install", surfaceButton)
	a.agentClosing.Add(1)
	go func() {
		defer a.agentClosing.Done()
		defer cancel()
		result, observationErr, requestErr := a.agentKernel.InstallAgentAdapter(ctx, a.store.Dir(), agentID, func(progress core.AgentInstallProgress) {
			a.postAgentInstallProgress(relay, generation, agentID, progress)
		})
		a.post(func(a *App) {
			if a.project != p || p.agent.installing != agentID {
				return
			}
			p.agent.installing = ""
			p.agent.installCancel = nil
			p.agent.installCancelling = false
			p.agent.installProgress = core.AgentInstallProgress{}
			relay.mu.Lock()
			relay.pending = false
			relay.latest = core.AgentInstallProgress{}
			relay.mu.Unlock()
			switch {
			case errors.Is(requestErr, context.Canceled):
				p.agent.installErr = a.text.Agent.InstallCancelled
			case errors.Is(requestErr, context.DeadlineExceeded):
				p.agent.installErr = a.text.Agent.InstallTimedOut
				a.emit(operationFailedLevel, operationFailedEvent, agentInstallFailureFields("agent_install", requestErr))
			case requestErr != nil:
				// The installer's raw output may contain registry or environment
				// details, so neither the panel nor the log repeats it.
				p.agent.installErr = a.text.Agent.InstallFailed(a.text.Agent.InstallFailedDetail)
				a.emit(operationFailedLevel, operationFailedEvent, agentInstallFailureFields("agent_install", requestErr))
			default:
				p.agent.installErr = ""
				_ = result
			}
			if observationErr != nil {
				p.agent.installWarning = a.text.Agent.InstallProgressLost
				a.emit(core.LevelWarn, operationFailedEvent, map[string]any{"operation": "agent_install_progress"})
			}
			// Whether the install succeeded, failed or was cancelled, the
			// authoritative state comes from Core, not from the result guess.
			p.agent.statusLoaded = false
			a.ensureAgentState(p)
		})
	}()
}

// postAgentInstallProgress coalesces background progress into at most one
// queued window task. The callback runs on Core's request goroutine and must
// not read project UI state directly.
func (a *App) postAgentInstallProgress(relay *agentInstallProgressRelay, generation uint64, agentID string, progress core.AgentInstallProgress) {
	relay.mu.Lock()
	relay.latest = progress
	if relay.pending {
		relay.mu.Unlock()
		return
	}
	relay.pending = true
	relay.mu.Unlock()
	a.post(func(a *App) {
		relay.mu.Lock()
		latest := relay.latest
		relay.pending = false
		current := relay.generation
		relay.mu.Unlock()
		p := a.project
		if p == nil || p.agent.installing != agentID || p.agent.installRelay != relay || current != generation {
			return
		}
		p.agent.installProgress = latest
	})
}

// agentInstallFailureFields keeps the stable Core error code in the log without
// repeating installer output that may include environment details.
func agentInstallFailureFields(operation string, err error) map[string]any {
	fields := map[string]any{"operation": operation}
	var coreErr *core.Error
	if errors.As(err, &coreErr) {
		fields["code"] = string(coreErr.Code)
	}
	return fields
}

// cancelAgentInstall asks Core to stop the current explicit install.
func (a *App) cancelAgentInstall(p *project) {
	if p == nil || p.agent.installCancel == nil || p.agent.installCancelling {
		return
	}
	p.agent.installCancelling = true
	p.agent.installCancel()
	a.performed("agent.install.cancel", surfaceButton)
}

// readAgentEvents consumes Core's events on a goroutine and hands each one to
// the window thread. It never waits on the UI or closes the session itself.
func (a *App) readAgentEvents(p *project, conn *agentConnection) {
	go func() {
		for {
			raw, err := conn.session.Next(conn.ctx)
			if err != nil {
				a.post(func(a *App) {
					if a.project != p || p.agent.conn != conn {
						return
					}
					a.agentConnectionFailed(p, conn, err)
				})
				return
			}
			event := append(json.RawMessage(nil), raw...)
			a.post(func(a *App) {
				if a.project != p || p.agent.conn != conn {
					return
				}
				a.applyAgentEvent(p, conn, event)
			})
		}
	}()
}

func (a *App) agentConnectionFailed(p *project, conn *agentConnection, err error) {
	if errors.Is(err, core.ErrAgentClosed) || errors.Is(err, core.ErrAgentEventOverflow) || errors.Is(err, context.Canceled) {
		// A closed connection is expected after disconnect or project close.
		if p.agent.conn == conn && p.agent.phase != agentPhaseIdle {
			if errors.Is(err, core.ErrAgentEventOverflow) {
				p.agent.err = a.text.Agent.ErrorOverflow
			}
		}
	} else {
		p.agent.err = a.text.Agent.ConnectionLost
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_stream", err))
	}
	a.dropAgentConnection(p, conn)
	p.agent.phase = agentPhaseFailed
}

// dropAgentConnection forgets conn and closes its Core session off the window
// thread. Close waits for the child process tree, so it must not run here.
func (a *App) dropAgentConnection(p *project, conn *agentConnection) {
	if conn == nil {
		return
	}
	if p.agent.conn == conn {
		p.agent.conn = nil
	}
	p.agent.connecting = false
	p.agent.sessionID = ""
	p.agent.pending = ""
	p.agent.permission = nil
	p.agent.auth = agentAuthNone
	p.agent.history = newAgentHistoryState()
	p.agent.config = newAgentSessionConfig()
	conn.cancel()
	a.closeAgentSession(conn.session)
}

func (a *App) closeAgentSession(session AgentSession) {
	if session == nil {
		return
	}
	a.agentClosing.Add(1)
	go func() {
		defer a.agentClosing.Done()
		session.Close()
	}()
}

// disconnectAgent closes the connection and returns to provider selection.
func (a *App) disconnectAgent(p *project) {
	if p == nil || p.agent.conn == nil {
		return
	}
	a.performed("agent.disconnect", surfaceButton)
	conn := p.agent.conn
	a.dropAgentConnection(p, conn)
	p.agent.phase = agentPhaseIdle
	p.agent.err = ""
	p.agent.messages = nil
	p.agent.bytes = 0
}

// closeAgent releases one project's Agent resources. It is called when the
// project closes; the Core session is closed on its own goroutine.
func (a *App) closeAgent(p *project) {
	if p == nil {
		return
	}
	if conn := p.agent.conn; conn != nil {
		a.dropAgentConnection(p, conn)
	}
	if p.agent.installCancel != nil {
		p.agent.installCancel()
		p.agent.installCancel = nil
	}
	for source, list := range p.agent.providers {
		for i := range list {
			list[i].APIKey = ""
		}
		p.agent.providers[source] = list
	}
	if p.agentPage != nil {
		p.agentPage.Close()
		p.agentPage = nil
	}
	p.agent = newAgentState()
}

// applyAgentEvent applies one Core event. Core exposes AgentEvent only as the
// fixed JSON shapes in shared/fixtures/agent/acp-events-v1.json; there is no
// normalized agent.event command, so this switch decodes those contract values
// and never branches on Codex or Claude names. Unknown additive events are
// ignored.
func (a *App) applyAgentEvent(p *project, conn *agentConnection, raw json.RawMessage) {
	var event struct {
		Kind            string                `json:"kind"`
		Token           string                `json:"token"`
		SessionID       string                `json:"sessionId"`
		Message         string                `json:"message"`
		RequestID       string                `json:"requestId"`
		Request         json.RawMessage       `json:"request"`
		Update          json.RawMessage       `json:"update"`
		ConfigOptions   json.RawMessage       `json:"configOptions"`
		CanListSessions bool                  `json:"canListSessions"`
		CanLoadSessions bool                  `json:"canLoadSessions"`
		Sessions        []agentSessionSummary `json:"sessions"`
	}
	if err := json.Unmarshal(raw, &event); err != nil {
		p.agent.err = a.text.Agent.ErrorConnection
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_event", err))
		return
	}
	switch event.Kind {
	case "ready":
		a.clearAgentAuthentication(p)
		p.agent.history.canList = event.CanListSessions
		p.agent.history.canLoad = event.CanLoadSessions
		p.agent.phase = agentPhaseReady
		p.agent.connecting = false
		if p.agent.sessionID == "" && p.agent.pending == "" && !p.agent.history.restoring() {
			a.newAgentSession(p, conn)
		}
	case "sessionCreated":
		if event.Token != "" && event.Token != p.agent.pending {
			return
		}
		a.agentSessionCreated(p, event.SessionID, event.ConfigOptions)
	case "sessionLoaded":
		a.applyAgentSessionLoaded(p, event.Token, event.SessionID, event.ConfigOptions)
	case "sessionsPage":
		a.applyAgentSessionsPage(p, event.Token, event.Sessions)
	case "sessions":
		a.applyAgentSessions(p, event.Token, event.Sessions)
	case "sessionConfigured":
		a.applyAgentSessionConfigured(p, event.Token, event.SessionID, event.ConfigOptions)
	case "update":
		a.applyAgentUpdate(p, event.SessionID, event.Update)
	case "permission":
		if !agentEventForCurrentSession(p, event.SessionID) {
			return
		}
		a.applyAgentPermission(p, event.RequestID, event.Request)
	case "turnCancelling":
		if !agentEventForCurrentSession(p, event.SessionID) {
			return
		}
		p.agent.phase = agentPhaseCancelling
		p.agent.permission = nil
	case "turnFinished":
		if !agentEventForCurrentSession(p, event.SessionID) {
			return
		}
		p.agent.connecting = false
		p.agent.permission = nil
		p.agent.phase = agentPhaseReady
	case "requestFailed":
		a.agentRequestFailed(p, event.Token, event.SessionID, event.Message)
	case "stopped":
		a.agentStopped(p, conn, event.Message)
	case "account":
		// Core's whitelisted account event only proves authentication succeeded;
		// the panel does not read or display account details of its own.
		a.clearAgentAuthentication(p)
		if p.agent.phase == agentPhaseFailed {
			p.agent.phase = agentPhaseReady
			p.agent.err = ""
		}
	case "authenticationRequired", "authenticating":
		a.applyAgentAuthentication(p, event.Kind)
	}
}

func (a *App) newAgentSession(p *project, conn *agentConnection) {
	p.agent.nextToken++
	token := fmt.Sprintf("desktop-%d", p.agent.nextToken)
	p.agent.pending = token
	command, err := json.Marshal(map[string]any{"kind": "newSession", "token": token})
	if err != nil {
		p.agent.err = a.text.Agent.ErrorSession
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_session_encode", err))
		return
	}
	if err := conn.session.Send(command); err != nil {
		p.agent.pending = ""
		p.agent.connecting = false
		p.agent.err = a.agentSessionError(err)
		p.agent.phase = agentPhaseFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_new_session", err))
	}
}

// applyAgentUpdate renders live chunks and Core's replayed history. A replayed
// update is accepted only for the conversation being restored (or its replay
// tail) and never turns a restored conversation busy.
func (a *App) applyAgentUpdate(p *project, sessionID string, raw json.RawMessage) {
	h := &p.agent.history
	live := p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling
	restoring := h.restoreSession != "" && (sessionID == "" || sessionID == h.restoreSession)
	replaying := h.replaySession != "" && (sessionID == "" || sessionID == h.replaySession)
	if !live && !restoring && !replaying {
		return
	}
	if live && sessionID != "" && p.agent.sessionID != "" && sessionID != p.agent.sessionID {
		return
	}
	var update struct {
		SessionUpdate string `json:"sessionUpdate"`
		Content       struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &update); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_update", err))
		return
	}
	if update.Content.Type != "text" || update.Content.Text == "" {
		return
	}
	// A load's replay is staged until sessionLoaded; the open conversation stays
	// untouched if Core rejects the load.
	messages, bytes := &p.agent.messages, &p.agent.bytes
	if restoring {
		messages, bytes = &h.replayMessages, &h.replayBytes
	}
	switch update.SessionUpdate {
	case "user_message_chunk":
		// A live prompt is already in the transcript; only replay supplies user
		// rows here, so a duplicated live echo is ignored.
		if live {
			return
		}
		appendAgentUserText(messages, bytes, update.Content.Text)
	case "agent_message_chunk":
		appendAgentAssistantText(messages, bytes, update.Content.Text)
		if live {
			p.agent.phase = agentPhaseBusy
		}
	default:
		return
	}
	trimAgentMessages(messages, bytes)
}

// appendAgentAssistantText merges a streamed chunk into the last assistant row,
// bounded by the display limit. Core's original event is unchanged.
func appendAgentAssistantText(messages *[]agentMessage, bytes *int, value string) {
	text := agentDisplayPrefix(value, agentMessageTextLimit)
	if len(*messages) > 0 && (*messages)[len(*messages)-1].Role == agentRoleAssistant && (*messages)[len(*messages)-1].Streaming {
		last := &(*messages)[len(*messages)-1]
		room := agentMessageTextLimit - len(last.Text)
		if room > 0 {
			text = agentDisplayPrefix(text, room)
			last.Text += text
			*bytes += len(text)
		}
		return
	}
	*messages = append(*messages, agentMessage{Role: agentRoleAssistant, Text: text, Streaming: true})
	*bytes += len(text)
}

// appendAgentUserText rebuilds replayed user turns. Consecutive chunks of one
// upstream message stay one row; a new chunk after an assistant row starts one.
func appendAgentUserText(messages *[]agentMessage, bytes *int, value string) {
	text := agentDisplayPrefix(value, agentMessageTextLimit)
	if len(*messages) > 0 {
		last := &(*messages)[len(*messages)-1]
		if last.Role == agentRoleAssistant {
			last.Streaming = false
		}
		if last.Role == agentRoleUser {
			room := agentMessageTextLimit - len(last.Text)
			if room <= 0 {
				return
			}
			text = agentDisplayPrefix(text, room)
			last.Text += text
			*bytes += len(text)
			return
		}
	}
	*messages = append(*messages, agentMessage{Role: agentRoleUser, Text: text})
	*bytes += len(text)
}

// agentDisplayPrefix bounds the rendered text without splitting a UTF-8 rune.
// Core's original event remains unchanged; this is only the display limit.
func agentDisplayPrefix(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	for limit > 0 && !utf8.RuneStart(value[limit]) {
		limit--
	}
	return value[:limit]
}

func (a *App) applyAgentPermission(p *project, requestID string, raw json.RawMessage) {
	if p.agent.phase != agentPhaseBusy {
		return
	}
	var request struct {
		ToolCall struct {
			Title string `json:"title"`
		} `json:"toolCall"`
		Options []struct {
			OptionID string `json:"optionId"`
			Name     string `json:"name"`
			Kind     string `json:"kind"`
		} `json:"options"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_permission_event", err))
		return
	}
	permission := &agentPermission{RequestID: requestID, Title: request.ToolCall.Title}
	for _, option := range request.Options {
		permission.Options = append(permission.Options, agentPermissionOption{
			OptionID: option.OptionID,
			Name:     option.Name,
			Kind:     option.Kind,
		})
	}
	p.agent.permission = permission
	p.agent.phase = agentPhaseBusy
}

func (a *App) answerAgentPermission(p *project, optionID string) {
	if p == nil || p.agent.conn == nil || p.agent.permission == nil {
		return
	}
	requestID := p.agent.permission.RequestID
	var value any
	if optionID != "" {
		value = optionID
	}
	command, err := json.Marshal(map[string]any{"kind": "permission", "requestId": requestID, "optionId": value})
	if err != nil {
		p.agent.err = a.text.Agent.ErrorPermission
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_permission_encode", err))
		return
	}
	if err := p.agent.conn.session.Send(command); err != nil {
		p.agent.err = a.text.Agent.ErrorPermission
		p.agent.phase = agentPhaseFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_permission", err))
		return
	}
	p.agent.permission = nil
	a.performed("agent.permission.answer", surfaceButton)
}

// agentCanSend reports that the composer can submit the current draft.
func (a *App) agentCanSend(p *project) bool {
	if p == nil || p.agent.conn == nil || p.agent.sessionID == "" || p.agent.connecting ||
		p.agent.pending != "" || p.agent.history.restoring() || p.agent.config.pendingToken != "" ||
		p.agent.auth != agentAuthNone ||
		p.agent.permission != nil || p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling {
		return false
	}
	return strings.TrimSpace(p.agent.editor.CommittedString()) != ""
}

func (a *App) sendAgentPrompt(p *project) {
	if !a.agentCanSend(p) {
		return
	}
	value := strings.TrimSpace(p.agent.editor.CommittedString())
	command, err := json.Marshal(map[string]any{"kind": "prompt", "sessionId": p.agent.sessionID, "text": value})
	if err != nil {
		p.agent.err = a.text.Agent.ErrorSend
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_prompt_encode", err))
		return
	}
	if err := p.agent.conn.session.Send(command); err != nil {
		p.agent.err = a.agentSessionError(err)
		p.agent.phase = agentPhaseFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_prompt", err))
		return
	}
	p.agent.messages = append(p.agent.messages, agentMessage{Role: agentRoleUser, Text: value})
	p.agent.bytes += len(value)
	p.agent.resetComposer()
	p.agent.phase = agentPhaseBusy
	p.agent.err = ""
	p.agent.permission = nil
	p.agent.history.replaySession = ""
	p.agent.history.open = false
	a.trimAgentTranscript(p)
	a.performed("agent.prompt", surfaceButton)
}

func (a *App) cancelAgentTurn(p *project) {
	if p == nil || p.agent.conn == nil || p.agent.sessionID == "" || p.agent.phase != agentPhaseBusy {
		return
	}
	command, err := json.Marshal(map[string]any{"kind": "cancel", "sessionId": p.agent.sessionID})
	if err != nil {
		p.agent.err = a.text.Agent.ErrorCancel
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_cancel_encode", err))
		return
	}
	if err := p.agent.conn.session.Send(command); err != nil {
		p.agent.err = a.agentSessionError(err)
		p.agent.phase = agentPhaseFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_cancel", err))
		return
	}
	p.agent.phase = agentPhaseCancelling
	p.agent.permission = nil
	a.performed("agent.cancel", surfaceButton)
}

// trimAgentTranscript drops the oldest messages while the transcript exceeds
// either bound. It never splits a message.
func (a *App) trimAgentTranscript(p *project) {
	trimAgentMessages(&p.agent.messages, &p.agent.bytes)
}

// trimAgentMessages drops the oldest rows while either bound is exceeded. It is
// shared by the live transcript and the load replay buffer.
func trimAgentMessages(messages *[]agentMessage, bytes *int) {
	for len(*messages) > agentMessageLimit || (*bytes > agentMessageBytesLimit && len(*messages) > 1) {
		*bytes -= len((*messages)[0].Text)
		*messages = (*messages)[1:]
	}
}

// agentStatusError localizes a detection timeout and keeps Core's own message.
func (a *App) agentStatusError(err error) string {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return a.text.Agent.ErrorDetection
	}
	return a.text.Agent.ErrorStatus(err.Error())
}

// agentDiscoveryIssue localizes a timeout and keeps Core's own message.
func (a *App) agentDiscoveryIssue(err error) string {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return agentIssueConfigRead
	}
	return err.Error()
}

// agentSessionError turns a bridge send failure into a translated message.
func (a *App) agentSessionError(err error) string {
	switch {
	case errors.Is(err, core.ErrAgentClosed):
		return a.text.Agent.ConnectionClosed
	case errors.Is(err, core.ErrAgentEventOverflow):
		return a.text.Agent.ErrorOverflow
	}
	return a.text.Agent.ErrorSend
}

// agentStatusText is the composer's status line.
func (a *App) agentStatusText(p *project) string {
	t := a.text.Agent
	if p.agent.statusErr != "" {
		return t.StatusFailed
	}
	if p.agent.permission != nil {
		return t.StatusWaitingPermission
	}
	switch p.agent.auth {
	case agentAuthRequired:
		return t.StatusSignIn
	case agentAuthSigningIn:
		return t.StatusSigningIn
	}
	if p.agent.history.restoring() {
		return t.StatusRestoring
	}
	if p.agent.config.pendingToken != "" {
		return t.StatusConfiguring
	}
	switch p.agent.phase {
	case agentPhaseLoading:
		return t.StatusChecking
	case agentPhaseStarting:
		return t.StatusStarting
	case agentPhaseBusy:
		return t.StatusWorking
	case agentPhaseCancelling:
		return t.StatusStopping
	case agentPhaseFailed:
		return t.StatusFailed
	}
	return t.StatusReady
}
