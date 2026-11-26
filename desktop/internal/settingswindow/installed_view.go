package settingswindow

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
	"github.com/vivaui/viva/ui/textview"
)

// The Installed tab of the plugin page, laid out as the macOS client's is: a search with
// filter chips over the installed plugins, the enabled ones before the disabled ones, beside
// the chosen plugin's header, its notices and six tabs. What it shows comes from the owner's
// InstalledPlugins, which answers from memory; the marketplace index the page reads adds the
// updates, descriptions and repositories, and the repository's releases the changelog
// (installed_changelog.go).

// installedState is the Installed tab's own state. Only the window thread uses it.
type installedState struct {
	// query is the search text; a text that starts with "/" picks a filter instead.
	query string
	// filter is the chosen filter chip, one of the installedFilter constants.
	filter int
	// selected is the ID of the chosen plugin and tab the open tab of its detail.
	selected string
	tab      int
	// list is the plugin list, listFor the plugin it last showed as chosen and rows what it
	// lists this paint.
	list    ui.ListState
	listFor string
	rows    []installedRow
	bound   bool
	// keys are the list keys the plugins have had, by plugin ID; see rowKey.
	keys map[string]int
	// programsOpen are the program declarations the Permissions & Programs tab shows in
	// full, by programKey, and programTexts the colored texts they are shown in: one is made
	// the first time its declaration is shown and dropped when the declaration closes.
	programsOpen map[string]bool
	programTexts map[string]*programText
	// programTheme colors the declarations as the editor colors JSON, in the look
	// programThemeDark names; see declarationTheme.
	programTheme     *syntax.Theme
	programThemeDark bool
	// uninstallOpen says the confirmation of an uninstall is shown, for the plugin
	// uninstallID named uninstallName. Both tabs ask through it.
	uninstallOpen bool
	uninstallID   string
	uninstallName string
}

// installedRow is one row of the Installed list: a group's heading, or a plugin.
type installedRow struct {
	// heading is the group's words, empty for a plugin's row.
	heading string
	// fact is the index of the plugin in the facts the list was made from.
	fact int
	id   string
	name string
	// key is the row's list key; see rowKey.
	key int
}

// The filter chips of the Installed tab, in the order the chips show them.
const (
	installedAll = iota
	installedLanguageServers
	installedBuild
	installedDebug
	installedInterface
	installedUpdates
	installedCommunity
	installedDisabled
	installedFilterCount
)

// installedFilterTokens are what the user types after "/" to pick a filter.
var installedFilterTokens = [installedFilterCount]string{"all", "lsp", "build", "debug", "ui", "update", "community", "disabled"}

// installedFilterTitle is a filter chip's words.
func installedFilterTitle(language i18n.Language, filter int) string {
	switch filter {
	case installedLanguageServers:
		return i18n.Shared(language, "native.languageServices")
	case installedBuild:
		return i18n.Shared(language, "native.build")
	case installedDebug:
		return i18n.Shared(language, "native.debug")
	case installedInterface:
		return i18n.Shared(language, "native.interface")
	case installedUpdates:
		return i18n.Shared(language, "native.updates")
	case installedCommunity:
		return i18n.Shared(language, "native.communityDisk")
	case installedDisabled:
		return i18n.Shared(language, "native.disabled.variant2")
	}
	return i18n.Shared(language, "native.all")
}

// The tabs of an installed plugin's detail, in the order the tab bar shows them.
const (
	installedOverview = iota
	installedFeatures
	installedSettings
	installedPermissions
	installedVersions
	installedChangelog
	installedTabCount
)

// installedTabTitle is a detail tab's words.
func installedTabTitle(language i18n.Language, tab int) string {
	switch tab {
	case installedFeatures:
		return i18n.Shared(language, "native.features")
	case installedSettings:
		return i18n.Shared(language, "desktop.marketplace.tab.settings")
	case installedPermissions:
		return i18n.Shared(language, "native.permissionsPrograms")
	case installedVersions:
		return i18n.Shared(language, "native.versionsSource")
	case installedChangelog:
		return i18n.Shared(language, "native.updateLog")
	}
	return i18n.Shared(language, "native.overview")
}

// installedFacts are the installed plugins the owner reports, in name order.
func (w *window) installedFacts() []PluginFacts {
	if w.ctrl.opts.InstalledPlugins == nil {
		return nil
	}
	return w.ctrl.opts.InstalledPlugins()
}

// installedColumns declares the Installed tab: the list beside the chosen plugin.
func (w *window) installedColumns(c ui.C, language i18n.Language) {
	s := &w.installed
	facts := w.installedFacts()
	s.layout(w, language, facts)
	var chosen *PluginFacts
	for index := range facts {
		if facts[index].ID == s.selected {
			chosen = &facts[index]
			break
		}
	}
	w.pluginColumns(c, language, func() { w.installedSidebar(c, language, facts) }, func() {
		if chosen == nil {
			w.emptyDetail(c, i18n.Shared(language, "native.selectAPlugin"), 36)
			return
		}
		w.installedDetail(c, language, *chosen)
	})
}

// layout works out the rows the list shows this paint: the plugins the search and the
// chip keep, enabled first, each group under its heading. A chosen plugin the rows no
// longer hold gives way to the first one.
func (s *installedState) layout(w *window, language i18n.Language, facts []PluginFacts) {
	if !s.bound {
		s.bound = true
		s.list.Key, s.list.Label = s.rowKey, s.rowLabel
		s.list.Header = func(i int) bool { return i >= 0 && i < len(s.rows) && s.rows[i].heading != "" }
	}
	query := strings.ToLower(strings.TrimSpace(s.query))
	if strings.HasPrefix(query, "/") {
		query = ""
	}
	var enabled, disabled []installedRow
	for index, fact := range facts {
		if !w.installedMatches(s.filter, fact) || query != "" && !installedFound(fact, query) {
			continue
		}
		row := installedRow{fact: index, id: fact.ID, name: installedName(fact), key: s.pluginKey(fact.ID)}
		if w.pluginState(fact.ID).Enabled {
			enabled = append(enabled, row)
		} else {
			disabled = append(disabled, row)
		}
	}
	s.rows = s.rows[:0]
	if len(enabled) > 0 {
		s.rows = append(s.rows, installedRow{heading: i18n.Shared(language, "native.enabled.variant2"), key: installedEnabledKey})
		s.rows = append(s.rows, enabled...)
	}
	if len(disabled) > 0 {
		s.rows = append(s.rows, installedRow{heading: i18n.Shared(language, "native.disabled.variant2"), key: installedDisabledKey})
		s.rows = append(s.rows, disabled...)
	}
	if s.selected == "" || !slices.ContainsFunc(s.rows, func(row installedRow) bool { return row.heading == "" && row.id == s.selected }) {
		s.selected = ""
		for _, row := range s.rows {
			if row.heading == "" {
				s.selected = row.id
				break
			}
		}
	}
}

// The list keys of the two headings; a plugin's key comes after them.
const (
	installedEnabledKey = iota
	installedDisabledKey
	installedFirstPluginKey
)

