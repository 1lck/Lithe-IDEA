package workbench

import (
	"slices"
	"strings"

	"github.com/vivaui/viva/ui"
)

// agentHistoryMetadataFile keeps Lithe's own annotations of the Agent's conversations: a
// title the user gave one and whether it is pinned. It is keyed by workspace root and then
// by session id. The Agent's records are never changed.
const agentHistoryMetadataFile = "agent-history-metadata.json"

// agentSessionMeta is one conversation's annotation. An empty one is not stored.
type agentSessionMeta struct {
	Title    string `json:"title,omitempty"`
	Favorite bool   `json:"favorite,omitempty"`
}

// agentHistoryMetaState is the loaded annotations of the open project and the rename in
// progress, if any.
type agentHistoryMetaState struct {
	loaded bool
	items  map[string]agentSessionMeta
	// renaming is the session whose row shows the title field, and field its text.
	renaming string
	field    ui.Field
}

// loadAgentSessionMeta reads the project's annotations once.
func (a *App) loadAgentSessionMeta(p *project) {
	s := &p.agent.history.meta
	if s.loaded {
		return
	}
	s.loaded = true
	s.items = map[string]agentSessionMeta{}
	all := map[string]map[string]agentSessionMeta{}
	if _, err := a.store.Load(agentHistoryMetadataFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_history_meta", err))
		return
	}
	for id, meta := range all[p.root] {
		s.items[id] = meta
	}
}

// updateAgentSessionMeta applies change to one conversation's annotation and stores the
// result. An annotation with nothing set is removed.
func (a *App) updateAgentSessionMeta(p *project, sessionID string, change func(*agentSessionMeta)) {
	a.loadAgentSessionMeta(p)
	s := &p.agent.history.meta
	meta := s.items[sessionID]
	change(&meta)
	if meta.Title == "" && !meta.Favorite {
		delete(s.items, sessionID)
	} else {
		s.items[sessionID] = meta
	}
	all := map[string]map[string]agentSessionMeta{}
	if _, err := a.store.Load(agentHistoryMetadataFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_history_meta", err))
		return
	}
	if len(s.items) == 0 {
		delete(all, p.root)
	} else {
		all[p.root] = s.items
	}
	if err := a.store.Save(agentHistoryMetadataFile, all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_history_meta", err))
	}
}

// agentSessionTitle is the title a conversation shows: the user's own title when there is
// one, otherwise the Agent's.
func (a *App) agentSessionTitle(p *project, session agentSessionSummary) string {
	a.loadAgentSessionMeta(p)
	if title := p.agent.history.meta.items[session.SessionID].Title; title != "" {
		return title
	}
	return session.Title
}

// agentHistoryOrdered lists the sessions with pinned ones first, each group in the Agent's
// own order.
func (a *App) agentHistoryOrdered(p *project) []agentSessionSummary {
	a.loadAgentSessionMeta(p)
	items := p.agent.history.meta.items
	list := slices.Clone(p.agent.history.sessions)
	slices.SortStableFunc(list, func(x, y agentSessionSummary) int {
		fx, fy := items[x.SessionID].Favorite, items[y.SessionID].Favorite
		switch {
		case fx == fy:
			return 0
		case fx:
			return -1
		}
		return 1
	})
	return list
}

// beginAgentRename shows the title field on a conversation's row, pre-filled with the title
// it shows now.
func (a *App) beginAgentRename(p *project, session agentSessionSummary) {
	h := &p.agent.history.meta
	h.renaming = session.SessionID
	h.field.SetText(a.agentSessionTitle(p, session))
}

// commitAgentRename stores the typed title. An empty title keeps the name as it was.
func (a *App) commitAgentRename(p *project) {
	h := &p.agent.history.meta
	id := h.renaming
	h.renaming = ""
	title := strings.TrimSpace(h.field.Text())
	if id == "" || title == "" {
		return
	}
	a.updateAgentSessionMeta(p, id, func(m *agentSessionMeta) { m.Title = title })
}

// cancelAgentRename drops the title field without storing anything.
func (a *App) cancelAgentRename(p *project) {
	p.agent.history.meta.renaming = ""
}

// toggleAgentFavorite pins or unpins a conversation.
func (a *App) toggleAgentFavorite(p *project, sessionID string) {
	a.updateAgentSessionMeta(p, sessionID, func(m *agentSessionMeta) { m.Favorite = !m.Favorite })
	a.performed("agent.history.pin", surfaceButton)
}

// agentRenameRow declares a conversation's row while it is being renamed: the title field
// with Save and Cancel.
func (a *App) agentRenameRow(c ui.C, p *project, session agentSessionSummary, busy bool) {
	m := a.text.Agent.HistoryMeta
	ui.Row(c.Key("rename")).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
		ui.TextField(c, &p.agent.history.meta.field, m.Rename, a.agentSessionTitle(p, session)).Grow(1)
		if ui.Button(c, m.Save).Outline().Disabled(busy).Clicked() {
			c.After(func() { a.commitAgentRename(p) })
		}
		if ui.Button(c, m.Cancel).Ghost().Clicked() {
			c.After(func() { a.cancelAgentRename(p) })
		}
	})
}

// agentCurrentTitle is the title of the open conversation: the user's own title when there
// is one, otherwise the title the Agent listed.
func (a *App) agentCurrentTitle(p *project) string {
	a.loadAgentSessionMeta(p)
	if title := p.agent.history.meta.items[p.agent.sessionID].Title; title != "" {
		return title
	}
	return p.agent.history.title(p.agent.sessionID)
}
