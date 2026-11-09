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

var (
	marketDetailID    = tree.ID(root, "marketplace-detail")
	marketQueryID     = tree.ID(root, "marketplace-query")
	marketScrollID    = tree.ID(root, "marketplace-list")
	marketRetryID     = tree.ID(root, "marketplace-retry")
	marketDividerID   = tree.ID(root, "marketplace-divider")
	marketInstallID   = tree.ID(root, "marketplace-install")
	marketUninstallID = tree.ID(root, "marketplace-uninstall")
	marketEnableID    = tree.ID(root, "marketplace-enable")
	marketDisableID   = tree.ID(root, "marketplace-disable")
	marketRows        = tree.Sub(root, tree.Name("marketplace-rows"))
	marketSourceScope = tree.Sub(root, tree.Name("marketplace-source"))
)

const (
	marketListWidth       = 320
	marketDividerWidth    = 5
	marketDividerHitWidth = 10
	marketRowHeight       = 50
	marketOverscan        = 2
)

// marketWake is called on the window thread when an index fetch completes.
func (w *window) marketWake() {
	if w.requestPlugins.Swap(false) {
		w.search.SetText("")
		w.sess.page = pagePlugins
	}
	previous := w.market.status
	w.market.drain()
	w.market.search.drain(w.market, w.marketQuery.Text())
	if previous == marketLoading && w.market.status == marketFailed && w.ctrl.opts.MarketplaceError != nil {
		w.ctrl.opts.MarketplaceError(w.market.err)
	}
	if previous == marketLoading && w.market.status == marketReady && len(w.market.snapshot.Index.Rejected) > 0 && w.ctrl.opts.MarketplaceRejected != nil {
		w.ctrl.opts.MarketplaceRejected(len(w.market.snapshot.Index.Rejected))
	}
}
func (w *window) marketLanguage() i18n.Language {
	language := i18n.English
	if w.ctrl.opts.Language != nil {
		language = w.ctrl.opts.Language()
	}
	return language
}

// drawMarketplace paints only visible rows; Core already sorted and validated the index.
func (w *window) drawMarketplace(f *ui.Frame) {
	m := w.market
	if m.status == marketIdle {
		m.start()
	}
	if m.status == marketReady && m.search.rank != nil {
		query := w.marketQuery.Text()
		if !m.search.known || m.search.query != query {
			w.view.ScrollState(marketScrollID).ScrollTo(0)
		}
		m.search.update(query)
		if m.search.tooLong {
			m.selected = ""
		}
		if m.search.empty && m.selected == "" && len(m.snapshot.Index.Plugins) > 0 {
			m.selected = m.snapshot.Index.Plugins[0].ID
		}
	}
	f.Column().FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		f.Row().FillWidth().Height(46).Shrink(0).PadX(16).Items(ui.Center).Children(func() {
			f.Text(titleOf(&w.text.Settings, pagePlugins)).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
			f.Spacer()
			f.Row().Height(30).PadX(12).Radius(6).Background(w.pal.selection).Center().Children(func() {
				f.Text(i18n.Shared(w.marketLanguage(), "native.marketplace")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
			})
		})
		f.Row().FillWidth().Height(1).Shrink(0).Background(w.pal.line)
		w.marketColumns(f)
	})
}

