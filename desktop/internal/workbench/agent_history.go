package workbench

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Agent session history is owned by the Agent: Core asks the adapter for the
// workspace's conversations and replays a selected one over ACP. Go keeps only a
// bounded, project-scoped view of that answer; it never reads or writes the
// adapter's own transcript files.
const (
	// agentHistoryLimit bounds the rows the panel keeps. Core already bounds its
	// page walk; this is the UI's own memory budget for a very large history.
	agentHistoryLimit = 200
	// agentHistoryFreshness reuses a successful listing while the user moves
	// between the conversation and the history panel. Explicit refresh ignores it.
	agentHistoryFreshness = 30 * time.Second
)

// agentSessionSummary is one Agent-owned conversation as Core lists it. Title and
// UpdatedAt may be absent upstream and are never invented locally.
type agentSessionSummary struct {
	SessionID string `json:"sessionId"`
	Title     string `json:"title"`
	UpdatedAt string `json:"updatedAt"`
}

// agentHistoryState is one project connection's history view. The connection and
// every list it returns belong to the project that started it, so closing or
// replacing the project drops this state with the rest of agentState.
type agentHistoryState struct {
	canList bool
	canLoad bool

	open     bool
	sessions []agentSessionSummary
	limited  bool
	loading  bool
	loaded   bool
	loadedAt time.Time
	listErr  string
	// listToken correlates listSessions requests. A late answer for any other
	// token is discarded, including one from a previous project.
	listToken string

	// loadToken correlates loadSession; restoreSession is the id being loaded
	// and also makes the transcript accept Core's replayed updates.
	loadToken      string
	restoreSession string
	// replaySession accepts a replay that Core keeps sending after sessionLoaded.
	// Sending a prompt or creating a new conversation ends it.
	replaySession string

	// replayMessages and replayBytes hold a load's replay until Core confirms it.
	// The live transcript is replaced only on sessionLoaded and the buffer dropped
	// on failure, so a rejected load cannot lose the open conversation.
	replayMessages []agentMessage
	replayBytes    int
}

func newAgentHistoryState() agentHistoryState {
	return agentHistoryState{}
}

// restoring reports that a selected conversation is being replayed.
func (h *agentHistoryState) restoring() bool { return h.restoreSession != "" }

// title returns the listed title of one conversation, or an empty string.
func (h *agentHistoryState) title(sessionID string) string {
	for _, session := range h.sessions {
		if session.SessionID == sessionID {
			return session.Title
		}
	}
	return ""
}

// agentNow returns the window's clock, which tests replace to keep freshness
// checks deterministic.
func (a *App) agentNow() time.Time {
	if a.now != nil {
		return a.now()
	}
	return time.Now()
}

// agentCommandToken allocates the next correlation token of this connection. The
// first new-session token keeps the historical "desktop-N" shape; other commands
// add their operation so a wrong answer cannot be mistaken for a session.
func (a *App) agentCommandToken(p *project, operation string) string {
	p.agent.nextToken++
	if operation == "" {
		return fmt.Sprintf("desktop-%d", p.agent.nextToken)
	}
	return fmt.Sprintf("desktop-%s-%d", operation, p.agent.nextToken)
}

func (a *App) sendAgentCommand(p *project, command map[string]any) error {
	raw, err := json.Marshal(command)
	if err != nil {
		return err
	}
	if p == nil || p.agent.conn == nil {
		return core.ErrAgentClosed
	}
	return p.agent.conn.session.Send(raw)
}

// toggleAgentHistory opens or closes the conversation list. Opening reads the
// Agent-owned list at most once per freshness window; it never writes history.
func (a *App) toggleAgentHistory(p *project) {
	if p == nil || p.agent.conn == nil {
		return
	}
	h := &p.agent.history
	h.open = !h.open
	if h.open {
		a.refreshAgentHistory(p, true)
	}
	a.performed("agent.history", surfaceButton)
}

func (a *App) closeAgentHistory(p *project) {
	if p == nil {
		return
	}
	p.agent.history.open = false
}

// refreshAgentHistory sends one read-only listSessions command. onlyIfStale reuses
// a recent successful answer; an explicit refresh always asks the Agent.
func (a *App) refreshAgentHistory(p *project, onlyIfStale bool) {
	if p == nil || p.agent.conn == nil {
		return
	}
	h := &p.agent.history
	if !h.canList || h.loading || h.loadToken != "" {
		return
	}
	if onlyIfStale && h.loaded && a.agentNow().Sub(h.loadedAt) < agentHistoryFreshness {
		return
	}
	h.loading = true
	h.listErr = ""
	h.listToken = a.agentCommandToken(p, "history")
	if err := a.sendAgentCommand(p, map[string]any{"kind": "listSessions", "token": h.listToken}); err != nil {
		h.loading = false
		h.listToken = ""
		h.listErr = a.text.Agent.HistoryFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_history_list", err))
	}
}

