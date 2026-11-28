package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

// This file is the logic of the Agent tool window (API-45, matrix id agent-native-sessions).
// Core runs every agent CLI and keeps the session records; the agents package names its
// commands and folds a session's events into a transcript. This file configures the agents the
// installed plugins declare, starts, prompts and closes the conversations of the open project,
// reads their events, opens an agent in a terminal and lists the recorded sessions.
//
// Nothing here knows a particular agent: names, tools, forms and session directories come from
// the plugins. Conversation text, prompts and tool output stay in memory and are never logged;
// the window logs only the action and, when one fails, Core's error code.

const (
	// agentWaitTimeout is how long one read of the event queue waits for an event.
	agentWaitTimeout = 5 * time.Second
	// agentRetryDelay is the pause after a failed read before the next one.
	agentRetryDelay = time.Second
	// agentCallTimeout bounds a prompt, a cancel, an answer or a close.
	agentCallTimeout = 30 * time.Second
	// agentStartTimeout bounds a start: the backend may start first and the CLI says hello.
	agentStartTimeout = 2 * time.Minute
	// agentSyncTimeout bounds reading the changed session files of the agents.
	agentSyncTimeout = 2 * time.Minute
	// agentEventLimit is the most events one read takes.
	agentEventLimit = 256
	// maxAgentConversations bounds the conversations a window keeps, live or ended; Core bounds
	// the live ones of each agent.
	maxAgentConversations = 8
)

// agentCacheBase is the user's cache directory, which the session record cache goes under; a
// test replaces it.
var agentCacheBase = os.UserCacheDir

// agentsTab is the tab the Agent tool window shows.
type agentsTab int

const (
	agentsTabChat agentsTab = iota
	agentsTabHistory
)

// agentsState is the Agent tool window of a window: the agents Core knows, the conversations
// of the open project and the History tab. It belongs to the window thread.
type agentsState struct {
	catalog  []agents.CatalogAgent
	rejected []agents.Rejected
	plugins  []pluginservice.AgentPlugin
	// configured is set once Core answered a configuration; until then the window does not
	// say that no agent is installed.
	configured bool
	// menu is the header menu that is open.
	menu agentsMenu

	conversations []*agentConversation
	// current is the index of the conversation the window shows.
	current int
	// cursor is the sequence of the last event read from Core's queue; cursorSet says it was
	// probed, so events older than this window's first session are never read.
	cursor    uint64
	cursorSet bool
	// rewind is the cursor a start probed while a read was in flight: the read's answer may
	// already be past the new session's first events, so the next read starts from here.
	rewind    uint64
	rewinding bool
	pumping   bool
	starting  bool

	tab     agentsTab
	history agentHistory
	// recordSync keeps the session records current for the views that read usage
	// (agents_records_sync.go).
	recordSync agentRecordSync
}

// agentsMenu is a menu of the Agent tool window's header.
type agentsMenu int

const (
	agentsMenuNone agentsMenu = iota
	// agentsMenuNew lists the agents a new conversation can start with.
	agentsMenuNew
	// agentsMenuMore opens an agent's CLI in a terminal or updates it.
	agentsMenuMore
)

// agentConversation is one session the window started.
type agentConversation struct {
	agent      agents.CatalogAgent
	transcript *agents.Transcript
	// seen is the sequence of the last event applied, so events read again after a rewind
	// are applied once.
	seen   uint64
	list   ui.ListState
	prompt string
	// busy is set while a prompt, a cancel or a close is on its way.
	busy bool
	// answering is the permission request whose answer is on its way.
	answering string
	// selections keeps the text selection of each entry drawn, by the entry's serial, so a
	// selection stays put while the rows scroll and new events arrive.
	selections map[uint64]*ui.TextSelectionState
	// pruned is the serial of the oldest entry when the selections were last pruned.
	pruned uint64
}

// selection is the text selection of the entry with serial, made when the entry is first drawn.
func (conversation *agentConversation) selection(serial uint64) *ui.TextSelectionState {
	if conversation.selections == nil {
		conversation.selections = map[uint64]*ui.TextSelectionState{}
	}
	state := conversation.selections[serial]
	if state == nil {
		state = &ui.TextSelectionState{}
		conversation.selections[serial] = state
	}
	return state
}

