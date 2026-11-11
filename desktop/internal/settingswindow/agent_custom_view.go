package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// customAgentsCard declares the custom Agent list and its add, edit and remove actions. The list
// is read from the owner on every paint, so the page shows the stored definitions.
func (w *window) customAgentsCard(c ui.C) {
	s := w.agent
	if s.customAgents == nil {
		return
	}
	lang := w.marketLanguage()
	list := s.customAgents()
	s.mu.Lock()
	d := s.custom
	s.mu.Unlock()
	w.card(c, i18n.Shared(lang, "desktop.settings.agent.custom.title"), i18n.Shared(lang, "desktop.settings.agent.custom.help"), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if len(list) == 0 && !d.editing {
				ui.Text(c, i18n.Shared(lang, "desktop.settings.agent.custom.empty")).FontSize(12).Color(w.pal.muted)
			}
			for i, entry := range list {
				entry := entry
				ui.Row(c.KeyInt(i)).FillWidth().Items(ui.Center).Gap(8).Children(func() {
					ui.Column(c).Grow(1).Gap(1).Children(func() {
						ui.Text(c, entry.Name).FontSize(13).Color(w.pal.text).Ellipsis()
						command := strings.TrimSpace(entry.Command + " " + strings.Join(entry.Args, " "))
						ui.Text(c, command).FontSize(12).Color(w.pal.muted).Ellipsis()
					})
					if ui.Button(c.KeyInt(i).Key("edit"), i18n.Shared(lang, "desktop.settings.agent.custom.edit")).Outline().Clicked() {
						c.After(func() { s.editCustomAgent(&entry) })
					}
					if d.confirmRemove == entry.ID {
						if ui.Button(c.KeyInt(i).Key("confirmRemove"), i18n.Shared(lang, "desktop.settings.agent.custom.confirmRemove")).Clicked() {
							c.After(func() { s.removeCustomAgent(list, entry.ID) })
						}
						if ui.Button(c.KeyInt(i).Key("cancelRemove"), i18n.Shared(lang, "desktop.settings.agent.custom.cancel")).Outline().Clicked() {
							c.After(func() {
								s.mu.Lock()
								s.custom.confirmRemove = ""
								s.mu.Unlock()
							})
						}
					} else if ui.Button(c.KeyInt(i).Key("remove"), i18n.Shared(lang, "desktop.settings.agent.custom.remove")).Outline().Clicked() {
						c.After(func() {
							s.mu.Lock()
							s.custom.confirmRemove = entry.ID
							s.mu.Unlock()
						})
					}
				})
			}
			if d.editing {
				w.customAgentForm(c, d, list)
				return
			}
			if ui.Button(c.Key("add"), i18n.Shared(lang, "desktop.settings.agent.custom.add")).Outline().Clicked() {
				c.After(func() { s.editCustomAgent(nil) })
			}
		})
	})
}

// customAgentForm declares the editor of one definition. Its text is kept in the draft as it
// changes; Save validates and stores the whole list, Cancel stores nothing.
func (w *window) customAgentForm(c ui.C, d customAgentDraft, list []CustomAgentSetting) {
	s := w.agent
	lang := w.marketLanguage()
	name, command, args, directory := d.name, d.command, d.args, d.directory
	ui.TextField(c.Key("name"), &name, i18n.Shared(lang, "desktop.settings.agent.custom.name"), "").FillWidth()
	ui.TextField(c.Key("command"), &command, i18n.Shared(lang, "desktop.settings.agent.custom.command"), "").FillWidth()
	ui.TextArea(c.Key("args"), &args, i18n.Shared(lang, "desktop.settings.agent.custom.args"), "").FillWidth().Height(72)
	ui.TextField(c.Key("directory"), &directory, i18n.Shared(lang, "desktop.settings.agent.custom.directory"), i18n.Shared(lang, "desktop.settings.agent.custom.directoryHint")).FillWidth()
	if name != d.name || command != d.command || args != d.args || directory != d.directory {
		s.mu.Lock()
		s.custom.name, s.custom.command, s.custom.args, s.custom.directory = name, command, args, directory
		s.custom.err = customAgentValid
		s.mu.Unlock()
	}
	if d.err != customAgentValid {
		ui.Wrap(c, customAgentProblemText(lang, d.err)).FontSize(12).Color(w.pal.danger)
	}
	ui.Row(c).Gap(8).Children(func() {
		if ui.Button(c.Key("save"), i18n.Shared(lang, "desktop.settings.agent.custom.save")).Clicked() {
			c.After(func() { s.saveCustomAgent(list) })
		}
		if ui.Button(c.Key("cancel"), i18n.Shared(lang, "desktop.settings.agent.custom.cancel")).Outline().Clicked() {
			c.After(s.cancelCustomAgent)
		}
	})
}

// customAgentProblemText is the message of a broken custom agent rule.
func customAgentProblemText(lang i18n.Language, problem customAgentProblem) string {
	switch problem {
	case customAgentNameRequired:
		return i18n.Shared(lang, "desktop.settings.agent.custom.nameRequired")
	case customAgentCommandRequired:
		return i18n.Shared(lang, "desktop.settings.agent.custom.commandRequired")
	default:
		return i18n.Shared(lang, "desktop.settings.agent.custom.directoryAbsolute")
	}
}
