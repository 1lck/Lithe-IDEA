package workbench

import (
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// This file draws the Agent tool window (agents.go keeps its state): the header's tabs and
// buttons, how to start a conversation, and the parts of a conversation its view
// (agents_chat_view.go) shares with it: a gap in the transcript, notices, the pending
// permission requests and the plan.

const (
	// agentToolOutputLines is how many lines of a tool call's output a row shows.
	agentToolOutputLines = 6
	// agentPlanLines is how many plan entries the window shows.
	agentPlanLines = 8
)

// agentsTabsShown reports whether the header shows the Chat and History tabs, in place of the
// title: a local project is open and an agent is configured.
func (a *App) agentsTabsShown(p *project) bool {
	return p != nil && p.remote == nil && a.agentKernel != nil && len(a.agentsView.catalog) > 0
}

// agentsTabs declares the Chat and History tabs of the header.
func (a *App) agentsTabs(c ui.C, p *project) {
	v := &a.agentsView
	lang := a.language()
	labels := []string{i18n.Shared(lang, "desktop.agents.chat"), i18n.Shared(lang, "desktop.agents.history")}
	a.toolTabsWith(c.Key("agents-tabs"), int(v.tab), labels, func(index int) { a.chooseAgentsTab(p, agentsTab(index)) })
}

// chooseAgentsTab shows a tab; the History tab reads the changed session files the first time it
// shows, listing what was read before meanwhile.
func (a *App) chooseAgentsTab(p *project, tab agentsTab) {
	v := &a.agentsView
	if v.tab == tab {
		return
	}
	v.tab = tab
	if tab == agentsTabHistory && v.history.refreshedAt.IsZero() && !v.history.refreshing && len(v.readableAgents()) > 0 {
		a.performed("agents.history.open", surfaceButton)
		a.refreshAgentHistory(p)
	}
}

// agentsToolActions declares the header's buttons: a new conversation and the menu of what runs an agent's CLI in a terminal. With several
// agents the new conversation button opens a menu of them.
func (a *App) agentsToolActions(c ui.C, p *project) {
	v := &a.agentsView
	if a.agentKernel == nil || len(v.catalog) == 0 {
		return
	}
	lang := a.language()
	ui.Row(c).Shrink(0).Items(ui.Center).Gap(2).Children(func() {
		label := i18n.Shared(lang, "desktop.agents.new")
		if len(v.catalog) == 1 {
			label = i18n.SharedFormat(lang, "desktop.agents.newSession", map[string]string{"agent": v.catalog[0].DisplayName})
		}
		startable := slices.ContainsFunc(v.catalog, a.canStartConversation)
		newButton, hit := a.toolIconButton(c.Part("new"), label, icons.Plus, v.menu == agentsMenuNew, !startable)
		if hit {
			c.After(func() {
				if catalog := a.agentsView.catalog; len(catalog) == 1 {
					a.startConversation(p, catalog[0], "")
					return
				}
				a.agentsView.menu = agentsMenuNew
			})
		}
		a.agentsNewMenu(c.Part("new-menu"), p, newButton)
		if slices.ContainsFunc(v.catalog, func(agent agents.CatalogAgent) bool { return agent.HasForm("terminal") || agent.Update != nil }) {
			more, hit := a.toolIconButton(c.Part("more"), i18n.Shared(lang, "desktop.agents.more"), icons.Ellipsis, v.menu == agentsMenuMore, false)
			if hit {
				c.After(func() { a.agentsView.menu = agentsMenuMore })
			}
			a.agentsMoreMenu(c.Part("more-menu"), p, more)
		}
	})
}

// agentsNewMenu declares the agents a new conversation can start with under the header's
// button, while it is open.
func (a *App) agentsNewMenu(c ui.C, p *project, anchor ui.Box) {
	v := &a.agentsView
	if v.menu != agentsMenuNew {
		return
	}
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		for _, agent := range v.catalog {
			if menu.Item(agent.DisplayName).Disabled(!a.canStartConversation(agent)).Clicked() {
				c.After(func() {
					a.agentsView.menu = agentsMenuNone
					a.startConversation(p, agent, "")
				})
			}
		}
	})
	if !open {
		v.menu = agentsMenuNone
	}
}

// agentsMoreMenu declares, for each agent, opening its CLI in a terminal and updating it, under
// the header's button, while it is open.
func (a *App) agentsMoreMenu(c ui.C, p *project, anchor ui.Box) {
	v := &a.agentsView
	if v.menu != agentsMenuMore {
		return
	}
	lang := a.language()
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		for i, agent := range v.catalog {
			if !agent.HasForm("terminal") && agent.Update == nil {
				continue
			}
			if i > 0 {
				menu.Separator()
			}
			if agent.HasForm("terminal") {
				if menu.Item(i18n.SharedFormat(lang, "desktop.agents.openTerminal", map[string]string{"agent": agent.DisplayName})).Disabled(!agent.MayRun).Clicked() {
					c.After(func() {
						a.agentsView.menu = agentsMenuNone
						a.openAgentTerminal(p, agent)
					})
				}
			}
			if agent.Update != nil {
				if menu.Item(i18n.SharedFormat(lang, "desktop.agents.updateCli", map[string]string{"agent": agent.DisplayName})).Disabled(!agent.MayRun).Clicked() {
					c.After(func() {
						a.agentsView.menu = agentsMenuNone
						a.updateAgent(p, agent)
					})
				}
			}
		}
	})
	if !open {
		v.menu = agentsMenuNone
	}
}