// pruneSelections forgets the selections of the entries the transcript dropped to keep its bounds.
func (conversation *agentConversation) pruneSelections() {
	entries := conversation.transcript.Entries
	if len(entries) == 0 || entries[0].Serial == conversation.pruned {
		return
	}
	conversation.pruned = entries[0].Serial
	for serial := range conversation.selections {
		if serial < conversation.pruned {
			delete(conversation.selections, serial)
		}
	}
}

// agentCatalogResult is what a configuration found, handed to the window thread. Stale
// reports that a later configuration reached Core first, so this one changed nothing.
type agentCatalogResult struct {
	configured agents.Configured
	plugins    []pluginservice.AgentPlugin
	err        error
	stale      bool
}

// agentConfigureTicket is one configuration of the agents, taken on the window thread: the
// consent it hands Core and its number among the configurations.
type agentConfigureTicket struct {
	consent    agents.Consent
	generation uint64
}

// agentConfigureTicket starts a configuration with the user's current consent.
func (a *App) agentConfigureTicket() agentConfigureTicket {
	a.agentConfigureIssued++
	return agentConfigureTicket{consent: agents.Consent(a.settings.AgentSessionConsent).Clone(), generation: a.agentConfigureIssued}
}

// configureAgents hands Core the agents of the snapshot's plugins and opens the session record
// cache for them, off the window thread. Each plugin is granted what its manifest asks for,
// with agents.sessions.read only when the user consented for it. The cache opens whenever an
// agent declares session files, consent or not, so taking a consent back can drop what an
// earlier run cached; Core reads no session file of an agent without the grant.
func (a *App) configureAgents(ctx context.Context, snapshot pluginservice.InstalledSnapshot, ticket agentConfigureTicket) agentCatalogResult {
	kernel := a.agentKernel
	if kernel == nil {
		return agentCatalogResult{}
	}
	a.agentConfigureMu.Lock()
	defer a.agentConfigureMu.Unlock()
	if ticket.generation <= a.agentConfigureDone {
		return agentCatalogResult{stale: true}
	}
	a.agentConfigureDone = ticket.generation
	plugins, readErr := snapshot.AgentPlugins()
	a.readAgentIcons(ctx, plugins)
	configured, err := kernel.Configure(ctx, agentConfiguration(plugins, ticket.consent))
	result := agentCatalogResult{configured: configured, plugins: plugins, err: errors.Join(readErr, err)}
	if err == nil && slices.ContainsFunc(configured.Agents, func(agent agents.CatalogAgent) bool { return agent.ReadsSessions }) {
		config, configErr := agentRecordsConfig(configured.Agents)
		if configErr == nil {
			_, configErr = kernel.ConfigureRecords(ctx, config)
		}
		result.err = errors.Join(result.err, configErr)
	}
	return result
}

// readAgentIcons reads the package icons the agents of the plugins declare, off the window
// thread, so a row draws them from memory; a broken icon is reported once and the row keeps the
// generic one.
func (a *App) readAgentIcons(ctx context.Context, plugins []pluginservice.AgentPlugin) {
	for _, plugin := range plugins {
		for _, declaration := range plugin.Icons {
			if err := a.pluginIcons.Read(plugin.PluginID, plugin.Package, declaration); err != nil {
				a.backgroundFailedIn(ctx, "plugin_icon", fmt.Errorf("%s: %w", plugin.PluginID, err))
			}
		}
	}
}

// agentConfiguration is agents.configure's plugins: each manifest with the permissions granted.
func agentConfiguration(plugins []pluginservice.AgentPlugin, consent agents.Consent) []agents.ConfiguredPlugin {
	configured := make([]agents.ConfiguredPlugin, 0, len(plugins))
	for _, plugin := range plugins {
		configured = append(configured, agents.ConfiguredPlugin{
			Manifest:           plugin.Manifest,
			GrantedPermissions: agents.GrantedPermissions(plugin.Permissions, consent.Plugin(plugin.PluginID)),
		})
	}
	return configured
}