func (w *window) marketColumns(f *ui.Frame) {
	m := w.market
	plugins := m.snapshot.Index.Plugins
	visible := m.search.visible()
	scroll := w.view.ScrollState(marketScrollID)
	height := scroll.Viewport
	if height <= 0 {
		height = 520
	}
	first := max(0, int(scroll.Offset/marketRowHeight)-marketOverscan)
	last := min(len(visible), int((scroll.Offset+height)/marketRowHeight)+marketOverscan+1)
	first = min(first, last)
	f.Row().FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		f.Column().Width(w.marketSplit.Size(w.marketExtent)).FillHeight().Shrink(0).Children(func() {
			if m.search.rank != nil {
				f.Row().FillWidth().Height(37).Shrink(0).PadX(12).Items(ui.End).Children(func() {
					f.Row().FillWidth().Height(30).Items(ui.Center).PadX(8).Gap(6).Border(1, w.pal.line).Radius(6).Children(func() {
						f.Icon(icons.Search).Size(15, 15).Color(w.pal.muted)
						f.FieldBase(&w.marketQuery, marketQueryID, i18n.Shared(w.marketLanguage(), "desktop.marketplace.search"), i18n.Shared(w.marketLanguage(), "desktop.marketplace.search")).Grow(1).MinWidth(0).Height(28).FontSize(13).Color(w.pal.text)
					})
				})
			}
			if m.official != nil {
				f.Row().FillWidth().Height(44).Shrink(0).PadX(12).Items(ui.Center).Children(func() {
					labels := []string{i18n.Shared(w.marketLanguage(), "desktop.marketplace.communitySource"), i18n.Shared(w.marketLanguage(), "desktop.marketplace.officialSource")}
					pick := f.Select(marketSourceScope, &w.marketSource, labels, m.source).Width(150).Label(i18n.Shared(w.marketLanguage(), "desktop.marketplace.source"))
					if index, ok := pick.Picked(); ok {
						previous := m.source
						m.chooseSource(index)
						if m.source != previous {
							w.view.ScrollState(marketScrollID).ScrollTo(0)
						}
					}
				})
				f.Row().FillWidth().Height(1).Shrink(0).Background(w.pal.line)
			}
			switch {
			case m.status == marketLoading || m.status == marketIdle:
				f.Column().FillWidth().Grow(1).Center().Children(func() { f.Text(i18n.Shared(w.marketLanguage(), "native.loading")).Color(w.pal.muted) })
			case m.status == marketFailed:
				f.Column().FillWidth().Grow(1).Center().Gap(8).Children(func() {
					f.Text(i18n.Shared(w.marketLanguage(), "native.pluginMarketplaceIsNotAvailable")).Color(w.pal.danger)
					if f.Button(marketRetryID, i18n.Shared(w.marketLanguage(), "ui.retry")).Outline().Clicked() {
						m.start()
					}
				})
			case m.search.loading:
				f.Column().FillWidth().Grow(1).Center().Children(func() { f.Text(i18n.Shared(w.marketLanguage(), "quickOpen.searching")).Color(w.pal.muted) })
			case m.search.failed:
				f.Column().FillWidth().Grow(1).Center().Children(func() { f.Text(i18n.Shared(w.marketLanguage(), "search.failed")).Color(w.pal.danger) })
			case m.search.tooLong:
				f.Column().FillWidth().Grow(1).Center().Children(func() { f.Text(i18n.Shared(w.marketLanguage(), "desktop.marketplace.queryTooLong")).Color(w.pal.muted) })
			case len(plugins) == 0:
				f.Column().FillWidth().Grow(1).Center().Children(func() { f.Text(i18n.Shared(w.marketLanguage(), "native.noPluginsAvailable")).Color(w.pal.muted) })
			case len(visible) == 0:
				f.Column().FillWidth().Grow(1).Center().Children(func() { f.Text(i18n.Shared(w.marketLanguage(), "native.noMatches")).Color(w.pal.muted) })
			default:
				f.Canvas().Container(w.marketListRect, gfx.RoleListBox, i18n.Shared(w.marketLanguage(), "native.marketplace"))
				w.marketListBox = f.ScrollArea(marketScrollID).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
					if first > 0 {
						f.Row().Height(float32(first) * marketRowHeight).Shrink(0)
					}
					for i := first; i < last; i++ {
						w.marketRow(f, i, len(visible), plugins[visible[i]])
					}
					if rest := len(visible) - last; rest > 0 {
						f.Row().Height(float32(rest) * marketRowHeight).Shrink(0)
					}
				})
			}
		})
		w.marketDivider = f.Row().Width(marketDividerWidth).FillHeight().Shrink(0).Center().Children(func() {
			f.Row().Width(2).FillHeight().Shrink(0).Background(w.pal.line)
		})
		f.ScrollArea(marketDetailID).Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
			f.Column().FillWidth().Shrink(0).MinWidth(0).Pad(24).Gap(12).Children(func() {
				if m.status != marketReady {
					return
				}
				index, found := m.index[m.selected]
				if !found {
					f.Text(i18n.Shared(w.marketLanguage(), "native.selectAPlugin")).Color(w.pal.muted)
					return
				}
				selected := &plugins[index]
				f.Row().FillWidth().Gap(14).Items(ui.Center).Children(func() {
					w.marketAvatar(f, *selected, 48)
					f.Column().Grow(1).Shrink(1).MinWidth(0).Gap(6).Children(func() {
						f.Text(selected.Name).FontSize(20).Weight(gfx.WeightBold).Color(w.pal.text).Ellipsis()
						f.Text(selected.Author).FontSize(12).Color(w.pal.muted).Ellipsis()
					})
				})
				f.Wrap(i18n.Shared(w.marketLanguage(), "desktop.marketplace.hostUnavailable")).FontSize(12).Color(w.pal.muted)
				description := selected.Description
				if w.ctrl.opts.Language != nil && w.ctrl.opts.Language() == i18n.Chinese {
					if value := selected.LocalizedDescriptions["zh-Hans"]; value != "" {
						description = value
					}
				}
				f.Wrap(description).FontSize(12).Color(w.pal.text)
				w.marketMetadata(f, i18n.Shared(w.marketLanguage(), "native.version"), selected.LatestVersion)
				w.marketMetadata(f, i18n.Shared(w.marketLanguage(), "native.releaseDate"), selected.LatestReleaseDate)
				w.marketMetadata(f, i18n.Shared(w.marketLanguage(), "native.license"), selected.License)
				w.marketPluginActions(f, *selected)
			})
		})
	})
}