// applyAgentSessionsPage shows rows Core publishes before its page walk ends.
func (a *App) applyAgentSessionsPage(p *project, token string, sessions []agentSessionSummary) {
	h := &p.agent.history
	if token == "" || token != h.listToken {
		return
	}
	h.sessions = mergeAgentSessions(h.sessions, sessions, agentHistoryLimit)
	h.limited = h.limited || len(sessions) > agentHistoryLimit
}

// applyAgentSessions replaces the list with Core's final aggregate snapshot.
func (a *App) applyAgentSessions(p *project, token string, sessions []agentSessionSummary) {
	h := &p.agent.history
	if token == "" || token != h.listToken {
		return
	}
	h.listToken = ""
	h.loading = false
	h.loadedAt = a.agentNow()
	h.loaded = true
	h.sessions = mergeAgentSessions(nil, sessions, agentHistoryLimit)
	h.limited = len(sessions) > agentHistoryLimit
	h.listErr = ""
}

// mergeAgentSessions deduplicates by Agent-owned id, preserves upstream order,
// and bounds the retained rows.
func mergeAgentSessions(existing, incoming []agentSessionSummary, limit int) []agentSessionSummary {
	capacity := len(existing) + len(incoming)
	if limit > 0 && capacity > limit {
		capacity = limit
	}
	merged := make([]agentSessionSummary, 0, capacity)
	seen := make(map[string]struct{}, capacity)
	for _, list := range [][]agentSessionSummary{existing, incoming} {
		for _, session := range list {
			if session.SessionID == "" {
				continue
			}
			if _, ok := seen[session.SessionID]; ok {
				continue
			}
			seen[session.SessionID] = struct{}{}
			merged = append(merged, session)
			if limit > 0 && len(merged) == limit {
				return merged
			}
		}
	}
	return merged
}

// openAgentHistorySession asks Core to replay one Agent-owned conversation. The
// current session stays selected until Core confirms the load, so a rejected
// request leaves the connection usable.
func (a *App) openAgentHistorySession(p *project, sessionID string) {
	if p == nil || p.agent.conn == nil || sessionID == "" {
		return
	}
	h := &p.agent.history
	if !h.canLoad || h.restoring() || h.loading || p.agent.connecting || p.agent.pending != "" ||
		p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling {
		return
	}
	token := a.agentCommandToken(p, "load")
	if err := a.sendAgentCommand(p, map[string]any{"kind": "loadSession", "token": token, "sessionId": sessionID}); err != nil {
		h.listErr = a.text.Agent.HistoryRestoreFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_history_load", err))
		return
	}
	h.loadToken = token
	h.restoreSession = sessionID
	h.replaySession = ""
	h.replayMessages = nil
	h.replayBytes = 0
	h.open = false
	h.listErr = ""
	p.agent.err = ""
	p.agent.phase = agentPhaseStarting
	p.agent.connecting = false
	a.performed("agent.history.open", surfaceButton)
}

// applyAgentSessionLoaded commits a replayed conversation only for the request
// that is still current. Replay updates that arrived first are already in the
// transcript; Core may keep sending a few after this event.
func (a *App) applyAgentSessionLoaded(p *project, token, sessionID string, configOptions json.RawMessage) {
	h := &p.agent.history
	if token == "" || token != h.loadToken || sessionID == "" {
		return
	}
	h.loadToken = ""
	h.restoreSession = ""
	h.replaySession = sessionID
	p.agent.sessionID = sessionID
	p.agent.pending = ""
	p.agent.connecting = false
	p.agent.phase = agentPhaseReady
	p.agent.err = ""
	p.agent.permission = nil
	p.agent.messages = h.replayMessages
	p.agent.bytes = h.replayBytes
	h.replayMessages = nil
	h.replayBytes = 0
	if n := len(p.agent.messages); n > 0 {
		p.agent.messages[n-1].Streaming = false
	}
	a.applyAgentConfigOptions(p, configOptions)
}

// agentSessionCreated commits a new conversation after Core confirms it. The
// previous transcript goes with the previous session; nothing from it is kept.
func (a *App) agentSessionCreated(p *project, sessionID string, configOptions json.RawMessage) {
	p.agent.pending = ""
	p.agent.connecting = false
	p.agent.sessionID = sessionID
	p.agent.history.replaySession = ""
	p.agent.history.restoreSession = ""
	p.agent.history.loadToken = ""
	p.agent.history.replayMessages = nil
	p.agent.history.replayBytes = 0
	p.agent.messages = nil
	p.agent.bytes = 0
	p.agent.permission = nil
	p.agent.phase = agentPhaseReady
	p.agent.err = ""
	a.applyAgentConfigOptions(p, configOptions)
}