// agentRecordsConfig is the session record cache's configuration: a directory under the user's
// cache directory, which Core owns, the user's home and the values of the environment
// variables the agents' session directories name, from the login shell first.
func agentRecordsConfig(catalog []agents.CatalogAgent) (agents.RecordsConfig, error) {
	base, err := agentCacheBase()
	if err != nil {
		return agents.RecordsConfig{}, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return agents.RecordsConfig{}, err
	}
	directory := filepath.Join(base, "Lithe", "agent-sessions")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return agents.RecordsConfig{}, err
	}
	login := loginenv.Environment()
	environment := map[string]string{}
	for _, agent := range catalog {
		for _, name := range agent.SessionRootVariables {
			value := login[name]
			if value == "" {
				value = os.Getenv(name)
			}
			if value != "" {
				environment[name] = value
			}
		}
	}
	return agents.RecordsConfig{CacheDirectory: directory, UserHome: home, Environment: environment}, nil
}

// applyAgentCatalog keeps what a configuration found. Conversations of an agent that is gone
// stay as they are: Core ended them and their exit event says so. A plugin Core refused is
// announced once, not on every configuration that refuses it again.
func (a *App) applyAgentCatalog(result agentCatalogResult) {
	if a.agentKernel == nil || result.stale {
		return
	}
	v := &a.agentsView
	previous := v.rejected
	if result.err != nil {
		a.backgroundFailed("agents_configure", result.err)
	}
	if result.err == nil || len(result.configured.Agents) > 0 {
		v.catalog = result.configured.Agents
		v.rejected = result.configured.Rejected
		v.plugins = result.plugins
		v.configured = true
	}
	for _, rejected := range result.configured.Rejected {
		if slices.Contains(previous, rejected) {
			continue
		}
		a.operationRejected("agents_configure", "plugin_rejected")
		a.notify(i18n.SharedFormat(a.language(), "desktop.agents.pluginRejected", map[string]string{"plugin": rejected.PluginID, "reason": rejected.Message}))
	}
	a.publishAgentSettings()
	a.refreshIDEAPISessionTools()
	v.history.forgetUnreadable(v.readableAgents())
	a.syncAgentRecords(true)
}

// currentConversation is the conversation the window shows, nil when there is none.
func (a *App) currentConversation() *agentConversation {
	v := &a.agentsView
	if v.current < 0 || v.current >= len(v.conversations) {
		return nil
	}
	return v.conversations[v.current]
}

// canStartConversation reports whether agent may start a conversation from the header.
func (a *App) canStartConversation(agent agents.CatalogAgent) bool {
	return a.agentKernel != nil && !a.agentsView.starting && agent.MayRun &&
		agent.HasMode("native") && agent.HasForm("conversation")
}

// refuseAgent reports whether the project cannot run agents, telling the user why: Core runs
// the CLI on this computer, so a remote workspace refuses it, and in safe mode the user is
// asked to trust the project first, then proceed runs.
func (a *App) refuseAgent(p *project, operation string, proceed func()) bool {
	if p == nil || a.agentKernel == nil {
		return true
	}
	if a.refuseRemote(p, operation) {
		return true
	}
	if p.safeMode() {
		a.askToTrustProject(p, proceed)
		return true
	}
	return false
}

// startConversation starts a native session of agent in the project, resuming the agent's own
// session resume when it is not empty.
func (a *App) startConversation(p *project, agent agents.CatalogAgent, resume string) {
	if a.refuseAgent(p, "agents_start", func() { a.startConversation(p, agent, resume) }) {
		return
	}
	v := &a.agentsView
	if !a.canStartConversation(agent) {
		a.operationRejected("agents_start", "agent_unavailable")
		return
	}
	a.performed("agents.start", surfaceButton)
	v.starting = true
	kernel, service, root := a.agentKernel, a.plugins, p.root
	base := append(loginenv.Environ(), a.terminalEnvironment()...)
	a.background(p, agentStartTimeout, func(ctx context.Context) func(*App) {
		session, probe, err := a.startAgentSession(ctx, kernel, service, agent, root, resume, base)
		return func(a *App) { a.finishConversationStart(p, agent, session, probe, err) }
	})
}

