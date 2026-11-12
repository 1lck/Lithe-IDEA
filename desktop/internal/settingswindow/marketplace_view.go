package settingswindow

import (
	"errors"
	"hash/fnv"
	"strings"
	"unicode"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The plugin page is laid out as the macOS client's is, which follows IntelliJ IDEA's
// plugin manager: a header with the Marketplace and Installed tabs and a gear menu for
// the plugin repositories and disk installs, then a list beside the selected plugin.
// The gear menu only manages where plugins come from; each tab keeps its own list,
// search and detail.

const (
	marketListWidth = 320
	// marketRowHeight is the height of a plugin in the marketplace list.
	marketRowHeight = 50
	// marketMinWidth and marketMaxWidth bound the plugin list's width, and marketMinDetail
	// is what the detail beside it keeps.
	marketMinWidth  = 200
	marketMaxWidth  = 520
	marketMinDetail = 160
	// marketSplitterWidth is the thickness of the divider between the list and the detail.
	marketSplitterWidth = 8
	// pluginHeaderHeight is the height of the page's header with the tabs.
	pluginHeaderHeight = 42
)

// The tabs of the plugin page. Installed is first in value because a window opens on
// it; the header shows Marketplace first, as the macOS client does.
const (
	pluginTabInstalled = iota
	pluginTabMarketplace
)

func (w *window) marketLanguage() i18n.Language {
	language := i18n.English
	if w.ctrl.opts.Language != nil {
		language = w.ctrl.opts.Language()
	}
	return language
}

// marketSourceLabel is the words of source.
func (w *window) marketSourceLabel(source int) string {
	switch {
	case source == 1:
		return i18n.Shared(w.marketLanguage(), "desktop.marketplace.officialSource")
	case source == 2:
		return i18n.Shared(w.marketLanguage(), "desktop.marketplace.installedSource")
	case source == w.market.aggregateSource():
		return i18n.Shared(w.marketLanguage(), "native.allRepositories")
	case source >= marketFixedSources && source-marketFixedSources < len(w.market.custom):
		return w.market.custom[source-marketFixedSources]
	}
	return i18n.Shared(w.marketLanguage(), "desktop.marketplace.communitySource")
}

// marketplacePage declares the plugin page: the header with its tabs, then the open tab.
// The marketplace index is read whichever tab is open, because the Installed tab finds
// updates, descriptions and repositories in it.
func (w *window) marketplacePage(c ui.C) {
	m := w.market
	if m.status == marketIdle {
		m.start()
	}
	language := w.marketLanguage()
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		w.pluginHeader(c, language)
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
		if w.pluginTab == pluginTabMarketplace {
			w.marketSearch()
			w.pluginColumns(c, language, func() { w.marketSidebar(c, language) }, func() { w.marketDetail(c, language) })
		} else {
			w.installedColumns(c, language)
		}
	})
	w.repositoriesModal(c, language)
	w.uninstallModal(c, language)
}

// marketSearch hands the search text to Core's ranking while the index is shown.
func (w *window) marketSearch() {
	m := w.market
	if m.status != marketReady || m.search.rank == nil {
		return
	}
	query := w.marketQuery
	if !m.search.known || m.search.query != query {
		m.list.ScrollTo(0, ui.ListStart)
	}
	m.search.update(query)
	if m.search.tooLong {
		m.selected = ""
	}
	if m.search.empty && m.selected == "" && len(m.snapshot.Index.Plugins) > 0 {
		m.selected = m.snapshot.Index.Plugins[0].ID
	}
}

// pluginHeader is the page's title, the two tabs between flexible spaces and the gear menu.
func (w *window) pluginHeader(c ui.C, language i18n.Language) {
	ui.Row(c).FillWidth().Height(pluginHeaderHeight).Shrink(0).PadX(16).Gap(6).Items(ui.Center).Children(func() {
		ui.Text(c, titleOf(&w.text.Settings, pagePlugins)).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
		ui.Spacer(c)
		w.pluginTabButton(c, pluginTabMarketplace, i18n.Shared(language, "native.marketplace"))
		w.pluginTabButton(c, pluginTabInstalled, i18n.Shared(language, "native.installed"))
		ui.Spacer(c)
		w.pluginMenu(c, language)
	})
}

