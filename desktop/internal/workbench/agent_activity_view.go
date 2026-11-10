package workbench

import (
	"fmt"
	"strings"
	"time"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the Agent activity surfaces: tool and reasoning rows of the
// transcript, the strip above the composer (plan, subagents, context usage,
// statistics, quota), the slash completion list and the attached-file chips. State
// and decoding are in agent_activity.go; the strip only reads them.

// agentCompactCount writes a token count as 1.2k or 3.4M, the way a status line does.
func agentCompactCount(value uint64) string {
	switch {
	case value >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(value)/1e6)
	case value >= 1_000:
		return fmt.Sprintf("%.1fk", float64(value)/1e3)
	}
	return fmt.Sprintf("%d", value)
}

// agentUsagePercent is used/size as a whole percent, capped for display.
func agentUsagePercent(used, size uint64) int {
	if size == 0 {
		return 0
	}
	percent := int(float64(used) * 100 / float64(size))
	if percent > 999 {
		percent = 999
	}
	return percent
}

// agentToolStatusColor tints a tool status; unknown statuses stay quiet.
func (a *App) agentToolStatusColor(status string) gfx.Color {
	switch status {
	case "completed":
		return a.theme.Success
	case "failed":
		return a.theme.Danger
	}
	return a.colors.Subtle
}

// agentToggle declares a quiet expand/collapse control and reports a click on it.
func (a *App) agentToggle(c ui.C, label string) bool {
	return ui.Button(c, label).Ghost().Clicked()
}

// agentActivityRow declares a tool or reasoning row. Clicking its header opens or
// closes the details; the transcript list measures whichever height results.
func (a *App) agentActivityRow(c ui.C, p *project, index int, message agentMessage) {
	t := a.text.Agent
	switch message.Role {
	case agentRoleTool:
		tool := message.Tool
		if tool == nil {
			return
		}
		ui.Column(c).FillWidth().Gap(2).PadY(2).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, tool.Title).Ellipsis().Grow(1).Color(a.colors.Text)
				ui.Text(c, t.Activity.ToolStatus(tool.Status)).FontSize(a.theme.Metrics.FontSizeS).Color(a.agentToolStatusColor(tool.Status)).Shrink(0)
				if tool.Output != "" {
					label := t.Activity.Expand
					if tool.Expanded {
						label = t.Activity.Collapse
					}
					if a.agentToggle(c.Key("toggle"), label) {
						c.After(func() { tool.Expanded = !tool.Expanded })
					}
				}
			})
			if tool.Expanded && tool.Output != "" {
				ui.Wrap(c, tool.Output).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
		})
	case agentRoleThought:
		ui.Column(c).FillWidth().Gap(2).PadY(2).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, t.Activity.Thought).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1)
				label := t.Activity.Expand
				if message.Expanded {
					label = t.Activity.Collapse
				}
				if a.agentToggle(c.Key("toggle"), label) {
					c.After(func() {
						if index < len(p.agent.messages) {
							p.agent.messages[index].Expanded = !p.agent.messages[index].Expanded
						}
					})
				}
			})
			if message.Expanded {
				ui.Wrap(c, message.Text).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
		})
	}
}

// agentDeliveryText labels supplementary input's delivery state.
func (a *App) agentDeliveryText(d agentDelivery) string {
	t := a.text.Agent.Activity
	switch d {
	case agentDeliveryPending:
		return t.SteerPending
	case agentDeliveryReceived:
		return t.SteerReceived
	case agentDeliveryQueued:
		return t.SteerQueued
	case agentDeliveryFailed:
		return t.SteerFailed
	}
	return ""
}