// rowKey is row i's list key. A plugin's row has the key its plugin was given the first time
// a list held it, so a row keeps its identity while the groups move it. The keys count up
// rather than hash the ID: the list names a row's identity only by a key from 0 to 2^31-1 and
// gives every other key the same name, under which a click on any row reaches all of them.
func (s *installedState) rowKey(i int) int {
	if i < 0 || i >= len(s.rows) {
		return i
	}
	return s.rows[i].key
}

// pluginKey is the list key of plugin id, given the next free one the first time it is asked.
func (s *installedState) pluginKey(id string) int {
	if key, ok := s.keys[id]; ok {
		return key
	}
	if s.keys == nil {
		s.keys = map[string]int{}
	}
	key := installedFirstPluginKey + len(s.keys)
	s.keys[id] = key
	return key
}

// rowLabel is the name of the plugin row i lists.
func (s *installedState) rowLabel(i int) string {
	if i < 0 || i >= len(s.rows) {
		return ""
	}
	if s.rows[i].heading != "" {
		return s.rows[i].heading
	}
	return s.rows[i].name
}

// installedName is the name a plugin shows: its manifest's display name, or its ID.
func installedName(fact PluginFacts) string {
	if fact.Name != "" {
		return fact.Name
	}
	return fact.ID
}

// installedFound reports whether the search text names the plugin: its name, its vendor
// or the title of something it provides.
func installedFound(fact PluginFacts, query string) bool {
	if strings.Contains(strings.ToLower(installedName(fact)), query) || strings.Contains(strings.ToLower(fact.Vendor), query) {
		return true
	}
	for _, capability := range fact.Capabilities {
		if strings.Contains(strings.ToLower(capability.Title), query) {
			return true
		}
	}
	return false
}

// installedMatches reports whether the filter chip keeps the plugin.
func (w *window) installedMatches(filter int, fact PluginFacts) bool {
	has := func(kinds ...string) bool {
		return slices.ContainsFunc(fact.Capabilities, func(capability PluginCapability) bool { return slices.Contains(kinds, capability.Kind) })
	}
	switch filter {
	case installedLanguageServers:
		return has(CapabilityLanguageServer)
	case installedBuild:
		return has(CapabilityBuildSystem)
	case installedDebug:
		return has(CapabilityDebugger)
	case installedInterface:
		return has(CapabilityToolWindow, CapabilityCommand)
	case installedUpdates:
		_, update := w.installedUpdate(fact)
		return update
	case installedDisabled:
		return !w.pluginState(fact.ID).Enabled
	}
	// Every plugin is a community one: Lithe signs none of them.
	return true
}

// marketEntry is the listing of an installed plugin in the index the page last read.
func (w *window) marketEntry(id string) (core.MarketplacePlugin, bool) {
	m := w.market
	if m.status != marketReady {
		return core.MarketplacePlugin{}, false
	}
	index, ok := m.index[id]
	if !ok {
		return core.MarketplacePlugin{}, false
	}
	return m.snapshot.Index.Plugins[index], true
}

// installedUpdate is the listing that updates an installed plugin, and whether there is one.
func (w *window) installedUpdate(fact PluginFacts) (core.MarketplacePlugin, bool) {
	entry, ok := w.marketEntry(fact.ID)
	return entry, ok && newerOffered(entry, fact.Version)
}

// installedSidebar is the Installed tab's list column: the search and the filter chips,
// how many are installed and enabled, then the plugins.
func (w *window) installedSidebar(c ui.C, language i18n.Language, facts []PluginFacts) {
	s := &w.installed
	ui.Column(c).FillWidth().Shrink(0).Pad(8).Gap(8).Children(func() {
		search := i18n.Shared(language, "native.typeToSeeOptions")
		ui.TextField(c, &s.query, search, search).Icon(icons.Search).FillWidth().Height(30)
		if strings.HasPrefix(s.query, "/") {
			w.installedSlashMenu(c, language)
			return
		}
		ui.Flow(c).FillWidth().Gap(5).LineGap(5).Children(func() {
			for filter := range installedFilterCount {
				w.installedChip(c, language, filter)
			}
		})
	})
	ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
	enabled := 0
	for _, fact := range facts {
		if w.pluginState(fact.ID).Enabled {
			enabled++
		}
	}
	ui.Row(c).FillWidth().Height(38).Shrink(0).PadX(14).Items(ui.Center).Children(func() {
		summary := i18n.SharedFormat(language, "native.installedLldOfLldEnabled", map[string]string{"arg1": strconv.Itoa(enabled), "arg2": strconv.Itoa(len(facts))})
		ui.Text(c, summary).FontSize(12).Weight(gfx.WeightMedium).Color(w.pal.muted).Ellipsis()
	})
	if len(s.rows) == 0 {
		ui.Column(c).FillWidth().Grow(1).Center().Gap(10).Children(func() {
			ui.Icon(c, icons.Cpu).Size(30, 30).Color(w.pal.subtle)
			ui.Text(c, i18n.Shared(language, "native.noPlugins")).FontSize(15).Weight(gfx.WeightMedium).Color(w.pal.muted)
		})
		return
	}
	w.installedList(c, language, facts)
}

// installedChip is one filter chip: filled while it is chosen, outlined otherwise.
func (w *window) installedChip(c ui.C, language i18n.Language, filter int) {
	s := &w.installed
	k := c.KeyInt(filter)
	title := installedFilterTitle(language, filter)
	chosen := s.filter == filter
	chip := ui.Row(k).Shrink(0).PadX(8).PadY(3).Radius(100).Items(ui.Center).
		HitWith(ui.ID(k), title, gfx.HitOptions{Role: gfx.RoleRadio, Cursor: gfx.PointerCursorHand, Checked: chosen})
	weight := gfx.WeightRegular
	if chosen {
		chip = chip.Background(w.pal.selection)
		weight = gfx.WeightSemibold
	} else {
		chip = chip.Stroke(1, w.pal.border).Hover(ui.Look{}.Background(w.pal.hover))
	}
	chip.Children(func() {
		ui.Text(c, title).FontSize(11).Weight(weight).Color(w.pal.text)
	})
	if chip.Clicked() {
		s.filter = filter
		s.list.ScrollTo(0, ui.ListStart)
	}
}

// installedSlashMenu is what typing "/" offers: the filters whose word starts with what
// follows it. Choosing one picks its chip and clears the search.
func (w *window) installedSlashMenu(c ui.C, language i18n.Language) {
	s := &w.installed
	typed := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(s.query), "/"))
	ui.Column(c).FillWidth().PadY(4).Radius(7).Background(w.pal.card).Stroke(1, w.pal.border).Children(func() {
		found := false
		for filter := installedAll + 1; filter < installedFilterCount; filter++ {
			token := installedFilterTokens[filter]
			if !strings.HasPrefix(token, typed) {
				continue
			}
			found = true
			k := c.KeyInt(filter)
			title := installedFilterTitle(language, filter)
			option := ui.Row(k).FillWidth().PadX(10).PadY(5).Gap(6).Items(ui.Center).
				HitWith(ui.ID(k), title, gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand}).
				Hover(ui.Look{}.Background(w.pal.hover))
			option.Children(func() {
				ui.Text(c, "/"+token).Mono().FontSize(12).Color(w.pal.text).Width(92).Shrink(0)
				ui.Text(c, title).FontSize(11).Color(w.pal.muted).Ellipsis()
			})
			if option.Clicked() {
				s.filter, s.query = filter, ""
				s.list.ScrollTo(0, ui.ListStart)
			}
		}
		if !found {
			ui.Text(c, i18n.Shared(language, "native.noMatches")).FontSize(12).Color(w.pal.muted).PadX(10).PadY(5)
		}
	})
}

