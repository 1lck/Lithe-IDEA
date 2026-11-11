package workbench

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// Slash commands are the Agent's own: the list comes from the session's
// available_commands_update and is cached per session. A chosen command is only
// filled into the composer; it is sent as an ordinary message, exactly as typed,
// and the Agent parses it. `$` lists the Agent's Skills (agent.skills list).
const agentSlashMenuLimit = 8

// agentSkillSource is the optional Core capability that discovers Skills. Fakes
// that do not implement it simply have no Skill list.
type agentSkillSource interface {
	ListAgentSkills(ctx context.Context, agentID, workspace string) (core.AgentSkillListing, error)
}

// ListAgentSkills discovers one Agent's Skills through Core.
func (k CoreAgentKernel) ListAgentSkills(ctx context.Context, agentID, workspace string) (core.AgentSkillListing, error) {
	return k.Client.ListAgentSkills(ctx, agentID, workspace)
}

// agentSlashState is the composer's completion state.
type agentSlashState struct {
	skills        []core.AgentSkill
	skillsFor     string
	skillsLoading bool
	skillsLoaded  bool
}

// agentSlashTrigger classifies the draft: '/' for commands and '$' for Skills,
// including the characters a Chinese input method types for them.
func agentSlashTrigger(value string) (trigger rune, query string, ok bool) {
	runes := []rune(value)
	if len(runes) == 0 {
		return 0, "", false
	}
	switch runes[0] {
	case '/', '、':
		trigger = '/'
	case '$', '¥', '￥':
		trigger = '$'
	default:
		return 0, "", false
	}
	query = string(runes[1:])
	if strings.ContainsAny(query, " \t\r\n") {
		return 0, "", false
	}
	return trigger, query, true
}

// agentSlashCandidate is one row of the completion list.
type agentSlashCandidate struct {
	Insert      string
	Name        string
	Description string
	Hint        string
	// File is the absolute path an @ mention attaches instead of inserting text.
	File string
}

// agentSlashCandidates lists what the draft's trigger offers, prefix matches first.
func (a *App) agentSlashCandidates(p *project) []agentSlashCandidate {
	if p == nil || p.agent.conn == nil || p.agent.sessionID == "" {
		return nil
	}
	if _, ok := agentMentionQuery(p.agent.editor.CommittedString()); ok {
		return a.agentMentionCandidates(p)
	}
	trigger, query, ok := agentSlashTrigger(p.agent.editor.CommittedString())
	if !ok {
		return nil
	}
	query = strings.ToLower(query)
	var prefix, contains []agentSlashCandidate
	add := func(c agentSlashCandidate) {
		name := strings.ToLower(c.Name)
		switch {
		case strings.HasPrefix(name, query):
			prefix = append(prefix, c)
		case strings.Contains(name, query):
			contains = append(contains, c)
		}
	}
	if trigger == '/' {
		for _, command := range p.agent.activity.commandsFor(p.agent.sessionID) {
			add(agentSlashCandidate{Insert: "/" + command.Name + " ", Name: command.Name, Description: command.Description, Hint: command.Hint})
		}
	} else {
		for _, skill := range p.agent.slash.skills {
			if skill.Enabled != nil && !*skill.Enabled {
				continue
			}
			add(agentSlashCandidate{Insert: "$" + skill.Name + " ", Name: skill.Name, Description: skill.Description})
		}
	}
	return append(prefix, contains...)
}

// ensureAgentSkills loads the Skill list once per connection, off the window thread.
func (a *App) ensureAgentSkills(p *project) {
	s := &p.agent.slash
	source, ok := a.agentKernel.(agentSkillSource)
	agent, found := p.selectedAgent()
	if !ok || !found || s.skillsLoading || (s.skillsLoaded && s.skillsFor == agent.ID) {
		return
	}
	s.skillsLoading = true
	agentID, root := agent.ID, p.root
	a.background(p, agentLoadTimeout, func(ctx context.Context) func(*App) {
		listing, err := source.ListAgentSkills(ctx, agentID, root)
		return func(a *App) {
			if a.project != p {
				return
			}
			s := &p.agent.slash
			s.skillsLoading = false
			s.skillsLoaded = true
			s.skillsFor = agentID
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_skills", err))
				return
			}
			s.skills = listing.Skills
		}
	})
}

// chooseAgentSlash fills the composer with the chosen command. It does not send.
func (a *App) chooseAgentSlash(p *project, insert string) {
	if p == nil {
		return
	}
	a.setAgentDraft(p, insert)
	a.performed("agent.slash.choose", surfaceMenu)
}

// setAgentDraft replaces the composer's text with draft and puts the caret at its end.
func (a *App) setAgentDraft(p *project, draft string) {
	editor := text.NewEditor(draft)
	editor.MoveTo(len(draft), false)
	p.agent.editor = editor
	p.agent.input = ui.Field{}
	p.agent.input.Bind(editor)
}
