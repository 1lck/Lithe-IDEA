package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// Custom marketplace sources: index URLs the user adds in the plugin page. They are kept by the
// application's settings, read when the page opens and written only when the user adds or removes one.

// marketSourceURLPrefix is the only scheme a custom index may use; the host fetches it over HTTPS.
const marketSourceURLPrefix = "https://"

// validSourceURL reports whether text can be added as an index: an HTTPS URL without spaces.
func validSourceURL(text string) bool {
	return strings.HasPrefix(text, marketSourceURLPrefix) && len(text) > len(marketSourceURLPrefix) && !strings.ContainsAny(text, " \t\n")
}

// sourceChoices are the sources the select offers, in index order.
func (m *marketplaceState) sourceChoices() []int {
	choices := []int{0}
	if m.official != nil {
		choices = append(choices, 1)
	}
	if m.installed != nil {
		choices = append(choices, 2)
	}
	for index := range m.custom {
		choices = append(choices, marketFixedSources+index)
	}
	if len(choices) > 1 {
		choices = append(choices, m.aggregateSource())
	}
	return choices
}

// addMarketSource saves a new custom index and selects it. A duplicate or a malformed URL changes nothing.
func (w *window) addMarketSource() {
	text := strings.TrimSpace(w.marketSourceDraft)
	if !validSourceURL(text) {
		w.notifyMarketSource(i18n.Shared(w.marketLanguage(), "desktop.marketplace.sourceInvalid"))
		return
	}
	for _, existing := range w.market.custom {
		if existing == text {
			return
		}
	}
	urls := append(append([]string(nil), w.market.custom...), text)
	w.marketSourceDraft = ""
	w.saveMarketSources(urls)
	w.market.chooseSource(marketFixedSources + len(urls) - 1)
	w.market.list.ScrollTo(0, ui.ListStart)
}

// removeMarketSource drops a custom index. The page falls back to community when the removed one was chosen.
func (w *window) removeMarketSource(index int) {
	if index < 0 || index >= len(w.market.custom) {
		return
	}
	urls := append(append([]string(nil), w.market.custom[:index]...), w.market.custom[index+1:]...)
	w.saveMarketSources(urls)
}

// saveMarketSources stores the list through the owner and rebuilds the page's sources from it.
func (w *window) saveMarketSources(urls []string) {
	if w.ctrl.opts.SetMarketplaceSources != nil {
		w.ctrl.opts.SetMarketplaceSources(urls)
	}
	w.market.setCustom(urls)
	w.market.list.ScrollTo(0, ui.ListStart)
}

// notifyMarketSource reports a refused change in the page's own notice line.
func (w *window) notifyMarketSource(text string) {
	w.marketSourceNotice = text
}

// marketSourceManager declares the custom sources of the page: each with a remove button, and a field
// that adds one. It is shown only when the owner stores sources.
func (w *window) marketSourceManager(c ui.C) {
	if w.ctrl.opts.SetMarketplaceSources == nil {
		return
	}
	language := w.marketLanguage()
	ui.Column(c).FillWidth().Gap(6).PadX(12).Children(func() {
		for index, url := range w.market.custom {
			index := index
			ui.Row(c.Key("custom-source-" + url)).FillWidth().Height(26).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, url).Grow(1).Shrink(1).MinWidth(0).FontSize(12).Color(w.pal.muted).Ellipsis()
				if ui.Button(c.Key("remove-source-"+url), i18n.Shared(language, "desktop.marketplace.removeSource")).Small().Outline().Clicked() {
					c.After(func() { w.removeMarketSource(index) })
				}
			})
		}
		ui.Row(c).FillWidth().Height(32).Items(ui.Center).Gap(8).Children(func() {
			ui.TextField(c, &w.marketSourceDraft, i18n.Shared(language, "desktop.marketplace.sourceURL"), i18n.Shared(language, "desktop.marketplace.sourceURLPlaceholder")).Grow(1)
			if ui.Button(c, i18n.Shared(language, "desktop.marketplace.addSource")).Outline().Clicked() {
				c.After(w.addMarketSource)
			}
		})
		if w.marketSourceNotice != "" {
			ui.Text(c, w.marketSourceNotice).FontSize(12).Color(w.pal.danger)
		}
	})
}