// installedList is the plugins the search and the chip keep, under their groups' headings.
func (w *window) installedList(c ui.C, language i18n.Language, facts []PluginFacts) {
	s := &w.installed
	if s.listFor != s.selected {
		s.listFor = s.selected
		s.list.Select(-1)
		for index, row := range s.rows {
			if row.heading == "" && row.id == s.selected {
				s.list.Select(index)
				s.list.ScrollIntoView(index)
				break
			}
		}
	}
	ui.List(c, &s.list, len(s.rows), func(row ui.ListRow) {
		entry := s.rows[row.Index]
		if row.Header {
			row.Element.FillWidth().PadX(14).PadTop(10).PadBottom(4).Background(w.pal.sidebar).Children(func() {
				ui.Text(row.C, entry.heading).FontSize(11).Weight(gfx.WeightMedium).Color(w.pal.muted)
			})
			return
		}
		fact := facts[entry.fact]
		row.Element.FillWidth().PadX(14).PadY(10).Gap(10).Items(ui.Center).Hover(ui.Look{}.Background(w.pal.hover))
		if row.Selected() {
			row.Element.Background(w.pal.selectionIdle)
		}
		row.Element.Children(func() {
			w.marketAvatar(row.C, fact.ID, installedName(fact), 32)
			ui.Column(row.C).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
				ui.Text(row.C, installedName(fact)).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
				ui.Text(row.C, installedSubtitle(fact)).FontSize(11).Color(w.pal.muted).Ellipsis()
			})
			if _, update := w.installedUpdate(fact); update {
				k := row.C.Part("update")
				available := i18n.Shared(language, "native.updateAvailable.variant2")
				ui.Row(k).Size(16, 16).Shrink(0).Radius(8).Background(w.pal.accent).Center().
					HitWith(ui.ID(k), available, gfx.HitOptions{Role: gfx.RoleStatus}).Tooltip(available).Children(func() {
					ui.Icon(c, icons.ArrowUp).Size(10, 10).Color(w.pal.white)
				})
			}
			w.enabledMark(row.C, w.pluginState(fact.ID).Enabled)
		})
	}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(i18n.Shared(language, "native.installed"))
	if s.list.Changed() {
		if index := s.list.Selected(); index >= 0 && index < len(s.rows) && s.rows[index].heading == "" {
			s.selected = s.rows[index].id
			s.listFor = s.selected
		}
	}
}

// enabledMark shows whether a plugin is on: a checked box in the accent, or an empty one.
// It only shows the state; the detail's button turns the plugin on or off.
func (w *window) enabledMark(c ui.C, enabled bool) {
	if enabled {
		ui.Row(c).Size(16, 16).Shrink(0).Radius(4).Background(w.pal.accent).Center().Children(func() {
			ui.Icon(c, icons.Check).Size(11, 11).Color(w.pal.white)
		})
		return
	}
	ui.Row(c).Size(16, 16).Shrink(0).Radius(4).Stroke(1, w.pal.muted)
}

// installedSubtitle is a row's second line: the version, the vendor and what it provides.
func installedSubtitle(fact PluginFacts) string {
	line := fact.Version
	if fact.Vendor != "" {
		line += "  " + fact.Vendor
	}
	var titles []string
	for _, capability := range fact.Capabilities {
		switch capability.Kind {
		case CapabilityLanguageServer, CapabilityBuildSystem, CapabilityToolWindow:
			if capability.Title != "" && !slices.Contains(titles, capability.Title) {
				titles = append(titles, capability.Title)
			}
		}
	}
	if len(titles) > 0 {
		line += " · " + strings.Join(titles, " · ")
	}
	return line
}

// installedDetail is the chosen plugin: its header with the actions, the notices, the tab
// bar and the open tab, which scrolls under the header. The tab grows to the scroll's height,
// so the settings form's list can fill what the tab bar leaves.
func (w *window) installedDetail(c ui.C, language i18n.Language, fact PluginFacts) {
	s := &w.installed
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		w.installedHeader(c, language, fact)
		w.installedNotices(c, language, fact)
		w.installedTabs(c, language, fact)
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
		ui.Scroll(c.Part("installed-detail")).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
			ui.Column(c).FillWidth().Grow(1).Shrink(0).MinWidth(0).Pad(22).Gap(16).Children(func() {
				switch s.tab {
				case installedFeatures:
					w.installedFeatures(c, language, fact)
				case installedSettings:
					if fact.Settings == 0 {
						ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.empty")).FontSize(12).Color(w.pal.muted)
					} else {
						w.pluginSettingsPanel(c, fact.ID, true)
					}
				case installedPermissions:
					w.installedPermissions(c, language, fact)
				case installedVersions:
					w.installedVersions(c, language, fact)
				case installedChangelog:
					w.installedChangelog(c, language, fact)
				default:
					w.installedOverview(c, language, fact)
				}
			})
		})
	})
}

// installedHeader is the plugin's icon, name, badge, vendor, version and state beside its
// actions; a narrow detail puts the actions under the rest.
func (w *window) installedHeader(c ui.C, language i18n.Language, fact PluginFacts) {
	identity := func() {
		w.marketAvatar(c, fact.ID, installedName(fact), 48)
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(5).Children(func() {
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				ui.Text(c, installedName(fact)).FontSize(20).Weight(gfx.WeightBold).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
				w.originBadge(c, language, false)
			})
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				byline := fact.Version
				if fact.Vendor != "" {
					byline = fact.Vendor + " · " + fact.Version
				}
				ui.Text(c, byline).FontSize(12).Color(w.pal.muted).Shrink(1).MinWidth(0).Ellipsis()
				w.statusPill(c, language, fact)
			})
		})
	}
	actions := func() {
		ui.Row(c).Shrink(0).Gap(8).Items(ui.Center).Children(func() { w.installedActions(c, language, fact) })
	}
	if w.extent-w.marketApplied-marketSplitterWidth >= 520 {
		ui.Row(c).FillWidth().Shrink(0).PadX(22).PadTop(20).PadBottom(12).Gap(14).Items(ui.Start).Children(func() {
			identity()
			actions()
		})
		return
	}
	ui.Column(c).FillWidth().Shrink(0).PadX(22).PadTop(20).PadBottom(12).Gap(12).Children(func() {
		ui.Row(c).FillWidth().Gap(14).Items(ui.Start).Children(identity)
		actions()
	})
}

// statusPill is whether the plugin's language server runs, or whether the plugin is on.
func (w *window) statusPill(c ui.C, language i18n.Language, fact PluginFacts) {
	label, color := i18n.Shared(language, "native.disabled.variant2"), w.pal.muted
	switch {
	case w.serverRunning(fact.ID):
		label, color = i18n.Shared(language, "native.running"), w.pal.success
	case w.pluginState(fact.ID).Enabled:
		label, color = i18n.Shared(language, "native.enabled.variant2"), w.pal.success
	}
	ui.Row(c).Shrink(0).PadX(7).PadY(2).Radius(100).Background(color.WithAlpha(0.12)).Children(func() {
		ui.Text(c, label).FontSize(11).Weight(gfx.WeightMedium).Color(color)
	})
}

