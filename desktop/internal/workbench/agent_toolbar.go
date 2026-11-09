package workbench

import (
	"time"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The conversation toolbar, history panel and session-setting bar. They are
// separate from the streamed transcript so a history or toolbar change cannot
// disturb the transcript's measured virtual window.
var (
	agentHistoryToggle  = tree.ID(shellPage, "agent-history-toggle")
	agentHistoryBack    = tree.ID(shellPage, "agent-history-back")
	agentHistoryRefresh = tree.ID(shellPage, "agent-history-refresh")
	agentHistoryScroll  = tree.ID(shellPage, "agent-history")
	agentHistoryRow     = tree.Sub(shellPage, tree.Name("agent-history-row"))
	agentNewChat        = tree.ID(shellPage, "agent-new-chat")
	agentConfigBar      = tree.Sub(shellPage, tree.Name("agent-config"))
)

// drawAgentConversationHeader draws the title and the conversation-level actions.
func (a *App) drawAgentConversationHeader(f *ui.Frame, p *project) {
	t := a.text.Agent
	f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(8).PadSides(0, 8, 0, 12).Children(func() {
		f.Text(a.agentConversationTitle(p)).Weight(gfx.WeightMedium).Ellipsis().Grow(1)
		historyDisabled := p.agent.phase == agentPhaseStarting || p.agent.phase == agentPhaseLoading
		if f.Button(agentHistoryToggle, t.History).Ghost().Disabled(historyDisabled).Clicked() {
			a.toggleAgentHistory(p)
		}
		if f.Button(agentNewChat, t.NewChat).Ghost().Disabled(!a.agentCanStartConversation(p)).Clicked() {
			a.newAgentConversation(p)
		}
		if f.Button(agentChange, t.Change).Ghost().Clicked() {
			a.disconnectAgent(p)
		}
	})
}

// agentConversationTitle names the Agent and provider, then the listed title of
// the open conversation when the Agent supplied one.
func (a *App) agentConversationTitle(p *project) string {
	agent, _ := p.selectedAgent()
	provider, _ := p.selectedProvider()
	title := agent.Name
	if provider.Name != "" {
		if title != "" {
			title += " · "
		}
		title += provider.Name
	}
	if session := p.agent.history.title(p.agent.sessionID); session != "" {
		title += " · " + session
	}
	return title
}

// drawAgentHistoryPanel replaces the transcript while the user browses the
// Agent-owned conversation list. Selecting a row asks Core to replay it.
func (a *App) drawAgentHistoryPanel(f *ui.Frame, p *project) {
	t := a.text.Agent
	h := &p.agent.history
	f.Column().Fill().Children(func() {
		f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(8).PadSides(0, 8, 0, 12).Children(func() {
			f.Text(t.HistoryTitle).Weight(gfx.WeightMedium).Ellipsis().Grow(1)
			if f.Button(agentHistoryRefresh, t.Refresh).Ghost().Disabled(!h.canList || h.loading).Clicked() {
				a.refreshAgentHistory(p, false)
			}
			if f.Button(agentNewChat, t.NewChat).Ghost().Disabled(!a.agentCanStartConversation(p)).Clicked() {
				a.newAgentConversation(p)
			}
			if f.Button(agentHistoryBack, t.Back).Ghost().Clicked() {
				a.closeAgentHistory(p)
			}
		})
		if !h.canList {
			f.Row().FillWidth().Pad(shellContentPad).Children(func() {
				f.Paragraph(t.HistoryUnsupported, 4).Color(a.colors.Subtle)
			})
			return
		}
		if h.listErr != "" {
			f.Row().FillWidth().Shrink(0).Items(ui.Center).Gap(8).Pad(shellContentPad).Children(func() {
				f.Paragraph(h.listErr, 4).Grow(1).Color(a.theme.Danger)
				if f.Button(agentHistoryRefresh, t.CheckAgain).Outline().Disabled(h.loading).Clicked() {
					a.refreshAgentHistory(p, false)
				}
			})
			if len(h.sessions) == 0 {
				return
			}
		}
		if h.restoring() {
			f.Text(t.StatusRestoring).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Pad(shellContentPad)
		}
		if h.loading && len(h.sessions) == 0 {
			f.Text(t.HistoryLoading).Color(a.colors.Subtle).Pad(shellContentPad)
			return
		}
		if len(h.sessions) == 0 {
			f.Text(t.HistoryEmpty).Color(a.colors.Subtle).Pad(shellContentPad)
			return
		}
		busy := p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling ||
			p.agent.connecting || h.restoring()
		f.ScrollArea(agentHistoryScroll).Grow(1).Children(func() {
			f.Column().FillWidth().Shrink(0).Gap(2).Pad(shellContentPad).Children(func() {
				for i, session := range h.sessions {
					label := session.Title
					if label == "" {
						label = t.Untitled
					}
					if updated := formatAgentHistoryTime(session.UpdatedAt); updated != "" {
						label += " · " + updated
					}
					if session.SessionID == p.agent.sessionID {
						label += " · " + t.Current
					}
					row := f.Button(agentHistoryRow.At(i), label).Outline().Disabled(!h.canLoad || busy)
					if row.Clicked() {
						a.openAgentHistorySession(p, session.SessionID)
					}
				}
			})
		})
		if !h.canLoad {
			f.Text(t.HistoryLoadUnsupported).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Pad(shellContentPad)
		}
		if h.limited {
			f.Text(t.HistoryLimited).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Pad(shellContentPad)
		}
	})
}

// formatAgentHistoryTime renders the Agent's own ISO 8601 activity time in the
// viewer's local zone. Unknown or malformed values stay hidden rather than guessed.
func formatAgentHistoryTime(value string) string {
	if value == "" {
		return ""
	}
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return ""
	}
	return parsed.Local().Format("2006-01-02 15:04")
}

