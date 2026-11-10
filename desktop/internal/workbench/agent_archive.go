package workbench

import (
	"sort"
	"strings"
)

// Archived conversations are Agent-owned: Core lists them read-only with
// listArchivedSessions and restores one with unarchiveSession after the user
// confirms, because that changes the Agent's own state. Browsing never does.

// agentArchiveHiddenFile keeps the archived conversations the user removed from
// this client's list, per project. Hiding is local presentation only: the Agent's
// own records are untouched, and Restore to List just forgets the id here.
const agentArchiveHiddenFile = "agent-archive-hidden.json"

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
	// query and provider filter the listed rows locally. provider is "" for every
	// provider, "?" for rows without one, and an exact upstream identity otherwise.
	query      string
	provider   string
	showHidden bool
	// hidden are the ids the user removed from this client's list, loaded from the
	// store when the group first opens.
	hidden map[string]bool
}

// agentArchiveProviders returns the provider filter options of the listed conversations in
// a deterministic order: every provider, then the sorted identities, then unknown.
func agentArchiveProviders(sessions []agentSessionSummary) []string {
	seen := map[string]bool{}
	var known []string
	unknown := false
	for _, session := range sessions {
		if session.ModelProvider == "" {
			unknown = true
			continue
		}
		if !seen[session.ModelProvider] {
			seen[session.ModelProvider] = true
			known = append(known, session.ModelProvider)
		}
	}
	sort.Strings(known)
	options := append([]string{""}, known...)
	if unknown {
		options = append(options, "?")
	}
	return options
}

// foldAgentQuery normalizes the search text and the fields the archive search matches.
func foldAgentQuery(text string) string { return strings.ToLower(strings.TrimSpace(text)) }

// agentArchiveRows are the listed conversations the group shows: removed ones only while
// Show Removed is on, and otherwise the ones that match the search and provider filter.
func agentArchiveRows(s *agentArchiveState) []agentSessionSummary {
	query := foldAgentQuery(s.query)
	rows := make([]agentSessionSummary, 0, len(s.sessions))
	for _, session := range s.sessions {
		if s.hidden[session.SessionID] != s.showHidden {
			continue
		}
		switch s.provider {
		case "":
		case "?":
			if session.ModelProvider != "" {
				continue
			}
		default:
			if session.ModelProvider != s.provider {
				continue
			}
		}
		if query != "" {
			title := foldAgentQuery(session.Title)
			provider := foldAgentQuery(session.ModelProvider)
			if !strings.Contains(title, query) && !strings.Contains(foldAgentQuery(session.SessionID), query) &&
				!strings.Contains(provider, query) {
				continue
			}
		}
		rows = append(rows, session)
	}
	return rows
}

// loadAgentArchiveHidden reads the removed ids of the open project once.
func (a *App) loadAgentArchiveHidden(p *project) {
	s := &p.agent.history.archive
	if s.hidden != nil {
		return
	}
	s.hidden = map[string]bool{}
	all := map[string][]string{}
	if _, err := a.store.Load(agentArchiveHiddenFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_archive_hidden", err))
		return
	}
	for _, id := range all[p.root] {
		s.hidden[id] = true
	}
}

// setAgentArchiveHidden removes one archived conversation from the local list or puts it
// back. The Agent's records and its archived state are never changed.
func (a *App) setAgentArchiveHidden(p *project, sessionID string, hidden bool) {
	s := &p.agent.history.archive
	a.loadAgentArchiveHidden(p)
	if hidden {
		s.hidden[sessionID] = true
	} else {
		delete(s.hidden, sessionID)
	}
	all := map[string][]string{}
	if _, err := a.store.Load(agentArchiveHiddenFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_archive_hidden", err))
		return
	}
	if len(s.hidden) == 0 {
		delete(all, p.root)
	} else {
		ids := make([]string, 0, len(s.hidden))
		for id := range s.hidden {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		all[p.root] = ids
	}
	if err := a.store.Save(agentArchiveHiddenFile, all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_archive_hidden", err))
	}
	if hidden {
		a.performed("agent.archive.hide", surfaceButton)
	} else {
		a.performed("agent.archive.restore", surfaceButton)
	}
}

// toggleAgentArchived opens or closes the archived group, listing it on first open.
func (a *App) toggleAgentArchived(p *project) {
	if p == nil || p.agent.conn == nil || !p.agent.history.archive.canList {
		return
	}
	s := &p.agent.history.archive
	s.open = !s.open
	if s.open {
		a.loadAgentArchiveHidden(p)
		if !s.loaded {
			a.listAgentArchived(p)
		}
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
	sessionID := s.confirming
	s.unarchiveToken = ""
	s.confirming = ""
	s.loaded = false
	// The conversation is no longer archived, so it cannot stay removed from the archive
	// list; forgetting the id keeps the next listing consistent.
	if sessionID != "" {
		a.setAgentArchiveHidden(p, sessionID, false)
	}
	a.listAgentArchived(p)
	a.refreshAgentHistory(p, false)
}
