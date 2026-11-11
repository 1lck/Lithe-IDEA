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
	state := ""
	if w.ctrl.opts.LanguageServerState != nil {
		state = w.ctrl.opts.LanguageServerState(pluginID)
	}
	value, color := i18n.Shared(language, "desktop.languageStatus.none"), w.pal.muted
	switch state {
	case "":
	case "starting", "preparing":
		value = i18n.Shared(language, "desktop.languageStatus.starting")
	case "ready":
		value, color = i18n.Shared(language, "desktop.languageStatus.ready"), w.pal.text
	case "degraded":
		value = i18n.Shared(language, "desktop.languageStatus.degraded")
	case "stopped":
		value = i18n.Shared(language, "desktop.languageStatus.stopped")
	case "failed", "error":
		value, color = i18n.Shared(language, "desktop.languageStatus.failed"), w.pal.danger
	}
	ui.Row(c).FillWidth().Height(40).Shrink(0).PadX(12).Gap(12).Items(ui.Center).Radius(6).Background(w.pal.card).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.languageStatus.title")).FontSize(12).Color(w.pal.muted).Shrink(0)
		ui.Spacer(c)
		ui.Text(c, value).FontSize(13).Weight(gfx.WeightSemibold).Color(color).Ellipsis()
	})
}
