package workbench

// Archived conversations are Agent-owned: Core lists them read-only with
// listArchivedSessions and restores one with unarchiveSession after the user
// confirms, because that changes the Agent's own state. Browsing never does.

// agentArchiveState is the archived group of one connection's history.
type agentArchiveState struct {
	canList    bool
	open       bool
	loading    bool
	loaded     bool
	failed     bool
	incomplete bool
	sessions   []agentSessionSummary
	token      string
	// confirming is the conversation the user is asked to restore; unarchiving is the
	// one whose request is in flight, matched by its token.
	confirming      string
	unarchiveToken  string
	unarchiveFailed bool
}

// toggleAgentArchived opens or closes the archived group, listing it on first open.
func (a *App) toggleAgentArchived(p *project) {
	if p == nil || p.agent.conn == nil || !p.agent.history.archive.canList {
		return
	}
	s := &p.agent.history.archive
	s.open = !s.open
	if s.open && !s.loaded {
		a.listAgentArchived(p)
	}
}

// listAgentArchived sends one read-only listing request.
func (a *App) listAgentArchived(p *project) {
	s := &p.agent.history.archive
	if p == nil || p.agent.conn == nil || !s.canList || s.loading {
		return
	}
	s.loading = true
	s.failed = false
	s.token = a.agentCommandToken(p, "archived")
	if err := a.sendAgentCommand(p, map[string]any{"kind": "listArchivedSessions", "token": s.token}); err != nil {
		s.loading, s.failed, s.token = false, true, ""
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_archived_list", err))
	}
}

// applyAgentArchivedSessions accepts the answer to the current request only.
func (a *App) applyAgentArchivedSessions(p *project, token string, sessions []agentSessionSummary, complete bool) {
	s := &p.agent.history.archive
	if token == "" || token != s.token {
		return
	}
	s.token = ""
	s.loading = false
	s.loaded = true
	s.failed = false
	s.incomplete = !complete || len(sessions) > agentHistoryLimit
	s.sessions = mergeAgentSessions(nil, sessions, agentHistoryLimit)
}

// askAgentUnarchive shows the confirmation; nothing is sent yet.
func (a *App) askAgentUnarchive(p *project, sessionID string) {
	if p == nil {
		return
	}
	s := &p.agent.history.archive
	if s.unarchiveToken != "" {
		return
	}
	s.confirming = sessionID
	s.unarchiveFailed = false
}

// confirmAgentUnarchive sends the explicit restore request.
func (a *App) confirmAgentUnarchive(p *project) {
	s := &p.agent.history.archive
	if p == nil || p.agent.conn == nil || s.confirming == "" || s.unarchiveToken != "" {
		return
	}
	token := a.agentCommandToken(p, "unarchive")
	if err := a.sendAgentCommand(p, map[string]any{"kind": "unarchiveSession", "token": token, "sessionId": s.confirming}); err != nil {
		s.unarchiveFailed = true
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_unarchive", err))
		return
	}
	s.unarchiveToken = token
	a.performed("agent.history.unarchive", surfaceButton)
}

// applyAgentSessionUnarchived reconciles both lists after a confirmed restore.
func (a *App) applyAgentSessionUnarchived(p *project, token string) {
	s := &p.agent.history.archive
	if token == "" || token != s.unarchiveToken {
		return
	}
	s.unarchiveToken = ""
	s.confirming = ""
	s.loaded = false
	a.listAgentArchived(p)
	a.refreshAgentHistory(p, false)
}