// marketPluginActions declares what the user may do with the selected plugin.
//
// The page decides nothing about installation: it asks the owner for the state it
// paints and hands every action back, so the window cannot install, enable or
// remove anything on its own thread.
func (w *window) marketPluginActions(f *ui.Frame, plugin core.MarketplacePlugin) {
	if w.ctrl.opts.PluginState == nil {
		return
	}
	language := w.marketLanguage()
	state := w.ctrl.opts.PluginState(plugin.ID)
	f.Row().FillWidth().Gap(8).Items(ui.Center).Children(func() {
		if !state.Installed {
			if w.ctrl.opts.InstallPlugin == nil {
				return
			}
			if f.Button(marketInstallID, i18n.Shared(language, "desktop.marketplace.install")).Clicked() {
				w.ctrl.opts.InstallPlugin(plugin)
			}
			return
		}
		f.Text(i18n.Shared(language, "desktop.marketplace.installed")).FontSize(12).Color(w.pal.muted)
		if state.Enabled {
			if w.ctrl.opts.SetPluginEnabled != nil && f.Button(marketDisableID, i18n.Shared(language, "desktop.marketplace.disable")).Outline().Clicked() {
				w.ctrl.opts.SetPluginEnabled(plugin.ID, false)
			}
		} else if w.ctrl.opts.SetPluginEnabled != nil && f.Button(marketEnableID, i18n.Shared(language, "desktop.marketplace.enable")).Outline().Clicked() {
			w.ctrl.opts.SetPluginEnabled(plugin.ID, true)
		}
		if w.ctrl.opts.UninstallPlugin != nil && f.Button(marketUninstallID, i18n.Shared(language, "desktop.marketplace.uninstall")).Outline().Clicked() {
			w.ctrl.opts.UninstallPlugin(plugin.ID)
		}
	})
}

