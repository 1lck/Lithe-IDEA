package settingswindow

import (
	"hash/fnv"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The page of a kind of plugin pages under Build, Execution, Deployment, build systems or
// compilers, is laid out as the Toolchains and Debuggers pages are: the kind's pages on the
// left, with a filter and their count, and the chosen page's settings on the right. The
// sidebar has one row for the kind however many pages plugins contribute to it, and the list
// shows only the rows on the screen, so thousands of pages cost what a few do.
//
// The page aggregates: a plugin's settings stay on its detail's Settings tab, and the page
// shows the same form with the same drafts, kept to the settings of the chosen page.

// kindState is the list of one kind's page: its filter, its rows and the page it showed last,
// which opens when the kind's row is chosen again.
type kindState struct {
	query string
	list  ui.ListState
	last  string
}

// shownKind is the kind whose page shows: the kind of the open plugin page when it is one of
// buildKinds, empty for any other page.
func (w *window) shownKind() string {
	if w.sess.page != pageBuild || w.dynamicPage == "" {
		return ""
	}
	if page := w.dynamic.selected(w.dynamicPage); page != nil && kindIndex(page.Kind) >= 0 {
		return page.Kind
	}
	return ""
}

// openKind shows the page of kind with Build expanded, on the page it showed last if the
// catalog still lists it, else on the first page of the kind.
func (w *window) openKind(kind string) {
	index := kindIndex(kind)
	if index < 0 {
		return
	}
	key := ""
	if last := w.dynamic.selected(w.kinds[index].last); last != nil && last.Kind == kind {
		key = last.Key
	} else {
		for i := range w.dynamic.pages {
			if w.dynamic.pages[i].Kind == kind {
				key = w.dynamic.pages[i].Key
				break
			}
		}
	}
	if key == "" {
		return
	}
	w.sess.open[pageBuild] = true
	w.selectSettingsPage(pageBuild, key)
}

// buildKindPage is the page of kind: the list of its pages beside the chosen page's settings.
func (w *window) buildKindPage(c ui.C, kind string) {
	b := &w.bp
	language := w.marketLanguage()
	state := &w.kinds[kindIndex(kind)]
	state.last = w.dynamicPage
	width := float32(debuggerListWidth)
	if room := w.extent - 1 - toolchainDetailMin; room < width {
		width = max(220, room)
	}
	ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(b.surface).Children(func() {
		ui.Column(c).Width(width).Shrink(0).FillHeight().MinHeight(0).Children(func() {
			ui.Row(c).FillWidth().Shrink(0).PadX(10).PadY(10).Children(func() {
				label := i18n.Shared(language, "desktop.buildSettings.kindFilter")
				w.filterField(c.Part("filter"), &state.query, label, label, true)
			})
			ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
			w.kindList(c.Part("list"), language, kind, state)
			ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
			ui.Row(c).FillWidth().Shrink(0).PadX(12).PadY(5).Children(func() {
				ui.Text(c, kindPageCount(language, w.dynamic.kindCount(kind))).
					FontSize(11).Color(b.faint).Ellipsis()
			})
		})
		ui.Row(c).Width(1).Shrink(0).FillHeight().Background(b.line)
		// The detail scrolls, named by the page so it starts at its top each time a page is
		// chosen, and grows its content to its height, which the plugin's form fills.
		ui.Scroll(c.Key("page:"+w.dynamicPage)).Scrollbars().Grow(1).Shrink(1).MinWidth(0).FillHeight().
			PadSides(buildPagePadTop, buildPagePadX, buildPagePadEnd, buildPagePadX).Gap(10).Children(func() {
			if page := w.dynamic.selected(w.dynamicPage); page != nil {
				w.kindDetail(c, language, page)
			}
		})
	})
}

// kindList is the pages of kind whose title or plugin holds the filter, each with the plugins
// that contribute to it. Choosing one shows its settings beside the list.
func (w *window) kindList(c ui.C, language i18n.Language, kind string, state *kindState) {
	b := &w.bp
	pages := w.kindPages(kind, state.query)
	if len(pages) == 0 {
		ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).PadSides(50, 20, 50, 20).Items(ui.Center).Children(func() {
			ui.Wrap(c, i18n.Shared(language, "desktop.buildSettings.kindNoMatches")).FontSize(buildSmall).Color(b.faint).TextCenter()
		})
		return
	}
	state.list.Key = func(row int) int {
		if row < 0 || row >= len(pages) {
			return 0
		}
		return kindRowKey(pages[row].Key)
	}
	state.list.Header = nil
	state.list.Label = func(row int) string {
		if row < 0 || row >= len(pages) {
			return ""
		}
		return pages[row].Title
	}
	at := slices.IndexFunc(pages, func(page *core.SettingsPage) bool { return page.Key == w.dynamicPage })
	if state.list.Selected() != at {
		state.list.Select(at)
		if at >= 0 {
			state.list.ScrollIntoView(at)
		}
	}
	separator := i18n.Shared(language, "desktop.buildSettings.listSeparator")
	ui.List(c, &state.list, len(pages), func(r ui.ListRow) {
		page := pages[r.Index]
		k := r.C
		plugins := kindPlugins(page, separator)
		r.Element.Height(debuggerRow).PadSides(0, 12, 0, 14).Gap(9).Items(ui.Center).Hover(ui.Look{}.Background(b.hover))
		if r.Selected() {
			r.Element.Background(b.sel)
		}
		r.Element.Children(func() {
			w.pluginTile(k, plugins, 20)
			ui.Column(k).Grow(1).Shrink(1).MinWidth(0).Children(func() {
				ui.Text(c, page.Title).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Ellipsis()
				ui.Row(k).FillWidth().Height(2).Shrink(0)
				ui.Text(c, plugins).FontSize(11).Color(b.faint).Ellipsis()
			})
		})
	}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(kindTitle(language, kind))
	if state.list.Changed() {
		if at := state.list.Selected(); at >= 0 && at < len(pages) && pages[at].Key != w.dynamicPage {
			w.selectSettingsPage(pageBuild, pages[at].Key)
		}
	}
}

// kindDetail is the chosen page: its title and the plugins that contribute to it, the chooser
// of the contributor when there is more than one, and that contributor's settings of the page.
func (w *window) kindDetail(c ui.C, language i18n.Language, page *core.SettingsPage) {
	b := &w.bp
	if len(page.Contributors) == 0 {
		ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.pageUnavailable")).Color(w.pal.muted)
		return
	}
	// A refreshed catalog may no longer list the chosen contributor: the first one stands in.
	if w.contributionOf(page) < 0 {
		w.contributorID = page.Contributors[0].PluginID
	}
	plugins := kindPlugins(page, i18n.Shared(language, "desktop.buildSettings.listSeparator"))
	ui.Row(c).FillWidth().Shrink(0).Gap(12).Items(ui.Center).Children(func() {
		w.pluginTile(c, plugins, 40)
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
			ui.Text(c, page.Title).FontSize(buildHeading).Weight(gfx.WeightBold).Color(b.text).Ellipsis()
			ui.Row(c).Height(4).Shrink(0)
			ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.providedBy", map[string]string{"plugin": plugins})).
				FontSize(buildSmall).Color(b.sub).Ellipsis()
		})
	})
	if w.dynamic.failed != nil {
		ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.failed")).Color(w.pal.danger)
	}
	if len(page.Contributors) > 1 {
		ui.Select(c, &w.contributorID, w.dynamic.contributorIDs[page.Key], w.contributorLabel).FillWidth().
			Label(i18n.Shared(language, "desktop.pluginSettings.contributor"))
	}
	if page.Kind == "buildSystem" {
		for _, target := range w.ctrl.buildOptionsFor(page.ID) {
			if target.PluginID != w.contributorID {
				continue
			}
			label := i18n.SharedFormat(language, "desktop.build.instanceOptions", map[string]string{"name": target.Name})
			if target.Root != "" {
				label = i18n.SharedFormat(language, "desktop.buildSettings.workspaceOptionsAt", map[string]string{"name": target.Name, "root": target.Root})
			}
			if w.button(c.Part(target.InstanceID), buttonLink, label, false) {
				c.After(target.Open)
			}
		}
	}
	w.pluginSettingsPanel(c, w.contributorID, true)
}

