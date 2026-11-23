package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Languages & Frameworks page is the group's own page, which its sidebar row and the
// breadcrumb above one of its pages open. It is a directory of the pages plugins put under
// the group: each page's title, the plugins that contribute to it and, for a language, the
// state of the language server its first contributor runs. A click or Enter opens a page;
// the arrow keys only move between rows. The host writes no page for a language or a
// framework: every row comes from a plugin's declaration, and the list shows only the rows
// on the screen, so it costs the same with many language plugins as with a few.

// languageRowHeight is the height of one row of the directory.
const languageRowHeight = 52

// languagesPage is the title, a line on what the page lists and the directory, or what stands
// in for it while the catalog loads, after it failed or while no plugin contributes a page.
func (w *window) languagesPage(c ui.C) {
	b := &w.bp
	language := w.marketLanguage()
	pages := w.languagePages()
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(b.surface).
		PadSides(buildPagePadTop, buildPagePadX, buildPagePadEnd, buildPagePadX).Children(func() {
		ui.Text(c, titleOf(&w.text.Settings, pageLanguages)).FontSize(buildHeading).Weight(gfx.WeightBold).Color(b.text).Ellipsis()
		ui.Row(c).Height(4).Shrink(0)
		// The line asks to choose a page, so it shows only while there is one to choose.
		if len(pages) > 0 {
			ui.Wrap(c, i18n.Shared(language, "desktop.languageSettings.intro")).FontSize(buildSmall).Color(b.sub)
		}
		ui.Row(c).Height(12).Shrink(0)
		if w.dynamic.failed != nil {
			ui.Wrap(c, i18n.Shared(language, "desktop.languageSettings.failed")).FontSize(buildSmall).Color(b.err)
			ui.Row(c).Height(8).Shrink(0)
		}
		switch {
		case len(pages) > 0:
			w.languageDirectory(c.Part("directory"), language, pages)
		case !w.dynamic.loaded:
			ui.Text(c, i18n.Shared(language, "desktop.languageSettings.loading")).FontSize(buildSmall).Color(b.faint)
		case w.dynamic.failed == nil:
			w.languagesEmpty(c.Part("empty"), language)
		}
	})
}

// languagePages are the plugin pages under Languages & Frameworks, in the catalog's order,
// which is the sidebar's.
func (w *window) languagePages() []*core.SettingsPage {
	var pages []*core.SettingsPage
	for index := range w.dynamic.pages {
		page := &w.dynamic.pages[index]
		if contributedParent(page.Kind) == pageLanguages {
			pages = append(pages, page)
		}
	}
	return pages
}

// languageDirectory is the outlined list of pages. It is as tall as its rows until the page
// is shorter, and scrolls then.
func (w *window) languageDirectory(c ui.C, language i18n.Language, pages []*core.SettingsPage) {
	b := &w.bp
	state := &w.languages
	state.Key = func(row int) int {
		if row < 0 || row >= len(pages) {
			return 0
		}
		return kindRowKey(pages[row].Key)
	}
	state.Header = nil
	state.Label = func(row int) string {
		if row < 0 || row >= len(pages) {
			return ""
		}
		return pages[row].Title
	}
	separator := i18n.Shared(language, "desktop.buildSettings.listSeparator")
	focused := state.HasFocus()
	open := ""
	height := float32(len(pages))*languageRowHeight + 10
	ui.Column(c).FillWidth().MinWidth(0).Basis(height).Shrink(1).MinHeight(0).Pad(4).Radius(10).
		Border(1, b.line).Background(b.surface).Children(func() {
		ui.List(c, state, len(pages), func(r ui.ListRow) {
			page := pages[r.Index]
			k := r.C
			r.Element.Height(languageRowHeight).PadX(12).Gap(directoryRowGap).Radius(8).Items(ui.Center).
				Hover(ui.Look{}.Background(b.hover))
			// The row the keys are on is marked only while the list has the focus: the
			// page is a directory, which keeps no choice of its own.
			if focused && r.Current() {
				r.Element.Background(b.sel)
			}
			r.Element.Children(func() {
				w.pluginTile(k, page.Title, 28)
				ui.Column(k).Grow(1).Shrink(1).MinWidth(0).Children(func() {
					ui.Text(c, page.Title).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Ellipsis()
					ui.Row(k).Height(2).Shrink(0)
					ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.providedBy", map[string]string{"plugin": kindPlugins(page, separator)})).
						FontSize(buildSmall).Color(b.sub).Ellipsis()
				})
				if page.Kind == "language" && len(page.Contributors) > 0 && w.ctrl.opts.LanguageServerState != nil {
					words, tone := languageStateWords(language, w.languageServerState(page.Contributors[0].PluginID))
					ui.Row(k.Part("server")).Shrink(0).Gap(6).Items(ui.Center).Children(func() {
						dot(k, 8, b.statusColor(tone))
						ui.Text(c, i18n.SharedFormat(language, "desktop.languageSettings.serverState", map[string]string{"state": words})).
							FontSize(buildSmall).Color(b.sub)
					})
				}
				ui.Text(c, "›").FontSize(buildFont).Color(b.faint).Shrink(0)
			})
			if r.Element.Clicked() {
				open = page.Key
			}
		}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(titleOf(&w.text.Settings, pageLanguages))
	})
	if row, ok := state.Submitted(); ok && row >= 0 && row < len(pages) {
		open = pages[row].Key
	}
	if open != "" {
		w.selectSettingsPage(pageLanguages, open)
	}
}

// languagesEmpty stands in for the directory while no enabled plugin contributes a page:
// where pages come from, and the marketplace where language plugins are found.
func (w *window) languagesEmpty(c ui.C, language i18n.Language) {
	p := &w.pal
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Center().Gap(10).Children(func() {
		ui.Icon(c, icons.FileCode).Size(28, 28).Color(p.subtle)
		ui.Wrap(c, i18n.Shared(language, "desktop.languageSettings.empty")).FontSize(13).Color(p.muted).TextCenter().Width(emptyWidth)
		if w.ctrl.opts.Marketplace != nil && w.button(c.Part("marketplace"), buttonPlain, i18n.Shared(language, "desktop.languageSettings.browse"), false) {
			w.pluginTab = pluginTabMarketplace
			w.selectSettingsPage(pagePlugins, "")
		}
	})
}
