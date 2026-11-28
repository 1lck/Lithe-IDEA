package workbench

import (
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the Agent tool window (agents.go keeps its state): the header's tabs and
// buttons, how to start a conversation, and the parts of a conversation its view
// (agents_chat_view.go) shares with it: a gap in the transcript, notices, the pending
// permission requests and the plan.

const (
	// agentToolOutputLines is how many lines of a tool call's output a row shows.
	agentToolOutputLines = 6
	// agentPlanLines is how many plan entries the unfolded plan card shows.
	agentPlanLines = 8
	// agentPermissionPlaces is how many files of a tool call the permission card names.
	agentPermissionPlaces = 3
	// agentPermissionRadius rounds the permission and plan cards, less than the prompt card
	// they sit over.
	agentPermissionRadius = 14
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

// agentPending declares the permission request waiting first for the user as a card over the
// prompt card, as Claude Desktop asks: who asks, the tool call with the files it touches, and a
// row for each answer the agent offers, the first one marked as the one to take. Requests that
// wait behind it are counted in its corner and come up as it is answered.
func (a *App) agentPending(c ui.C, p *project, conversation *agentConversation) {
	t := conversation.transcript
	if len(t.Pending) == 0 {
		return
	}
	request := t.Pending[0]
	lang := a.language()
	small, medium := a.theme.Metrics.FontSizeS, a.theme.Metrics.FontSizeM
	kind, title := "", request.Title
	var places []agents.ToolLocation
	if call := t.ToolCall(request.ToolCallID); call != nil {
		kind, places = call.ToolKind, call.Locations
		if title == "" {
			title = call.Title
		}
	}
	ui.Column(c).FillWidth().Shrink(0).PadSides(4, 12, 4, 12).Children(func() {
		ui.Column(c).FillWidth().Radius(agentPermissionRadius).Border(1, a.colors.Line).Background(a.colors.Editor).
			Pad(10).Gap(8).Children(func() {
			ui.Row(c).FillWidth().Gap(6).Items(ui.Center).PadX(2).Children(func() {
				ui.Icon(c, icons.ShieldCheck).Size(14, 14).Color(a.colors.Accent).Shrink(0)
				ui.Wrap(c, i18n.SharedFormat(lang, "desktop.agents.permission.ask", map[string]string{"agent": conversation.agent.DisplayName})).
					FontSize(medium).Weight(gfx.WeightSemibold).Color(a.colors.Text).Grow(1).Shrink(1).MinWidth(0)
				if n := len(t.Pending); n > 1 {
					ui.Text(c, "1/"+strconv.Itoa(n)).FontSize(small).Color(a.colors.Subtle).Shrink(0)
				}
			})
			ui.Row(c.Part("call")).FillWidth().Gap(8).Items(ui.Start).PadX(10).PadY(8).Radius(8).Background(a.colors.Hover).Children(func() {
				ui.Icon(c, agentToolIcon(kind)).Size(14, 14).Color(a.colors.Subtle).Shrink(0).MarginTop(2)
				ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
					ui.Wrap(c, title).FontSize(small).Mono().Color(a.colors.Text).FillWidth()
					for i, place := range places {
						if i == agentPermissionPlaces {
							ui.Text(c.KeyInt(i), i18n.SharedFormat(lang, "desktop.agents.permission.morePlaces",
								map[string]string{"count": strconv.Itoa(len(places) - i)})).FontSize(small).Color(a.colors.Subtle)
							break
						}
						ui.Text(c.KeyInt(i), agentShownPath(p, place.Path)).FontSize(small).Color(a.colors.Subtle).Ellipsis().FillWidth()
					}
				})
			})
			ui.Column(c.Part("options")).FillWidth().Gap(2).Children(func() {
				first := agentFirstAllow(request.Options)
				for j, option := range request.Options {
					if a.agentPermissionOption(c.KeyInt(j), lang, option, j == first, conversation.answering != "") {
						permission, choice := request.Permission, option.ID
						c.After(func() { a.answerPermission(p, conversation, permission, choice) })
					}
				}
			})
		})
	})
}

// agentFirstAllow is the index of the first option that allows the call, the answer the card
// marks; -1 when the agent offers none.
func agentFirstAllow(options []agents.PermissionOption) int {
	for i, option := range options {
		if strings.HasPrefix(option.OptionKind, "allow") {
			return i
		}
	}
	return -1
}