// kindRowKey is a row's identity in a kind's list, its page's key hashed to the list's
// non-negative 31-bit keys.
func kindRowKey(key string) int {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(key))
	return int(hash.Sum32() & 0x7fffffff)
}

// kindPages are the plugin pages of kind the filter query keeps: the ones whose title or a
// contributing plugin's title holds it, ignoring case.
func (w *window) kindPages(kind, query string) []*core.SettingsPage {
	query = strings.ToLower(strings.TrimSpace(query))
	var pages []*core.SettingsPage
	for index := range w.dynamic.pages {
		page := &w.dynamic.pages[index]
		if page.Kind != kind || (query != "" && !kindMatches(page, query)) {
			continue
		}
		pages = append(pages, page)
	}
	return pages
}

// kindMatches reports whether a lower-case query is in page's title or a contributor's.
func kindMatches(page *core.SettingsPage, query string) bool {
	if strings.Contains(strings.ToLower(page.Title), query) {
		return true
	}
	for _, contribution := range page.Contributors {
		if strings.Contains(strings.ToLower(contribution.Title), query) {
			return true
		}
	}
	return false
}

// kindPlugins names the plugins that contribute to page.
func kindPlugins(page *core.SettingsPage, separator string) string {
	names := make([]string, 0, len(page.Contributors))
	for _, contribution := range page.Contributors {
		name := contribution.Title
		if name == "" {
			name = contribution.PluginID
		}
		names = append(names, name)
	}
	return strings.Join(names, separator)
}