// serverRunning reports whether a language server of the plugin is up or coming up.
func (w *window) serverRunning(id string) bool {
	if w.ctrl.opts.LanguageServerState == nil {
		return false
	}
	switch w.ctrl.opts.LanguageServerState(id) {
	case "", "stopped", "failed", "error":
		return false
	}
	return true
}

// installedActions shows the available controls to enable, disable, update, or remove a plugin.
func (w *window) installedActions(c ui.C, language i18n.Language, fact PluginFacts) {
	opts := w.ctrl.opts
	if opts.SetPluginEnabled != nil {
		if w.pluginState(fact.ID).Enabled {
			if ui.Button(c, i18n.Shared(language, "native.disable")).Small().Clicked() {
				opts.SetPluginEnabled(fact.ID, false)
			}
		} else if ui.Button(c, i18n.Shared(language, "desktop.marketplace.enable")).Small().Clicked() {
			opts.SetPluginEnabled(fact.ID, true)
		}
	}
	if opts.InstallPlugin != nil {
		if entry, available := w.installedUpdate(fact); available {
			label := i18n.SharedFormat(language, "native.updateTo.variant2", map[string]string{"arg1": offeredVersion(entry)})
			if ui.Button(c, label).Small().Clicked() {
				w.startMarketplaceInstall(entry)
			}
		}
	}
	if opts.UninstallPlugin != nil && ui.Button(c, i18n.Shared(language, "desktop.marketplace.uninstall")).Small().Outline().Clicked() {
		w.askUninstall(fact.ID, installedName(fact))
	}
}

// askUninstall opens the confirmation of removing the plugin id, named name.
func (w *window) askUninstall(id, name string) {
	s := &w.installed
	s.uninstallID, s.uninstallName, s.uninstallOpen = id, name, true
}

// uninstallModal asks before a plugin is removed; both tabs open it.
func (w *window) uninstallModal(c ui.C, language i18n.Language) {
	s := &w.installed
	if !s.uninstallOpen {
		return
	}
	title := i18n.SharedFormat(language, "native.uninstall", map[string]string{"arg1": s.uninstallName})
	ui.Modal(c.Part("uninstall"), &s.uninstallOpen, title, ui.ModalSpec{Width: 400}, nil, func() {
		if ui.Button(c, i18n.Shared(language, "ui.cancel")).Outline().Clicked() {
			s.uninstallOpen = false
		}
		if ui.Button(c, i18n.Shared(language, "desktop.marketplace.uninstall")).Destructive().Clicked() {
			s.uninstallOpen = false
			if w.ctrl.opts.UninstallPlugin != nil {
				w.ctrl.opts.UninstallPlugin(s.uninstallID)
			}
		}
	})
}

// installedNotices are the warnings about where a community plugin came from.
func (w *window) installedNotices(c ui.C, language i18n.Language, fact PluginFacts) {
	var notice string
	switch fact.Source {
	case PluginSourceMarketplace:
		notice = i18n.Shared(language, "native.communityPluginMaintainedByAThirdPartyReportPluginProblemsInItsOwnRepository")
	case PluginSourceDisk:
		notice = i18n.Shared(language, "native.communityPluginInstalledFromDiskItsPublisherAndRepositoryHaveNotBeenVerified")
	default:
		return
	}
	ui.Column(c).FillWidth().Shrink(0).PadX(22).PadBottom(10).Gap(6).Children(func() {
		ui.Row(c).FillWidth().PadX(10).PadY(7).Radius(6).Background(w.pal.warning.WithAlpha(0.08)).Children(func() {
			ui.Wrap(c, notice).FontSize(12).Color(w.pal.warning).Grow(1).Shrink(1).MinWidth(0)
		})
	})
}

// installedTabs is the detail's tab bar; a tab with something to count shows the count.
func (w *window) installedTabs(c ui.C, language i18n.Language, fact PluginFacts) {
	s := &w.installed
	counts := [installedTabCount]int{
		installedFeatures:    len(fact.Capabilities),
		installedSettings:    fact.Settings,
		installedPermissions: len(fact.Permissions) + len(fact.Programs),
	}
	// The tabs wrap onto a second line where the detail is too narrow for all of them, as in
	// English at the window's least width, so none is cut off.
	ui.Flow(c).FillWidth().Shrink(0).PadX(22).Gap(18).LineGap(8).Items(ui.End).Children(func() {
		for tab := range installedTabCount {
			if tab == installedChangelog && !w.changelog.available() {
				continue
			}
			k := c.KeyInt(tab)
			title := installedTabTitle(language, tab)
			chosen := s.tab == tab
			button := ui.Column(k).Shrink(0).Gap(6).
				HitWith(ui.ID(k), title, gfx.HitOptions{Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: chosen})
			button.Children(func() {
				ui.Row(k).Gap(5).Items(ui.Center).Children(func() {
					text := ui.Text(c, title).FontSize(13).Color(w.pal.muted)
					if chosen {
						text.Weight(gfx.WeightSemibold).Color(w.pal.text)
					}
					if counts[tab] > 0 {
						ui.Row(k).PadX(5).PadY(1).Radius(100).Background(w.pal.selectionIdle).Children(func() {
							ui.Text(c, strconv.Itoa(counts[tab])).FontSize(10).Weight(gfx.WeightMedium).Color(w.pal.muted)
						})
					}
				})
				underline := ui.Row(k).FillWidth().Height(2).Radius(1)
				if chosen {
					underline.Background(w.pal.accent)
				}
			})
			if button.Clicked() {
				s.tab = tab
			}
		}
	})
}

// installedFieldLine is the least height of a detail grid's line: the ⓘ glyph's, so a line
// that ends in one is as tall as a line of text and the grid keeps one rhythm.
const installedFieldLine = 18

// installedLabelColumn is the width of a detail grid's labels, where the values start. It
// holds the widest label with an ⓘ after it, "Content SHA-256", which the system font draws
// about 102 points wide, with room to spare for the ⓘ's gap and glyph.
const installedLabelColumn = 136

// installedLinkInset is the side padding Viva keeps around a link button's words, the same
// as a regular button's (components.Button's geometry). A link that is a field's value is
// pulled left by it so its words start where the plain values above and below start.
const installedLinkInset = 10

// installedField is one line of a detail's grid: a label in the secondary color beside
// what body declares. The label and the value stand on one text baseline, whatever their
// fonts, and a value that wraps keeps the label beside its first line.
func (w *window) installedField(c ui.C, label string, body func()) {
	w.installedFieldHelp(c, label, "", body)
}

