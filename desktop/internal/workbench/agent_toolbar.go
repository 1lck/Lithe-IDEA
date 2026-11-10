package workbench

import (
	"time"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The conversation toolbar, history panel and session-setting bar. They are separate
// from the streamed transcript so a history or toolbar change cannot disturb the
// transcript's measured rows.

// agentHeader declares the title and the conversation-level actions.
func (a *App) agentHeader(c ui.C, p *project) {
	t := a.text.Agent
	ui.Row(c).Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(8).PadSides(0, 8, 0, 12).Children(func() {
		ui.Text(c, a.agentConversationTitle(p)).Weight(gfx.WeightMedium).Ellipsis().Grow(1)
		historyDisabled := p.agent.phase == agentPhaseStarting || p.agent.phase == agentPhaseLoading
		if ui.Button(c, t.History).Ghost().Disabled(historyDisabled).Clicked() {
			c.After(func() { a.toggleAgentHistory(p) })
		}
		if ui.Button(c, t.NewChat).Ghost().Disabled(!a.agentCanStartConversation(p)).Clicked() {
			c.After(func() { a.newAgentConversation(p) })
		}
		if ui.Button(c, t.Change).Ghost().Clicked() {
			c.After(func() { a.disconnectAgent(p) })
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

// agentHistory replaces the transcript while the user browses the Agent-owned
// conversation list. Selecting a row asks Core to replay it.
func (a *App) agentHistory(c ui.C, p *project) {
	t := a.text.Agent
	h := &p.agent.history
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(8).PadSides(0, 8, 0, 12).Children(func() {
			ui.Text(c, t.HistoryTitle).Weight(gfx.WeightMedium).Ellipsis().Grow(1)
			if ui.Button(c, t.Refresh).Ghost().Disabled(!h.canList || h.loading).Clicked() {
				c.After(func() { a.refreshAgentHistory(p, false) })
			}
			if ui.Button(c, t.NewChat).Ghost().Disabled(!a.agentCanStartConversation(p)).Clicked() {
				c.After(func() { a.newAgentConversation(p) })
			}
			if ui.Button(c, t.Back).Ghost().Clicked() {
				c.After(func() { a.closeAgentHistory(p) })
			}
		})
		a.agentArchivedSection(c, p)
		if !h.canList {
			ui.Row(c).FillWidth().Pad(shellContentPad).Children(func() {
				ui.Paragraph(c, t.HistoryUnsupported, 4).Color(a.colors.Subtle)
			})
			return
		}
		if h.listErr != "" {
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Pad(shellContentPad).Children(func() {
				ui.Paragraph(c, h.listErr, 4).Grow(1).Color(a.theme.Danger)
				if ui.Button(c, t.CheckAgain).Outline().Disabled(h.loading).Clicked() {
					c.After(func() { a.refreshAgentHistory(p, false) })
				}
			})
			if len(h.sessions) == 0 {
				return
			}
		}
		if h.restoring() {
			ui.Text(c, t.StatusRestoring).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Pad(shellContentPad)
		}
		if h.loading && len(h.sessions) == 0 {
			ui.Text(c, t.HistoryLoading).Color(a.colors.Subtle).Pad(shellContentPad)
			return
		}
		if len(h.sessions) == 0 {
			ui.Text(c, t.HistoryEmpty).Color(a.colors.Subtle).Pad(shellContentPad)
			return
		}
		busy := p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling ||
			p.agent.connecting || h.restoring()
		ui.List(c, &p.agent.historyList, len(h.sessions), func(row ui.ListRow) {
			session := h.sessions[row.Index]
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
			row.Element.FillWidth().PadY(1)
			if ui.Button(row.C, label).Outline().FillWidth().Disabled(!h.canLoad || busy).Clicked() {
				c.After(func() { a.openAgentHistorySession(p, session.SessionID) })
			}
		}).Grow(1).Pad(shellContentPad)
		if !h.canLoad {
			ui.Text(c, t.HistoryLoadUnsupported).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Pad(shellContentPad)
		}
		if h.limited {
			ui.Text(c, t.HistoryLimited).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Pad(shellContentPad)
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

// agentConfigBar presents only the select options the adapter declared. The order is the
// adapter's, and the confirmed current value is always shown.
func (a *App) agentConfigBar(c ui.C, p *project) {
	cfg := &p.agent.config
	if len(cfg.options) == 0 && cfg.err == "" {
		return
	}
	t := a.text.Agent
	ui.Column(c).FillWidth().Shrink(0).Gap(4).PadX(shellContentPad).PadY(4).Children(func() {
		disabled := p.agent.phase != agentPhaseReady || p.agent.history.restoring() || cfg.pendingToken != ""
		for i := range cfg.options {
			option := &cfg.options[i]
			ui.Row(c.Key(option.ID)).FillWidth().Height(28).Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, a.agentConfigLabel(option)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Width(72)
				current := agentConfigChoiceIndex(*option)
				option.pick = current
				ui.Select(c, &option.pick, option.choiceIndexes, func(choice int) string { return option.Choices[choice].Name }).
					Placeholder(agentConfigCurrentName(*option)).Label(a.agentConfigLabel(option)).
					Disabled(disabled).Height(28).Grow(1)
				if option.pick != current && option.pick >= 0 && option.pick < len(option.Choices) {
					id, value := option.ID, option.Choices[option.pick].Value
					c.After(func() { a.selectAgentConfig(p, id, value) })
				}
			})
		}
		if cfg.pendingToken != "" {
			ui.Text(c, t.StatusConfiguring).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
		if cfg.err != "" {
			ui.Paragraph(c, cfg.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
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
