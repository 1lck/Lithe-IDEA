package workbench

import (
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// agentAbsolutePath resolves a path a tool call reported against the project root when the
// Agent gave a relative one.
func agentAbsolutePath(p *project, path string) string {
	if filepath.IsAbs(path) || p == nil {
		return path
	}
	return filepath.Join(p.root, filepath.FromSlash(path))
}

// agentToolDetails declares the files a tool call touched, each opening in the editor, and its
// reported diffs, shown on request. The Agent's text is shown as it was written.
func (a *App) agentToolDetails(c ui.C, p *project, tool *agentToolCall) {
	if len(tool.Paths) == 0 && len(tool.Diffs) == 0 {
		return
	}
	t := a.text.Agent.ToolDetail
	ui.Column(c.Key("tool-details")).FillWidth().Shrink(0).Gap(4).Children(func() {
		for i, path := range tool.Paths {
			file := agentAbsolutePath(p, path)
			if ui.Button(c.KeyInt(i), filepath.Base(path)).Ghost().Clicked() {
				c.After(func() { a.openFile(p, file) })
			}
		}
		if len(tool.Diffs) > 0 {
			label := t.ShowDiff
			if tool.DiffOpen {
				label = t.HideDiff
			}
			if ui.Button(c.Key("tool-diff"), label).Ghost().Clicked() {
				c.After(func() { tool.DiffOpen = !tool.DiffOpen })
			}
		}
		if !tool.DiffOpen {
			return
		}
		for i, diff := range tool.Diffs {
			a.agentToolDiffView(c.KeyInt(1000+i), t, diff)
		}
	})
}

// agentToolDiffView shows one reported diff as the text before and after. The Agent reports
// excerpts, so the note says the file itself may be longer.
func (a *App) agentToolDiffView(c ui.C, t i18n.AgentToolDetailMessages, diff agentToolDiff) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Shrink(0).Gap(2).PadX(8).PadY(4).Background(a.colors.Active).Children(func() {
		ui.Text(c, filepath.Base(diff.Path)).FontSize(small).Weight(gfx.WeightMedium).Color(a.colors.Text).Ellipsis()
		ui.Paragraph(c, t.DiffNote, 2).FontSize(small).Color(a.colors.Subtle)
		ui.Text(c, t.DiffBefore).FontSize(small).Color(a.colors.Subtle)
		ui.Wrap(c, diff.OldText).FontSize(small).Color(a.colors.Text)
		ui.Text(c, t.DiffAfter).FontSize(small).Color(a.colors.Subtle)
		ui.Wrap(c, diff.NewText).FontSize(small).Color(a.colors.Text)
	})
}
