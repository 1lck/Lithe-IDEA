package workbench

import (
	"context"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// A conversation is named by the title its agent gives the session, which Claude Code and Codex
// write into their session records once a turn has run: after each turn, and when a resumed
// session reports the agent's ID, the window reads the agent's changed session files and asks
// Core's record for the session's title. Until there is one (the agent names none, its sessions
// may not be read, or the record is not written yet) the first line of the first prompt names
// the conversation. Titles are the user's content: they live in memory and are never logged.

// agentTitleLength bounds the first line that names a conversation, in runes.
const agentTitleLength = 80

// agentFirstLine is the first line of a prompt with text, trimmed and cut to agentTitleLength.
func agentFirstLine(text string) string {
	for line := range strings.SplitSeq(text, "\n") {
		if line = strings.Join(strings.Fields(line), " "); line != "" {
			return clipRunes(line, agentTitleLength)
		}
	}
	return ""
}

// clipRunes cuts text to at most n runes, ending a cut one with an ellipsis.
func clipRunes(text string, n int) string {
	if utf8.RuneCountInString(text) <= n {
		return text
	}
	count := 0
	for at := range text {
		if count == n-1 {
			return text[:at] + "…"
		}
		count++
	}
	return text
}

// agentConversationTitle is what names a conversation: the agent's title of the session, the
// first line of its first prompt, or the agent's name before anything was asked.
func agentConversationTitle(conversation *agentConversation) string {
	switch {
	case conversation.title != "":
		return conversation.title
	case conversation.firstLine != "":
		return conversation.firstLine
	}
	return conversation.agent.DisplayName
}

// readAgentTitles reads the title of each conversation that asked for one, when the user lets
// Lithe read its agent's sessions. The reads are not the user's actions, so they carry none.
func (a *App) readAgentTitles(p *project) {
	v := &a.agentsView
	if a.agentKernel == nil || p == nil {
		return
	}
	readable := v.readableAgents()
	for _, conversation := range v.conversations {
		t := conversation.transcript
		if !conversation.titleWanted || conversation.titleReading || t.AgentSessionID == "" {
			continue
		}
		conversation.titleWanted = false
		if !slices.Contains(readable, conversation.agent.Key()) {
			continue
		}
		conversation.titleReading = true
		a.readAgentTitle(p, conversation)
	}
}

// readAgentTitle reads the agent's changed session files and the conversation's title from the
// record, away from the window thread.
func (a *App) readAgentTitle(p *project, conversation *agentConversation) {
	kernel, service := a.agentKernel, a.plugins
	agent, sessionID := conversation.agent, conversation.transcript.AgentSessionID
	a.within(operation{}, func(a *App) {
		a.background(p, agentSyncTimeout, func(ctx context.Context) func(*App) {
			title, err := readRecordedTitle(ctx, kernel, service, agent, sessionID)
			return func(a *App) {
				conversation.titleReading = false
				if err != nil {
					a.backgroundFailed("agents_title", err)
					return
				}
				if title != "" {
					conversation.title = title
				}
				if conversation.titleWanted {
					a.readAgentTitles(p)
				}
			}
		})
	})
}

// readRecordedTitle is the title the agent's record gives a session, the first line of it, empty
// when it gives none.
func readRecordedTitle(ctx context.Context, kernel *agents.Client, service *pluginservice.Service, agent agents.CatalogAgent, sessionID string) (string, error) {
	if service != nil {
		if err := service.EnsureAgentBackend(ctx, agent.PluginID, agent.AgentID); err != nil {
			return "", err
		}
	}
	if _, err := kernel.Sync(ctx, agent.PluginID, agent.AgentID); err != nil {
		return "", err
	}
	sessions, err := kernel.List(ctx, agents.ListQuery{Agents: []string{agent.Key()}, SessionID: sessionID, Titles: true, Limit: 1})
	if err != nil || len(sessions) == 0 {
		return "", err
	}
	return agentFirstLine(sessions[0].Title), nil
}