// installedFieldHelp is installedField whose label is followed, inside the label's column,
// by an ⓘ whose tip is help, so a note on the field neither takes a line of its own nor
// pushes the value aside. An empty help leaves the label alone.
func (w *window) installedFieldHelp(c ui.C, label, help string, body func()) {
	ui.Row(c).FillWidth().MinHeight(installedFieldLine).Gap(16).Items(ui.Baseline).Children(func() {
		ui.Row(c).Width(installedLabelColumn).Shrink(0).Gap(4).Items(ui.Baseline).Children(func() {
			ui.Text(c, label).FontSize(12).Color(w.pal.muted).Shrink(1).MinWidth(0)
			if help != "" {
				w.infoButton(c, help)
			}
		})
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(8).Items(ui.Baseline).Children(body)
	})
}

// installedLink is a field's value that opens something: link words that line up with the
// plain values of the other lines and keep the line as tall as theirs.
func (w *window) installedLink(c ui.C, label string) ui.Box {
	return ui.Button(c, label).Link().Height(installedFieldLine).MarginLeft(-installedLinkInset)
}

// installedValue is a field's plain value.
func (w *window) installedValue(c ui.C, value string) {
	ui.Wrap(c, value).FontSize(12).Color(w.pal.text).Grow(1).Shrink(1).MinWidth(0)
}

// installedOverview is what the plugin is about, what it provides, where it came from and
// where its settings are.
func (w *window) installedOverview(c ui.C, language i18n.Language, fact PluginFacts) {
	entry, listed := w.marketEntry(fact.ID)
	summary := installedName(fact)
	if listed {
		if description := w.marketDescription(entry); description != "" {
			summary = description
		}
	}
	ui.Wrap(c, summary).FontSize(13).Color(w.pal.text)
	none := i18n.Shared(language, "desktop.newProject.none")
	ui.Column(c).FillWidth().Gap(9).Children(func() {
		w.installedField(c, i18n.Shared(language, "native.status"), func() { w.statusPill(c, language, fact) })
		w.installedField(c, i18n.Shared(language, "native.provides"), func() {
			provides := w.providedKinds(language, fact)
			if provides == "" {
				provides = none
			}
			w.installedValue(c, provides)
		})
		w.installedField(c, i18n.Shared(language, "native.pluginSource"), func() {
			switch fact.Source {
			case PluginSourceDisk:
				ui.Text(c, i18n.Shared(language, "native.installedFromDisk")).FontSize(12).Color(w.pal.text).Shrink(0)
				if fact.Path != "" {
					ui.Text(c, filepath.Base(fact.Path)).Mono().FontSize(12).Color(w.pal.muted).Shrink(1).MinWidth(0).Ellipsis()
				}
			case PluginSourceMarketplace:
				ui.Text(c, i18n.SharedFormat(language, "native.installedFrom", map[string]string{"arg1": i18n.Shared(language, "native.marketplace")})).
					FontSize(12).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
				if listed && webURL(entry.Repository) && w.ctrl.opts.OpenURL != nil {
					if w.installedLink(c, i18n.Shared(language, "native.sourceRepository")).Tooltip(entry.Repository).Clicked() {
						w.ctrl.opts.OpenURL(entry.Repository)
					}
				}
			default:
				w.installedValue(c, none)
			}
		})
		w.installedField(c, i18n.Shared(language, "desktop.marketplace.tab.settings"), func() {
			if fact.Settings == 0 {
				w.installedValue(c, none)
				return
			}
			ui.Text(c, strconv.Itoa(fact.Settings)).FontSize(12).Color(w.pal.text).Shrink(0)
			if w.installedLink(c, i18n.Shared(language, "native.view")).Clicked() {
				w.installed.tab = installedSettings
			}
		})
	})
	w.configureInSettings(c, language, fact)
}

// configureInSettings lists the settings pages the plugin adds its settings to, each a
// link to its page.
func (w *window) configureInSettings(c ui.C, language i18n.Language, fact PluginFacts) {
	type contribution struct {
		page     core.SettingsPage
		subjects string
	}
	var pages []contribution
	for _, page := range w.dynamic.pages {
		for _, contributor := range page.Contributors {
			if contributor.PluginID != fact.ID {
				continue
			}
			var subjects []string
			for _, section := range contributor.Sections {
				if section.Title != "" {
					subjects = append(subjects, section.Title)
				}
			}
			pages = append(pages, contribution{page: page, subjects: strings.Join(subjects, ", ")})
		}
	}
	if len(pages) == 0 {
		return
	}
	ui.Column(c).FillWidth().Gap(8).Children(func() {
		ui.Text(c, i18n.Shared(language, "native.configureInSettings")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
		for _, entry := range pages {
			k := c.Key(entry.page.Key)
			ui.Row(k).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				icon := icons.FileCode
				if entry.page.Kind == "buildSystem" {
					icon = icons.Play
				}
				ui.Icon(c, icon).Size(14, 14).Color(w.pal.muted).Shrink(0)
				if entry.subjects != "" {
					ui.Text(c, entry.subjects).FontSize(12).Color(w.pal.muted).Shrink(1).MinWidth(0).Ellipsis()
				}
				if ui.Button(k, entry.page.Title).Link().Clicked() {
					key, pluginID := entry.page.Key, fact.ID
					k.After(func() { w.openContributedPage(key, pluginID) })
				}
			})
		}
	})
}

// openContributedPage shows the settings page key with the plugin pluginID's form chosen.
func (w *window) openContributedPage(key, pluginID string) {
	page := w.dynamic.selected(key)
	if page == nil {
		return
	}
	w.selectSettingsPage(contributedParent(page.Kind), key)
	w.contributorID = pluginID
}

// providedKinds is the kinds of what the plugin provides, each named once.
func (w *window) providedKinds(language i18n.Language, fact PluginFacts) string {
	var kinds []string
	for _, capability := range fact.Capabilities {
		if title := capabilityKindTitle(language, capability.Kind); title != "" && !slices.Contains(kinds, title) {
			kinds = append(kinds, title)
		}
	}
	return strings.Join(kinds, ", ")
}

// capabilityKindTitle is the words of a capability's kind.
func capabilityKindTitle(language i18n.Language, kind string) string {
	switch kind {
	case CapabilityLanguage:
		return i18n.Shared(language, "settings.mac.language")
	case CapabilityLanguageServer:
		return i18n.Shared(language, "native.languageServer")
	case CapabilityRun:
		return i18n.Shared(language, "desktop.runConfig.run")
	case CapabilityTest:
		return i18n.Shared(language, "native.test")
	case CapabilityDebugger:
		return i18n.Shared(language, "native.debugger")
	case CapabilityBuildSystem:
		return i18n.Shared(language, "native.buildSystem")
	case CapabilityProjectTemplate:
		return i18n.Shared(language, "native.projectTemplate")
	case CapabilityToolWindow:
		return i18n.Shared(language, "native.toolWindow")
	case CapabilityCommand:
		return i18n.Shared(language, "native.command")
	case CapabilityVersionControl:
		return i18n.Shared(language, "native.versionControl")
	}
	return ""
}