// newAgentConversation starts a fresh Agent conversation in the open connection.
// The current session stays visible until Core confirms the new one.
func (a *App) newAgentConversation(p *project) {
	if p == nil || !a.agentCanStartConversation(p) {
		return
	}
	p.agent.connecting = true
	p.agent.phase = agentPhaseStarting
	p.agent.err = ""
	p.agent.permission = nil
	p.agent.history.open = false
	p.agent.history.replaySession = ""
	p.agent.history.restoreSession = ""
	a.newAgentSession(p, p.agent.conn)
	a.performed("agent.newSession", surfaceButton)
}

func (a *App) agentCanStartConversation(p *project) bool {
	if p == nil || p.agent.conn == nil || p.agent.connecting || p.agent.pending != "" ||
		p.agent.history.restoring() || p.agent.auth != agentAuthNone {
		return false
	}
	return p.agent.phase != agentPhaseBusy && p.agent.phase != agentPhaseCancelling &&
		p.agent.phase != agentPhaseStarting && p.agent.phase != agentPhaseLoading
}

// agentRequestFailed routes a failed command to the surface that issued it, or
// leaves a generic failure where the conversation already shows errors.
func (a *App) agentRequestFailed(p *project, token, sessionID, message string) {
	if p == nil {
		return
	}
	switch {
	case token != "" && token == p.agent.history.listToken:
		p.agent.history.listToken = ""
		p.agent.history.loading = false
		p.agent.history.listErr = agentFailureText(message, a.text.Agent.HistoryFailed)
		a.emit(operationFailedLevel, operationFailedEvent, map[string]any{"operation": "agent_history_list"})
		return
	case token != "" && token == p.agent.history.loadToken:
		h := &p.agent.history
		h.loadToken = ""
		h.restoreSession = ""
		h.replaySession = ""
		h.replayMessages = nil
		h.replayBytes = 0
		h.open = false
		h.listErr = agentFailureText(message, a.text.Agent.HistoryRestoreFailed)
		p.agent.connecting = false
		if p.agent.sessionID != "" {
			p.agent.phase = agentPhaseReady
			// Keep the open conversation visible with the failure on its error
			// banner; reopening history still shows the cached list and error.
			p.agent.err = h.listErr
		} else {
			p.agent.phase = agentPhaseFailed
		}
		a.emit(operationFailedLevel, operationFailedEvent, map[string]any{"operation": "agent_history_load"})
		return
	case token != "" && token == p.agent.config.pendingToken:
		p.agent.config.pendingToken = ""
		p.agent.config.err = agentFailureText(message, a.text.Agent.ConfigFailed)
		a.emit(operationFailedLevel, operationFailedEvent, map[string]any{"operation": "agent_config"})
		return
	case token != "" && token == p.agent.pending:
		p.agent.pending = ""
	}
	if !agentEventForCurrentSession(p, sessionID) {
		return
	}
	p.agent.connecting = false
	p.agent.phase = agentPhaseFailed
	p.agent.err = agentFailureText(message, a.text.Agent.RequestFailed)
}

// agentStopped records Core's terminal connection event. An absent message means
// the stop was requested; a present one is upstream diagnostics and is kept.
func (a *App) agentStopped(p *project, conn *agentConnection, message string) {
	p.agent.connecting = false
	p.agent.pending = ""
	p.agent.auth = agentAuthNone
	p.agent.history.loading = false
	p.agent.history.listToken = ""
	p.agent.history.loadToken = ""
	p.agent.history.restoreSession = ""
	p.agent.history.replaySession = ""
	p.agent.config.pendingToken = ""
	p.agent.err = agentFailureText(message, a.text.Agent.ConnectionClosed)
	a.dropAgentConnection(p, conn)
	p.agent.phase = agentPhaseFailed
}

func agentFailureText(message, fallback string) string {
	if strings.TrimSpace(message) != "" {
		return message
	}
	return fallback
}

// agentEventForCurrentSession rejects late turn events that belong to another
// session, including one from before a history load.
func agentEventForCurrentSession(p *project, sessionID string) bool {
	if p == nil || sessionID == "" {
		return true
	}
	// While a conversation is being restored, only its own events are current;
	// late events of the session it will replace must not change the panel.
	if restoring := p.agent.history.restoreSession; restoring != "" {
		return sessionID == restoring
	}
	if p.agent.sessionID != "" && sessionID != p.agent.sessionID {
		return false
	}
	return true
}