// pluginTabButton is one tab of the header: its words on the selection's fill while it is
// open, in the secondary color otherwise.
func (w *window) pluginTabButton(c ui.C, tab int, label string) {
	k := c.KeyInt(tab)
	chosen := w.pluginTab == tab
	button := ui.Row(k).Shrink(0).PadX(12).PadY(7).Radius(7).Items(ui.Center).
		HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: chosen})
	color := w.pal.muted
	if chosen {
		button = button.Background(w.pal.selection)
		color = w.pal.text
	} else {
		button = button.Hover(ui.Look{}.Background(w.pal.hover))
	}
	button.Children(func() {
		ui.Text(k, label).FontSize(13).Color(color)
	})
	if button.Clicked() {
		w.pluginTab = tab
	}
}

// pluginMenu is the gear of the header: managing and refreshing the plugin repositories,
// and installing a package from disk.
func (w *window) pluginMenu(c ui.C, language i18n.Language) {
	label := i18n.Shared(language, "desktop.pluginSettings.title")
	gear := ui.Button(c, label).Icon(icons.Settings).IconOnly().Ghost().Size(26, 26).Tooltip(label)
	if gear.Clicked() {
		w.pluginMenuOpen = !w.pluginMenuOpen
	}
	ui.Menu(c, gear, &w.pluginMenuOpen, func(menu *ui.MenuItems) {
		menu.WidthRange(220, 320)
		if w.ctrl.opts.SetMarketplaceSources != nil && menu.Item(i18n.Shared(language, "native.managePluginRepositories")).Clicked() {
			c.After(func() { w.repositoriesOpen = true })
		}
		if menu.Item(i18n.Shared(language, "native.refreshPluginRepositories")).Clicked() {
			c.After(w.refreshMarket)
		}
		if w.ctrl.opts.InstallPluginFromFile != nil {
			menu.Separator()
			if menu.Item(i18n.Shared(language, "native.installPluginFromDisk.variant2")).Clicked() {
				c.After(w.pickPluginPackage)
			}
		}
	})
}

// refreshMarket reads the chosen source's index again.
func (w *window) refreshMarket() {
	w.market.close()
	w.market.start()
}

// pickPluginPackage asks for a plugin package on disk and hands it to the owner, which
// reviews it. Cancelling the native dialog changes nothing.
func (w *window) pickPluginPackage() {
	paths, err := app.OpenFiles(app.OpenFileOptions{
		Title:   i18n.Shared(w.marketLanguage(), "desktop.marketplace.installFromFile"),
		Filters: []app.FileFilter{{Name: i18n.Shared(w.marketLanguage(), "desktop.marketplace.packageFilter"), Pattern: "*.zip"}},
	})
	// log-exempt: 用户取消：关闭原生文件选择器不安装任何插件。
	if errors.Is(err, app.ErrCanceled) || len(paths) == 0 {
		return
	}
	if err != nil {
		if w.ctrl.opts.MarketplaceError != nil {
			w.ctrl.opts.MarketplaceError(err)
		}
		return
	}
	w.ctrl.opts.InstallPluginFromFile(paths[0])
}

// pluginColumns declares a tab's list beside its detail, with the divider between them.
// Both tabs share the divider, so the list keeps its width when the user switches tabs.
func (w *window) pluginColumns(c ui.C, language i18n.Language, list, detail func()) {
	w.syncMarketSplit()
	ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		ui.Column(c).Width(w.marketApplied).FillHeight().Shrink(0).Children(list)
		split := ui.Splitter(c, &w.marketSplit).Mins(marketMinWidth, marketMinDetail).Label(i18n.Shared(language, "settings.resizePlugins"))
		// The Page does not route a splitter's keys: the divider's own shortcuts move it
		// while it has the focus, by a step or to either end.
		for _, move := range marketSplitKeys {
			if split.Shortcut(0, move.key) {
				w.marketSplit.Pos = w.marketSplitMove(move.step, move.edge)
			}
		}
		ui.Column(c).Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(detail)
	})
}