// startAgentSession starts the backend, resolves the agent's tool, probes the event queue and
// starts the session, off the window thread.
func (a *App) startAgentSession(ctx context.Context, kernel *agents.Client, service *pluginservice.Service, agent agents.CatalogAgent, root, resume string, base []string) (string, uint64, error) {
	if service != nil {
		if err := service.EnsureAgentBackend(ctx, agent.PluginID, agent.AgentID); err != nil {
			return "", 0, err
		}
	}
	tool, err := a.resolveAgentTool(ctx, root, agent.PluginID, agent.Tool)
	if err != nil {
		return "", 0, err
	}
	environment, _ := agents.LaunchEnvironment(base, tool.Environment)
	var rootURI string
	if a.kernel != nil {
		if rootURI, err = a.kernel.PluginDocumentURI(ctx, root, "auto"); err != nil {
			return "", 0, err
		}
	}
	probe, err := kernel.Latest(ctx)
	if err != nil {
		return "", 0, err
	}
	session, err := kernel.Start(ctx, agents.StartRequest{
		PluginID: agent.PluginID, AgentID: agent.AgentID, Cwd: root, ToolPath: tool.Path,
		RootURI: rootURI, Resume: resume, WorkspaceTrusted: true, Environment: environment,
	})
	return session, probe, err
}

// finishConversationStart shows the started session and reads its events from the probed
// sequence, or says why it did not start.
func (a *App) finishConversationStart(p *project, agent agents.CatalogAgent, session string, probe uint64, err error) {
	v := &a.agentsView
	v.starting = false
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		a.operationFailed("agents_start", err)
		if agentToolMissing(err) {
			a.notifyAgentToolMissing(agent)
			return
		}
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.agents.startFailed", map[string]string{"agent": agent.DisplayName, "reason": a.agentFailure(err)}))
		return
	}
	conversation := &agentConversation{agent: agent, transcript: agents.NewTranscript(session, agent.PluginID, agent.AgentID), seen: probe}
	v.conversations = append(v.conversations, conversation)
	if len(v.conversations) > maxAgentConversations {
		v.conversations = dropEndedConversation(v.conversations)
	}
	v.current = len(v.conversations) - 1
	v.tab = agentsTabChat
	switch {
	case !v.cursorSet || !v.pumping:
		v.cursor, v.cursorSet = probe, true
	case !v.rewinding || probe < v.rewind:
		v.rewind, v.rewinding = probe, true
	}
	a.pumpAgentEvents(p)
}

// dropEndedConversation drops the oldest ended conversation of a list over the bound, or the
// oldest one when every one still runs; Core ends it when the window closes it.
func dropEndedConversation(conversations []*agentConversation) []*agentConversation {
	at := slices.IndexFunc(conversations, func(conversation *agentConversation) bool { return !conversation.transcript.Live() })
	if at < 0 {
		at = 0
	}
	return slices.Delete(conversations, at, at+1)
}

// liveConversations reports whether any conversation still runs.
func (v *agentsState) liveConversations() bool {
	return slices.ContainsFunc(v.conversations, func(conversation *agentConversation) bool { return conversation.transcript.Live() })
}

// pumpAgentEvents reads the next events of the queue while a conversation runs. The read is
// not the user's action, so it carries none.
func (a *App) pumpAgentEvents(p *project) {
	v := &a.agentsView
	if v.pumping || !v.cursorSet || !v.liveConversations() || a.agentKernel == nil || p == nil {
		return
	}
	v.pumping = true
	kernel, after := a.agentKernel, v.cursor
	a.within(operation{}, func(a *App) {
		a.background(p, 0, func(ctx context.Context) func(*App) {
			batch, err := kernel.WaitEvents(ctx, after, agentWaitTimeout, agentEventLimit)
			if err != nil && ctx.Err() == nil {
				// The next read waits a moment, so a Core that keeps failing is not asked in a loop.
				timer := time.NewTimer(agentRetryDelay)
				select {
				case <-ctx.Done():
				case <-timer.C:
				}
				timer.Stop()
			}
			if ctx.Err() != nil {
				return nil
			}
			return func(a *App) { a.applyAgentEvents(p, batch, err) }
		})
	})
}

