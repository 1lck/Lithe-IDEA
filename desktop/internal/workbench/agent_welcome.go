package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// agentWelcome declares the page shown until an Agent is chosen: a banner, the built-in
// Agents, the Agents that need the settings, and the third-party provider entry. Choosing a
// built-in Agent opens its setup with that Agent selected; the other rows open AI settings.
func (a *App) agentWelcome(c ui.C, p *project) {
	t := a.text.Agent.Welcome
	ui.Scroll(c).Fill().Children(func() {
		ui.Column(c).FillWidth().Shrink(0).Gap(20).Pad(shellContentPad).Children(func() {
			ui.Text(c, t.Title).Weight(gfx.WeightMedium).FontSize(a.theme.Metrics.FontSizeL).Color(a.colors.Text)
			ui.Column(c).FillWidth().Shrink(0).Gap(4).Pad(12).Background(a.colors.Active).Radius(a.theme.Metrics.RadiusItem()).Children(func() {
				ui.Text(c, t.BannerTitle).Weight(gfx.WeightMedium).Color(a.colors.Text)
				ui.Paragraph(c, t.BannerBody, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			})
			ui.Text(c, t.ChooseAgent).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			ui.Column(c).FillWidth().Shrink(0).Gap(6).Children(func() {
				if ui.Button(c.Key("welcome-codex"), t.Codex).Outline().FillWidth().Icon(a.agentBrandIcon("codex-acp")).Clicked() {
					c.After(func() { a.chooseWelcomeAgent(p, "codex-acp") })
				}
				if ui.Button(c.Key("welcome-claude"), t.Claude).Outline().FillWidth().Icon(a.agentBrandIcon("claude-acp")).Clicked() {
					c.After(func() { a.chooseWelcomeAgent(p, "claude-acp") })
				}
				if ui.Button(c.Key("welcome-more"), t.MoreAgents).Outline().FillWidth().Icon(icons.Sparkles).Tooltip(t.MoreSubtitle).Clicked() {
					c.After(func() { a.openSettingsPage(surfaceButton, settingsAI) })
				}
			})
			ui.Text(c, t.ProviderTitle).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			if ui.Button(c.Key("welcome-providers"), t.ProviderButton).Outline().FillWidth().Icon(icons.Settings).Clicked() {
				c.After(func() { a.openSettingsPage(surfaceButton, settingsAI) })
			}
		})
	})
}

// chooseWelcomeAgent selects the Agent the welcome page named and shows its setup. The setup
// then starts the conversation with the provider that is selected there.
func (a *App) chooseWelcomeAgent(p *project, agentID string) {
	for i, agent := range p.agent.agents {
		if agent.ID == agentID {
			p.agent.selected = i
			p.agent.selectedProvider = 0
		}
	}
	p.agent.chosen = true
}