// agentDisplayName is the name of a configured agent by key, the key when it is gone.
func (a *App) agentDisplayName(key string) string {
	for _, agent := range a.agentsView.catalog {
		if agent.Key() == key {
			return agent.DisplayName
		}
	}
	return key
}

// agentsPanel declares the body of the Agent tool window.
func (a *App) agentsPanel(c ui.C, p *project) {
	v := &a.agentsView
	lang := a.language()
	switch {
	case p == nil:
		a.panelMessage(c, i18n.Shared(lang, "desktop.agents.noProject"), a.colors.Subtle)
	case a.agentKernel == nil:
		a.panelMessage(c, i18n.Shared(lang, "desktop.agents.unavailable"), a.colors.Subtle)
	case !v.configured:
		a.panelMessage(c, i18n.Shared(lang, "desktop.agents.loading"), a.colors.Subtle)
	case len(v.catalog) == 0:
		a.agentsEmpty(c)
	case v.tab == agentsTabHistory:
		a.agentsHistoryPanel(c, p)
	default:
		a.agentsChat(c, p)
	}
}

// agentsEmpty says that no installed plugin declares an agent and leads to the marketplace.
func (a *App) agentsEmpty(c ui.C) {
	lang := a.language()
	ui.Column(c).Fill().Center().Gap(10).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, i18n.Shared(lang, "desktop.agents.empty"), 4).FillWidth().TextCenter().Color(a.colors.Subtle)
		if ui.Button(c.Key("marketplace"), i18n.Shared(lang, "desktop.agents.openMarketplace")).Outline().Clicked() {
			c.After(func() { a.openSettingsPage(surfaceButton, settingsMarketplace) })
		}
	})
}

// agentsChat declares the Chat tab: the conversations' switcher, the shown conversation and
// its prompt field, or how to start one.
func (a *App) agentsChat(c ui.C, p *project) {
	v := &a.agentsView
	lang := a.language()
	conversation := a.sidebarConversation()
	if conversation == nil {
		ui.Column(c).Fill().Center().Gap(10).PadX(shellContentPad).Children(func() {
			message := i18n.Shared(lang, "desktop.agents.noConversation")
			if v.starting {
				message = i18n.Shared(lang, "desktop.agents.starting")
			}
			ui.Paragraph(c, message, 3).FillWidth().TextCenter().Color(a.colors.Subtle)
			if v.starting {
				return
			}
			unable := false
			for i, agent := range v.catalog {
				start := ui.Button(c.KeyInt(i), i18n.SharedFormat(lang, "desktop.agents.newSession", map[string]string{"agent": agent.DisplayName})).
					Outline().Disabled(!a.canStartConversation(agent))
				if start.Clicked() {
					c.After(func() { a.startConversation(p, agent, "") })
				}
				unable = unable || !agent.MayRun || !agent.HasMode("native") || !agent.HasForm("conversation")
			}
			if unable {
				ui.Paragraph(c, i18n.Shared(lang, "desktop.agents.noNativeMode"), 3).FillWidth().TextCenter().Color(a.colors.Subtle)
			}
		})
		return
	}
	a.agentChatBody(c, p, conversation, false)
}