// syncMarketSplit settles the divider before the panes are declared. A position that is not
// the one the last paint gave it was moved by the user (a drag or a key): it becomes the
// preferred width, and is saved once the divider is let go. The width the list gets is the
// preference inside the room the window has, so a narrow window does not forget what the
// user chose.
func (w *window) syncMarketSplit() {
	if pos := w.marketSplit.Pos; pos != w.marketApplied {
		w.marketPreferred = min(max(pos, marketMinWidth), marketMaxWidth)
		w.marketMoved = true
	}
	if w.marketMoved && !w.marketSplit.Dragging() {
		w.marketMoved = false
		if w.ctrl.opts.MarketplaceResized != nil {
			w.ctrl.opts.MarketplaceResized(w.marketPreferred)
		}
	}
	hi := min(marketMaxWidth, w.extent-marketSplitterWidth-marketMinDetail)
	w.marketApplied = min(max(w.marketPreferred, min(marketMinWidth, hi)), hi)
	if !w.marketMoved || !w.marketSplit.Dragging() {
		w.marketSplit.Pos = w.marketApplied
	}
}

// marketSplitKeys are the keys that move the focused divider: a step in pixels, or an edge
// (-1 the narrowest list, 1 the widest) for Home and End.
var marketSplitKeys = [...]struct {
	key  string
	step float32
	edge int
}{{"left", -16, 0}, {"up", -16, 0}, {"right", 16, 0}, {"down", 16, 0}, {"home", 0, -1}, {"end", 0, 1}}

// marketSplitMove is the divider's position after a key: step from where it is, or an edge.
func (w *window) marketSplitMove(step float32, edge int) float32 {
	hi := min(marketMaxWidth, w.extent-marketSplitterWidth-marketMinDetail)
	switch edge {
	case -1:
		return min(marketMinWidth, hi)
	case 1:
		return hi
	}
	return min(max(w.marketApplied+step, min(marketMinWidth, hi)), hi)
}

// marketNotice is a sentence in the middle of a list's column.
func (w *window) marketNotice(c ui.C, text string, color ui.Color) {
	ui.Column(c).FillWidth().Grow(1).Center().Children(func() { ui.Text(c, text).Color(color) })
}

// marketSidebar is the marketplace tab's list column: the search, the repository and the
// order, then the plugins.
func (w *window) marketSidebar(c ui.C, language i18n.Language) {
	m := w.market
	if m.search.rank != nil {
		ui.Row(c).FillWidth().Height(44).Shrink(0).PadX(8).Items(ui.Center).Children(func() {
			search := i18n.Shared(language, "native.searchPlugins")
			ui.TextField(c, &w.marketQuery, search, search).Icon(icons.Search).FillWidth().Height(30)
		})
	}
	ui.Row(c).FillWidth().Shrink(0).PadX(8).PadBottom(8).Gap(8).Items(ui.Center).Children(func() {
		if choices := w.repositoryChoices(); len(choices) > 1 {
			w.marketSourcePick = m.source
			ui.Select(c, &w.marketSourcePick, choices, w.marketSourceLabel).Width(132).Label(i18n.Shared(language, "native.pluginRepository"))
			if w.marketSourcePick != m.source {
				m.chooseSource(w.marketSourcePick)
				m.list.ScrollTo(0, ui.ListStart)
			}
		}
		ui.Spacer(c)
		sort := m.sort
		ui.Select(c, &sort, []int{marketSortName, marketSortUpdated}, func(order int) string {
			if order == marketSortUpdated {
				return i18n.Shared(language, "native.sortByLastUpdated")
			}
			return i18n.Shared(language, "native.sortByName")
		}).Width(120).Label(i18n.Shared(language, "native.sortPlugins"))
		if sort != m.sort {
			m.sort = sort
			m.list.ScrollTo(0, ui.ListStart)
		}
	})
	for _, failure := range m.failures {
		name := failure.name
		if name == "" {
			name = i18n.Shared(language, "desktop.marketplace.communitySource")
		}
		ui.Text(c, i18n.SharedFormat(language, "desktop.marketplace.sourceUnavailable", map[string]string{"source": name})).
			FontSize(11).Color(w.pal.danger).Ellipsis().PadX(12).PadBottom(6)
	}
	ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
	plugins := m.snapshot.Index.Plugins
	rows := m.rows()
	switch {
	case m.status == marketLoading || m.status == marketIdle:
		w.marketNotice(c, i18n.Shared(language, "native.loading"), w.pal.muted)
	case m.status == marketFailed:
		ui.Column(c).FillWidth().Grow(1).Center().Gap(8).Children(func() {
			ui.Text(c, i18n.Shared(language, "native.pluginMarketplaceIsNotAvailable")).Color(w.pal.danger)
			if ui.Button(c, i18n.Shared(language, "ui.retry")).Outline().Clicked() {
				m.start()
			}
		})
	case m.search.loading:
		w.marketNotice(c, i18n.Shared(language, "quickOpen.searching"), w.pal.muted)
	case m.search.failed:
		w.marketNotice(c, i18n.Shared(language, "search.failed"), w.pal.danger)
	case m.search.tooLong:
		w.marketNotice(c, i18n.Shared(language, "desktop.marketplace.queryTooLong"), w.pal.muted)
	case len(plugins) == 0 || len(rows) == 0 && strings.TrimSpace(w.marketQuery) == "":
		w.marketNotice(c, i18n.Shared(language, "native.noPluginsAvailable"), w.pal.muted)
	case len(rows) == 0:
		w.marketNotice(c, i18n.Shared(language, "native.noMatchingPlugins"), w.pal.muted)
	default:
		w.marketList(c, language, plugins, rows)
	}
}