// applyAgentEvents folds a read's events into the conversations they belong to and reads on.
// Events of sessions other windows started are skipped.
func (a *App) applyAgentEvents(p *project, batch agents.EventBatch, err error) {
	v := &a.agentsView
	v.pumping = false
	if err != nil {
		a.backgroundFailed("agents_events", err)
	} else {
		applyAgentBatch(v, batch)
	}
	a.pumpAgentEvents(p)
}

// applyAgentBatch folds batch into the conversations of v and moves the cursor past it.
func applyAgentBatch(v *agentsState, batch agents.EventBatch) {
	if batch.Missed {
		for _, conversation := range v.conversations {
			if conversation.transcript.Live() {
				conversation.transcript.Missed = true
			}
		}
	}
	for _, event := range batch.Events {
		conversation := v.conversation(event.Session)
		if conversation == nil || event.Sequence <= conversation.seen {
			continue
		}
		conversation.seen = event.Sequence
		conversation.transcript.Apply(event.Event)
	}
	if batch.Next > v.cursor || len(batch.Events) > 0 {
		v.cursor = batch.Next
	}
	if v.rewinding {
		v.cursor = min(v.cursor, v.rewind)
		v.rewinding = false
	}
}

// conversation is the conversation of a Core session, nil when the window did not start it.
func (v *agentsState) conversation(session string) *agentConversation {
	for _, conversation := range v.conversations {
		if conversation.transcript.Session == session {
			return conversation
		}
	}
	return nil
}

// canSendPrompt reports whether the conversation takes a prompt now: it runs, no turn is in
// progress and no request is on its way.
func (conversation *agentConversation) canSendPrompt() bool {
	t := conversation.transcript
	return t.Live() && t.ActiveTurn == 0 && !conversation.busy && strings.TrimSpace(conversation.prompt) != ""
}

// sendPrompt sends the prompt field as the conversation's next turn. The prompt shows at once;
// a refused one goes back into the field.
func (a *App) sendPrompt(p *project, conversation *agentConversation, surface actionSurface) {
	if conversation == nil || !conversation.canSendPrompt() {
		return
	}
	if a.refuseAgent(p, "agents_prompt", nil) {
		return
	}
	a.performed("agents.prompt", surface)
	text := strings.TrimSpace(conversation.prompt)
	if len(text) > agentPromptLimit {
		a.operationRejected("agents_prompt", "prompt_too_long")
		a.notify(i18n.Shared(a.language(), "desktop.agents.promptTooLong"))
		return
	}
	conversation.prompt, conversation.busy = "", true
	conversation.transcript.AddPrompt(text)
	conversation.list.ScrollToEnd()
	kernel, session := a.agentKernel, conversation.transcript.Session
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		turn, err := kernel.Prompt(ctx, session, text)
		return func(a *App) {
			conversation.busy = false
			if err != nil {
				restored := conversation.transcript.PromptRefused()
				if conversation.prompt == "" {
					conversation.prompt = restored
				}
				a.operationFailed("agents_prompt", err)
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.agents.promptFailed", map[string]string{"reason": a.agentFailure(err)}))
				return
			}
			conversation.transcript.PromptAccepted(turn)
		}
	})
}

// agentPromptLimit is the longest prompt Core takes.
const agentPromptLimit = 1 << 20

// cancelTurn asks the agent to stop the turn in progress.
func (a *App) cancelTurn(p *project, conversation *agentConversation) {
	if conversation == nil || conversation.transcript.ActiveTurn == 0 || !conversation.transcript.Live() {
		return
	}
	a.performed("agents.cancel", surfaceButton)
	a.agentCall(p, "agents_cancel", func(ctx context.Context, kernel *agents.Client, session string) error {
		_, err := kernel.Cancel(ctx, session)
		return err
	}, conversation)
}

