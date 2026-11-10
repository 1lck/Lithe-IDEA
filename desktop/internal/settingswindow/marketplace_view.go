package settingswindow

import (
	"hash/fnv"
	"strings"
	"unicode"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	marketListWidth = 320
	// marketRowHeight is the height of a plugin in the list.
	marketRowHeight = 50
	// marketMinWidth and marketMaxWidth bound the plugin list's width, and marketMinDetail
	// is what the detail beside it keeps.
	marketMinWidth  = 200
	marketMaxWidth  = 520
	marketMinDetail = 160
	// marketSplitterWidth is the thickness of the divider between the list and the detail.
	marketSplitterWidth = 8
)

// marketSourceChoices are the sources of the index: community, official, installed.
var marketSourceChoices = []int{0, 1, 2}

func (w *window) marketLanguage() i18n.Language {
	language := i18n.English
	if w.ctrl.opts.Language != nil {
		language = w.ctrl.opts.Language()
	}
	return language
}

// marketSourceLabel is the words of source.
func (w *window) marketSourceLabel(source int) string {
	switch source {
	case 1:
		return i18n.Shared(w.marketLanguage(), "desktop.marketplace.officialSource")
	case 2:
		return i18n.Shared(w.marketLanguage(), "desktop.marketplace.installedSource")
	}
	return i18n.Shared(w.marketLanguage(), "desktop.marketplace.communitySource")
}

// marketplacePage declares the plugin marketplace; only the rows on screen are declared,
// and Core already sorted and validated the index.
func (w *window) marketplacePage(c ui.C) {
	m := w.market
	if m.status == marketIdle {
		m.start()
	}
	if m.status == marketReady && m.search.rank != nil {
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
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		ui.Row(c).FillWidth().Height(46).Shrink(0).PadX(16).Items(ui.Center).Children(func() {
			ui.Text(c, titleOf(&w.text.Settings, pagePlugins)).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
			ui.Spacer(c)
			ui.Row(c).Height(30).PadX(12).Radius(6).Background(w.pal.selection).Center().Children(func() {
				ui.Text(c, i18n.Shared(w.marketLanguage(), "native.marketplace")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
			})
		})
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
		w.marketColumns(c)
	})
}

// marketColumns declares the list beside the detail of the selected plugin, with the
// divider between them.
func (w *window) marketColumns(c ui.C) {
	m := w.market
	language := w.marketLanguage()
	plugins := m.snapshot.Index.Plugins
	visible := m.search.visible()
	w.syncMarketSplit()
	ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		ui.Column(c).Width(w.marketApplied).FillHeight().Shrink(0).Children(func() {
			if m.search.rank != nil {
				ui.Row(c).FillWidth().Height(37).Shrink(0).PadX(12).Items(ui.End).Children(func() {
					search := i18n.Shared(language, "desktop.marketplace.search")
					ui.TextField(c, &w.marketQuery, search, search).Icon(icons.Search).FillWidth().Height(30)
				})
			}
			if m.official != nil || m.installed != nil {
				ui.Row(c).FillWidth().Height(44).Shrink(0).PadX(12).Items(ui.Center).Children(func() {
					choices := marketSourceChoices[:2]
					if m.installed != nil {
						choices = marketSourceChoices
					}
					w.marketSourcePick = m.source
					ui.Select(c, &w.marketSourcePick, choices, w.marketSourceLabel).Width(150).Label(i18n.Shared(language, "desktop.marketplace.source"))
					if w.marketSourcePick != m.source {
						m.chooseSource(w.marketSourcePick)
						m.list.ScrollTo(0, ui.ListStart)
					}
				})
				ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
			}
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
			case len(plugins) == 0:
				w.marketNotice(c, i18n.Shared(language, "native.noPluginsAvailable"), w.pal.muted)
			case len(visible) == 0:
				w.marketNotice(c, i18n.Shared(language, "native.noMatches"), w.pal.muted)
			default:
				w.marketList(c, plugins, visible)
			}
		})
		split := ui.Splitter(c, &w.marketSplit).Mins(marketMinWidth, marketMinDetail).Label(i18n.Shared(language, "settings.resizePlugins"))
		// The Page does not route a splitter's keys: the divider's own shortcuts move it
		// while it has the focus, by a step or to either end.
		for _, move := range marketSplitKeys {
			if split.Shortcut(0, move.key) {
				w.marketSplit.Pos = w.marketSplitMove(move.step, move.edge)
			}
		}
		ui.Scroll(c.Part("detail")).Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
			ui.Column(c).FillWidth().Shrink(0).MinWidth(0).Pad(24).Gap(12).Children(func() {
				w.marketDetail(c)
			})
		})
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

// marketNotice is a sentence in the middle of the list's column.
func (w *window) marketNotice(c ui.C, text string, color ui.Color) {
	ui.Column(c).FillWidth().Grow(1).Center().Children(func() { ui.Text(c, text).Color(color) })
}