// installedFeatures is a card for each thing the plugin's manifest declares.
func (w *window) installedFeatures(c ui.C, language i18n.Language, fact PluginFacts) {
	ui.Row(c).FillWidth().Children(func() {
		ui.Spacer(c)
		w.infoButton(c, i18n.Shared(language, "native.generatedFromThePluginSDeclaration"))
	})
	if len(fact.Capabilities) == 0 {
		ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.noFeatures")).FontSize(12).Color(w.pal.muted)
		return
	}
	enabled := w.pluginState(fact.ID).Enabled
	var missing []MissingCommand
	if enabled {
		missing = w.commands.want(fact.ID)
		w.commandMissingBanner(c, language, fact, unmatchedMissing(missing, fact.Capabilities))
	}
	ui.Grid(c, 220).FillWidth().Gap(10).Children(func() {
		for index, capability := range fact.Capabilities {
			k := c.KeyInt(index)
			ui.Column(k).FillWidth().Gap(5).Pad(12).Radius(8).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
				ui.Text(c, capabilityKindTitle(language, capability.Kind)).FontSize(11).Weight(gfx.WeightMedium).Color(w.pal.muted)
				title := capability.Title
				if title == "" {
					title = capability.ID
				}
				ui.Text(c, title).FontSize(13).Color(w.pal.text).Ellipsis()
				if detail := capabilityDetail(language, capability); detail != "" {
					ui.Wrap(c, detail).FontSize(11).Color(w.pal.muted)
				}
				ui.Row(k).FillWidth().Gap(8).Items(ui.Center).Children(func() {
					if entry, ok := missingFor(missing, capability); enabled && ok {
						w.commandMissingStatus(k, language, fact, entry)
					} else if enabled {
						ui.Text(c, i18n.Shared(language, "native.available")).FontSize(11).Color(w.pal.success)
					} else {
						ui.Text(c, i18n.Shared(language, "native.pluginDisabled")).FontSize(11).Color(w.pal.muted)
					}
					ui.Spacer(c)
					if key := capabilityPage(capability); enabled && key != "" && w.dynamic.selected(key) != nil {
						if ui.Button(k, i18n.Shared(language, "native.configure")+" →").Link().XSmall().Clicked() {
							pluginID := fact.ID
							k.After(func() { w.openContributedPage(key, pluginID) })
						}
					}
				})
			})
		}
	})
}

// capabilityPage is the settings page a capability is configured on, or "".
func capabilityPage(capability PluginCapability) string {
	switch capability.Kind {
	case CapabilityLanguageServer, CapabilityRun, CapabilityTest:
		return "language:" + capability.ID
	case CapabilityBuildSystem:
		return "buildSystem:" + capability.ID
	}
	return ""
}

// capabilityDetail is a feature card's third line: what the capability works on or needs.
func capabilityDetail(language i18n.Language, capability PluginCapability) string {
	switch capability.Kind {
	case CapabilityLanguage:
		return strings.Join(capability.Extensions, " ")
	case CapabilityLanguageServer:
		if capability.Packaged {
			return i18n.Shared(language, "native.insideThePlugin")
		}
		if len(capability.Commands) > 0 {
			return i18n.SharedFormat(language, "desktop.plugins.installedOnThisComputer", map[string]string{"arg1": strings.Join(capability.Commands, " | ")})
		}
	case CapabilityBuildSystem:
		return i18n.SharedFormat(language, "native.tasksD", map[string]string{"arg1": strconv.Itoa(capability.Tasks)})
	case CapabilityProjectTemplate:
		return capability.Description
	}
	return ""
}

// permissionDescription says what a permission lets the plugin do. Every permission of the
// plugin contract has one; a permission from a newer contract that this host does not know
// returns "" and shows only its name.
func permissionDescription(language i18n.Language, permission string) string {
	switch permission {
	case "languageServer.launch":
		return i18n.Shared(language, "native.startALanguageServerWhenYouOpenFilesOfItsLanguage")
	case "backend.launch":
		return i18n.Shared(language, "desktop.marketplace.permissionBackend")
	case "process.build":
		return i18n.Shared(language, "desktop.marketplace.permissionBuild")
	case "process.run":
		return i18n.Shared(language, "native.runYourFiles")
	case "process.test":
		return i18n.Shared(language, "native.runYourTests")
	case "process.vcs":
		return i18n.Shared(language, "desktop.marketplace.permissionVcs")
	case "project.generate":
		return i18n.Shared(language, "desktop.marketplace.permissionGenerate")
	case "debug.launch":
		return i18n.Shared(language, "desktop.marketplace.permissionDebug")
	case "debug.attach":
		return i18n.Shared(language, "desktop.marketplace.permissionDebugAttach")
	case "debug.start":
		return i18n.Shared(language, "desktop.marketplace.permissionDebugStart")
	case "run.start":
		return i18n.Shared(language, "desktop.marketplace.permissionRunStart")
	case "terminal.create":
		return i18n.Shared(language, "desktop.marketplace.permissionTerminalCreate")
	case "commands.install":
		return i18n.Shared(language, "desktop.marketplace.permissionCommandsInstall")
	case "runtimes.install":
		return i18n.Shared(language, "desktop.marketplace.permissionRuntimesInstall")
	case "toolchains.provide":
		return i18n.Shared(language, "desktop.marketplace.permissionToolchainsProvide")
	case "ui.contribute":
		return i18n.Shared(language, "native.addToolWindowsAndCommandsToTheWorkbench")
	case "ui.web":
		return i18n.Shared(language, "native.showItsOwnPageInAToolWindow")
	case "window.messages":
		return i18n.Shared(language, "desktop.marketplace.permissionWindowMessages")
	case "browser.open":
		return i18n.Shared(language, "desktop.marketplace.permissionBrowserOpen")
	case "window.input":
		return i18n.Shared(language, "desktop.marketplace.permissionWindowInput")
	case "views.refresh":
		return i18n.Shared(language, "desktop.marketplace.permissionViewsRefresh")
	case "output.write":
		return i18n.Shared(language, "desktop.marketplace.permissionOutputWrite")
	case "window.progress":
		return i18n.Shared(language, "desktop.marketplace.permissionWindowProgress")
	case "statusBar.write":
		return i18n.Shared(language, "desktop.marketplace.permissionStatusBarWrite")
	case "clipboard.read":
		return i18n.Shared(language, "desktop.marketplace.permissionClipboardRead")
	case "clipboard.write":
		return i18n.Shared(language, "desktop.marketplace.permissionClipboardWrite")
	case "workspace.reveal":
		return i18n.Shared(language, "desktop.marketplace.permissionWorkspaceReveal")
	case "network.request":
		return i18n.Shared(language, "desktop.marketplace.permissionNetworkRequest")
	case "preview.open":
		return i18n.Shared(language, "desktop.marketplace.permissionPreviewOpen")
	case "workspace.metadata":
		return i18n.Shared(language, "desktop.marketplace.permissionWorkspaceMetadata")
	case "workspace.files.read":
		return i18n.Shared(language, "desktop.marketplace.permissionWorkspaceFilesRead")
	case "workspace.files.write":
		return i18n.Shared(language, "desktop.marketplace.permissionWorkspaceFilesWrite")
	case "workspace.files.watch":
		return i18n.Shared(language, "desktop.marketplace.permissionWorkspaceFilesWatch")
	case "workspace.search":
		return i18n.Shared(language, "desktop.marketplace.permissionWorkspaceSearch")
	case "build.options.read":
		return i18n.Shared(language, "desktop.marketplace.permissionBuildOptionsRead")
	case "build.configuration.watch":
		return i18n.Shared(language, "desktop.marketplace.permissionBuildConfigurationWatch")
	case "documents.read":
		return i18n.Shared(language, "desktop.marketplace.permissionDocumentsRead")
	case "documents.save":
		return i18n.Shared(language, "desktop.marketplace.permissionDocumentsSave")
	case "documents.contentProvider":
		return i18n.Shared(language, "desktop.marketplace.permissionDocumentsContentProvider")
	case "editor.open":
		return i18n.Shared(language, "desktop.marketplace.permissionEditorOpen")
	case "editor.edit":
		return i18n.Shared(language, "desktop.marketplace.permissionEditorEdit")
	case "editor.actions":
		return i18n.Shared(language, "desktop.marketplace.permissionEditorActions")
	case "editor.providers":
		return i18n.Shared(language, "desktop.marketplace.permissionEditorProviders")
	case "languageServer.request":
		return i18n.Shared(language, "desktop.marketplace.permissionLanguageServerRequest")
	case "credentials.store":
		return i18n.Shared(language, "desktop.marketplace.permissionCredentialsStore")
	case "keymaps.provide":
		return i18n.Shared(language, "desktop.marketplace.permissionKeymapsProvide")
	case "keymaps.readSelectedSources":
		return i18n.Shared(language, "desktop.marketplace.permissionKeymapsReadSelectedSources")
	}
	return ""
}

