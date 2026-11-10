package workbench

import (
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the AI Assistant tool window as a component: provider selection
// while no connection is open, then the conversation. The state is the project's
// (agentState); the actions are in agent.go and agent_history.go. The toolbar, the
// history panel and the session-setting bar are in agent_toolbar.go.

// agentPanel declares the AI Assistant tool window's body.
func (a *App) agentPanel(c ui.C) {
	p := a.project
	if p == nil {
		return
	}
	if !a.agentKernelReady() {
		ui.Row(c).Fill().Items(ui.Center).PadX(shellContentPad).Children(func() {
			ui.Paragraph(c, a.text.Panel.Placeholder, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
		})
		return
	}
	a.ensureAgentState(p)
	if p.agent.conn == nil {
		a.agentSetup(c, p)
		return
	}
	a.agentConversation(c, p)
}

// agentRetryCheck forgets what the discovery found, so the next paint reads it again.
func (a *App) agentRetryCheck(p *project) {
	p.agent.statusLoaded = false
	p.agent.statusErr = ""
	p.agent.providerErr = map[string]string{}
	a.ensureAgentState(p)
}

// agentChoiceRow declares one row of a radio list and reports a click on an enabled one.
// key names the row among its siblings.
func (a *App) agentChoiceRow(c ui.C, key, label string, selected, disabled bool) bool {
	id := ui.ID(c.Key("hit/" + key))
	row := ui.Row(c.Key(key)).FillWidth().Height(rowHeight+6).Shrink(0).Items(ui.Center).PadX(8).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, label, gfx.HitOptions{Role: gfx.RoleRadio, Selected: selected, Disabled: disabled, Cursor: gfx.PointerCursorHand}).
		Hover(ui.Look{}.Background(a.colors.Hover))
	if selected {
		row = row.Background(a.colors.Active)
	}
	row.Children(func() {
		ui.Text(c, label).Ellipsis().Color(a.colors.Text)
	})
	return row.Clicked() && !disabled
}

// agentSetup lists the installed adapters and the providers discovered in the user's own
// Codex and Claude configuration. It never invents a provider.
func (a *App) agentSetup(c ui.C, p *project) {
	t := a.text.Agent
	ui.Scroll(c).Fill().Children(func() {
		ui.Column(c).FillWidth().Shrink(0).Gap(8).Pad(shellContentPad).Children(func() {
			if p.agent.phase == agentPhaseLoading {
				ui.Text(c, t.Checking).Color(a.colors.Subtle)
				return
			}
			if p.agent.statusErr != "" {
				ui.Paragraph(c, p.agent.statusErr, 4).Color(a.theme.Danger)
				if ui.Button(c, t.CheckAgain).Outline().Clicked() {
					c.After(func() { a.agentRetryCheck(p) })
				}
				return
			}
			if p.agent.err != "" {
				ui.Paragraph(c, p.agent.err, 4).Color(a.theme.Danger)
			}
			if p.agent.connecting {
				ui.Text(c, t.StatusStarting).Color(a.colors.Subtle)
			}
			if len(p.agent.agents) == 0 {
				ui.Paragraph(c, t.NoAgents, 4).Color(a.colors.Subtle)
				return
			}

			ui.Text(c, t.AgentLabel).Weight(gfx.WeightMedium).Color(a.colors.Text)
			for i, agent := range p.agent.agents {
				installed := agent.InstalledVersion != nil
				label := agent.Name
				if installed {
					label += " · " + *agent.InstalledVersion
				} else {
					label += " · " + t.NotInstalled
				}
				if a.agentChoiceRow(c, "agent/"+agent.ID, label, i == p.agent.selected, !installed) {
					c.After(func() {
						p.agent.selected = i
						p.agent.selectedProvider = 0
					})
				}
				for j, issue := range agent.Issues {
					ui.Paragraph(c.KeyInt(j), issue, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				}
				if !installed {
					a.agentInstallControls(c, p, agent)
				}
			}

			agent, ok := p.selectedAgent()
			if !ok {
				return
			}
			ui.Text(c, t.ProviderLabel).Weight(gfx.WeightMedium).Color(a.colors.Text)
			for _, source := range agentProviderSources() {
				if issue := p.agent.providerErr[source]; issue != "" {
					ui.Paragraph(c, t.ErrorProvider(a.agentIssueText(issue)), 4).Color(a.theme.Danger)
					if ui.Button(c.Key("provider-retry"), t.CheckAgain).Outline().Clicked() {
						c.After(func() { a.agentRetryCheck(p) })
					}
					break
				}
			}
			providers := p.providersForAgent(agent)
			if len(providers) == 0 {
				ui.Paragraph(c, t.NoProviders, 4).Color(a.colors.Subtle)
				return
			}
			for i, provider := range providers {
				disabled := provider.Issue != "" || provider.MissingKey
				label := provider.Name
				if provider.Endpoint != "" {
					label += " · " + provider.Endpoint
				}
				if provider.Model != "" {
					label += " · " + provider.Model
				}
				if a.agentChoiceRow(c, fmt.Sprintf("provider/%d", i), label, i == p.agent.selectedProvider, disabled) {
					c.After(func() { p.agent.selectedProvider = i })
				}
				switch {
				case provider.MissingKey:
					ui.Text(c.KeyInt(i), t.MissingKey).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
				case provider.Issue != "":
					ui.Text(c.KeyInt(i), t.ProviderUnsupported(a.agentIssueText(provider.Issue))).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
				}
			}

			if ui.Button(c, t.Start).Disabled(!p.canStartAgent() || p.agent.connecting).Clicked() {
				c.After(func() { a.startAgent(p) })
			}
		})
	})
}

// agentInstallControls declares the explicit install entry for one adapter, the live
// progress of an install in flight, and its failure/retry state. Opening the panel only
// reads status; this control is the only way an install starts.
func (a *App) agentInstallControls(c ui.C, p *project, agent core.AgentCatalogStatus) {
	t := a.text.Agent
	if p.agent.installing == agent.ID {
		progress := p.agent.installProgress
		ui.Column(c.Key("install/" + agent.ID)).FillWidth().Shrink(0).Gap(4).PadX(8).PadY(4).Children(func() {
			ui.Text(c, a.agentInstallStage(progress.Stage)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			if progress.DownloadedBytes > 0 || progress.BytesPerSecond > 0 {
				ui.Text(c, t.InstallProgress(agentFormatBytes(progress.DownloadedBytes), agentFormatBytes(progress.BytesPerSecond), agentFormatDuration(progress.ElapsedMilliseconds))).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
			if progress.IdleMilliseconds >= 2000 {
				ui.Text(c, t.InstallWaiting).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
			}
			label := t.InstallCancel
			if p.agent.installCancelling {
				label = t.InstallCancelling
			}
			if ui.Button(c, label).Outline().Disabled(p.agent.installCancelling).Clicked() {
				c.After(func() { a.cancelAgentInstall(p) })
			}
		})
		return
	}
	disabled := p.agent.installing != ""
	if ui.Button(c.Key("install/"+agent.ID), t.Install).Outline().Disabled(disabled).Clicked() {
		c.After(func() { a.installAgent(p, agent.ID) })
	}
	if p.agent.lastInstall == agent.ID && p.agent.installErr != "" {
		ui.Paragraph(c.Key("install-error/"+agent.ID), p.agent.installErr, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		if ui.Button(c.Key("install-retry/"+agent.ID), t.InstallRetry).Outline().Disabled(disabled).Clicked() {
			c.After(func() { a.installAgent(p, agent.ID) })
		}
	}
	if p.agent.lastInstall == agent.ID && p.agent.installWarning != "" {
		ui.Paragraph(c.Key("install-warning/"+agent.ID), p.agent.installWarning, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
	}
}

// agentInstallStage localizes the stages Core reports; an unknown stage stays
// as Core wrote it rather than being guessed.
func (a *App) agentInstallStage(stage string) string {
	switch stage {
	case "preparing":
		return a.text.Agent.InstallPreparing
	case "downloading":
		return a.text.Agent.InstallDownloading
	case "updating":
		return a.text.Agent.InstallUpdating
	}
	return stage
}

func agentFormatBytes(bytes uint64) string {
	if bytes < 1024 {
		return fmt.Sprintf("%d B", bytes)
	}
	value := float64(bytes)
	units := [...]string{"B", "KB", "MB", "GB", "TB"}
	unit := 0
	for value >= 1024 && unit < len(units)-1 {
		value /= 1024
		unit++
	}
	return fmt.Sprintf("%.1f %s", value, units[unit])
}

func agentFormatDuration(milliseconds uint64) string {
	if milliseconds < 1000 {
		return fmt.Sprintf("%dms", milliseconds)
	}
	return fmt.Sprintf("%.1fs", float64(milliseconds)/1000)
}

// agentConversation declares the header, the transcript, the pending permission card and
// the composer. The transcript is a List, which declares only the rows on screen; the
// message list itself is bounded in agent.go.
func (a *App) agentConversation(c ui.C, p *project) {
	t := a.text.Agent
	ui.Column(c).Fill().Children(func() {
		a.agentHeader(c, p)
		if p.agent.history.open {
			a.agentHistory(c, p)
			return
		}
		if p.agent.err != "" {
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Pad(8).Background(a.colors.Active).Children(func() {
				ui.Paragraph(c, p.agent.err, 4).Grow(1).Color(a.colors.Text)
				if ui.Button(c, t.Dismiss).Ghost().Clicked() {
					c.After(func() {
						p.agent.err = ""
						p.agent.phase = agentPhaseReady
					})
				}
			})
		}
		a.agentConfigBar(c, p)
		a.agentTranscript(c, p)
		if p.agent.permission != nil {
			a.agentPermission(c, p)
		}
		ui.Column(c).FillWidth().Shrink(0).Gap(6).Pad(8).Children(func() {
			a.agentComposer(c, p)
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, a.agentStatusText(p)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).Ellipsis()
				if p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling {
					label := t.Stop
					if p.agent.phase == agentPhaseCancelling {
						label = t.Stopping
					}
					if ui.Button(c, label).Outline().Disabled(p.agent.phase == agentPhaseCancelling).Clicked() {
						c.After(func() { a.cancelAgentTurn(p) })
					}
				} else if ui.Button(c, t.Send).Disabled(!a.agentCanSend(p)).Clicked() {
					c.After(func() { a.sendAgentPrompt(p) })
				}
			})
		})
	})
}

// agentTranscript declares the messages. A List measures the rows it shows and estimates
// the rest, so a long conversation costs what the visible rows cost, and Follow keeps it
// at its end while a reply streams in until the user scrolls away.
func (a *App) agentTranscript(c ui.C, p *project) {
	t := a.text.Agent
	messages := p.agent.messages
	if len(messages) == 0 {
		ui.Column(c).Grow(1).Pad(8).Children(func() {
			ui.Paragraph(c, t.Empty, 3).Color(a.colors.Subtle)
		})
		return
	}
	assistantRole, _ := p.selectedAgent()
	ui.List(c, &p.agent.transcript, len(messages), func(row ui.ListRow) {
		message := messages[row.Index]
		role := t.RoleUser
		if message.Role == agentRoleAssistant {
			role = assistantRole.Name
			if role == "" {
				role = t.RoleAssistant
			}
		}
		ui.Column(row.C).FillWidth().Gap(2).PadY(4).Children(func() {
			ui.Text(row.C, role).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			ui.Wrap(row.C, message.Text).Color(a.colors.Text)
		})
	}).Grow(1).Pad(8).Follow(true)
}

// agentPermission asks the user to choose one of the Agent's own options. There is no
// default and no automatic answer.
func (a *App) agentPermission(c ui.C, p *project) {
	t := a.text.Agent
	permission := p.agent.permission
	ui.Column(c).FillWidth().Shrink(0).Gap(6).Pad(8).Background(a.colors.Active).Children(func() {
		ui.Text(c, t.PermissionTitle).Weight(gfx.WeightMedium).Color(a.colors.Text)
		if permission.Title != "" {
			ui.Paragraph(c, t.PermissionTool(permission.Title), 3).Color(a.colors.Text)
		}
		if len(permission.Options) == 0 {
			if ui.Button(c, t.Deny).Outline().Clicked() {
				c.After(func() { a.answerAgentPermission(p, "") })
			}
			return
		}
		for i, option := range permission.Options {
			if ui.Button(c.KeyInt(i), option.Name).Outline().Clicked() {
				c.After(func() { a.answerAgentPermission(p, option.OptionID) })
			}
		}
	})
}

// agentComposer declares the multiline message box. Enter is a new line, as in every
// Viva text area; Primary+Enter sends, as it does in the Commit message.
func (a *App) agentComposer(c ui.C, p *project) {
	t := a.text.Agent
	disabled := p.agent.phase == agentPhaseCancelling || p.agent.auth != agentAuthNone || p.agent.history.restoring()
	area := ui.TextArea(c, &p.agent.input, t.MessageLabel, t.Placeholder).FillWidth().Height(72).Disabled(disabled)
	if area.Shortcut(ui.Primary, "enter") {
		c.After(func() { a.sendAgentPrompt(p) })
	}
}

// agentIssueText localizes the panel's own discovery reasons. Upstream Core
// messages are returned unchanged.
func (a *App) agentIssueText(issue string) string {
	switch issue {
	case agentIssueHome:
		return a.text.Agent.ErrorHome
	case agentIssueConfigRead:
		return a.text.Agent.ErrorConfigRead
	case agentIssueInvalidConfig:
		return a.text.Agent.ErrorInvalidConfig
	case agentIssueUnsupportedAuth:
		return a.text.Agent.ErrorUnsupportedAuth
	case agentIssueCredential:
		return a.text.Agent.ErrorCredential
	case agentIssueCredentialUnsupported:
		return a.text.Agent.ErrorCredential
	}
	return issue
}
