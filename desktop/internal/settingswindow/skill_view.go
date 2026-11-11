package settingswindow

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// skillRow is one skill of the list: its name and scope, the native switch, the SKILL.md viewer
// and the reveal action.
func (w *window) skillRow(c ui.C, index int, skill core.AgentSkill, busy bool) {
	s := w.agent
	language := w.marketLanguage()
	ui.Row(c.Key("skill/" + skill.Path)).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.Column(c).Grow(1).Gap(1).Children(func() {
			ui.Text(c, skill.Name+" · "+w.skillScopeLabel(skill.Scope)).FontSize(13).Color(w.pal.text).Ellipsis()
			if skill.Description != "" {
				ui.Text(c, skill.Description).FontSize(12).Color(w.pal.muted).Ellipsis()
			}
		})
		// Unknown enablement is shown as unavailable rather than guessed, and a
		// plugin's skills are managed by the plugin.
		known := skill.Enabled != nil && skill.PluginID == nil
		on := known && *skill.Enabled
		value := on
		// The switch writes a click into value only when it is asked, after Disabled is set.
		if ui.Switch(c.KeyInt(index), &value, i18n.SharedFormat(language, "desktop.settings.agent.skills.enable", map[string]string{"name": skill.Name})).Disabled(!known || busy).Changed() && value != on {
			enabled := value
			c.After(func() { s.setSkillEnabled(skill, enabled) })
		}
		if ui.Button(c.KeyInt(index).Key("view"), i18n.Shared(language, "desktop.settings.agent.skills.view")).Outline().Clicked() {
			c.After(func() { s.readSkill(skill) })
		}
		if s.openSkill != nil && ui.Button(c.KeyInt(index).Key("open"), i18n.Shared(language, "desktop.settings.agent.skills.openFile")).Outline().Clicked() {
			path := skill.Path
			c.After(func() { s.openSkill(path) })
		}
		if ui.Button(c.KeyInt(index).Key("reveal"), i18n.Shared(language, "desktop.settings.agent.skills.reveal")).Outline().Clicked() {
			path := skill.Path
			c.After(func() { s.revealSkill(path) })
		}
	})
}

// skillViewer shows the SKILL.md that was read. The text cannot be edited.
func (w *window) skillViewer(c ui.C, st skillsState) {
	s := w.agent
	language := w.marketLanguage()
	w.card(c, i18n.Shared(language, "desktop.settings.agent.skills.viewTitle"), i18n.Shared(language, "desktop.settings.agent.skills.viewHelp"), func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			ui.Text(c, st.viewPath).FontSize(12).Color(w.pal.muted).Ellipsis()
			content := st.viewContent
			ui.TextArea(c.Key("skillContent"), &content, "", "").FillWidth().Height(240).Disabled(true)
			if ui.Button(c.Key("skillClose"), i18n.Shared(language, "desktop.settings.agent.skills.close")).Outline().Clicked() {
				c.After(s.closeSkill)
			}
		})
	})
}

// pickImportSource fills the import path from the system picker. A cancelled picker changes nothing.
func (s *agentSettings) pickImportSource(title string, directory bool) {
	path, err := pickSkillSource(title, directory)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		s.skills.err = err
		return
	}
	if path != "" {
		s.skills.importPath = path
	}
}

// revealSkill shows a skill's path in the file browser, off the window thread.
func (s *agentSettings) revealSkill(path string) {
	s.run(func(context.Context) {
		err := revealSkillPath(path)
		s.mu.Lock()
		defer s.mu.Unlock()
		s.skills.err = err
	})
}