// repositoryChoices are the repositories the marketplace select offers: all of them
// first, then each one. The installed plugins are the Installed tab, so the select does
// not offer them as a repository.
func (w *window) repositoryChoices() []int {
	choices := w.market.sourceChoices()
	offered := make([]int, 0, len(choices))
	all := w.market.aggregateSource()
	for _, source := range choices {
		if source == all {
			offered = append([]int{all}, offered...)
		} else if source != 2 {
			offered = append(offered, source)
		}
	}
	return offered
}

// marketList is the plugins the search lists, in the chosen order. Choosing a row, by
// pointer or by the arrows, selects its plugin; a row's own button installs or updates it.
func (w *window) marketList(c ui.C, language i18n.Language, plugins []core.MarketplacePlugin, rows []int) {
	m := w.market
	if m.listFor != m.selected {
		m.listFor = m.selected
		m.list.Select(-1)
		for row, index := range rows {
			if plugins[index].ID == m.selected {
				m.list.Select(row)
				m.list.ScrollIntoView(row)
				break
			}
		}
	}
	ui.List(c, &m.list, len(rows), func(row ui.ListRow) {
		plugin := plugins[rows[row.Index]]
		row.Element.FillWidth().Height(marketRowHeight).PadX(14).Gap(10).Items(ui.Center).Hover(ui.Look{}.Background(w.pal.hover))
		if row.Selected() {
			row.Element.Background(w.pal.selectionIdle)
		}
		row.Element.Children(func() {
			w.marketAvatar(row.C, plugin.ID, plugin.Name, 32)
			ui.Column(row.C).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
				ui.Text(row.C, plugin.Name).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
				ui.Text(row.C, plugin.Author+" · "+offeredVersion(plugin)).FontSize(11).Color(w.pal.muted).Ellipsis()
			})
			w.marketRowAction(row.C, language, plugin)
		})
	}).FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(i18n.Shared(language, "native.marketplace"))
	if m.list.Changed() {
		if row := m.list.Selected(); row >= 0 && row < len(rows) {
			m.selected = plugins[rows[row]].ID
			m.listFor = m.selected
		}
	}
}

// marketOffer is what the marketplace offers for one plugin against what is installed.
type marketOffer uint8

const (
	// offerInstall is a plugin that is not installed and can be.
	offerInstall marketOffer = iota
	// offerUpdate is an installed plugin with a newer version offered.
	offerUpdate
	// offerInstalled is an installed plugin with nothing newer offered.
	offerInstalled
	// offerUnsupported is a plugin this platform or host cannot install.
	offerUnsupported
)

// marketOfferFor compares the listing with the installed plugin.
func (w *window) marketOfferFor(plugin core.MarketplacePlugin) marketOffer {
	var state PluginState
	if w.ctrl.opts.PluginState != nil {
		state = w.ctrl.opts.PluginState(plugin.ID)
	}
	switch {
	case state.Installed && newerOffered(plugin, state.Version):
		return offerUpdate
	case state.Installed:
		return offerInstalled
	case plugin.Availability.Status != "available":
		return offerUnsupported
	}
	return offerInstall
}

