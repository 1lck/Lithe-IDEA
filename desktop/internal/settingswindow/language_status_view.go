package settingswindow

import "github.com/1lck/Lithe-IDEA/desktop/internal/i18n"

// A language's row in the Languages & Frameworks directory says the state of the language
// server its first contributor runs. The row reads the state the window thread last recorded,
// so drawing it never waits for the server. The language's own page does not repeat it.

// languageServerState is the state of the language server pluginID runs as the window thread
// last recorded it, empty when none runs or the host reports none.
func (w *window) languageServerState(pluginID string) string {
	if w.ctrl.opts.LanguageServerState == nil || pluginID == "" {
		return ""
	}
	return w.ctrl.opts.LanguageServerState(pluginID)
}

// languageStateWords are the words of a language server's state and its tone, as
// buildPalette.statusColor reads it: "ok" while it is ready, "error" once it failed, "warning"
// while it starts or works with less, and "idle" when it stopped or none runs.
func languageStateWords(language i18n.Language, state string) (string, string) {
	switch state {
	case "starting", "preparing":
		return i18n.Shared(language, "desktop.languageStatus.starting"), "warning"
	case "ready":
		return i18n.Shared(language, "desktop.languageStatus.ready"), "ok"
	case "degraded":
		return i18n.Shared(language, "desktop.languageStatus.degraded"), "warning"
	case "stopped":
		return i18n.Shared(language, "desktop.languageStatus.stopped"), "idle"
	case "failed", "error":
		return i18n.Shared(language, "desktop.languageStatus.failed"), "error"
	}
	return i18n.Shared(language, "desktop.languageStatus.none"), "idle"
}