// installedPermissionLine is the height of one line of a permission's description. Its
// shield is centered in a box this tall, so it stays on the first line of a description that
// wraps.
const installedPermissionLine = 19

// installedPermissions is what the user approved: the permissions, each one line of what it
// lets the plugin do followed by its name in the contract, then the programs the plugin may
// run, each one line that opens to its full declaration.
func (w *window) installedPermissions(c ui.C, language i18n.Language, fact PluginFacts) {
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Text(c, i18n.Shared(language, "native.permissions")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).PadBottom(4)
		if len(fact.Permissions) == 0 {
			ui.Wrap(c, i18n.Shared(language, "native.needsNoExtraPermissions")).FontSize(12).Color(w.pal.muted)
		}
		for index, permission := range fact.Permissions {
			k := c.KeyInt(index)
			ui.Row(k).FillWidth().PadY(3).Gap(8).Items(ui.Start).Children(func() {
				ui.Row(k).Height(installedPermissionLine).Shrink(0).Items(ui.Center).Children(func() {
					ui.Icon(c, icons.ShieldCheck).Size(14, 14).Color(w.pal.accent)
				})
				ui.Row(k).Grow(1).Shrink(1).MinWidth(0).Gap(8).Items(ui.Baseline).Children(func() {
					if description := permissionDescription(language, permission); description != "" {
						ui.Wrap(c, description).FontSize(12).LineHeight(installedPermissionLine).Color(w.pal.text).Shrink(1).MinWidth(0)
					}
					ui.Text(c, permission).Mono().FontSize(11).Color(w.pal.subtle).Shrink(0)
				})
			})
		}
		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).PadTop(14).PadBottom(4).Children(func() {
			ui.Text(c, i18n.Shared(language, "native.programsItCanRun")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
			if len(fact.Programs) != 0 {
				w.infoButton(c, i18n.Shared(language, "desktop.marketplace.programsSettingsHelp"))
			}
		})
		if len(fact.Programs) == 0 {
			ui.Wrap(c, i18n.Shared(language, "native.startsNoPrograms")).FontSize(12).Color(w.pal.muted)
		}
		for index, program := range fact.Programs {
			w.installedProgram(c.KeyInt(1000+index), language, fact, program)
		}
	})
}

// programKey names one program declaration of one plugin in installedState.programsOpen.
func programKey(fact PluginFacts, program string) string {
	return fact.ID + "\x00" + program
}

// installedProgram is one program the plugin may run: a line that names it by its kind and
// the words its declaration gives it, which opens and closes the declaration in full, and a
// button that copies the declaration. The line's caret sits in the column of the permissions'
// shields, so the two lists start at one edge.
func (w *window) installedProgram(c ui.C, language i18n.Language, fact PluginFacts, program string) {
	key := programKey(fact, program)
	open := w.installed.programsOpen[key]
	kind, detail := programSummary(program)
	declaration := programDeclaration(program)
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Row(c).FillWidth().Gap(4).Items(ui.Center).Children(func() {
			disclose := ui.ButtonBase(c.Part("open"), strings.TrimSpace(kind+" "+detail)).Grow(1).Shrink(1).MinWidth(0).
				MinHeight(installedFieldLine).PadX(4).PadY(3).MarginLeft(-4).Gap(8).Radius(6).Items(ui.Center).Justify(ui.Start).
				Hover(ui.Look{}.Background(w.pal.hover)).Tooltip(i18n.Shared(language, "native.fullProgramDeclaration"))
			if disclose.Clicked() {
				if open {
					delete(w.installed.programsOpen, key)
					delete(w.installed.programTexts, key)
				} else {
					if w.installed.programsOpen == nil {
						w.installed.programsOpen = map[string]bool{}
					}
					w.installed.programsOpen[key] = true
				}
			}
			disclose.Children(func() {
				caret := icons.ChevronRight
				if open {
					caret = icons.ChevronDown
				}
				ui.Row(c).Width(14).Shrink(0).Center().Children(func() {
					ui.Icon(c, caret).Size(10, 10).Color(w.pal.muted)
				})
				if kind == "" {
					ui.Text(c, program).Mono().FontSize(11).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
					return
				}
				ui.Text(c, kind).Mono().FontSize(11).Color(w.pal.text).Shrink(0)
				if detail != "" {
					ui.Text(c, detail).Mono().FontSize(11).Color(w.pal.subtle).Shrink(1).MinWidth(0).Ellipsis()
				}
			})
			copyLabel := i18n.Shared(language, "native.copyJSON")
			copyButton := ui.ButtonBase(c.Part("copy"), copyLabel).Size(20, 20).Shrink(0).Radius(6).Center().
				Hover(ui.Look{}.Background(w.pal.hover)).Tooltip(copyLabel)
			if copyButton.Clicked() {
				if err := copyText(declaration); err != nil {
					reportSettingsError(w.ctrl.opts, "settings_plugin_program_copy", err)
				}
			}
			copyButton.Children(func() {
				ui.Icon(c, icons.Copy).Size(11, 11).Color(w.pal.muted)
			})
		})
		if open {
			text := w.declarationText(key, declaration)
			theme := w.declarationTheme()
			ui.Column(c).FillWidth().MarginLeft(22).Pad(8).Radius(6).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
				// The lines never change for one text, so it wraps them again only when its
				// width does.
				text.view.Declare(c.Key("declaration"), textview.Spec{
					Label:      i18n.Shared(language, "native.fullProgramDeclaration"),
					Source:     text.lines,
					Font:       gfx.TextStyle{Size: 11, Weight: gfx.WeightRegular, Mono: true, Color: w.pal.text},
					LineHeight: 16,
					Selection:  w.pal.highlight,
					Wrap:       true,
					Revision:   1,
					Spans: func(n int, line string, dst []textview.Span) []textview.Span {
						return text.spans(theme, w.pal.text, n, line, dst)
					},
					Copy: func(selected string) {
						if err := copyText(selected); err != nil {
							reportSettingsError(w.ctrl.opts, "settings_plugin_program_copy", err)
						}
					},
				})
			})
		}
	})
}