// agentActivityStrip declares what the Agent reports about the open session above
// the composer. It declares nothing for a session with nothing to show.
func (a *App) agentActivityStrip(c ui.C, p *project) {
	act := &p.agent.activity
	t := a.text.Agent.Activity
	s := act.current(p.agent.sessionID)
	showQuota := act.quotaSeen
	if s == nil && !showQuota {
		return
	}
	small := a.theme.Metrics.FontSizeS
	ui.Column(c.Key("activity")).FillWidth().Shrink(0).Gap(2).PadX(8).PadY(2).Children(func() {
		if s != nil {
			a.agentPlanStrip(c, s, small)
			a.agentSubagentStrip(c, s, small)
			if s.usageKnown {
				ui.Text(c.Key("usage"), t.Context(agentCompactCount(s.used), agentCompactCount(s.size), fmt.Sprint(agentUsagePercent(s.used, s.size)))).
					FontSize(small).Color(a.agentUsageColor(agentUsagePercent(s.used, s.size)))
			}
			a.agentStatsStrip(c, s, small)
			if s.turnUsage != nil {
				ui.Text(c.Key("turnUsage"), t.TurnUsage(agentCompactCount(s.turnUsage.Total), agentCompactCount(s.turnUsage.Input), agentCompactCount(s.turnUsage.Output))).
					FontSize(small).Color(a.colors.Subtle)
			}
			if s.quiet {
				ui.Paragraph(c.Key("quiet"), t.Quiet, 2).FontSize(small).Color(a.colors.Warning)
			}
			if s.retrying {
				ui.Text(c.Key("retrying"), t.Retrying).FontSize(small).Color(a.colors.Warning)
			}
		}
		if showQuota {
			a.agentQuotaStrip(c, p, small)
		}
	})
}

// agentUsageColor follows the quota thresholds: green through 60%, yellow above
// that through 90%, red above 90%.
func (a *App) agentUsageColor(percent int) gfx.Color {
	switch {
	case percent > 90:
		return a.theme.Danger
	case percent > 60:
		return a.colors.Warning
	}
	return a.colors.Subtle
}

func (a *App) agentPlanStrip(c ui.C, s *agentSessionActivity, small float32) {
	if len(s.plan) == 0 {
		return
	}
	t := a.text.Agent.Activity
	done, current := 0, ""
	for _, entry := range s.plan {
		if entry.Status == "completed" {
			done++
		} else if current == "" && entry.Status == "in_progress" {
			current = entry.Content
		}
	}
	ui.Row(c.Key("plan")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.Text(c, t.Plan(fmt.Sprint(done), fmt.Sprint(len(s.plan)))).FontSize(small).Color(a.colors.Text).Shrink(0)
		ui.Text(c, current).FontSize(small).Color(a.colors.Subtle).Ellipsis().Grow(1)
		label := t.Expand
		if s.planOpen {
			label = t.Collapse
		}
		if a.agentToggle(c.Key("planToggle"), label) {
			c.After(func() { s.planOpen = !s.planOpen })
		}
	})
	if s.planOpen {
		for i, entry := range s.plan {
			ui.Row(c.KeyInt(i)).FillWidth().Gap(8).Children(func() {
				ui.Text(c, t.PlanStatus(entry.Status)).FontSize(small).Color(a.agentPlanColor(entry.Status)).Width(64).Shrink(0)
				ui.Paragraph(c, entry.Content, 3).FontSize(small).Color(a.colors.Text).Grow(1)
			})
		}
	}
}

func (a *App) agentPlanColor(status string) gfx.Color {
	if status == "completed" {
		return a.theme.Success
	}
	return a.colors.Subtle
}

func (a *App) agentSubagentStrip(c ui.C, s *agentSessionActivity, small float32) {
	if len(s.subagents) == 0 {
		return
	}
	t := a.text.Agent.Activity
	ui.Row(c.Key("subagents")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.Text(c, t.Subagents(fmt.Sprint(len(s.subagents)))).FontSize(small).Color(a.colors.Text).Grow(1)
		label := t.Expand
		if s.subagentsOp {
			label = t.Collapse
		}
		if a.agentToggle(c.Key("toggle"), label) {
			c.After(func() { s.subagentsOp = !s.subagentsOp })
		}
	})
	if !s.subagentsOp {
		return
	}
	for i, sub := range s.subagents {
		ui.Column(c.Key("sub/" + sub.ID)).FillWidth().Gap(2).PadY(2).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, sub.Name).FontSize(small).Color(a.colors.Text).Ellipsis().Grow(1)
				color := a.colors.Subtle
				switch sub.State {
				case "completed":
					color = a.theme.Success
				case "failed", "disconnected":
					color = a.theme.Danger
				}
				ui.Text(c, t.SubagentState(sub.State)).FontSize(small).Color(color).Shrink(0)
				label := t.Expand
				if sub.Expanded {
					label = t.Collapse
				}
				if a.agentToggle(c.KeyInt(i), label) {
					c.After(func() { sub.Expanded = !sub.Expanded })
				}
			})
			if sub.Expanded {
				if sub.Task != "" {
					ui.Paragraph(c, t.SubagentTask(sub.Task), 3).FontSize(small).Color(a.colors.Subtle)
				}
				for _, tool := range sub.Tools {
					ui.Text(c.Key("tool/"+tool.ID), tool.Title+" · "+t.ToolStatus(tool.Status)).FontSize(small).Color(a.colors.Subtle).Ellipsis()
				}
				if sub.Thought != "" {
					ui.Wrap(c.Key("thought"), sub.Thought).FontSize(small).Color(a.colors.Subtle)
				}
				if sub.Reply != "" {
					ui.Wrap(c.Key("reply"), sub.Reply).FontSize(small).Color(a.colors.Text)
				}
			}
		})
	}
}