func (w *window) marketRow(f *ui.Frame, index, total int, plugin core.MarketplacePlugin) {
	selected := plugin.ID == w.market.selected
	row := f.Row().FillWidth().Height(marketRowHeight).Shrink(0).PadX(14).Gap(10).Items(ui.Center).
		HitWith(marketRows.At(index), plugin.Name, gfx.HitOptions{Role: gfx.RoleOption, Selected: selected, PosInSet: int32(index + 1), SetSize: int32(total), Cursor: gfx.PointerCursorHand}).
		Hover(ui.Look{}.Background(w.pal.hover))
	if selected {
		row = row.Background(w.pal.selectionIdle)
	}
	row.Children(func() {
		w.marketAvatar(f, plugin, 32)
		f.Column().Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
			f.Text(plugin.Name).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
			f.Text(plugin.Author + " · " + plugin.LatestVersion).FontSize(11).Color(w.pal.muted).Ellipsis()
		})
	})
	if row.Clicked() {
		w.market.selected = plugin.ID
	}
}
func (w *window) marketMetadata(f *ui.Frame, label, value string) {
	f.Row().FillWidth().Gap(12).Children(func() {
		f.Text(label).Width(96).Shrink(0).FontSize(12).Color(w.pal.muted)
		f.Text(value).Grow(1).Shrink(1).FontSize(12).Color(w.pal.text).Ellipsis()
	})
}

// The native client uses a stable color per plugin ID and an initials avatar
// until an index icon is available. Keep these presentation metrics identical.
func (w *window) marketAvatar(f *ui.Frame, plugin core.MarketplacePlugin, size float32) {
	colors := [...][2]uint32{
		{0xe08855, 0xe9806f}, {0xb08b14, 0xbb7f19}, {0xa1a359, 0x87aa59},
		{0x3b92b8, 0x6183ec}, {0x3574f0, 0x7a64f0}, {0xc84d8f, 0xa956cf},
		{0x955ae0, 0xa84de0}, {0x24a394, 0x279ccd}, {0x5fad65, 0x3d968b},
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(plugin.ID))
	color := colors[hash.Sum64()%uint64(len(colors))]
	label := marketplaceInitials(plugin.Name)
	f.Row().Size(size, size).Shrink(0).Radius(size*0.235).
		Gradient(ui.ToBottomRight, gfx.RGB24(color[0]), gfx.RGB24(color[1])).Center().Children(func() {
		if label == "" {
			f.Icon(icons.Cpu).Size(size*0.65, size*0.65).Color(w.pal.white)
		} else {
			f.Text(label).FontSize(size * 0.65).Mono().Weight(gfx.WeightSemibold).Color(w.pal.white)
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

// marketKey keeps keyboard selection and the scroll viewport together.
func (w *window) marketKey(event gfx.KeyEvent) gfx.EventResult {
	index, ok := event.Target.In(marketRows)
	plugins := w.market.snapshot.Index.Plugins
	visible := w.market.search.visible()
	if !ok || event.Release || event.Modifiers != 0 || index < 0 || index >= len(visible) {
		return gfx.EventResult{}
	}
	switch event.Key {
	case gfx.KeyUp:
		index = max(0, index-1)
	case gfx.KeyDown:
		index = min(len(visible)-1, index+1)
	default:
		return gfx.EventResult{}
	}
	w.market.selected = plugins[visible[index]].ID
	scroll := w.view.ScrollState(marketScrollID)
	top, bottom := float32(index)*marketRowHeight, float32(index+1)*marketRowHeight
	if top < scroll.Offset {
		scroll.ScrollTo(top)
	} else if bottom > scroll.Offset+scroll.Viewport {
		scroll.ScrollTo(bottom - scroll.Viewport)
	}
	w.marketFocus = marketRows.At(index)
	return gfx.EventResult{Handled: true, Repaint: true}
}