// agentPermissionOption declares one answer to a permission request as a row across the card:
// a mark of what it does and its words, the agent's own wording in its tooltip when they
// differ. The marked row is filled with the accent. It reports a click.
func (a *App) agentPermissionOption(c ui.C, lang i18n.Language, option agents.PermissionOption, marked, disabled bool) bool {
	label := permissionOptionLabel(lang, option)
	icon, iconColor := icons.CircleX, a.colors.Subtle
	switch option.OptionKind {
	case "allowOnce":
		icon, iconColor = icons.Check, a.colors.Success
	case "allowAlways":
		icon, iconColor = icons.CircleCheck, a.colors.Success
	}
	text := a.colors.Text
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	row := ui.ButtonBase(c, label).FillWidth().Height(30).PadX(10).Gap(8).Radius(8).Items(ui.Center).Disabled(disabled).
		Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring))
	if marked {
		// The theme's primary button, as the answer to take.
		rest := components.ButtonRecipe(a.theme, components.ButtonDefault, gfx.State{})
		hover := components.ButtonRecipe(a.theme, components.ButtonDefault, gfx.State{Hovered: true})
		pressed := components.ButtonRecipe(a.theme, components.ButtonDefault, gfx.State{Pressed: true})
		iconColor, text = rest.Foreground, rest.Foreground
		row = row.Background(rest.Background).Hover(ui.Look{}.Background(hover.Background)).
			Pressed(ui.Look{}.Background(pressed.Background))
	} else {
		row = row.Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	}
	if label != option.Label {
		// The agent's own wording says what the choice covers, such as remembering it only for
		// this session.
		row = row.Tooltip(option.Label)
	}
	row.Children(func() {
		ui.Icon(c, icon).Size(14, 14).Color(iconColor).Shrink(0)
		ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeM).Color(text).Ellipsis().Shrink(1).MinWidth(0)
	})
	return row.Clicked()
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

// agentPlan declares the agent's latest plan as a card over the prompt card: a head with how
// many entries are done and, folded, the entry in progress; unfolded, the first entries, each
// marked done, in progress or waiting. The head folds and unfolds it.
func (a *App) agentPlan(c ui.C, conversation *agentConversation) {
	plan := conversation.transcript.Plan
	if len(plan) == 0 {
		return
	}
	lang := a.language()
	small := a.theme.Metrics.FontSizeS
	done, current := 0, -1
	for i, entry := range plan {
		switch entry.Status {
		case "completed":
			done++
		case "inProgress":
			if current < 0 {
				current = i
			}
		}
	}
	open := conversation.planOpen
	ui.Column(c).FillWidth().Shrink(0).PadSides(4, 12, 0, 12).Children(func() {
		ui.Column(c).FillWidth().Radius(agentPermissionRadius).Border(1, a.colors.Line).Background(a.colors.Editor).
			PadX(6).PadY(4).Gap(2).Children(func() {
			tip := i18n.Shared(lang, "desktop.agents.plan.show")
			if open {
				tip = i18n.Shared(lang, "desktop.agents.plan.hide")
			}
			head := ui.ButtonBase(c.Part("head"), i18n.Shared(lang, "desktop.agents.plan.title")).FillWidth().Height(26).PadX(6).Gap(6).
				Radius(6).Items(ui.Center).Hover(ui.Look{}.Background(a.colors.Hover)).Tooltip(tip)
			head.Children(func() {
				ui.Icon(c, icons.CircleCheck).Size(14, 14).Color(a.colors.Subtle).Shrink(0)
				ui.Text(c, i18n.Shared(lang, "desktop.agents.plan.title")).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Text).Shrink(0)
				ui.Text(c, i18n.SharedFormat(lang, "desktop.agents.plan.progress",
					map[string]string{"done": strconv.Itoa(done), "total": strconv.Itoa(len(plan))})).FontSize(small).Color(a.colors.Subtle).Shrink(0)
				if !open && current >= 0 {
					ui.Text(c, plan[current].Content).FontSize(small).Color(a.colors.Text).Ellipsis().Grow(1).Shrink(1).MinWidth(0)
				} else {
					ui.Spacer(c)
				}
				icon := icons.ChevronUp
				if open {
					icon = icons.ChevronDown
				}
				ui.Icon(c, icon).Size(12, 12).Color(a.colors.Subtle).Shrink(0)
			})
			if head.Clicked() {
				c.After(func() { conversation.planOpen = !open })
			}
			if !open {
				return
			}
			for i, entry := range plan {
				if i == agentPlanLines {
					ui.Text(c.KeyInt(i), i18n.SharedFormat(lang, "desktop.agents.plan.more",
						map[string]string{"count": strconv.Itoa(len(plan) - i)})).FontSize(small).Color(a.colors.Subtle).PadX(28).PadY(2)
					break
				}
				ui.Row(c.KeyInt(i)).FillWidth().Gap(8).Items(ui.Center).PadX(8).Height(22).Children(func() {
					a.agentPlanMark(c, entry.Status)
					color := a.colors.Text
					if entry.Status == "completed" {
						color = a.colors.Subtle
					}
					line := ui.Text(c, entry.Content).FontSize(small).Color(color).Ellipsis().Shrink(1).MinWidth(0)
					if entry.Status == "completed" {
						line.Strike()
					}
				})
			}
		})
	})
}

// agentPlanMark declares the mark of a plan entry: a check for one done, a spinning circle for
// the one in progress and an empty ring for one waiting.
func (a *App) agentPlanMark(c ui.C, status string) {
	switch status {
	case "completed":
		ui.Icon(c, icons.CircleCheck).Size(14, 14).Color(a.colors.Success).Shrink(0)
	case "inProgress":
		ui.Icon(c, icons.LoaderCircle).Size(14, 14).Color(a.colors.Accent).Shrink(0)
	default:
		ui.Row(c).Size(12, 12).Margin(1).Radius(6).Border(1.5, a.colors.Subtle).Shrink(0)
	}
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
