package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// pluginSettingActions declares what the form says about the actions: the stop button
// while one runs, the outcome of the last one, and the confirmation dialog a plan asks for.
func (w *window) pluginSettingActions(c ui.C) {
	p := w.pluginSettings
	if _, ok := p.loader.(PluginSettingsActionLoader); !ok {
		return
	}
	language := w.marketLanguage()
	if p.acting {
		if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.actionCancel")).Outline().Clicked() {
			p.stop()
		}
	}
	if p.actionComplete {
		ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.actionCompleted")).FontSize(12).Color(w.pal.muted)
	}
	if p.actionCanceled {
		ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.actionCanceled")).FontSize(12).Color(w.pal.muted)
	}
	if p.actionUnavailable != "" {
		message := i18n.Shared(language, "desktop.pluginSettings.actionProviderUnavailable")
		switch p.actionUnavailable {
		case "projectRequired":
			message = i18n.Shared(language, "desktop.pluginSettings.openProject")
		case "pluginDisabled":
			message = i18n.Shared(language, "desktop.pluginSettings.actionDisabled")
		}
		ui.Wrap(c, message).FontSize(12).Color(w.pal.muted)
	}
	if confirmation := p.actionConfirmation; confirmation != nil {
		question := i18n.SharedFormat(language, "desktop.pluginSettings.actionConfirm", map[string]string{"action": confirmation.Title})
		ui.Modal(c, &p.confirmOpen, confirmation.Title, func() {
			ui.Wrap(c, question).FontSize(12).Color(w.pal.text)
		}, func() {
			if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.actionCancel")).Outline().Disabled(p.running).Clicked() {
				p.confirmOpen = false
			}
			if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.actionContinue")).Disabled(p.running).Clicked() {
				p.act(confirmation.ActionID, true)
			}
		})
		if !p.confirmOpen {
			p.actionConfirmation = nil
		}
	}
}

// pluginSettingActionRow declares one action of the form: its button, and its description
// behind the information glyph.
func (w *window) pluginSettingActionRow(c ui.C, index int) {
	p := w.pluginSettings
	if _, ok := p.loader.(PluginSettingsActionLoader); !ok {
		return
	}
	action := p.editor.Snapshot.State.Actions[index]
	ui.Row(c).FillWidth().Height(44).Shrink(0).Gap(8).Items(ui.Center).Children(func() {
		if ui.Button(c, action.Title).Outline().Disabled(p.running || !p.loaded).Clicked() {
			p.act(action.ID, false)
		}
		if action.Description != "" {
			w.infoButton(c, action.Description)
		}
	})
}