// offeredVersion is the version installing the listing would install.
func offeredVersion(plugin core.MarketplacePlugin) string {
	if plugin.Availability.Version != "" {
		return plugin.Availability.Version
	}
	return plugin.LatestVersion
}

// newerOffered reports whether the listing offers a version released after installed.
// Versions lists the releases newest first, so the offered version is newer when the
// installed one comes after it; an installed version the listing does not know of (a
// package from disk, or one the index dropped) is never offered a replacement.
func newerOffered(plugin core.MarketplacePlugin, installed string) bool {
	offered := offeredVersion(plugin)
	if plugin.Availability.Status != "available" || offered == "" || offered == installed {
		return false
	}
	seenOffered := false
	for _, version := range plugin.Versions {
		switch version.Version {
		case offered:
			seenOffered = true
		case installed:
			return seenOffered
		}
	}
	return false
}

// marketRowAction is the right end of a marketplace row: Install, Update, or what the
// plugin's state is.
func (w *window) marketRowAction(c ui.C, language i18n.Language, plugin core.MarketplacePlugin) {
	switch w.marketOfferFor(plugin) {
	case offerInstall:
		if w.ctrl.opts.InstallPlugin != nil && ui.Button(c, i18n.Shared(language, "desktop.marketplace.install")).Outline().XSmall().Clicked() {
			w.ctrl.opts.InstallPlugin(plugin)
		}
	case offerUpdate:
		if w.ctrl.opts.InstallPlugin != nil && ui.Button(c, i18n.Shared(language, "native.update")).Outline().XSmall().Clicked() {
			w.ctrl.opts.InstallPlugin(plugin)
		}
	case offerInstalled:
		ui.Text(c, i18n.Shared(language, "native.installed")).FontSize(11).Color(w.pal.muted).Shrink(0)
	case offerUnsupported:
		ui.Text(c, i18n.Shared(language, "native.notSupported")).FontSize(11).Color(w.pal.muted).Shrink(0)
	}
}

// marketDetail is the selected listing: who made it, its tags and description, where it
// comes from and what the user can do with it.
func (w *window) marketDetail(c ui.C, language i18n.Language) {
	m := w.market
	index, found := m.index[m.selected]
	if m.status != marketReady || !found {
		w.emptyDetail(c, i18n.Shared(language, "native.selectAPlugin"), 36)
		return
	}
	selected := m.snapshot.Index.Plugins[index]
	ui.Scroll(c.Part("market-detail")).Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
		ui.Column(c).FillWidth().Shrink(0).MinWidth(0).Pad(24).Gap(18).Children(func() {
			ui.Row(c).FillWidth().Gap(14).Items(ui.Start).Children(func() {
				w.marketAvatar(c, selected.ID, selected.Name, 48)
				ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Children(func() {
					ui.Text(c, selected.Name).FontSize(20).Weight(gfx.WeightBold).Color(w.pal.text).Ellipsis()
					ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
						w.originBadge(c, language, m.source == 1)
						byline := selected.Author
						if repository := repositoryName(selected.Repository); repository != "" {
							byline += " · " + repository
						}
						ui.Text(c, byline).FontSize(12).Color(w.pal.muted).Shrink(1).MinWidth(0).Ellipsis()
					})
				})
				ui.Row(c).Shrink(0).PadTop(4).Gap(8).Items(ui.Center).Children(func() {
					w.marketDetailAction(c, language, selected)
				})
			})
			if len(selected.Tags) > 0 {
				ui.Flow(c).FillWidth().Gap(6).Children(func() {
					for _, tag := range selected.Tags {
						ui.Row(c.Key(tag)).PadX(7).PadY(2).Radius(4).Background(w.pal.selection).Children(func() {
							ui.Text(c, tag).FontSize(11).Color(w.pal.text)
						})
					}
				})
			}
			if description := w.marketDescription(selected); description != "" {
				ui.Wrap(c, description).FontSize(13).Color(w.pal.text)
			}
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				w.marketMetadata(c, i18n.Shared(language, "native.repository"), w.marketSourceLabel(m.source))
				w.marketMetadata(c, i18n.Shared(language, "native.version"), offeredVersion(selected))
				if date := selected.Availability.ReleaseDate; date != "" || selected.LatestReleaseDate != "" {
					if date == "" {
						date = selected.LatestReleaseDate
					}
					w.marketMetadata(c, i18n.Shared(language, "native.releaseDate"), date)
				}
				if selected.License != "" {
					w.marketMetadata(c, i18n.Shared(language, "native.license"), selected.License)
				}
				if len(selected.Platforms) > 0 {
					w.marketMetadata(c, i18n.Shared(language, "native.platforms"), strings.Join(selected.Platforms, ", "))
				}
				if state := w.pluginState(selected.ID); state.Installed {
					ui.Wrap(c, i18n.SharedFormat(language, "native.versionIsInstalled", map[string]string{"arg1": state.Version})).FontSize(12).Color(w.pal.success)
				} else if selected.Availability.Status != "available" && selected.Availability.Message != "" {
					// Core's own sentence about why this platform cannot install it.
					ui.Wrap(c, selected.Availability.Message).FontSize(12).Color(w.pal.warning)
				}
			})
			w.marketLinks(c, language, selected)
			ui.Row(c).FillWidth().Gap(8).Pad(10).Radius(6).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
				ui.Icon(c, icons.Info).Size(14, 14).Color(w.pal.muted).Shrink(0)
				ui.Wrap(c, i18n.Shared(language, "native.thisPluginIsMaintainedByACommunityDeveloperNotByLitheLitheVerifiedThatTheDownl1989920b43")).
					FontSize(12).Color(w.pal.muted).Grow(1).Shrink(1).MinWidth(0)
			})
		})
	})
}

