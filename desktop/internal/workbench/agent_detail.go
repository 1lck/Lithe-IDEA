package workbench

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the session-detail sidebar that sits beside the conversation when it
// is an editor tab: the context usage, the files the current turn changed (each opening its
// Git diff) and the session statistics. The numbers are the Agent's own reports read from
// agentSessionActivity and the transcript; nothing is estimated here.

const (
	// agentDetailWidth is the sidebar's fixed width; agentDetailClosedWidth is the strip left
	// when it is folded away.
	agentDetailWidth       = 280
	agentDetailClosedWidth = 40
)

// agentDetailSide declares the sidebar, or the strip that opens it. It appears only while
// the conversation is connected, because a welcome or setup page has nothing to report.
func (a *App) agentDetailSide(c ui.C, p *project) {
	t := a.text.Agent.Detail
	if !p.agent.detailOpen {
		ui.Column(c.Key("detail-closed")).Width(agentDetailClosedWidth).Shrink(0).PadY(8).Items(ui.Center).Children(func() {
			if ui.Button(c.Key("detail-show"), t.Show).Ghost().Clicked() {
				c.After(func() { p.agent.detailOpen = true })
			}
		})
		return
	}
	small := a.theme.Metrics.FontSizeS
	ui.Column(c.Key("detail")).Width(agentDetailWidth).Shrink(0).Fill().Children(func() {
		ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(12).PadY(8).Children(func() {
			ui.Text(c, t.Title).Weight(gfx.WeightMedium).Color(a.colors.Text).Grow(1).Ellipsis()
			if ui.Button(c.Key("detail-hide"), t.Hide).Ghost().Clicked() {
				c.After(func() { p.agent.detailOpen = false })
			}
		})
		ui.Scroll(c.Key("detail-scroll")).Grow(1).Fill().Children(func() {
			ui.Column(c.Key("detail-body")).FillWidth().Gap(16).PadX(12).PadY(8).Children(func() {
				s := p.agent.activity.current(p.agent.sessionID)
				a.agentDetailContext(c, s, small)
				a.agentDetailChanges(c, p, small)
				a.agentDetailStatistics(c, p, s, small)
			})
		})
	})
}

// agentDetailSection declares a section heading; the caller declares the rows under it.
func (a *App) agentDetailSection(c ui.C, title string) {
	ui.Text(c, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightMedium).Color(a.colors.Text)
}

// agentDetailContext declares the context usage the Agent reported, with its breakdown when
// the Agent sent one.
func (a *App) agentDetailContext(c ui.C, s *agentSessionActivity, small float32) {
	t := a.text.Agent.Detail
	ui.Column(c.Key("context")).FillWidth().Gap(4).Children(func() {
		a.agentDetailSection(c, t.Context)
		if s == nil || !s.usageKnown || s.size == 0 {
			ui.Text(c, t.ContextUnknown).FontSize(small).Color(a.colors.Subtle)
			return
		}
		percent := agentUsagePercent(s.used, s.size)
		ui.Text(c.Key("used"), t.ContextUsed(agentCompactCount(s.used), agentCompactCount(s.size), fmt.Sprint(percent))).
			FontSize(small).Color(a.agentUsageColor(percent))
		ui.Progress(c.Key("bar"), float32(min(percent, 100))/100).FillWidth()
		if s.statsKnown && s.stats.Context != nil {
			ctx := s.stats.Context
			rows := []struct {
				label  string
				tokens uint64
			}{
				{t.ContextSystem, ctx.SystemPromptTokens},
				{t.ContextTools, ctx.ToolTokens + ctx.MCPToolTokens},
				{t.ContextMessage, ctx.MessageTokens},
			}
			for i, row := range rows {
				ui.Row(c.KeyInt(i)).FillWidth().Gap(8).Children(func() {
					ui.Text(c, row.label).FontSize(small).Color(a.colors.Subtle).Grow(1)
					ui.Text(c, agentCompactCount(row.tokens)).FontSize(small).Color(a.colors.Text).Shrink(0)
				})
			}
		}
	})
}

