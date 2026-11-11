package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// Composer drafts belong to a session. The live composer (agentState.editor, input, files) is
// the open session's draft; drafts holds the drafts of the other sessions of the connection,
// so switching sessions keeps each text and attachments apart. A session without a draft starts
// empty, and an empty draft is not kept.

// agentDraft is one session's composer text and attached files while another session is open.
type agentDraft struct {
	editor *text.Editor
	files  []agentFileRef
}

// agentDraftMaximumSessions bounds how many sessions keep a draft at once; the oldest entries
// are not tracked, so the map cannot grow with the history.
const agentDraftMaximumSessions = 32

// stashDraft keeps the open composer for session id and clears nothing else. An empty draft is
// dropped, and a session without an id keeps no draft.
func (s *agentState) stashDraft(id string) {
	if id == "" {
		return
	}
	if strings.TrimSpace(s.editor.CommittedString()) == "" && len(s.files) == 0 {
		delete(s.drafts, id)
		return
	}
	if s.drafts == nil {
		s.drafts = map[string]agentDraft{}
	}
	if _, known := s.drafts[id]; !known && len(s.drafts) >= agentDraftMaximumSessions {
		return
	}
	s.drafts[id] = agentDraft{editor: s.editor, files: s.files}
}

// loadDraft makes session id's draft the open composer. A session without one gets an empty
// composer.
func (s *agentState) loadDraft(id string) {
	draft, ok := s.drafts[id]
	delete(s.drafts, id)
	if !ok || draft.editor == nil {
		s.resetComposer()
		s.files = nil
		return
	}
	s.editor = draft.editor
	s.input = ui.Field{}
	s.input.Bind(s.editor)
	s.files = draft.files
}

// agentFileTarget is one session a file can be added to from a menu.
type agentFileTarget struct {
	ID, Title string
	Current   bool
}

// agentFileTargets lists the open session first, then the other sessions the history has
// listed. Without a history listing only the open session is offered.
func (a *App) agentFileTargets(p *project) []agentFileTarget {
	targets := []agentFileTarget{{ID: p.agent.sessionID, Current: true}}
	seen := map[string]bool{p.agent.sessionID: true}
	for _, session := range p.agent.history.sessions {
		if seen[session.SessionID] || session.SessionID == "" {
			continue
		}
		seen[session.SessionID] = true
		targets = append(targets, agentFileTarget{ID: session.SessionID, Title: a.agentSessionTitle(p, session)})
	}
	return targets
}

// addAgentFilesTo adds paths to the draft of session id: the open draft when id is the open
// session, otherwise that session's kept draft. It never sends.
func (a *App) addAgentFilesTo(p *project, id string, paths []string) int {
	if p == nil {
		return 0
	}
	if id == p.agent.sessionID {
		return a.addAgentFiles(p, paths)
	}
	draft := p.agent.drafts[id]
	files, added := addFileRefs(draft.files, paths)
	if added == 0 {
		return 0
	}
	if draft.editor == nil {
		draft.editor = text.NewEditor("")
	}
	draft.files = files
	if p.agent.drafts == nil {
		p.agent.drafts = map[string]agentDraft{}
	}
	if _, known := p.agent.drafts[id]; !known && len(p.agent.drafts) >= agentDraftMaximumSessions {
		return 0
	}
	p.agent.drafts[id] = draft
	a.performed("agent.files.add", surfaceMenu)
	return added
}

// agentFileMenuItems declares the "add to Agent" entries of a context menu for paths. With one
// session it is a single entry; with more, one entry per session, the open one first.
func (a *App) agentFileMenuItems(c ui.C, menu *ui.MenuItems, p *project, paths []string) {
	t := a.text.Agent.Activity
	targets := a.agentFileTargets(p)
	if len(targets) == 1 {
		if menu.Item(t.AddToAgent).Clicked() {
			c.After(func() { a.addAgentFiles(p, paths) })
		}
		return
	}
	for _, target := range targets {
		label := t.AddToAgent
		if !target.Current {
			label = i18n.SharedFormat(a.language(), "desktop.agent.files.addToSession", map[string]string{"title": target.Title})
		}
		if menu.Item(label).Clicked() {
			id := target.ID
			c.After(func() { a.addAgentFilesTo(p, id, paths) })
		}
	}
}

// addFileRefs appends paths to files under the same rules as addAgentFiles: relative paths,
// duplicates and anything beyond agentFileLimit are ignored.
func addFileRefs(files []agentFileRef, paths []string) ([]agentFileRef, int) {
	added := 0
	for _, path := range paths {
		ref, ok := agentFileRefFor(path)
		if !ok || len(files) >= agentFileLimit {
			continue
		}
		duplicate := false
		for _, file := range files {
			if file.Path == ref.Path {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		files = append(files, ref)
		added++
	}
	return files, added
}