// marketDetailAction is the button of the listing's header.
func (w *window) marketDetailAction(c ui.C, language i18n.Language, plugin core.MarketplacePlugin) {
	install := w.ctrl.opts.InstallPlugin
	switch w.marketOfferFor(plugin) {
	case offerInstall:
		if ui.Button(c, i18n.Shared(language, "desktop.marketplace.install")).Small().Disabled(install == nil).Clicked() && install != nil {
			install(plugin)
		}
	case offerUpdate:
		label := i18n.SharedFormat(language, "native.updateTo.variant2", map[string]string{"arg1": offeredVersion(plugin)})
		if ui.Button(c, label).Small().Disabled(install == nil).Clicked() && install != nil {
			install(plugin)
		}
	case offerInstalled:
		ui.Button(c, i18n.Shared(language, "native.installed")).Small().Secondary().Disabled(true)
		if w.ctrl.opts.UninstallPlugin != nil && ui.Button(c, i18n.Shared(language, "desktop.marketplace.uninstall")).Small().Outline().Clicked() {
			w.askUninstall(plugin.ID, plugin.Name)
		}
	case offerUnsupported:
		ui.Button(c, i18n.Shared(language, "native.notSupported")).Small().Secondary().Disabled(true)
	}
}

// marketLinks are the listing's source repository and homepage, opened in the browser.
func (w *window) marketLinks(c ui.C, language i18n.Language, plugin core.MarketplacePlugin) {
	open := w.ctrl.opts.OpenURL
	homepage := ""
	if plugin.Homepage != nil {
		homepage = *plugin.Homepage
	}
	if open == nil || !webURL(plugin.Repository) && !webURL(homepage) {
		return
	}
	ui.Row(c).FillWidth().Gap(16).Items(ui.Center).Children(func() {
		if webURL(plugin.Repository) && ui.Button(c, i18n.Shared(language, "native.sourceRepository")).Link().Tooltip(plugin.Repository).Clicked() {
			open(plugin.Repository)
		}
		if webURL(homepage) && homepage != plugin.Repository && ui.Button(c, i18n.Shared(language, "native.homepage")).Link().Tooltip(homepage).Clicked() {
			open(homepage)
		}
	})
}

// webURL reports whether a listing's address can be opened in the browser.
func webURL(url string) bool {
	return strings.HasPrefix(url, "https://") && len(url) > len("https://")
}

// repositoryName is how a header names a source repository: owner/name for a GitHub
// address, the address without its scheme otherwise.
func repositoryName(repository string) string {
	name := strings.TrimSuffix(strings.TrimPrefix(repository, "https://"), "/")
	name = strings.TrimSuffix(name, ".git")
	return strings.TrimPrefix(name, "github.com/")
}