// programText is an opened program declaration: its lines, the editor's JSON tokens of each,
// and the read-only text that shows them, which can be selected and copied.
type programText struct {
	lines  textview.Strings
	tokens [][]syntax.Token
	view   textview.View
}

// declarationGrammar is the editor's JSON grammar, the one the declarations are colored with.
// The grammars are built into Lithe, so making it reads no file; its patterns compile the
// first time a declaration opens.
var declarationGrammar = sync.OnceValue(func() *syntax.Syntax {
	return syntax.NewRegistry().Syntax("json")
})

// declarationText is the text of the declaration of the program key names, made the first
// time it is shown: a declaration is a few lines, read once through one highlighter so a
// string that spans lines is colored as the editor colors it.
func (w *window) declarationText(key, declaration string) *programText {
	if text, ok := w.installed.programTexts[key]; ok {
		return text
	}
	source := rope.FromString(declaration)
	text := &programText{}
	for i := 0; i < source.LineCount(); i++ {
		text.lines = append(text.lines, source.Line(i))
	}
	text.tokens = make([][]syntax.Token, len(text.lines))
	if grammar := declarationGrammar(); grammar != nil {
		highlighter := syntax.NewHighlighter(grammar, source, syntax.HighlighterOptions{})
		for i := range text.lines {
			text.tokens[i] = highlighter.Line(nil, i)
		}
		highlighter.Close()
	}
	if w.installed.programTexts == nil {
		w.installed.programTexts = map[string]*programText{}
	}
	w.installed.programTexts[key] = text
	return text
}

// declarationTheme is the editor's Lithe scheme in the window's look, built again only when
// the look changes.
func (w *window) declarationTheme() *syntax.Theme {
	s := &w.installed
	if s.programTheme == nil || s.programThemeDark != w.dark {
		options := syntax.ThemeOptions{Dark: w.dark, Scheme: syntax.SchemeLithe}
		s.programTheme, s.programThemeDark = syntax.BuildTheme(options, syntax.DefaultPalette()), w.dark
	}
	return s.programTheme
}

// spans appends to dst the styled stretches of line n of the declaration, in theme's colors.
// A token in the scheme's text color takes plain, the card's text color, as the hover's code
// does, and one that is plain in every way is left out.
func (t *programText) spans(theme *syntax.Theme, plain gfx.Color, n int, line string, dst []textview.Span) []textview.Span {
	if n < 0 || n >= len(t.tokens) {
		return dst
	}
	tokens, text := t.tokens[n], theme.Default().Foreground
	for i, token := range tokens {
		start, end := int(token.Start), len(line)
		if i+1 < len(tokens) {
			end = int(tokens[i+1].Start)
		}
		if start < 0 || start >= end || end > len(line) {
			continue
		}
		style := theme.Style(token.Name)
		if style.Foreground == text && style.Font == 0 {
			continue
		}
		span := textview.Span{From: start, To: end, Color: plain}
		if style.Foreground != text {
			span.Color = gfx.RGB24(uint32(style.Foreground))
		}
		span.Bold, span.Italic = style.Font&syntax.Bold != 0, style.Font&syntax.Italic != 0
		dst = append(dst, span)
	}
	return dst
}

// programSummary names a program declaration on one line: its kind, and the words its
// declaration gives it at the top level (the language, the tool, the installer's or build
// system's ID), in the order it gives them. A declaration that is not a JSON object with a
// kind has no summary, and the caller shows it as it is.
func programSummary(program string) (kind, detail string) {
	decoder := json.NewDecoder(strings.NewReader(program))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return "", ""
	}
	var words []string
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return "", ""
		}
		name, _ := token.(string)
		var value any
		if err := decoder.Decode(&value); err != nil {
			return "", ""
		}
		text, ok := value.(string)
		if !ok || text == "" {
			continue
		}
		if name == "kind" {
			kind = text
		} else {
			words = append(words, text)
		}
	}
	if kind == "" {
		return "", ""
	}
	return kind, strings.Join(words, " · ")
}

// programDeclaration is a program declaration indented for reading, the form it is shown
// and copied in; a declaration that is not JSON stays as it is.
func programDeclaration(program string) string {
	var indented bytes.Buffer
	if err := json.Indent(&indented, []byte(program), "", "  "); err != nil {
		return program
	}
	return indented.String()
}

// installedVersions is the installed version, where updates come from and what the
// approval recorded about the package.
func (w *window) installedVersions(c ui.C, language i18n.Language, fact PluginFacts) {
	entry, listed := w.marketEntry(fact.ID)
	dash := "—"
	mono := func(value string) func() {
		return func() {
			if value == "" {
				value = dash
			}
			ui.Wrap(c, value).Mono().FontSize(11).Color(w.pal.text).Grow(1).Shrink(1).MinWidth(0)
		}
	}
	ui.Column(c).FillWidth().Gap(9).Children(func() {
		w.installedField(c, i18n.Shared(language, "native.currentVersion"), func() { w.installedValue(c, fact.Version) })
		w.installedField(c, i18n.Shared(language, "native.previousVersion"), func() { w.installedValue(c, dash) })
		w.installedField(c, i18n.Shared(language, "native.updates"), func() {
			switch fact.Source {
			case PluginSourceMarketplace:
				w.installedValue(c, i18n.SharedFormat(language, "native.installedFromUpdatesOnlyComeFromThatRepository", map[string]string{"arg1": i18n.Shared(language, "native.marketplace")}))
			case PluginSourceDisk:
				w.installedValue(c, i18n.Shared(language, "native.managedOutsideTheMarketplaceNoUpdateSource"))
			default:
				w.installedValue(c, dash)
			}
		})
		w.installedField(c, i18n.Shared(language, "native.sourceRepository"), func() {
			if !listed || !webURL(entry.Repository) {
				w.installedValue(c, dash)
				return
			}
			if w.ctrl.opts.OpenURL == nil {
				w.installedValue(c, entry.Repository)
				return
			}
			if w.installedLink(c, repositoryName(entry.Repository)).Tooltip(entry.Repository).Clicked() {
				w.ctrl.opts.OpenURL(entry.Repository)
			}
		})
		w.installedField(c, i18n.Shared(language, "native.localPackage"), mono(fact.Path))
		w.installedField(c, i18n.Shared(language, "native.archiveSHA256"), mono(fact.ArchiveSHA256))
		// The ⓘ that says when the digest is checked follows the label: after the digest it would
		// sit at the far end of a line the digest fills, away from what it explains.
		checked := ""
		if fact.ContentDigest != "" {
			checked = i18n.Shared(language, "native.checkedAgainEveryTimeLitheLoadsThePlugin")
		}
		w.installedFieldHelp(c, i18n.Shared(language, "native.contentSHA256"), checked, mono(fact.ContentDigest))
		w.installedField(c, i18n.Shared(language, "native.pluginID"), mono(fact.ID))
	})
}
