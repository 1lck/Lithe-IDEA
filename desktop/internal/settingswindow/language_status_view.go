package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// languageStatusCard declares the state of the language server a language page's contributor runs.
// It reads the state the window thread last recorded, so the card never waits for the server.
func (w *window) languageStatusCard(c ui.C, pluginID string) {
	language := w.marketLanguage()
	value, tone := languageStateWords(language, w.languageServerState(pluginID))
	color := w.pal.muted
	switch tone {
	case "ok":
		color = w.pal.text
	case "error":
		color = w.pal.danger
	}
	ui.Row(c).FillWidth().Height(40).Shrink(0).PadX(12).Gap(12).Items(ui.Center).Radius(6).Background(w.pal.card).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.languageStatus.title")).FontSize(12).Color(w.pal.muted).Shrink(0)
		ui.Spacer(c)
		ui.Text(c, value).FontSize(13).Weight(gfx.WeightSemibold).Color(color).Ellipsis()
	})
}

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
