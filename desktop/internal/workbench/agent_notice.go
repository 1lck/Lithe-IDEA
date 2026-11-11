package workbench

import (
	"github.com/vivaui/viva/ui"
)

// autoFallbackTitle is the title Claude ACP gives its structured warning when Auto mode is
// unavailable. Claude reports no code for it, so the title is matched only on that Agent's
// warning and never on assistant text (macOS rule).
const (
	autoFallbackTitle = "Auto mode unavailable"
	autoModeValue     = "auto"
	acceptEditsValue  = "acceptEdits"
)

// agentNotice is one live advisory. Titles and details are the Agent's words and are shown as
// it wrote them.
type agentNotice struct {
	Severity string
	Title    string
	Detail   string
}

// isAutoFallback says the notice is Claude's warning that Auto mode fell back to Accept edits.
func (n agentNotice) isAutoFallback() bool {
	return n.Severity == "warning" && n.Title == autoFallbackTitle
}

// applyAgentNotice keeps the latest notice of the session. An empty title is ignored.
func (a *App) applyAgentNotice(p *project, update agentUpdateWire) {
	if update.Title == "" {
		return
	}
	p.agent.notice = &agentNotice{Severity: update.Severity, Title: update.Title, Detail: update.Description}
}

// reconcileAgentNotice drops a notice the confirmed configuration has made stale. An Auto
// fallback warning does not survive a mode other than Accept edits, so it never covers Plan.
// Any notice is dropped when the model changes, since it was about the previous model.
func (a *App) reconcileAgentNotice(p *project, previous, current []agentConfigOption) {
	if p == nil || p.agent.notice == nil || len(previous) == 0 {
		return
	}
	if mode := agentOptionValue(current, "mode"); mode != "" && mode != acceptEditsValue && p.agent.notice.isAutoFallback() {
		p.agent.notice = nil
		return
	}
	before, after := agentOptionValue(previous, "model"), agentOptionValue(current, "model")
	if before != "" && after != "" && before != after {
		p.agent.notice = nil
	}
}

// agentOptionValue is the confirmed value of the first option of category, or "" if none.
func agentOptionValue(options []agentConfigOption, category string) string {
	for _, option := range options {
		if option.Category == category {
			return option.Current
		}
	}
	return ""
}

// agentNoticeBanner shows the session's latest advisory above the transcript, with a dismiss
// control. It is not part of the transcript and disappears on the next prompt.
func (a *App) agentNoticeBanner(c ui.C, p *project) {
	n := p.agent.notice
	if n == nil {
		return
	}
	color := a.colors.Text
	switch n.Severity {
	case "error":
		color = a.theme.Danger
	case "warning":
		color = a.colors.Warning
	}
	ui.Row(c.Key("notice")).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Pad(8).Background(a.colors.Active).Children(func() {
		ui.Column(c).Grow(1).Gap(2).Children(func() {
			ui.Paragraph(c, n.Title, 2).Color(color)
			if n.Detail != "" {
				ui.Paragraph(c, n.Detail, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
		})
		if ui.Button(c, a.text.Agent.Dismiss).Ghost().Clicked() {
			c.After(func() { p.agent.notice = nil })
		}
	})
}
