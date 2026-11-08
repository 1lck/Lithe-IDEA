package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/app"
)

// newSettingsWindow makes the controller of the settings window. The settings are a window
// of their own, like the log window, so the controller is handed what it may read from its
// own thread (the language and the look of the frame last painted) and two ways back into
// the workbench, both of which only queue the work for the workbench's window thread.
func (a *App) newSettingsWindow() *settingswindow.Controller {
	return settingswindow.NewController(settingswindow.Options{
		Text: a.shared.text.Load,
		Dark: a.shared.dark.Load,
		// The look "follow the system" resolves to is the system's own, which Dark cannot
		// tell once the user has picked a look: then it reports that pick.
		SystemDark:     func() bool { return app.SystemAppearance() == app.AppearanceDark },
		SystemLanguage: a.systemLanguage,
		Version:        appVersion,
		// OK arrives on the settings window's thread, and the settings belong to the
		// workbench's, so the draft is queued and applied there.
		Apply: func(values settingswindow.Values) {
			a.post(func(a *App) {
				a.setLanguage(values.Language)
				a.setTheme(themeChoice(values.Theme))
			})
		},
		ResetLayout: func() {
			a.post(func(a *App) { a.resetLayout() })
		},
	})
}

// openSettings shows the settings window, or raises it when it is already open. surface is
// where the user started the action from, written as the catalog's token.
//
// The window is opened from a queued task because the toolkit only opens a window from a
// window thread, which the task runs on. The settings in force are read there, at the
// moment the window opens, so a window that has to be made starts from the latest ones.
func (a *App) openSettings(surface string) {
	a.performed("settings.open", surface)
	if a.application == nil {
		return
	}
	a.post(func(a *App) {
		if a.application == nil {
			return
		}
		current := settingswindow.Values{Language: a.settings.Language, Theme: string(a.settings.Theme)}
		if err := a.settingsWindow.Open(a.application, current); err != nil {
			a.notify(a.text.Errors.SettingsFailed(err.Error()))
		}
	})
}
