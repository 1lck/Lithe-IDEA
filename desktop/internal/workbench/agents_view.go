package workbench

import (
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the Agent tool window (agents.go keeps its state): the header's tabs and
// buttons, a conversation's transcript, its pending permission requests, plan and usage, the
// prompt field and the History tab.

const (
	// agentPromptHeight is the height of the prompt field.
	agentPromptHeight = 76
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

// chooseAgentsTab shows a tab; the History tab reads the sessions the first time it shows.
func (a *App) chooseAgentsTab(p *project, tab agentsTab) {
	v := &a.agentsView
	if v.tab == tab {
		return
	}
	v.tab = tab
	if tab == agentsTabHistory && !v.history.loaded && !v.history.loading && len(v.readableAgents()) > 0 {
		a.performed("agents.history.open", surfaceButton)
		a.loadAgentHistory(p, true)
	}
}

// agentsToolActions declares the header's buttons: reading the sessions again on the History
// tab, a new conversation and the menu of what runs an agent's CLI in a terminal. With several
// agents the new conversation button opens a menu of them.
func (a *App) agentsToolActions(c ui.C, p *project) {
	v := &a.agentsView
	if a.agentKernel == nil || len(v.catalog) == 0 {
		return
	}
	lang := a.language()
	ui.Row(c).Shrink(0).Items(ui.Center).Gap(2).Children(func() {
		if v.tab == agentsTabHistory {
			if _, hit := a.toolIconButton(c.Part("sync"), i18n.Shared(lang, "desktop.agents.history.sync"), icons.RefreshCw, false, v.history.loading || len(v.readableAgents()) == 0); hit {
				c.After(func() {
					a.performed("agents.history.sync", surfaceButton)
					a.loadAgentHistory(p, true)
				})
			}
		}
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
	conversation := a.currentConversation()
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
	ui.Column(c).Fill().Children(func() {
		a.agentConversationBar(c.Part("bar"), p, conversation)
		a.agentTranscript(c.Part("transcript"), conversation)
		a.agentPending(c.Part("pending"), p, conversation)
		a.agentPlan(c.Part("plan"), conversation)
		a.agentStatus(c.Part("status"), conversation)
		a.agentPrompt(c.Part("prompt"), p, conversation)
	})
}

// agentConversationBar declares the switcher of the window's conversations, when there are
// several, and the button that closes the shown one.
func (a *App) agentConversationBar(c ui.C, p *project, conversation *agentConversation) {
	v := &a.agentsView
	lang := a.language()
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).PadX(8).Gap(4).Items(ui.Center).Children(func() {
		if len(v.conversations) > 1 {
			labels := make([]string, len(v.conversations))
			for i, each := range v.conversations {
				labels[i] = agentConversationLabel(lang, i, each)
			}
			a.toolTabsWith(c.Key("conversations"), v.current, labels, func(index int) { a.agentsView.current = index })
		} else {
			ui.Text(c, agentConversationLabel(lang, 0, conversation)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1)
		}
		ui.Spacer(c)
		if _, hit := a.toolIconButton(c.Part("close"), i18n.Shared(lang, "desktop.agents.closeSession"), icons.X, false, conversation.busy); hit {
			c.After(func() { a.closeConversation(p, conversation) })
		}
	})
}

// agentConversationLabel names a conversation by its agent and place, with the state of one
// that ended.
func agentConversationLabel(lang i18n.Language, index int, conversation *agentConversation) string {
	label := i18n.SharedFormat(lang, "desktop.agents.conversation", map[string]string{
		"agent": conversation.agent.DisplayName, "number": strconv.Itoa(index + 1),
	})
	if !conversation.transcript.Live() {
		label = i18n.SharedFormat(lang, "desktop.agents.conversationEnded", map[string]string{"conversation": label})
	}
	return label
}

// agentTranscript declares the conversation's rows, newest at the bottom.
func (a *App) agentTranscript(c ui.C, conversation *agentConversation) {
	t := conversation.transcript
	lang := a.language()
	atEnd := conversation.list.AtEnd()
	extra := 0
	if t.Missed || t.Dropped > 0 {
		extra = 1
	}
	ui.List(c, &conversation.list, extra+len(t.Entries), func(row ui.ListRow) {
		row.Element.FillWidth().PadX(10).PadY(5)
		if row.Index < extra {
			a.agentGapRow(row.C, lang, t)
			return
		}
		a.agentEntryRow(row.C, lang, t.Entries[row.Index-extra])
	}).Label(i18n.Shared(lang, "desktop.agents.transcript")).Scrollbars().Grow(1).Shrink(1).MinHeight(0).FillWidth()
	if atEnd {
		conversation.list.ScrollToEnd()
	}
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

// agentEntryRow declares one transcript row.
func (a *App) agentEntryRow(c ui.C, lang i18n.Language, entry agents.Entry) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Gap(3).Children(func() {
		switch entry.Kind {
		case agents.EntryUser:
			ui.Text(c, i18n.Shared(lang, "desktop.agents.you")).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Accent)
			ui.Wrap(c, entry.Text).Color(a.colors.Text)
		case agents.EntryAssistant:
			ui.Wrap(c, entry.Text).Color(a.colors.Text)
		case agents.EntryThought:
			ui.Text(c, i18n.Shared(lang, "desktop.agents.thinking")).FontSize(small).Color(a.colors.Subtle)
			ui.Wrap(c, entry.Text).FontSize(small).Color(a.colors.Subtle)
		case agents.EntryTool:
			a.agentToolRow(c, lang, entry)
		case agents.EntryNotice:
			color := a.colors.Subtle
			if entry.Level == "warning" || entry.Level == "error" {
				color = a.colors.Warning
			}
			text := entry.Text
			if text == "" {
				text = agentNoticeText(lang, entry.Code)
			}
			ui.Row(c).FillWidth().Gap(6).Items(ui.Start).Children(func() {
				ui.Icon(c, icons.CircleAlert).Size(13, 13).Color(color).Shrink(0)
				ui.Wrap(c, text).FontSize(small).Color(color).Grow(1).Shrink(1)
			})
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

// agentToolRow declares a tool call: its title and state, the files it touches and the end of
// its output.
func (a *App) agentToolRow(c ui.C, lang i18n.Language, entry agents.Entry) {
	small := a.theme.Metrics.FontSizeS
	title := entry.Title
	if title == "" {
		title = entry.ToolKind
	}
	ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
		ui.Icon(c, icons.Wrench).Size(13, 13).Color(a.colors.Subtle).Shrink(0)
		ui.Text(c, title).FontSize(small).Color(a.colors.Text).Ellipsis().Shrink(1)
		if entry.Status != "" {
			ui.Text(c, agentToolStatus(lang, entry.Status)).FontSize(small).Color(agentToolStatusColor(a, entry.Status)).Shrink(0)
		}
	})
	for i, location := range entry.Locations {
		if i == 3 {
			break
		}
		place := location.Path
		if location.Line > 0 {
			place += ":" + strconv.FormatUint(location.Line, 10)
		}
		ui.Text(c.KeyInt(i), place).FontSize(small).Mono().Color(a.colors.Subtle).Ellipsis()
	}
	if output := strings.TrimRight(entry.Output, "\n"); output != "" {
		ui.Paragraph(c, strings.ReplaceAll(lastLines(output, agentToolOutputLines), "\t", "    "), agentToolOutputLines).FontSize(small).Mono().Color(a.colors.Subtle).FillWidth()
	}
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

func agentToolStatusColor(a *App, status string) gfx.Color {
	switch status {
	case "completed":
		return a.colors.Success
	case "failed":
		return a.colors.Warning
	}
	return a.colors.Subtle
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

// agentStatus declares the conversation's state line: whether it works, its model, how much
// of the context it uses, its tokens and cost.
func (a *App) agentStatus(c ui.C, conversation *agentConversation) {
	ui.Text(c, agentStatusText(a.language(), conversation)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).
		Ellipsis().FillWidth().PadX(10).PadY(3).Shrink(0)
}

// agentStatusText is the state line of a conversation.
func agentStatusText(lang i18n.Language, conversation *agentConversation) string {
	t := conversation.transcript
	var parts []string
	switch {
	case !t.Live():
		parts = append(parts, i18n.Shared(lang, "desktop.agents.ended"))
	case t.ActiveTurn != 0 || conversation.busy:
		parts = append(parts, i18n.Shared(lang, "desktop.agents.working"))
	default:
		parts = append(parts, i18n.Shared(lang, "desktop.agents.ready"))
	}
	model := t.Model
	if t.Usage != nil && t.Usage.Model != "" {
		model = t.Usage.Model
	}
	if model != "" {
		parts = append(parts, model)
	}
	if usage := t.Usage; usage != nil {
		if usage.ContextWindow > 0 {
			parts = append(parts, i18n.SharedFormat(lang, "desktop.agents.context", map[string]string{
				"used": compactCount(usage.ContextUsed), "window": compactCount(usage.ContextWindow),
			}))
		}
		if total := usage.Tokens.Total(); total > 0 {
			parts = append(parts, i18n.SharedFormat(lang, "desktop.agents.tokens", map[string]string{"count": compactCount(total)}))
		}
		if usage.CostUSD != nil {
			parts = append(parts, i18n.SharedFormat(lang, "desktop.agents.cost", map[string]string{"cost": strconv.FormatFloat(*usage.CostUSD, 'f', 2, 64)}))
		}
	}
	return strings.Join(parts, " · ")
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

// agentPrompt declares the prompt field with its Send and Stop buttons; ⌘↩ sends.
func (a *App) agentPrompt(c ui.C, p *project, conversation *agentConversation) {
	t := conversation.transcript
	if !t.Live() {
		return
	}
	lang := a.language()
	ui.Column(c).FillWidth().Shrink(0).PadX(8).PadY(6).Gap(6).Children(func() {
		field := ui.TextArea(c.Key("prompt"), &conversation.prompt, i18n.Shared(lang, "desktop.agents.promptLabel"),
			i18n.SharedFormat(lang, "desktop.agents.promptPlaceholder", map[string]string{"agent": conversation.agent.DisplayName})).
			FillWidth().Height(agentPromptHeight)
		if field.Shortcut(ui.Primary, "enter") && conversation.canSendPrompt() {
			c.After(func() { a.sendPrompt(p, conversation, surfaceShortcut) })
		}
		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			ui.Text(c, i18n.Shared(lang, "desktop.agents.sendHint")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1)
			ui.Spacer(c)
			if t.ActiveTurn != 0 {
				if ui.Button(c.Key("stop"), i18n.Shared(lang, "desktop.agents.stop")).Icon(icons.Square).Outline().Disabled(conversation.busy).Clicked() {
					c.After(func() { a.cancelTurn(p, conversation) })
				}
			}
			if ui.Button(c.Key("send"), i18n.Shared(lang, "desktop.agents.send")).Icon(icons.ArrowUp).Disabled(!conversation.canSendPrompt()).Clicked() {
				c.After(func() { a.sendPrompt(p, conversation, surfaceButton) })
			}
		})
	})
}

// agentsHistoryPanel declares the History tab: the search field, the scope switch and the
// recorded sessions or search hits, or why there are none.
func (a *App) agentsHistoryPanel(c ui.C, p *project) {
	v := &a.agentsView
	h := &v.history
	lang := a.language()
	if len(v.readableAgents()) == 0 {
		ui.Column(c).Fill().Center().Gap(10).PadX(shellContentPad).Children(func() {
			message := i18n.Shared(lang, "desktop.agents.history.unsupported")
			if v.sessionReadingOffered() {
				message = i18n.Shared(lang, "desktop.agents.history.noConsent")
			}
			ui.Paragraph(c, message, 4).FillWidth().TextCenter().Color(a.colors.Subtle)
			if v.sessionReadingOffered() && ui.Button(c.Key("settings"), i18n.Shared(lang, "desktop.agents.history.openSettings")).Outline().Clicked() {
				c.After(func() { a.openSettingsPage(surfaceButton, settingsAgents) })
			}
		})
		return
	}
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).FillWidth().Shrink(0).PadX(8).PadY(6).Gap(8).Items(ui.Center).Children(func() {
			field := ui.TextField(c.Key("query"), &h.query, i18n.Shared(lang, "desktop.agents.history.search"),
				i18n.Shared(lang, "desktop.agents.history.searchPlaceholder")).Grow(1).Shrink(1).MinWidth(0)
			if field.Submitted() {
				c.After(func() {
					a.performed("agents.history.search", surfaceShortcut)
					a.loadAgentHistory(p, false)
				})
			}
			everywhere := h.everywhere
			if ui.Switch(c.Key("everywhere"), &everywhere, i18n.Shared(lang, "desktop.agents.history.allProjects")).Changed() {
				c.After(func() {
					a.agentsView.history.everywhere = everywhere
					a.loadAgentHistory(p, false)
				})
			}
		})
		switch {
		case h.failure != "":
			a.panelMessage(c.Part("failure"), i18n.SharedFormat(lang, "desktop.agents.history.failed", map[string]string{"reason": h.failure}), a.colors.Warning)
		case h.loading && !h.loaded:
			a.panelMessage(c.Part("loading"), i18n.Shared(lang, "desktop.agents.history.loading"), a.colors.Subtle)
		case h.searched && len(h.hits) == 0, !h.searched && len(h.sessions) == 0:
			a.panelMessage(c.Part("none"), i18n.Shared(lang, "desktop.agents.history.none"), a.colors.Subtle)
		case h.searched:
			a.agentHitList(c.Part("hits"), p, lang)
		default:
			a.agentSessionList(c.Part("sessions"), p, lang)
		}
	})
}

// agentSessionList declares the recorded sessions, newest first; a double click resumes one.
func (a *App) agentSessionList(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	sessions := h.sessions
	ui.List(c, &h.list, len(sessions), func(row ui.ListRow) {
		session := sessions[row.Index]
		row.Element.FillWidth().PadX(10).PadY(5).Gap(8).Items(ui.Center).Children(func() {
			ui.Column(row.C).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
				title := session.Title
				if title == "" {
					title = session.SessionID
				}
				ui.Text(row.C, title).Color(a.colors.Text).Ellipsis()
				ui.Text(row.C, agentSessionDetail(lang, a.agentDisplayName(session.Agent), session.Cwd, session.UpdatedAtMs, h.everywhere)).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
			if _, hit := a.toolIconButton(row.C.Part("resume"), i18n.Shared(lang, "desktop.agents.history.resume"), icons.Play, false, !a.canResume(session.PluginID, session.AgentID)); hit {
				pluginID, agentID, id := session.PluginID, session.AgentID, session.SessionID
				row.C.After(func() { a.resumeRecorded(p, pluginID, agentID, id) })
			}
		})
	}).Label(i18n.Shared(lang, "desktop.agents.history")).Scrollbars().Grow(1).Shrink(1).MinHeight(0).FillWidth()
	if index, ok := h.list.Submitted(); ok && index < len(sessions) && a.canResume(sessions[index].PluginID, sessions[index].AgentID) {
		session := sessions[index]
		c.After(func() { a.resumeRecorded(p, session.PluginID, session.AgentID, session.SessionID) })
	}
}

// agentHitList declares the search hits; a double click resumes the session of one.
func (a *App) agentHitList(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	hits := h.hits
	ui.List(c, &h.list, len(hits), func(row ui.ListRow) {
		hit := hits[row.Index]
		row.Element.FillWidth().PadX(10).PadY(5).Gap(2).Children(func() {
			ui.Column(row.C).FillWidth().Gap(2).Children(func() {
				ui.Text(row.C, hit.SessionID).Color(a.colors.Text).Ellipsis()
				ui.Text(row.C, agentSessionDetail(lang, a.agentDisplayName(hit.Agent), "", hit.AtMs, false)).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		})
	}).Label(i18n.Shared(lang, "desktop.agents.history")).Scrollbars().Grow(1).Shrink(1).MinHeight(0).FillWidth()
	if index, ok := h.list.Submitted(); ok && index < len(hits) && a.canResume(hits[index].PluginID, hits[index].AgentID) {
		hit := hits[index]
		c.After(func() { a.resumeRecorded(p, hit.PluginID, hit.AgentID, hit.SessionID) })
	}
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

// agentSessionDetail is a recorded session's second line: its agent, when it last changed
// and, when every directory is listed, its directory.
func agentSessionDetail(lang i18n.Language, agent, cwd string, atMs int64, withDirectory bool) string {
	parts := []string{agent}
	if atMs > 0 {
		parts = append(parts, time.UnixMilli(atMs).Local().Format("2006-01-02 15:04"))
	}
	if withDirectory && cwd != "" {
		parts = append(parts, cwd)
	}
	return strings.Join(parts, " · ")
}
