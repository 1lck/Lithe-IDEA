package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// agentProviderDetail shows the selected provider's configuration read-only: where it
// came from, its endpoint, model and protocol, and whether a key was found. The key itself
// is never shown, and editing stays in the user's own Codex or Claude configuration until
// Core offers a write path.
func (a *App) agentProviderDetail(c ui.C, provider agentProvider) {
	t := a.text.Agent.Provider
	if provider.Subscription {
		return
	}
	rows := [][2]string{{t.Source, provider.Source}}
	if provider.Endpoint != "" {
		rows = append(rows, [2]string{t.Endpoint, provider.Endpoint})
	}
	if provider.Model != "" {
		rows = append(rows, [2]string{t.Model, provider.Model})
	}
	if provider.Protocol != "" {
		rows = append(rows, [2]string{t.Protocol, provider.Protocol})
	}
	if provider.Authentication != "" {
		rows = append(rows, [2]string{t.Authentication, provider.Authentication})
	}
	key := t.KeyFound
	if provider.APIKey == "" {
		key = t.KeyMissing
	}
	rows = append(rows, [2]string{t.Key, key})
	ui.Column(c.Key("provider-detail")).FillWidth().Shrink(0).Gap(4).PadX(8).PadY(4).Children(func() {
		ui.Text(c, t.Detail).Weight(gfx.WeightMedium).Color(a.colors.Text)
		for i, row := range rows {
			ui.Row(c.KeyInt(i)).FillWidth().Shrink(0).Gap(8).Children(func() {
				ui.Text(c, row[0]).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Width(96)
				ui.Text(c, row[1]).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis().Grow(1)
			})
		}
		ui.Paragraph(c, t.ReadOnly, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
}