// marketList is the plugins the search lists. Choosing a row, by pointer or by the arrows,
// selects its plugin.
func (w *window) marketList(c ui.C, plugins []core.MarketplacePlugin, visible []int) {
	m := w.market
	if m.listFor != m.selected {
		m.listFor = m.selected
		m.list.Select(-1)
		for row, index := range visible {
			if plugins[index].ID == m.selected {
				m.list.Select(row)
				m.list.ScrollIntoView(row)
				break
			}
		}
	}
	ui.List(c, &m.list, len(visible), func(row ui.ListRow) {
		plugin := plugins[visible[row.Index]]
		row.Element.FillWidth().Height(marketRowHeight).PadX(14).Gap(10).Items(ui.Center).Hover(ui.Look{}.Background(w.pal.hover))
		if row.Selected() {
			row.Element.Background(w.pal.selectionIdle)
		}
		row.Element.Children(func() {
			w.marketAvatar(row.C, plugin, 32)
			ui.Column(row.C).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
				ui.Text(row.C, plugin.Name).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
				ui.Text(row.C, plugin.Author+" · "+plugin.LatestVersion).FontSize(11).Color(w.pal.muted).Ellipsis()
			})
		})
	}).FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(i18n.Shared(w.marketLanguage(), "native.marketplace"))
	if m.list.Changed() {
		if row := m.list.Selected(); row >= 0 && row < len(visible) {
			m.selected = plugins[visible[row]].ID
			m.listFor = m.selected
		}
	}
}

// marketDetail is the selected plugin: who made it, what it says about itself and what the
// user can do with it.
func (w *window) marketDetail(c ui.C) {
	m := w.market
	language := w.marketLanguage()
	plugins := m.snapshot.Index.Plugins
	if m.status != marketReady {
		return
	}
	index, found := m.index[m.selected]
	if !found {
		ui.Text(c, i18n.Shared(language, "native.selectAPlugin")).Color(w.pal.muted)
		return
	}
	selected := &plugins[index]
	ui.Row(c).FillWidth().Gap(14).Items(ui.Center).Children(func() {
		w.marketAvatar(c, *selected, 48)
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Children(func() {
			ui.Text(c, selected.Name).FontSize(20).Weight(gfx.WeightBold).Color(w.pal.text).Ellipsis()
			ui.Text(c, selected.Author).FontSize(12).Color(w.pal.muted).Ellipsis()
		})
	})
	if w.ctrl.opts.PluginSettings == nil {
		ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.hostUnavailable")).FontSize(12).Color(w.pal.muted)
	}
	description := selected.Description
	if w.ctrl.opts.Language != nil && w.ctrl.opts.Language() == i18n.Chinese {
		if value := selected.LocalizedDescriptions["zh-Hans"]; value != "" {
			description = value
		}
	}
	if description != "" {
		ui.Wrap(c, description).FontSize(12).Color(w.pal.text)
	}
	w.marketMetadata(c, i18n.Shared(language, "native.version"), selected.LatestVersion)
	if selected.LatestReleaseDate != "" {
		w.marketMetadata(c, i18n.Shared(language, "native.releaseDate"), selected.LatestReleaseDate)
	}
	if selected.License != "" {
		w.marketMetadata(c, i18n.Shared(language, "native.license"), selected.License)
	}
	w.marketPluginActions(c, *selected)
	if w.ctrl.opts.PluginState != nil && w.ctrl.opts.PluginState(selected.ID).Installed {
		w.pluginSettingsPanel(c, selected.ID)
	}
}

// marketPluginActions declares what the user may do with the selected plugin.
//
// The page decides nothing about installation: it asks the owner for the state it
// paints and hands every action back, so the window cannot install, enable or
// remove anything on its own thread.
func (w *window) marketPluginActions(c ui.C, plugin core.MarketplacePlugin) {
	if w.ctrl.opts.PluginState == nil {
		return
	}
	language := w.marketLanguage()
	state := w.ctrl.opts.PluginState(plugin.ID)
	ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
		if !state.Installed {
			if w.ctrl.opts.InstallPlugin == nil {
				return
			}
			if ui.Button(c, i18n.Shared(language, "desktop.marketplace.install")).Clicked() {
				w.ctrl.opts.InstallPlugin(plugin)
			}
			return
		}
		ui.Text(c, i18n.Shared(language, "desktop.marketplace.installed")).FontSize(12).Color(w.pal.muted)
		if state.Enabled {
			if w.ctrl.opts.SetPluginEnabled != nil && ui.Button(c, i18n.Shared(language, "desktop.marketplace.disable")).Outline().Clicked() {
				w.ctrl.opts.SetPluginEnabled(plugin.ID, false)
			}
		} else if w.ctrl.opts.SetPluginEnabled != nil && ui.Button(c, i18n.Shared(language, "desktop.marketplace.enable")).Outline().Clicked() {
			w.ctrl.opts.SetPluginEnabled(plugin.ID, true)
		}
		if w.ctrl.opts.UninstallPlugin != nil && ui.Button(c, i18n.Shared(language, "desktop.marketplace.uninstall")).Outline().Clicked() {
			w.ctrl.opts.UninstallPlugin(plugin.ID)
		}
	})
}

func (w *window) marketMetadata(c ui.C, label, value string) {
	ui.Row(c).FillWidth().Gap(12).Children(func() {
		ui.Text(c, label).Width(96).Shrink(0).FontSize(12).Color(w.pal.muted)
		ui.Text(c, value).Grow(1).Shrink(1).FontSize(12).Color(w.pal.text).Ellipsis()
	})
}

// The native client uses a stable color per plugin ID and an initials avatar
// until an index icon is available. Keep these presentation metrics identical.
func (w *window) marketAvatar(c ui.C, plugin core.MarketplacePlugin, size float32) {
	colors := [...][2]uint32{
		{0xe08855, 0xe9806f}, {0xb08b14, 0xbb7f19}, {0xa1a359, 0x87aa59},
		{0x3b92b8, 0x6183ec}, {0x3574f0, 0x7a64f0}, {0xc84d8f, 0xa956cf},
		{0x955ae0, 0xa84de0}, {0x24a394, 0x279ccd}, {0x5fad65, 0x3d968b},
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(plugin.ID))
	color := colors[hash.Sum64()%uint64(len(colors))]
	label := marketplaceInitials(plugin.Name)
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