// agentGapRow says that the transcript is not whole: Core lost some events, or the oldest
// rows were dropped to keep the transcript bounded.
func (a *App) agentGapRow(c ui.C, lang i18n.Language, t *agents.Transcript) {
	ui.Column(c).FillWidth().Gap(2).Children(func() {
		if t.Missed {
			ui.Wrap(c, i18n.Shared(lang, "desktop.agents.missed")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
		}
		if t.Dropped > 0 {
			ui.Wrap(c, i18n.SharedFormat(lang, "desktop.agents.dropped", map[string]string{"count": strconv.Itoa(t.Dropped)})).
				FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
	})
}

// agentNoticeText is what a notice without text says: why a turn did not complete, or the
// backend's code as it is.
func agentNoticeText(lang i18n.Language, code string) string {
	switch code {
	case "cancelled":
		return i18n.Shared(lang, "desktop.agents.turnEnded.cancelled")
	case "maxTokens":
		return i18n.Shared(lang, "desktop.agents.turnEnded.maxTokens")
	case "maxTurns":
		return i18n.Shared(lang, "desktop.agents.turnEnded.maxTurns")
	case "refused":
		return i18n.Shared(lang, "desktop.agents.turnEnded.refused")
	case "failed":
		return i18n.Shared(lang, "desktop.agents.turnEnded.failed")
	}
	return code
}

// agentToolStatus is the words of a tool call's state.
func agentToolStatus(lang i18n.Language, status string) string {
	switch status {
	case "pending":
		return i18n.Shared(lang, "desktop.agents.toolStatus.pending")
	case "inProgress":
		return i18n.Shared(lang, "desktop.agents.toolStatus.inProgress")
	case "completed":
		return i18n.Shared(lang, "desktop.agents.toolStatus.completed")
	case "failed":
		return i18n.Shared(lang, "desktop.agents.toolStatus.failed")
	}
	return status
}

// lastLines keeps the last n lines of text; a line break that ends the text starts no line.
func lastLines(text string, n int) string {
	text = strings.TrimRight(text, "\n")
	end := len(text)
	for i := len(text) - 1; i >= 0; i-- {
		if text[i] == '\n' {
			n--
			if n == 0 {
				return text[i+1 : end]
			}
		}
	}
	return text
}

// agentPending declares the permission requests waiting for the user, each with the options
// the agent offered.
func (a *App) agentPending(c ui.C, p *project, conversation *agentConversation) {
	pending := conversation.transcript.Pending
	if len(pending) == 0 {
		return
	}
	lang := a.language()
	ui.Column(c).FillWidth().Shrink(0).PadX(10).PadY(6).Gap(6).Background(a.colors.Hover).Children(func() {
		for i, request := range pending {
			k := c.KeyInt(i)
			ui.Column(k).FillWidth().Gap(4).Children(func() {
				ui.Wrap(k, i18n.SharedFormat(lang, "desktop.agents.permission", map[string]string{"title": request.Title})).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text)
				ui.Flow(k).FillWidth().Gap(6).Children(func() {
					for j, option := range request.Options {
						label := permissionOptionLabel(lang, option)
						button := ui.Button(k.KeyInt(j), label).Disabled(conversation.answering != "")
						if label != option.Label {
							// The agent's own wording says what the choice covers,
							// such as remembering it only for this session.
							button = button.Tooltip(option.Label)
						}
						if !strings.HasPrefix(option.OptionKind, "allow") {
							button = button.Outline()
						}
						if button.Clicked() {
							permission, choice := request.Permission, option.ID
							k.After(func() { a.answerPermission(p, conversation, permission, choice) })
						}
					}
				})
			})
		}
	})
}

// permissionOptionLabel is the button text of a permission option: the translation of its
// kind (the contract allows these four), or the agent's own label for any other kind.
func permissionOptionLabel(lang i18n.Language, option agents.PermissionOption) string {
	switch option.OptionKind {
	case "allowOnce":
		return i18n.Shared(lang, "desktop.agents.option.allowOnce")
	case "allowAlways":
		return i18n.Shared(lang, "desktop.agents.option.allowAlways")
	case "rejectOnce":
		return i18n.Shared(lang, "desktop.agents.option.rejectOnce")
	case "rejectAlways":
		return i18n.Shared(lang, "desktop.agents.option.rejectAlways")
	}
	return option.Label
}

// agentPlan declares the agent's latest plan, its first entries.
func (a *App) agentPlan(c ui.C, conversation *agentConversation) {
	plan := conversation.transcript.Plan
	if len(plan) == 0 {
		return
	}
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Shrink(0).PadX(10).PadY(4).Gap(2).Children(func() {
		for i, entry := range plan {
			if i == agentPlanLines {
				break
			}
			mark, color := "○", a.colors.Subtle
			switch entry.Status {
			case "inProgress":
				mark, color = "◐", a.colors.Accent
			case "completed":
				mark, color = "●", a.colors.Success
			}
			ui.Row(c.KeyInt(i)).FillWidth().Gap(6).Items(ui.Center).Children(func() {
				ui.Text(c, mark).FontSize(small).Color(color).Shrink(0)
				ui.Text(c, entry.Content).FontSize(small).Color(a.colors.Text).Ellipsis().Shrink(1)
			})
		}
	})
}

// compactCount writes a count as 1234, 12.3K or 1.2M.
func compactCount(count uint64) string {
	switch {
	case count >= 1_000_000:
		return strconv.FormatFloat(float64(count)/1_000_000, 'f', 1, 64) + "M"
	case count >= 10_000:
		return strconv.FormatFloat(float64(count)/1_000, 'f', 1, 64) + "K"
	}
	return strconv.FormatUint(count, 10)
}

// canResume reports whether a recorded session's agent can start a conversation now.
func (a *App) canResume(pluginID, agentID string) bool {
	for _, agent := range a.agentsView.catalog {
		if agent.PluginID == pluginID && agent.AgentID == agentID {
			return a.canStartConversation(agent)
		}
	}
	return false
}