func (a *App) agentStatsStrip(c ui.C, s *agentSessionActivity, small float32) {
	if !s.statsKnown {
		return
	}
	t := a.text.Agent.Activity
	st := s.stats
	ui.Row(c.Key("stats")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.Text(c, t.Statistics(fmt.Sprint(st.Steps), agentCompactCount(st.Input), agentCompactCount(st.CacheRead), agentCompactCount(st.Output))).
			FontSize(small).Color(a.colors.Subtle).Ellipsis().Grow(1)
		label := t.Expand
		if s.statsOpen {
			label = t.Collapse
		}
		if a.agentToggle(c.Key("toggle"), label) {
			c.After(func() { s.statsOpen = !s.statsOpen })
		}
	})
	if !s.statsOpen {
		return
	}
	if st.FirstTokenCount > 0 && st.GenerationMs > 0 {
		first := time.Duration(st.FirstTokenMs/st.FirstTokenCount) * time.Millisecond
		speed := float64(st.GeneratedTokens) * 1000 / float64(st.GenerationMs)
		ui.Text(c.Key("latency"), t.StatisticsLatency(first.String(), fmt.Sprintf("%.1f", speed))).FontSize(small).Color(a.colors.Subtle)
	}
	if st.FailedSteps > 0 {
		ui.Text(c.Key("failed"), t.StatisticsFailed(fmt.Sprint(st.FailedSteps))).FontSize(small).Color(a.colors.Warning)
	}
	if st.CallsWithUsage < st.Steps {
		ui.Paragraph(c.Key("lower"), t.StatisticsLowerBound, 2).FontSize(small).Color(a.colors.Subtle)
	}
}

func (a *App) agentQuotaStrip(c ui.C, p *project, small float32) {
	act := &p.agent.activity
	t := a.text.Agent.Activity
	if act.quotaFailed != "" {
		ui.Text(c.Key("quotaFailed"), t.QuotaFailed(act.quotaFailed)).FontSize(small).Color(a.colors.Subtle)
	}
	for _, window := range act.quota {
		line := t.Quota(window.Name, fmt.Sprintf("%.0f", window.UsedPercent))
		if window.ResetsAt > 0 {
			line += " · " + t.QuotaReset(time.Unix(window.ResetsAt, 0).Local().Format("01-02 15:04"))
		}
		ui.Text(c.Key("quota/"+window.ID), line).FontSize(small).Color(a.agentUsageColor(int(window.UsedPercent))).Ellipsis()
	}
	if ui.Button(c.Key("quotaRefresh"), t.QuotaRefresh).Ghost().Disabled(act.quotaPending).Clicked() {
		c.After(func() { a.refreshAgentQuota(p) })
	}
}

// agentSlashMenu declares the completion list above the composer. Choosing a row
// only fills the draft.
func (a *App) agentSlashMenu(c ui.C, p *project) {
	if trigger, _, ok := agentSlashTrigger(p.agent.editor.CommittedString()); ok && trigger == '$' {
		a.ensureAgentSkills(p)
	}
	candidates := a.agentSlashCandidates(p)
	if len(candidates) == 0 {
		return
	}
	t := a.text.Agent.Activity
	if len(candidates) > agentSlashMenuLimit {
		candidates = candidates[:agentSlashMenuLimit]
	}
	ui.Column(c.Key("slash")).FillWidth().Shrink(0).Gap(2).Pad(4).Background(a.colors.Active).Children(func() {
		for i, candidate := range candidates {
			label := candidate.Name
			if candidate.Hint != "" {
				label = t.CommandHint(candidate.Name, candidate.Hint)
			}
			if candidate.Description != "" {
				label += " · " + strings.TrimSpace(candidate.Description)
			}
			if ui.Button(c.KeyInt(i), label).Ghost().FillWidth().Clicked() {
				insert := candidate.Insert
				c.After(func() { a.chooseAgentSlash(p, insert) })
			}
		}
	})
}

