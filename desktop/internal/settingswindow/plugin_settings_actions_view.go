package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

var (
	pluginSettingActions       = tree.Sub(root, tree.Name("plugin-setting-actions"))
	pluginSettingActionConfirm = tree.ID(root, "plugin-setting-action-confirm")
	pluginSettingActionDismiss = tree.ID(root, "plugin-setting-action-dismiss")
	pluginSettingActionStop    = tree.ID(root, "plugin-setting-action-stop")
)

func (w *window) drawPluginSettingActions(f *ui.Frame) {
	p := w.pluginSettings
	if _, ok := p.loader.(PluginSettingsActionLoader); !ok {
		return
	}
	language := w.marketLanguage()
	if p.acting && p.cancel != nil {
		if f.Button(pluginSettingActionStop, i18n.Shared(language, "desktop.pluginSettings.actionCancel")).Outline().Clicked() {
			p.cancel()
		}
	}
	if p.actionComplete {
		f.Wrap(i18n.Shared(language, "desktop.pluginSettings.actionCompleted")).FontSize(12).Color(w.pal.muted)
	}
	if p.actionCanceled {
		f.Wrap(i18n.Shared(language, "desktop.pluginSettings.actionCanceled")).FontSize(12).Color(w.pal.muted)
	}
	if p.actionUnavailable != "" {
		message := i18n.Shared(language, "desktop.pluginSettings.actionProviderUnavailable")
		switch p.actionUnavailable {
		case "projectRequired":
			message = i18n.Shared(language, "desktop.pluginSettings.openProject")
		case "pluginDisabled":
			message = i18n.Shared(language, "desktop.pluginSettings.actionDisabled")
		}
		f.Wrap(message).FontSize(12).Color(w.pal.muted)
	}
	if confirmation := p.actionConfirmation; confirmation != nil {
		f.Wrap(i18n.SharedFormat(language, "desktop.pluginSettings.actionConfirm", map[string]string{"action": confirmation.Title})).FontSize(12).Color(w.pal.text)
		f.Row().Gap(8).Children(func() {
			if f.Button(pluginSettingActionConfirm, i18n.Shared(language, "desktop.pluginSettings.actionContinue")).Disabled(p.running).Clicked() {
				p.act(confirmation.ActionID, true)
			}
			if f.Button(pluginSettingActionDismiss, i18n.Shared(language, "desktop.pluginSettings.actionCancel")).Outline().Disabled(p.running).Clicked() {
				p.actionConfirmation = nil
			}
		})
	}
}

func (w *window) pluginSettingActionRow(f *ui.Frame, index int, height float32) {
	p := w.pluginSettings
	if _, ok := p.loader.(PluginSettingsActionLoader); !ok {
		return
	}
	action := p.editor.Snapshot.State.Actions[index]
	f.Row().FillWidth().Height(height).Shrink(0).Gap(8).Items(ui.Center).Children(func() {
		if f.Button(pluginSettingActions.At(index), action.Title).Outline().Disabled(p.running || !p.loaded).Clicked() {
			p.act(action.ID, false)
		}
		if action.Description != "" {
			w.infoButton(f, 2000+index, action.Description)
		}
	})
}