// answerPermission answers a permission request with one of its options.
func (a *App) answerPermission(p *project, conversation *agentConversation, permission, option string) {
	if conversation == nil || conversation.answering != "" || !conversation.transcript.Live() {
		return
	}
	if a.refuseAgent(p, "agents_permission", nil) {
		return
	}
	a.performed("agents.respondPermission", surfaceButton)
	conversation.answering = permission
	kernel, session := a.agentKernel, conversation.transcript.Session
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		_, err := kernel.RespondPermission(ctx, session, permission, option)
		return func(a *App) {
			conversation.answering = ""
			if err != nil {
				a.operationFailed("agents_permission", err)
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.agents.permissionFailed", map[string]string{"reason": a.agentFailure(err)}))
			}
		}
	})
}

// closeConversation ends the conversation's session and takes it out of the window.
func (a *App) closeConversation(p *project, conversation *agentConversation) {
	if conversation == nil {
		return
	}
	a.performed("agents.close", surfaceButton)
	v := &a.agentsView
	if at := slices.Index(v.conversations, conversation); at >= 0 {
		v.conversations = slices.Delete(v.conversations, at, at+1)
		v.current = min(v.current, len(v.conversations)-1)
	}
	if !conversation.transcript.Live() {
		return
	}
	a.agentCall(p, "agents_close", func(ctx context.Context, kernel *agents.Client, session string) error {
		return kernel.Close(ctx, session)
	}, conversation)
}

// agentCall sends one request about the conversation's session and reports a failure.
func (a *App) agentCall(p *project, operation string, call func(context.Context, *agents.Client, string) error, conversation *agentConversation) {
	conversation.busy = true
	kernel, session := a.agentKernel, conversation.transcript.Session
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		err := call(ctx, kernel, session)
		return func(a *App) {
			conversation.busy = false
			if err != nil && !errors.Is(err, context.Canceled) {
				a.operationFailed(operation, err)
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.agents.requestFailed", map[string]string{"reason": a.agentFailure(err)}))
			}
		}
	})
}

// closeAgentSessions ends the sessions of the project's conversations when the project closes.
// The requests do not wait for the project, whose context ends with it.
func (a *App) closeAgentSessions(p *project) {
	v := &a.agentsView
	conversations := v.conversations
	*v = agentsState{catalog: v.catalog, rejected: v.rejected, plugins: v.plugins, configured: v.configured}
	kernel := a.agentKernel
	if kernel == nil {
		return
	}
	var sessions []string
	for _, conversation := range conversations {
		if conversation.transcript.Live() {
			sessions = append(sessions, conversation.transcript.Session)
		}
	}
	if len(sessions) == 0 {
		return
	}
	a.within(operation{}, func(a *App) {
		a.background(nil, agentCallTimeout, func(ctx context.Context) func(*App) {
			var failures []error
			for _, session := range sessions {
				failures = append(failures, kernel.Close(ctx, session))
			}
			if err := errors.Join(failures...); err != nil {
				a.backgroundFailedIn(ctx, "agents_close", err)
			}
			return nil
		})
	})
}

// openAgentTerminal runs agent's CLI in a terminal of the project, with the arguments its
// plugin declares for that form.
func (a *App) openAgentTerminal(p *project, agent agents.CatalogAgent) {
	a.runAgentTool(p, agent, "agents.terminal", "agents_terminal", agent.TerminalArguments)
}

// updateAgent asks the user to confirm, then runs agent's update command in a terminal.
func (a *App) updateAgent(p *project, agent agents.CatalogAgent) {
	if agent.Update == nil {
		return
	}
	lang := a.language()
	a.performed("agents.update", surfaceButton)
	a.notifyActions(
		i18n.SharedFormat(lang, "desktop.agents.updateTitle", map[string]string{"agent": agent.DisplayName}),
		i18n.Shared(lang, "desktop.agents.updateDetail"), ui.ToastInfo,
		i18n.Shared(lang, "desktop.agents.updateConfirm"), func(a *App) {
			a.runAgentTool(p, agent, "agents.update.confirm", "agents_update", agent.Update.Arguments)
		},
		i18n.Shared(lang, "desktop.agents.updateCancel"), func(*App) {},
	)
}