// drawAgentConfigBar presents only the select options the adapter declared. The
// order is the adapter's, and the confirmed current value is always shown.
func (a *App) drawAgentConfigBar(f *ui.Frame, p *project) {
	c := &p.agent.config
	if len(c.options) == 0 && c.err == "" {
		return
	}
	t := a.text.Agent
	f.Column().FillWidth().Shrink(0).Gap(4).PadX(shellContentPad).PadY(4).Children(func() {
		disabled := p.agent.phase != agentPhaseReady || p.agent.history.restoring() || c.pendingToken != ""
		for i := range c.options {
			option := &c.options[i]
			state := c.selects[option.ID]
			if state == nil {
				state = new(ui.SelectState)
				c.selects[option.ID] = state
			}
			labels := make([]string, len(option.Choices))
			for choice := range option.Choices {
				labels[choice] = option.Choices[choice].Name
			}
			f.Row().FillWidth().Height(28).Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				f.Text(a.agentConfigLabel(option)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Width(72)
				pick := f.Select(option.scope, state, labels, agentConfigChoiceIndex(*option)).
					Placeholder(agentConfigCurrentName(*option)).
					Disabled(disabled).
					Height(28).
					Grow(1)
				if index, ok := pick.Picked(); ok && index >= 0 && index < len(option.Choices) {
					a.selectAgentConfig(p, option.ID, option.Choices[index].Value)
				}
			})
		}
		if c.pendingToken != "" {
			f.Text(t.StatusConfiguring).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
		if c.err != "" {
			f.Paragraph(c.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		}
	})
}

// agentConfigLabel localizes the ACP semantic categories the panel knows. Any
// other option keeps the adapter's own name because it is upstream vocabulary.
func (a *App) agentConfigLabel(option *agentConfigOption) string {
	switch agentConfigCategories[option.Category] {
	case "model":
		return a.text.Agent.ConfigModel
	case "thinking":
		return a.text.Agent.ConfigThinking
	case "permissions":
		return a.text.Agent.ConfigPermissions
	}
	return option.Name
}