// agentFileChips declares the attached files, each removable, and the entry that
// attaches the editor's current file.
func (a *App) agentFileChips(c ui.C, p *project) {
	t := a.text.Agent.Activity
	doc := p.selectedDocument(p.docs.group)
	if len(p.agent.files) == 0 && doc == nil {
		return
	}
	ui.Row(c.Key("files")).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
		for i, file := range p.agent.files {
			if ui.Button(c.KeyInt(i), t.AttachedFile(file.Name)).Outline().Label(t.RemoveFile(file.Name)).Clicked() {
				c.After(func() { a.removeAgentFile(p, i) })
			}
		}
		if doc != nil && ui.Button(c.Key("attach"), t.AttachCurrent).Ghost().Clicked() {
			path := doc.path
			c.After(func() { a.addAgentFiles(p, []string{path}) })
		}
	})
}

// agentArchivedSection declares the collapsed "Archived (N)" group of the history
// panel. Only Agents that report canListArchivedSessions have one.
func (a *App) agentArchivedSection(c ui.C, p *project) {
	s := &p.agent.history.archive
	if !s.canList {
		return
	}
	t := a.text.Agent.Activity
	small := a.theme.Metrics.FontSizeS
	ui.Column(c.Key("archived")).FillWidth().Shrink(0).Gap(2).PadX(shellContentPad).PadY(4).Children(func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, t.ArchivedTitle(fmt.Sprint(len(s.sessions)))).Color(a.colors.Text).Grow(1)
			label := t.Expand
			if s.open {
				label = t.Collapse
			}
			if a.agentToggle(c.Key("toggle"), label) {
				c.After(func() { a.toggleAgentArchived(p) })
			}
		})
		if !s.open {
			return
		}
		switch {
		case s.loading && len(s.sessions) == 0:
			ui.Text(c.Key("loading"), a.text.Agent.HistoryLoading).FontSize(small).Color(a.colors.Subtle)
		case s.failed:
			ui.Text(c.Key("failed"), t.ArchivedListFailed).FontSize(small).Color(a.theme.Danger)
		case len(s.sessions) == 0:
			ui.Text(c.Key("empty"), t.ArchivedEmpty).FontSize(small).Color(a.colors.Subtle)
		}
		for i, session := range s.sessions {
			title := session.Title
			if title == "" {
				title = a.text.Agent.Untitled
			}
			if updated := formatAgentHistoryTime(session.UpdatedAt); updated != "" {
				title += " · " + updated
			}
			ui.Row(c.Key("row/" + session.SessionID)).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, title).Ellipsis().Grow(1).Color(a.colors.Subtle)
				if ui.Button(c.KeyInt(i), t.ArchivedRestore).Outline().Disabled(s.unarchiveToken != "").Clicked() {
					id := session.SessionID
					c.After(func() { a.askAgentUnarchive(p, id) })
				}
			})
		}
		if s.incomplete {
			ui.Text(c.Key("incomplete"), t.ArchivedIncomplete).FontSize(small).Color(a.colors.Subtle)
		}
		if s.confirming != "" {
			name := s.confirming
			for _, session := range s.sessions {
				if session.SessionID == s.confirming && session.Title != "" {
					name = session.Title
				}
			}
			ui.Column(c.Key("confirm")).FillWidth().Gap(4).Pad(6).Background(a.colors.Active).Children(func() {
				ui.Paragraph(c, t.ArchivedConfirm(name), 3).Color(a.colors.Text)
				if s.unarchiveFailed {
					ui.Text(c.Key("restoreFailed"), t.ArchivedFailed).FontSize(small).Color(a.theme.Danger)
				}
				ui.Row(c).Gap(8).Children(func() {
					if ui.Button(c.Key("yes"), t.ArchivedRestore).Disabled(s.unarchiveToken != "").Clicked() {
						c.After(func() { a.confirmAgentUnarchive(p) })
					}
					if ui.Button(c.Key("no"), t.ArchivedCancel).Outline().Clicked() {
						c.After(func() { s.confirming, s.unarchiveFailed = "", false })
					}
				})
			})
		}
	})
}