// runAgentTool resolves agent's tool and runs it with args in a new terminal of the project.
func (a *App) runAgentTool(p *project, agent agents.CatalogAgent, action, operation string, args []string) {
	if a.refuseAgent(p, operation, func() { a.runAgentTool(p, agent, action, operation, args) }) {
		return
	}
	if !agent.MayRun || (!agent.HasForm("terminal") && agent.Update == nil) {
		a.operationRejected(operation, "agent_unavailable")
		return
	}
	a.performed(action, surfaceButton)
	root := p.root
	args = append([]string{}, args...)
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		tool, err := a.resolveAgentTool(ctx, root, agent.PluginID, agent.Tool)
		return func(a *App) {
			if err != nil {
				a.operationFailed(operation, err)
				if agentToolMissing(err) {
					a.notifyAgentToolMissing(agent)
					return
				}
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.agents.toolFailed", map[string]string{"agent": agent.DisplayName, "reason": err.Error()}))
				return
			}
			t := a.newTerminalWith(p, terminalOptions{
				shell: tool.Path, args: args, env: environmentList(tool.Environment),
				dir: root, title: agent.DisplayName, activate: true,
			})
			if t == nil {
				return
			}
			a.openToolWindow(itemTerminal)
			a.focusTerminal(t.id)
		}
	})
}

// environmentList is environment as KEY=value entries, sorted by key.
func environmentList(environment map[string]string) []string {
	list := make([]string, 0, len(environment))
	for key, value := range environment {
		list = append(list, key+"="+value)
	}
	slices.Sort(list)
	return list
}

// agentFailure is the reason a notification gives for a failed agents request: what Core's
// refusal means, or Core's message.
func (a *App) agentFailure(err error) string {
	lang := a.language()
	var coreErr *core.Error
	if !errors.As(err, &coreErr) {
		if errors.Is(err, pluginservice.ErrAgentNotActivating) {
			return i18n.Shared(lang, "desktop.agents.reason.backendStopped")
		}
		return err.Error()
	}
	switch coreErr.Details {
	case "agents.remoteWorkspace":
		return i18n.Shared(lang, "desktop.agents.reason.remoteWorkspace")
	case "agents.untrustedWorkspace":
		return i18n.Shared(lang, "desktop.agents.reason.untrustedWorkspace")
	case "agents.runNotGranted":
		return i18n.Shared(lang, "desktop.agents.reason.runNotGranted")
	case "agents.tooManySessions":
		return i18n.Shared(lang, "desktop.agents.reason.tooManySessions")
	case "agents.toolNotFound":
		return i18n.Shared(lang, "desktop.agents.reason.toolNotFound")
	case "agents.backendUnavailable", "agents.launchFailed", "agents.launchTimeout":
		return i18n.Shared(lang, "desktop.agents.reason.backendUnavailable")
	case "agents.turnInProgress":
		return i18n.Shared(lang, "desktop.agents.reason.turnInProgress")
	case "agents.unknownSession":
		return i18n.Shared(lang, "desktop.agents.reason.sessionEnded")
	case "agents.invalidResume":
		return i18n.Shared(lang, "desktop.agents.reason.invalidResume")
	}
	return coreErr.Message
}

// readableAgents are the keys of the configured agents whose sessions the user lets Lithe read.
func (v *agentsState) readableAgents() []string {
	var keys []string
	for _, agent := range v.catalog {
		if agent.ReadsSessions && agent.MayReadSessions {
			keys = append(keys, agent.Key())
		}
	}
	return keys
}

// sessionReadingOffered reports whether any configured agent can read its sessions, with or
// without the user's consent.
func (v *agentsState) sessionReadingOffered() bool {
	return slices.ContainsFunc(v.catalog, func(agent agents.CatalogAgent) bool { return agent.ReadsSessions })
}

// resumeRecorded starts a conversation that resumes a recorded session of one of the agents.
func (a *App) resumeRecorded(p *project, pluginID, agentID, sessionID string) {
	for _, agent := range a.agentsView.catalog {
		if agent.PluginID == pluginID && agent.AgentID == agentID {
			a.startConversation(p, agent, sessionID)
			return
		}
	}
	a.operationRejected("agents_start", "agent_unavailable")
}
