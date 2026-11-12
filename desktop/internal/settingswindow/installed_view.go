package settingswindow

import (
	"hash/fnv"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Installed tab of the plugin page, laid out as the macOS client's is: a search with
// filter chips over the installed plugins, the enabled ones before the disabled ones, beside
// the chosen plugin's header, its notices and five tabs. What it shows comes from the
// owner's InstalledPlugins, which answers from memory; the marketplace index the page reads
// adds the updates, descriptions and repositories.

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
		row := installedRow{fact: index, id: fact.ID, name: installedName(fact)}
		if w.pluginState(fact.ID).Enabled {
			enabled = append(enabled, row)
		} else {
			disabled = append(disabled, row)
		}
	}
	s.rows = s.rows[:0]
	if len(enabled) > 0 {
		s.rows = append(s.rows, installedRow{heading: i18n.Shared(language, "native.enabled.variant2")})
		s.rows = append(s.rows, enabled...)
	}
	if len(disabled) > 0 {
		s.rows = append(s.rows, installedRow{heading: i18n.Shared(language, "native.disabled.variant2")})
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

// rowKey names a row by its plugin, so a row keeps its identity while the groups move it;
// the two headings have keys no plugin's hash takes.
func (s *installedState) rowKey(i int) int {
	if i < 0 || i >= len(s.rows) {
		return i
	}
	row := s.rows[i]
	if row.heading != "" {
		return -1 - i
	}
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(row.id))
	return int(hash.Sum32())
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
		ui.Text(k, title).FontSize(11).Weight(weight).Color(w.pal.text)
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
				ui.Text(k, "/"+token).Mono().FontSize(12).Color(w.pal.text).Width(92).Shrink(0)
				ui.Text(k, title).FontSize(11).Color(w.pal.muted).Ellipsis()
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
					ui.Icon(k, icons.ArrowUp).Size(10, 10).Color(w.pal.white)
				})
			}
			w.enabledMark(row.C, w.pluginState(fact.ID).Enabled)
		})
	}).FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(i18n.Shared(language, "native.installed"))
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
// bar and the open tab, which scrolls under the header.
func (w *window) installedDetail(c ui.C, language i18n.Language, fact PluginFacts) {
	s := &w.installed
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		w.installedHeader(c, language, fact)
		w.installedNotices(c, language, fact)
		w.installedTabs(c, language, fact)
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
		ui.Scroll(c.Part("installed-detail")).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
			ui.Column(c).FillWidth().Shrink(0).MinWidth(0).Pad(22).Gap(16).Children(func() {
				switch s.tab {
				case installedFeatures:
					w.installedFeatures(c, language, fact)
				case installedSettings:
					if fact.Settings == 0 {
						ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.empty")).FontSize(12).Color(w.pal.muted)
					} else {
						w.pluginSettingsPanel(c, fact.ID)
					}
				case installedPermissions:
					w.installedPermissions(c, language, fact)
				case installedVersions:
					w.installedVersions(c, language, fact)
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

// installedActions are the header's buttons: turning the plugin on or off, updating or
// reinstalling it from the marketplace, and removing it.
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
		entry, listed := w.marketEntry(fact.ID)
		switch {
		case listed && newerOffered(entry, fact.Version):
			label := i18n.SharedFormat(language, "native.updateTo.variant2", map[string]string{"arg1": offeredVersion(entry)})
			if ui.Button(c, label).Small().Clicked() {
				opts.InstallPlugin(entry)
			}
		case listed && fact.Source == PluginSourceMarketplace && entry.Availability.Status == "available":
			if ui.Button(c, i18n.Shared(language, "extensions.reinstall")).Small().Outline().Clicked() {
				opts.InstallPlugin(entry)
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
	ui.ModalWith(c.Part("uninstall"), &s.uninstallOpen, title, ui.ModalSpec{Width: 400}, nil, func() {
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
	ui.Row(c).FillWidth().Shrink(0).PadX(22).Gap(18).Items(ui.End).Children(func() {
		for tab := range installedTabCount {
			k := c.KeyInt(tab)
			title := installedTabTitle(language, tab)
			chosen := s.tab == tab
			button := ui.Column(k).Shrink(0).Gap(6).
				HitWith(ui.ID(k), title, gfx.HitOptions{Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: chosen})
			button.Children(func() {
				ui.Row(k).Gap(5).Items(ui.Center).Children(func() {
					text := ui.Text(k, title).FontSize(13).Color(w.pal.muted)
					if chosen {
						text.Weight(gfx.WeightSemibold).Color(w.pal.text)
					}
					if counts[tab] > 0 {
						ui.Row(k).PadX(5).PadY(1).Radius(100).Background(w.pal.selectionIdle).Children(func() {
							ui.Text(k, strconv.Itoa(counts[tab])).FontSize(10).Weight(gfx.WeightMedium).Color(w.pal.muted)
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

// installedField is one line of a detail's grid: a label in the secondary color beside
// what body declares.
func (w *window) installedField(c ui.C, label string, body func()) {
	ui.Row(c).FillWidth().Gap(16).Items(ui.Start).Children(func() {
		ui.Text(c, label).Width(120).Shrink(0).FontSize(12).Color(w.pal.muted)
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(8).Items(ui.Center).Children(body)
	})
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
					if ui.Button(c, i18n.Shared(language, "native.sourceRepository")).Link().Tooltip(entry.Repository).Clicked() {
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
			if ui.Button(c, i18n.Shared(language, "native.view")).Link().Clicked() {
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
				ui.Icon(k, icon).Size(14, 14).Color(w.pal.muted).Shrink(0)
				if entry.subjects != "" {
					ui.Text(k, entry.subjects).FontSize(12).Color(w.pal.muted).Shrink(1).MinWidth(0).Ellipsis()
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
	parent := pageLanguages
	if page.Kind == "buildSystem" {
		parent = pageBuild
	}
	w.selectSettingsPage(parent, key)
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
	ui.Grid(c, 220).FillWidth().Gap(10).Children(func() {
		for index, capability := range fact.Capabilities {
			k := c.KeyInt(index)
			ui.Column(k).FillWidth().Gap(5).Pad(12).Radius(8).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
				ui.Text(k, capabilityKindTitle(language, capability.Kind)).FontSize(11).Weight(gfx.WeightMedium).Color(w.pal.muted)
				title := capability.Title
				if title == "" {
					title = capability.ID
				}
				ui.Text(k, title).FontSize(13).Color(w.pal.text).Ellipsis()
				if detail := capabilityDetail(language, capability); detail != "" {
					ui.Wrap(k, detail).FontSize(11).Color(w.pal.muted)
				}
				ui.Row(k).FillWidth().Gap(8).Items(ui.Center).Children(func() {
					if enabled {
						ui.Text(k, i18n.Shared(language, "native.available")).FontSize(11).Color(w.pal.success)
					} else {
						ui.Text(k, i18n.Shared(language, "native.pluginDisabled")).FontSize(11).Color(w.pal.muted)
					}
					ui.Spacer(k)
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

// permissionDescription says what a permission lets the plugin do, or "" for a permission
// that shows only its name.
func permissionDescription(language i18n.Language, permission string) string {
	switch permission {
	case "languageServer.launch":
		return i18n.Shared(language, "native.startALanguageServerWhenYouOpenFilesOfItsLanguage")
	case "process.run":
		return i18n.Shared(language, "native.runYourFiles")
	case "ui.contribute":
		return i18n.Shared(language, "native.addToolWindowsAndCommandsToTheWorkbench")
	case "ui.web":
		return i18n.Shared(language, "native.showItsOwnPageInAToolWindow")
	case "process.test":
		return i18n.Shared(language, "native.runYourTests")
	}
	return ""
}

// installedPermissions is what the user approved: the permissions, then the programs the
// plugin may run.
func (w *window) installedPermissions(c ui.C, language i18n.Language, fact PluginFacts) {
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Text(c, i18n.Shared(language, "native.permissions")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).PadBottom(4)
		if len(fact.Permissions) == 0 {
			ui.Wrap(c, i18n.Shared(language, "native.needsNoExtraPermissions")).FontSize(12).Color(w.pal.muted)
		}
		for index, permission := range fact.Permissions {
			k := c.KeyInt(index)
			ui.Row(k).FillWidth().PadY(4).Gap(8).Items(ui.Start).Children(func() {
				ui.Icon(k, icons.ShieldCheck).Size(14, 14).Color(w.pal.accent).Shrink(0)
				ui.Column(k).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
					if description := permissionDescription(language, permission); description != "" {
						ui.Wrap(k, description).FontSize(12).Color(w.pal.text)
					}
					ui.Text(k, permission).Mono().FontSize(11).Color(w.pal.subtle)
				})
			})
		}
		ui.Text(c, i18n.Shared(language, "native.programsItCanRun")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).PadTop(14).PadBottom(4)
		if len(fact.Programs) == 0 {
			ui.Wrap(c, i18n.Shared(language, "native.startsNoPrograms")).FontSize(12).Color(w.pal.muted)
		} else {
			ui.Text(c, i18n.Shared(language, "native.fullProgramDeclaration")).FontSize(11).Color(w.pal.muted).PadBottom(2)
		}
		for index, program := range fact.Programs {
			k := c.KeyInt(1000 + index)
			ui.Row(k).FillWidth().Pad(8).Radius(6).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
				ui.Wrap(k, program).Mono().FontSize(11).Color(w.pal.text).Grow(1).Shrink(1).MinWidth(0)
			})
		}
		ui.Wrap(c, i18n.Shared(language, "native.settingValuesOnlyFillThePlacesTheProgramTemplatesReserveForThemSoChangingASetta1ef53141a")).
			FontSize(11).Color(w.pal.subtle).PadTop(10)
	})
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
			if ui.Button(c, repositoryName(entry.Repository)).Link().Tooltip(entry.Repository).Clicked() {
				w.ctrl.opts.OpenURL(entry.Repository)
			}
		})
		w.installedField(c, i18n.Shared(language, "native.localPackage"), mono(fact.Path))
		w.installedField(c, i18n.Shared(language, "native.archiveSHA256"), mono(fact.ArchiveSHA256))
		w.installedField(c, i18n.Shared(language, "native.contentSHA256"), func() {
			ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
				mono(fact.ContentDigest)()
				ui.Wrap(c, i18n.Shared(language, "native.checkedAgainEveryTimeLitheLoadsThePlugin")).FontSize(11).Color(w.pal.subtle)
			})
		})
		w.installedField(c, i18n.Shared(language, "native.pluginID"), mono(fact.ID))
	})
}
