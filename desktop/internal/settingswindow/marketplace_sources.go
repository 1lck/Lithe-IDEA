package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
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

// repositoriesModal is the plugin repositories dialog the page's gear opens: the help on what
// can be added, a field that adds an index, then every repository the page reads with its own
// refresh, the built-in ones marked as such and the added ones with a remove button.
func (w *window) repositoriesModal(c ui.C, language i18n.Language) {
	if !w.repositoriesOpen {
		return
	}
	m := w.market
	title := i18n.Shared(language, "native.pluginRepositories")
	body := func() {
		ui.Column(c).FillWidth().Gap(12).Children(func() {
			ui.Wrap(c, i18n.Shared(language, "native.pasteAnHttpsPluginIndexURLOrAGitHubRepositoryURLAGitHubRepositoryMustContainLi7616c31790")).
				FontSize(12).Color(w.pal.muted)
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				ui.TextField(c, &w.marketSourceDraft, title, "https://github.com/owner/repository").Grow(1).Shrink(1).MinWidth(0)
				if ui.Button(c, i18n.Shared(language, "ai.add")).Disabled(strings.TrimSpace(w.marketSourceDraft) == "").Clicked() {
					c.After(w.addMarketSource)
				}
			})
			if w.marketSourceNotice != "" {
				ui.Wrap(c, w.marketSourceNotice).FontSize(12).Color(w.pal.warning)
			}
			ui.Scroll(c.Part("repositories")).FillWidth().MaxHeight(320).Radius(8).Stroke(1, w.pal.line).Background(w.pal.card).Children(func() {
				ui.Column(c).FillWidth().Shrink(0).Children(func() {
					for position, source := range m.sourceChoices() {
						if source == m.aggregateSource() || source == 2 {
							continue
						}
						if position > 0 {
							ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
						}
						w.repositoryRow(c.KeyInt(source), language, source)
					}
				})
			})
		})
	}
	footer := func() {
		if ui.Button(c, i18n.Shared(language, "native.refreshAll")).Outline().Clicked() {
			c.After(func() {
				if m.source != m.aggregateSource() {
					m.chooseSource(m.aggregateSource())
					return
				}
				w.refreshMarket()
			})
		}
		if ui.Button(c, i18n.Shared(language, "ui.done")).Clicked() {
			w.repositoriesOpen = false
		}
	}
	ui.ModalWith(c.Part("repositories-modal"), &w.repositoriesOpen, title, ui.ModalSpec{Width: 600}, body, footer)
	if !w.repositoriesOpen {
		w.marketSourceNotice = ""
	}
}

// repositoryRow is one repository of the dialog: its name and badge over its address, then
// its refresh and either the built-in mark or the remove button.
func (w *window) repositoryRow(c ui.C, language i18n.Language, source int) {
	m := w.market
	custom := source >= marketFixedSources
	address := ""
	switch {
	case custom:
		address = m.custom[source-marketFixedSources]
	case source == 1:
		address = w.ctrl.opts.OfficialMarketplaceURL
	default:
		address = w.ctrl.opts.MarketplaceURL
	}
	ui.Row(c).FillWidth().PadX(12).PadY(9).Gap(10).Items(ui.Center).Children(func() {
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				name := w.marketSourceLabel(source)
				if custom {
					name = repositoryName(address)
				}
				ui.Text(c, name).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
				w.originBadge(c, language, source == 1)
			})
			if address != "" {
				ui.Text(c, address).Mono().FontSize(12).Color(w.pal.muted).Ellipsis()
			}
		})
		if ui.Button(c, i18n.Shared(language, "ui.refresh")).XSmall().Ghost().Clicked() {
			c.After(func() {
				if m.source != source {
					m.chooseSource(source)
					return
				}
				w.refreshMarket()
			})
		}
		if !custom {
			ui.Text(c, i18n.Shared(language, "native.default")).FontSize(11).Color(w.pal.subtle).Shrink(0)
			return
		}
		if ui.Button(c, i18n.Shared(language, "ui.remove")).XSmall().Ghost().Color(w.pal.danger).Clicked() {
			index := source - marketFixedSources
			c.After(func() { w.removeMarketSource(index) })
		}
	})
}
