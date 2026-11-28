package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// agentsPage is the Agents page under AI: one switch per plugin that asks to read the session
// files its agents' CLIs write. Lithe reads none of them until the user turns a switch on, and
// turning it off drops what Lithe cached from them. A separate switch lets the MCP clients of
// an IDE connection search the sessions the user allowed.
func (w *window) agentsPage(c ui.C) {
	loader := w.ctrl.opts.Agents
	st := loader.State()
	lang := w.marketLanguage()
	p := &w.pal
	w.pageScroll(c, pageAgents, func() {
		ui.Wrap(c, i18n.Shared(lang, "desktop.agents.settings.intro")).FontSize(12).Color(p.muted)
		w.card(c, i18n.Shared(lang, "desktop.agents.settings.readSessions"), i18n.Shared(lang, "desktop.agents.settings.readSessionsHelp"), func() {
			ui.Column(c).FillWidth().Gap(10).Children(func() {
				switch {
				case !st.Loaded:
					ui.Text(c, i18n.Shared(lang, "desktop.agents.history.loading")).FontSize(12).Color(p.muted)
					return
				case len(st.Plugins) == 0:
					ui.Wrap(c, i18n.Shared(lang, "desktop.agents.settings.noPlugins")).FontSize(12).Color(p.muted)
					return
				}
				for _, plugin := range st.Plugins {
					w.agentSessionPlugin(c.Key(plugin.PluginID), lang, loader, plugin)
				}
			})
		})
		if st.Loaded && len(st.Plugins) > 0 {
			w.card(c, i18n.Shared(lang, "desktop.agents.settings.mcpSearch"), i18n.Shared(lang, "desktop.agents.settings.mcpSearchHelp"), func() {
				allowed := st.MCPSearch
				ui.Switch(c.Key("mcpSearch"), &allowed, i18n.Shared(lang, "desktop.agents.settings.mcpSearchSwitch"))
				if allowed != st.MCPSearch {
					c.After(func() { loader.SetMCPSearch(allowed) })
				}
			})
		}
		if st.Error != "" {
			ui.Wrap(c, i18n.SharedFormat(lang, "desktop.agents.settings.failed", map[string]string{"reason": st.Error})).FontSize(12).Color(p.muted)
		}
	})
}

// agentSessionPlugin is one plugin's switch, its agents and, behind ⓘ, the directories it
// would read.
func (w *window) agentSessionPlugin(c ui.C, lang i18n.Language, loader AgentSessionsLoader, plugin AgentSessionPlugin) {
	p := &w.pal
	ui.Column(c).FillWidth().Gap(2).Children(func() {
		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			allowed := plugin.Allowed
			ui.Switch(c.Key("allow"), &allowed, plugin.Name)
			if allowed != plugin.Allowed {
				id := plugin.PluginID
				c.After(func() { loader.SetAllowed(id, allowed) })
			}
			if len(plugin.Roots) > 0 {
				w.infoButton(c, i18n.SharedFormat(lang, "desktop.agents.settings.roots", map[string]string{"roots": strings.Join(plugin.Roots, "\n")}))
			}
		})
		if len(plugin.Agents) > 0 {
			ui.Text(c, strings.Join(plugin.Agents, ", ")).FontSize(11).Color(p.muted).Ellipsis()
		}
	})
}
