package workbench

import (
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Agent panel's identities. They live in one block so the panel can be
// tested by the same labels and hit targets it paints.
var (
	agentSetupScroll     = tree.ID(shellPage, "agent-setup")
	agentChoice          = tree.Sub(shellPage, tree.Name("agent-choice"))
	agentProviderChoice  = tree.Sub(shellPage, tree.Name("agent-provider"))
	agentStart           = tree.ID(shellPage, "agent-start")
	agentRetry           = tree.ID(shellPage, "agent-retry")
	agentChange          = tree.ID(shellPage, "agent-change")
	agentTranscript      = tree.ID(shellPage, "agent-transcript")
	agentInput           = tree.ID(shellPage, "agent-input")
	agentSend            = tree.ID(shellPage, "agent-send")
	agentStop            = tree.ID(shellPage, "agent-stop")
	agentPermissionScope = tree.Sub(shellPage, tree.Name("agent-permission"))
	agentInstall         = tree.Sub(shellPage, tree.Name("agent-install"))
	agentInstallCancel   = tree.ID(shellPage, "agent-install-cancel")
	agentInstallRetry    = tree.ID(shellPage, "agent-install-retry")
	agentDismissError    = tree.ID(shellPage, "agent-dismiss-error")
)

// agentView is the window's state of the Agent panel that is not the project's:
// the native editor behind the composer and the measured rows of the virtual
// transcript window.
type agentView struct {
	input app.TextInput
	// measured lists the message rows painted in the frame being declared, so
	// capture can replace their estimated heights with the laid out ones.
	measured []agentMeasure
}

type agentMeasure struct {
	index int
	box   ui.Box
}

func (v *agentView) beginFrame() { v.measured = v.measured[:0] }

// capture records the real heights of the rows painted this frame. The next
// frame uses them to place the virtual window; a new or streaming message has
// height zero and is estimated until it is painted.
func (v *agentView) capture(state *agentState) {
	for _, measure := range v.measured {
		if measure.index < len(state.messages) {
			if height := measure.box.Rect().Height; height > 0 {
				state.messages[measure.index].height = height
			}
		}
	}
	v.measured = v.measured[:0]
}

// agentMessageHeight is the measured height or a conservative estimate for a
// row that has not been painted yet. The estimate over-counts lines so the
// scrollbar is never shorter than the content.
func agentMessageHeight(message agentMessage) float32 {
	if message.height > 0 {
		return message.height
	}
	lines, column := 1, 0
	for _, r := range message.Text {
		if r == '\n' {
			lines, column = lines+1, 0
			continue
		}
		column++
		if column >= 20 {
			lines, column = lines+1, 0
		}
	}
	height := 20 + float32(lines)*18
	return min(max(height, 36), 4000)
}

// agentVisibleRange returns the first and last message index to paint and the
// estimated room of the rows before and after them. One row is painted beyond
// each edge so scrolling reveals the next message without a blank frame.
func agentVisibleRange(messages []agentMessage, offset, viewport float32) (first, last int, before, after float32) {
	if len(messages) == 0 {
		return 0, 0, 0, 0
	}
	if viewport <= 0 {
		viewport = 400
	}
	y := float32(0)
	for first < len(messages) {
		height := agentMessageHeight(messages[first])
		if y+height >= offset {
			break
		}
		y += height
		first++
	}
	if first > 0 {
		first--
		y -= agentMessageHeight(messages[first])
	}
	last = first
	end := y
	for last < len(messages) && end < offset+viewport {
		end += agentMessageHeight(messages[last])
		last++
	}
	if last < len(messages) {
		last++
	}
	if last == first {
		last++
	}
	for i := 0; i < first; i++ {
		before += agentMessageHeight(messages[i])
	}
	for i := last; i < len(messages); i++ {
		after += agentMessageHeight(messages[i])
	}
	return first, last, before, after
}

// drawAgentPanel declares the AI Assistant tool window's body: provider
// selection while no connection is open, then the conversation.
func (a *App) drawAgentPanel(f *ui.Frame, p *project) {
	if !a.agentKernelReady() {
		f.Row().Fill().Items(ui.Center).PadX(shellContentPad).Children(func() {
			f.Paragraph(a.text.Panel.Placeholder, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
		})
		return
	}
	a.ensureAgentState(p)
	if p.agent.conn == nil {
		a.drawAgentSetup(f, p)
		return
	}
	a.drawAgentConversation(f, p)
}

// drawAgentSetup lists the installed adapters and the providers discovered in
// the user's own Codex and Claude configuration. It never invents a provider.
func (a *App) drawAgentSetup(f *ui.Frame, p *project) {
	t := a.text.Agent
	f.ScrollArea(agentSetupScroll).Fill().Children(func() {
		f.Column().FillWidth().Shrink(0).Gap(8).Pad(shellContentPad).Children(func() {
			if p.agent.phase == agentPhaseLoading {
				f.Text(t.Checking).Color(a.colors.Subtle)
				return
			}
			if p.agent.statusErr != "" {
				f.Paragraph(p.agent.statusErr, 4).Color(a.theme.Danger)
				if f.Button(agentRetry, t.CheckAgain).Outline().Clicked() {
					p.agent.statusLoaded = false
					p.agent.statusErr = ""
					p.agent.providerErr = map[string]string{}
					a.ensureAgentState(p)
				}
				return
			}
			if p.agent.err != "" {
				f.Paragraph(p.agent.err, 4).Color(a.theme.Danger)
			}
			if p.agent.connecting {
				f.Text(t.StatusStarting).Color(a.colors.Subtle)
			}
			if len(p.agent.agents) == 0 {
				f.Paragraph(t.NoAgents, 4).Color(a.colors.Subtle)
				return
			}

			f.Text(t.AgentLabel).Weight(gfx.WeightMedium).Color(a.colors.Text)
			for i, agent := range p.agent.agents {
				installed := agent.InstalledVersion != nil
				label := agent.Name
				if installed {
					label += " · " + *agent.InstalledVersion
				} else {
					label += " · " + t.NotInstalled
				}
				row := f.Row().FillWidth().Height(rowHeight+6).Shrink(0).Items(ui.Center).PadX(8).
					Radius(a.theme.Metrics.RadiusItem()).
					HitWith(agentChoice.At(i), label, gfx.HitOptions{
						Role: gfx.RoleRadio, Selected: i == p.agent.selected,
						Disabled: !installed, Cursor: gfx.PointerCursorHand,
					}).
					Hover(ui.Look{}.Background(a.colors.Hover))
				if i == p.agent.selected {
					row = row.Background(a.colors.Active)
				}
				row.Children(func() {
					f.Text(label).Ellipsis().Color(a.colors.Text)
				})
				if row.Clicked() && installed {
					p.agent.selected = i
					p.agent.selectedProvider = 0
				}
				for _, issue := range agent.Issues {
					f.Paragraph(issue, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				}
				if !installed {
					a.drawAgentInstall(f, p, i, agent)
				}
			}

			agent, ok := p.selectedAgent()
			if !ok {
				return
			}
			f.Text(t.ProviderLabel).Weight(gfx.WeightMedium).Color(a.colors.Text)
			for _, source := range agentProviderSources() {
				if issue := p.agent.providerErr[source]; issue != "" {
					f.Paragraph(t.ErrorProvider(a.agentIssueText(issue)), 4).Color(a.theme.Danger)
					if f.Button(agentRetry, t.CheckAgain).Outline().Clicked() {
						p.agent.statusLoaded = false
						p.agent.statusErr = ""
						p.agent.providerErr = map[string]string{}
						a.ensureAgentState(p)
					}
					break
				}
			}
			providers := p.providersForAgent(agent)
			if len(providers) == 0 {
				f.Paragraph(t.NoProviders, 4).Color(a.colors.Subtle)
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
				row := f.Row().FillWidth().Height(rowHeight+6).Shrink(0).Items(ui.Center).PadX(8).
					Radius(a.theme.Metrics.RadiusItem()).
					HitWith(agentProviderChoice.At(i), label, gfx.HitOptions{
						Role: gfx.RoleRadio, Selected: i == p.agent.selectedProvider,
						Disabled: disabled, Cursor: gfx.PointerCursorHand,
					}).
					Hover(ui.Look{}.Background(a.colors.Hover))
				if i == p.agent.selectedProvider {
					row = row.Background(a.colors.Active)
				}
				row.Children(func() {
					f.Text(label).Ellipsis().Color(a.colors.Text)
				})
				if row.Clicked() && !disabled {
					p.agent.selectedProvider = i
				}
				switch {
				case provider.MissingKey:
					f.Text(t.MissingKey).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
				case provider.Issue != "":
					f.Text(t.ProviderUnsupported(a.agentIssueText(provider.Issue))).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
				}
			}

			start := f.Button(agentStart, t.Start).Disabled(!p.canStartAgent() || p.agent.connecting)
			if start.Clicked() {
				a.startAgent(p)
			}
		})
	})
}

// drawAgentInstall declares the explicit install entry for one adapter, the
// live progress of an install in flight, and its failure/retry state. Opening
// the panel only reads status; this control is the only way an install starts.
func (a *App) drawAgentInstall(f *ui.Frame, p *project, index int, agent core.AgentCatalogStatus) {
	t := a.text.Agent
	if p.agent.installing == agent.ID {
		progress := p.agent.installProgress
		f.Column().FillWidth().Shrink(0).Gap(4).PadX(8).PadY(4).Children(func() {
			f.Text(a.agentInstallStage(progress.Stage)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			if progress.DownloadedBytes > 0 || progress.BytesPerSecond > 0 {
				f.Text(t.InstallProgress(agentFormatBytes(progress.DownloadedBytes), agentFormatBytes(progress.BytesPerSecond), agentFormatDuration(progress.ElapsedMilliseconds))).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
			if progress.IdleMilliseconds >= 2000 {
				f.Text(t.InstallWaiting).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
			}
			label := t.InstallCancel
			if p.agent.installCancelling {
				label = t.InstallCancelling
			}
			if f.Button(agentInstallCancel, label).Outline().Disabled(p.agent.installCancelling).Clicked() {
				a.cancelAgentInstall(p)
			}
		})
		return
	}
	disabled := p.agent.installing != ""
	if f.Button(agentInstall.At(index), t.Install).Outline().Disabled(disabled).Clicked() {
		a.installAgent(p, agent.ID)
	}
	if p.agent.lastInstall == agent.ID && p.agent.installErr != "" {
		f.Paragraph(p.agent.installErr, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		if f.Button(agentInstallRetry, t.InstallRetry).Outline().Disabled(disabled).Clicked() {
			a.installAgent(p, agent.ID)
		}
	}
	if p.agent.lastInstall == agent.ID && p.agent.installWarning != "" {
		f.Paragraph(p.agent.installWarning, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
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

// drawAgentConversation declares the transcript, the pending permission card
// and the composer. The transcript is virtualized only by its scroll area; the
// message list itself is bounded in agent.go.
func (a *App) drawAgentConversation(f *ui.Frame, p *project) {
	t := a.text.Agent
	f.Column().Fill().Children(func() {
		a.drawAgentConversationHeader(f, p)
		if p.agent.history.open {
			a.drawAgentHistoryPanel(f, p)
			return
		}
		if p.agent.err != "" {
			f.Row().FillWidth().Shrink(0).Items(ui.Center).Gap(6).Pad(8).Background(a.colors.Active).Children(func() {
				f.Paragraph(p.agent.err, 4).Grow(1).Color(a.colors.Text)
				if f.Button(agentDismissError, t.Dismiss).Ghost().Clicked() {
					p.agent.err = ""
					p.agent.phase = agentPhaseReady
				}
			})
		}
		a.drawAgentConfigBar(f, p)
		scroll := a.view.ScrollState(agentTranscript)
		first, last, before, after := agentVisibleRange(p.agent.messages, scroll.Offset, scroll.Viewport)
		assistantRole, _ := p.selectedAgent()
		f.ScrollArea(agentTranscript).Grow(1).Pad(8).Follow(true).Children(func() {
			if len(p.agent.messages) == 0 {
				f.Paragraph(t.Empty, 3).Color(a.colors.Subtle)
				return
			}
			if before > 0 {
				f.Row().Height(before).Shrink(0)
			}
			for i := first; i < last && i < len(p.agent.messages); i++ {
				message := p.agent.messages[i]
				role := t.RoleUser
				if message.Role == agentRoleAssistant {
					role = assistantRole.Name
					if role == "" {
						role = t.RoleAssistant
					}
				}
				row := f.Column().FillWidth().Shrink(0).Gap(2).PadY(4)
				row.Children(func() {
					f.Text(role).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
					f.Wrap(message.Text).Color(a.colors.Text)
				})
				a.agentView.measured = append(a.agentView.measured, agentMeasure{index: i, box: row})
			}
			if after > 0 {
				f.Row().Height(after).Shrink(0)
			}
		})
		if p.agent.permission != nil {
			a.drawAgentPermission(f, p)
		}
		f.Column().FillWidth().Shrink(0).Gap(6).Pad(8).Children(func() {
			a.drawAgentComposer(f, p)
			f.Row().FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				f.Text(a.agentStatusText(p)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).Ellipsis()
				if p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling {
					label := t.Stop
					if p.agent.phase == agentPhaseCancelling {
						label = t.Stopping
					}
					if f.Button(agentStop, label).Outline().Disabled(p.agent.phase == agentPhaseCancelling).Clicked() {
						a.cancelAgentTurn(p)
					}
				} else {
					if f.Button(agentSend, t.Send).Disabled(!a.agentCanSend(p)).Clicked() {
						a.sendAgentPrompt(p)
					}
				}
			})
		})
	})
}

// drawAgentPermission asks the user to choose one of the Agent's own options.
// There is no default and no automatic answer.
func (a *App) drawAgentPermission(f *ui.Frame, p *project) {
	t := a.text.Agent
	permission := p.agent.permission
	f.Column().FillWidth().Shrink(0).Gap(6).Pad(8).Background(a.colors.Active).Children(func() {
		f.Text(t.PermissionTitle).Weight(gfx.WeightMedium).Color(a.colors.Text)
		if permission.Title != "" {
			f.Paragraph(t.PermissionTool(permission.Title), 3).Color(a.colors.Text)
		}
		if len(permission.Options) == 0 {
			if f.Button(agentPermissionScope.At(0), t.Deny).Outline().Clicked() {
				a.answerAgentPermission(p, "")
			}
			return
		}
		for i, option := range permission.Options {
			if f.Button(agentPermissionScope.At(i), option.Name).Outline().Clicked() {
				a.answerAgentPermission(p, option.OptionID)
			}
		}
	})
}

// drawAgentComposer declares the multiline message box.
func (a *App) drawAgentComposer(f *ui.Frame, p *project) {
	value := p.agent.editor.String()
	selection := p.agent.editor.Selection()
	snapshot := components.TextareaSnapshot{
		ID:             agentInput,
		Label:          a.text.Agent.MessageLabel,
		Value:          value,
		Placeholder:    a.text.Agent.Placeholder,
		Disabled:       p.agent.phase == agentPhaseCancelling || p.agent.auth != agentAuthNone || p.agent.history.restoring(),
		HideEditorText: true,
		ShowCaret:      true,
		Layout:         p.agent.layout,
		Caret:          byteOffsetOfRune(value, p.agent.editor.Caret()),
		SelectionStart: byteOffsetOfRune(value, selection.Start),
		SelectionEnd:   byteOffsetOfRune(value, selection.End),
	}
	if composition, ok := p.agent.editor.Composition(); ok {
		snapshot.CompositionStart = byteOffsetOfRune(value, composition.Start)
		snapshot.CompositionEnd = byteOffsetOfRune(value, composition.End)
	}
	f.Textarea(snapshot).FillWidth().Height(72)
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

// agentTextInput connects the composer's native editor to the project's
// text.Editor, as the Commit message box does.
func (a *App) agentTextInput(ctx app.TextInputContext) *app.TextInput {
	p := a.project
	if p == nil || ctx.ID != agentInput {
		return nil
	}
	input := &a.agentView.input
	input.Editor = nil
	input.State = app.TextStateOf(p.agent.editor)
	input.OnEvent = func(event app.TextEvent) (app.TextState, error) {
		if event.Kind == app.TextCommandEvent && event.Command == app.TextInsertNewline && a.agentCanSend(p) {
			a.sendAgentPrompt(p)
		} else {
			event.Apply(p.agent.editor)
		}
		return app.TextStateOf(p.agent.editor), nil
	}
	return input
}