// agentDetailChanges declares the files changed since the user's last message. Each opens its
// Git diff in the editor; a file outside the repository opens as a plain file.
func (a *App) agentDetailChanges(c ui.C, p *project, small float32) {
	t := a.text.Agent.Detail
	paths := agentTurnPaths(p.agent.messages)
	ui.Column(c.Key("changes")).FillWidth().Gap(4).Children(func() {
		a.agentDetailSection(c, t.Changes)
		if len(paths) == 0 {
			ui.Text(c, t.ChangesNone).FontSize(small).Color(a.colors.Subtle)
			return
		}
		for i, path := range paths {
			if ui.Button(c.KeyInt(i), path).Ghost().FillWidth().Clicked() {
				c.After(func() { a.openAgentChangedFile(p, path) })
			}
		}
	})
}

// agentDetailStatistics declares the session counters: turns, tool calls, duration and tokens.
func (a *App) agentDetailStatistics(c ui.C, p *project, s *agentSessionActivity, small float32) {
	t := a.text.Agent.Detail
	turns, tools := 0, 0
	for _, message := range p.agent.messages {
		switch message.Role {
		case agentRoleUser:
			turns++
		case agentRoleTool:
			tools++
		}
	}
	ui.Column(c.Key("statistics")).FillWidth().Gap(4).Children(func() {
		a.agentDetailSection(c, t.Statistics)
		ui.Row(c.Key("turns")).FillWidth().Gap(8).Children(func() {
			ui.Text(c, t.Turns).FontSize(small).Color(a.colors.Subtle).Grow(1)
			ui.Text(c, fmt.Sprint(turns)).FontSize(small).Color(a.colors.Text).Shrink(0)
		})
		ui.Row(c.Key("tools")).FillWidth().Gap(8).Children(func() {
			ui.Text(c, t.ToolCalls).FontSize(small).Color(a.colors.Subtle).Grow(1)
			ui.Text(c, fmt.Sprint(tools)).FontSize(small).Color(a.colors.Text).Shrink(0)
		})
		if s == nil || !s.statsKnown {
			ui.Text(c.Key("none"), t.NoStatistics).FontSize(small).Color(a.colors.Subtle)
			return
		}
		st := s.stats
		ui.Row(c.Key("duration")).FillWidth().Gap(8).Children(func() {
			ui.Text(c, t.Duration).FontSize(small).Color(a.colors.Subtle).Grow(1)
			ui.Text(c, (time.Duration(st.DurationMs) * time.Millisecond).Round(time.Second).String()).FontSize(small).Color(a.colors.Text).Shrink(0)
		})
		ui.Paragraph(c.Key("tokens"), t.Tokens(agentCompactCount(st.Input), agentCompactCount(st.Output), agentCompactCount(st.CacheRead)), 2).
			FontSize(small).Color(a.colors.Subtle)
	})
}

// agentTurnPaths lists the files the tool calls after the last user message reported, once
// each, in the order they were first touched.
func agentTurnPaths(messages []agentMessage) []string {
	start := 0
	for i, message := range messages {
		if message.Role == agentRoleUser {
			start = i + 1
		}
	}
	seen := map[string]bool{}
	var paths []string
	add := func(path string) {
		if path == "" || seen[path] {
			return
		}
		seen[path] = true
		paths = append(paths, path)
	}
	for _, message := range messages[start:] {
		if message.Role != agentRoleTool || message.Tool == nil {
			continue
		}
		for _, path := range message.Tool.Paths {
			add(path)
		}
		for _, diff := range message.Tool.Diffs {
			add(diff.Path)
		}
	}
	return paths
}

// openAgentChangedFile opens the Git diff of a changed file when it lies in the project's
// repository, and the file itself otherwise.
func (a *App) openAgentChangedFile(p *project, path string) {
	abs := agentAbsolutePath(p, path)
	root := p.git.repositoryRoot(p.root)
	rel, err := filepath.Rel(root, abs)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		a.openFile(p, abs)
		return
	}
	// The Git status says what the change is (added, untracked, modified, ...). A file the status
	// no longer lists has no diff to show, so the file opens instead.
	change, found := p.git.changeAt(filepath.ToSlash(rel))
	if !found {
		a.openFile(p, abs)
		return
	}
	a.openDiff(p, change)
}