// marketDescription is the listing's description in the window's language when the
// listing has one, the description it gives otherwise.
func (w *window) marketDescription(plugin core.MarketplacePlugin) string {
	if w.marketLanguage() == i18n.Chinese {
		if value := plugin.LocalizedDescriptions["zh-Hans"]; value != "" {
			return value
		}
	}
	return plugin.Description
}

// pluginState is what the owner reports about an installed plugin.
func (w *window) pluginState(id string) PluginState {
	if w.ctrl.opts.PluginState == nil {
		return PluginState{}
	}
	return w.ctrl.opts.PluginState(id)
}

// originBadge says who stands behind a plugin: Lithe for an official one, a community
// developer for every other.
func (w *window) originBadge(c ui.C, language i18n.Language, official bool) {
	label, color := i18n.Shared(language, "native.community"), w.pal.warning
	if official {
		label, color = i18n.Shared(language, "native.official"), w.pal.accent
	}
	ui.Row(c).Shrink(0).PadX(6).PadY(2).Radius(4).Stroke(1, color).Children(func() {
		ui.Text(c, label).FontSize(10).Weight(gfx.WeightSemibold).Color(color)
	})
}

// emptyDetail is the detail pane with nothing chosen: a placeholder icon over a sentence.
func (w *window) emptyDetail(c ui.C, text string, size float32) {
	ui.Column(c).FillWidth().Grow(1).Center().Gap(10).Children(func() {
		ui.Row(c).Size(size, size).Radius(size * 0.235).Background(w.pal.selectionIdle).Center().Children(func() {
			ui.Icon(c, icons.Cpu).Size(size*0.6, size*0.6).Color(w.pal.subtle)
		})
		ui.Text(c, text).FontSize(15).Weight(gfx.WeightMedium).Color(w.pal.muted)
	})
}

func (w *window) marketMetadata(c ui.C, label, value string) {
	ui.Row(c).FillWidth().Gap(12).Children(func() {
		ui.Text(c, label).Width(96).Shrink(0).FontSize(12).Color(w.pal.muted)
		ui.Text(c, value).Grow(1).Shrink(1).FontSize(12).Color(w.pal.text).Ellipsis()
	})
}

// marketAvatar is a plugin's icon: the native client uses a stable color per plugin ID and
// the initials of its name until an index icon is available. Keep these presentation
// metrics identical.
func (w *window) marketAvatar(c ui.C, id, name string, size float32) {
	colors := [...][2]uint32{
		{0xe08855, 0xe9806f}, {0xb08b14, 0xbb7f19}, {0xa1a359, 0x87aa59},
		{0x3b92b8, 0x6183ec}, {0x3574f0, 0x7a64f0}, {0xc84d8f, 0xa956cf},
		{0x955ae0, 0xa84de0}, {0x24a394, 0x279ccd}, {0x5fad65, 0x3d968b},
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(id))
	color := colors[hash.Sum64()%uint64(len(colors))]
	label := marketplaceInitials(name)
	ui.Row(c).Size(size, size).Shrink(0).Radius(size*0.235).
		Gradient(ui.ToBottomRight, gfx.RGB24(color[0]), gfx.RGB24(color[1])).Center().Children(func() {
		if label == "" {
			ui.Icon(c, icons.Cpu).Size(size*0.65, size*0.65).Color(w.pal.white)
		} else {
			ui.Text(c, label).FontSize(size * 0.65).Mono().Weight(gfx.WeightSemibold).Color(w.pal.white)
		}
	})
}

func marketplaceInitials(name string) string {
	words := strings.FieldsFunc(name, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) })
	if len(words) == 0 {
		return ""
	}
	first := []rune(words[0])
	if unicode.Is(unicode.Han, first[0]) || unicode.Is(unicode.Hiragana, first[0]) || unicode.Is(unicode.Katakana, first[0]) || unicode.Is(unicode.Hangul, first[0]) {
		return string(first[0])
	}
	if len(words) > 1 {
		second := []rune(words[1])[0]
		if !unicode.Is(unicode.Han, second) && !unicode.Is(unicode.Hiragana, second) && !unicode.Is(unicode.Katakana, second) && !unicode.Is(unicode.Hangul, second) {
			return strings.ToUpper(string([]rune{first[0], second}))
		}
	}
	return strings.ToUpper(string(first[:min(2, len(first))]))
}
