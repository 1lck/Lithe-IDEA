package settingswindow

import (
	"hash/fnv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Build, Execution, Deployment page and the page of a folder under it follow pgBuild and
// pgFolder of the prototype docs/design/build-execution-settings.html. The Build page lists its
// pages with what each holds in one line, and the tools that need attention above them; it
// shows nothing plugins put on their pages. A folder's page lists the plugin pages of one kind,
// with a filter, for the kinds the sidebar folds.

const (
	// buildPageWidth is the widest the Build page grows, the prototype's max-width.
	buildPageWidth = 860
	// directoryRowGap is the room between a row's tile, words and end, the prototype's .drow.
	directoryRowGap = 12
	// folderRowHeight is a row of a folder's page, the prototype's 52 points.
	folderRowHeight = 52
	// folderFilterWidth is the width of a folder page's filter.
	folderFilterWidth = 260
	// kindNames is how many of a kind's pages the Build page names before it counts them.
	kindNames = 3
)

// buildPage is the prototype's pgBuild: the title, the tools that need attention, the
// directory of the pages under Build, Execution, Deployment and a note on what it leaves out.
func (w *window) buildPage(c ui.C) {
	b := &w.bp
	language := w.marketLanguage()
	if t := w.toolchains; t.available() {
		t.ensureLoaded()
		t.requestView()
	}
	if s := w.stepping; s.available() {
		s.beginLoad()
	}
	ui.Scroll(c).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(b.surface).Children(func() {
		ui.Column(c).FillWidth().MaxWidth(buildPageWidth).PadSides(buildPagePadTop, buildPagePadX, buildPagePadEnd, buildPagePadX).Children(func() {
			ui.Text(c, titleOf(&w.text.Settings, pageBuild)).FontSize(buildHeading).Weight(gfx.WeightBold).Color(b.text).Ellipsis()
			ui.Row(c).Height(12).Shrink(0)
			w.buildIssues(c.Part("issues"), language)
			w.buildDirectory(c.Part("directory"), language)
			ui.Wrap(c, i18n.Shared(language, "desktop.buildSettings.directoryNote")).FontSize(11.5).Color(b.faint)
		})
	})
}

// buildIssues is the prototype's .issues box: how many tools of the shown scope need
// attention, the first of them, and a link to all of them once there are more. Choosing a
// tool opens the Toolchains page on it. Nothing shows while nothing needs attention or before
// Core projected the list.
func (w *window) buildIssues(c ui.C, language i18n.Language) {
	t := w.toolchains
	if !t.available() || !t.view.ready {
		return
	}
	view := &t.view.view
	if view.Counts.Problems == 0 || len(view.Issues) == 0 {
		return
	}
	b := &w.bp
	kind := boxWarn
	if view.Counts.Errors > 0 {
		kind = boxErr
	}
	colors := b.boxes[kind]
	scope := t.current()
	var chosen *core.ToolchainSettingsIssue
	all := false
	ui.Column(c).FillWidth().MinWidth(0).Shrink(0).PadX(10).PadY(8).Radius(8).
		Border(1, colors.border).Background(colors.background).Children(func() {
		ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.issuesTitle", map[string]string{"count": formatCount(view.Counts.Problems)})).
			FontSize(buildSmall).Weight(gfx.WeightSemibold).Color(colors.text).Ellipsis()
		ui.Row(c).Height(4).Shrink(0)
		for i := range view.Issues {
			issue := &view.Issues[i]
			if issue.Index < 0 || issue.Index >= len(t.view.entries) {
				continue
			}
			entry := &t.view.entries[issue.Index]
			k := c.Key(entry.tool.ID)
			name := toolchainName(&entry.tool)
			row := ui.ButtonBase(k, name).FillWidth().MinWidth(0).PadX(4).PadY(5).Gap(8).Radius(6).Items(ui.Center).
				Hover(ui.Look{}.Background(b.press))
			if row.Clicked() {
				chosen = issue
			}
			row.Children(func() {
				dot(k, 8, b.statusColor(issue.Status))
				ui.Text(k, name).FontSize(buildSmall).Weight(gfx.WeightSemibold).Color(colors.text).Shrink(0)
				ui.Text(k, w.toolchainReasonText(language, scope, entry, toolchainReason(entry.tool))).
					FontSize(buildSmall).Color(colors.text).Shrink(1).MinWidth(0).Ellipsis()
				ui.Spacer(k)
				ui.Text(k, "›").FontSize(buildSmall).Color(colors.text).Shrink(0)
			})
		}
		if view.Counts.Problems > len(view.Issues) {
			label := i18n.SharedFormat(language, "desktop.buildSettings.issuesAll", map[string]string{"count": formatCount(view.Counts.Problems)})
			row := ui.ButtonBase(c.Part("all"), label).FillWidth().PadX(4).PadY(5).Radius(6).Items(ui.Center).
				Hover(ui.Look{}.Background(b.press))
			if row.Clicked() {
				all = true
			}
			row.Children(func() {
				// The prototype's underlined link, in the words' color: a line under the words.
				ui.Column(c).Shrink(1).MinWidth(0).Children(func() {
					ui.Text(c, label).FontSize(buildSmall).Color(colors.text).Ellipsis()
					ui.Row(c).FillWidth().Height(1).Shrink(0).Background(colors.text)
				})
			})
		}
	})
	ui.Row(c).Height(14).Shrink(0)
	switch {
	case chosen != nil:
		t.reveal(t.view.entries[chosen.Index].tool.ID, chosen.Group)
		w.openBuildChild(pageToolchains)
	case all:
		t.query, t.filter, t.selected = "", "problems", ""
		w.openBuildChild(pageToolchains)
	}
}

// directoryEntry is one row of the Build page's directory: what it opens and what it shows.
type directoryEntry struct {
	key         string
	tile        gfx.Color
	icon        gfx.Icon
	title, desc string
	// problems is the count of the badge at the row's end, none at zero.
	problems int
	open     func()
}

// buildDirectory is the prototype's .sec.dir: one row for each page under Build, Execution,
// Deployment, the host's own first and then a row for each kind of plugin page.
func (w *window) buildDirectory(c ui.C, language i18n.Language) {
	entries := w.directoryEntries(language)
	if len(entries) == 0 {
		return
	}
	b := &w.bp
	var open func()
	ui.Column(c).FillWidth().MinWidth(0).Shrink(0).Pad(4).Radius(10).Border(1, b.line).Background(b.surface).Children(func() {
		for i := range entries {
			entry := &entries[i]
			k := c.Key(entry.key)
			if i > 0 {
				// The prototype's .drow+.drow: a line between two rows, inside their margins.
				ui.Row(k.Part("line")).FillWidth().Height(1).Shrink(0).Background(b.line)
			}
			row := ui.ButtonBase(k, entry.title).FillWidth().MinWidth(0).PadX(12).PadY(10).Gap(directoryRowGap).Radius(8).Items(ui.Center).
				Hover(ui.Look{}.Background(b.hover))
			if row.Clicked() {
				open = entry.open
			}
			row.Children(func() {
				w.glyphTile(k, entry.tile, entry.icon, 28)
				ui.Column(k).Grow(1).Shrink(1).MinWidth(0).Children(func() {
					ui.Text(k, entry.title).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Ellipsis()
					ui.Row(k).Height(2).Shrink(0)
					ui.Text(k, entry.desc).FontSize(buildSmall).Color(b.sub).Ellipsis()
				})
				if entry.problems > 0 {
					w.badge(k, entry.problems, false)
				}
				ui.Text(k, "›").FontSize(buildFont).Color(b.faint).Shrink(0)
			})
		}
	})
	ui.Row(c).Height(12).Shrink(0)
	if open != nil {
		open()
	}
}

// directoryEntries are the rows of the Build page's directory, in the sidebar's order.
func (w *window) directoryEntries(language i18n.Language) []directoryEntry {
	var entries []directoryEntry
	if t := w.toolchains; t.available() {
		entry := directoryEntry{
			key: "toolchains", tile: toolchainsTile, icon: icons.Wrench, title: titleOf(&w.text.Settings, pageToolchains),
			desc: i18n.Shared(language, "desktop.toolchains.loading"),
			open: func() { w.openBuildChild(pageToolchains) },
		}
		if scope := t.current(); scope != nil && scope.loaded {
			shown := i18n.Shared(language, "desktop.buildSettings.directoryScopeGlobal")
			if scope.name == scopeProject {
				shown = i18n.Shared(language, "desktop.buildSettings.directoryScopeProject")
			}
			tools, plugins := toolchainCounts(scope)
			if t.view.ready {
				tools = t.view.view.Counts.Total
				entry.problems = t.view.view.Counts.Problems
			}
			entry.desc = i18n.SharedFormat(language, "desktop.buildSettings.directoryToolchains", map[string]string{
				"tools": formatCount(tools), "plugins": formatCount(plugins), "scope": shown,
			})
		}
		entries = append(entries, entry)
	}
	if s := w.stepping; s.available() {
		entry := directoryEntry{
			key: "debuggers", tile: debuggersTile, icon: icons.Bug, title: titleOf(&w.text.Settings, pageDebuggers),
			desc: i18n.Shared(language, "desktop.toolchains.loading"),
			open: func() { w.openBuildChild(pageDebuggers) },
		}
		if s.loaded {
			customized := 0
			for _, adapter := range s.adapters {
				if _, ok := w.sess.values.SteppingFilters[adapter.ID]; ok {
					customized++
				}
			}
			if customized > 0 {
				entry.desc = i18n.SharedFormat(language, "desktop.buildSettings.directoryDebuggersCustomized", map[string]string{
					"count": formatCount(len(s.adapters)), "customized": formatCount(customized),
				})
			} else {
				entry.desc = i18n.SharedFormat(language, "desktop.buildSettings.directoryDebuggers", map[string]string{"count": formatCount(len(s.adapters))})
			}
		}
		entries = append(entries, entry)
	}
	separator := i18n.Shared(language, "desktop.buildSettings.listSeparator")
	for _, kind := range buildKinds {
		var names []string
		count, first := 0, ""
		for index := range w.dynamic.pages {
			page := &w.dynamic.pages[index]
			if page.Kind != kind {
				continue
			}
			if count == 0 {
				first = page.Key
			}
			if count < kindNames {
				names = append(names, page.Title)
			}
			count++
		}
		if count == 0 {
			continue
		}
		var desc string
		if count > kindNames {
			desc = i18n.SharedFormat(language, "desktop.buildSettings.directoryKindMore", map[string]string{
				"names": strings.Join(names, separator), "count": formatCount(count),
			})
		} else {
			desc = i18n.SharedFormat(language, "desktop.buildSettings.directoryKind", map[string]string{"names": strings.Join(names, separator)})
		}
		entry := directoryEntry{key: "kind:" + kind, tile: kindTile, icon: icons.LayoutGrid, title: kindTitle(language, kind), desc: desc}
		if count >= folderMin {
			entry.open = func() { w.openFolder(kind) }
		} else {
			entry.open = func() { w.selectSettingsPage(pageBuild, first) }
		}
		entries = append(entries, entry)
	}
	return entries
}

// toolchainCounts is how many tools the scope lists and how many plugins declare them.
func toolchainCounts(scope *toolchainScope) (tools, plugins int) {
	seen := make(map[string]bool)
	for _, tool := range scope.snapshot.Tools {
		if tool.ID == "" || tool.PluginID == "" {
			continue
		}
		tools++
		if !seen[tool.PluginID] {
			seen[tool.PluginID] = true
			plugins++
		}
	}
	return tools, plugins
}

// buildFolderPage is the prototype's pgFolder: the plugin pages of the open folder's kind,
// the ones whose title or plugin the filter matches, each with its plugin and what it holds.
// Choosing one opens it with its folder open in the sidebar.
func (w *window) buildFolderPage(c ui.C) {
	b := &w.bp
	language := w.marketLanguage()
	kind := w.folderPage
	pages := w.folderPages(kind)
	total := w.dynamic.kindCount(kind)
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(b.surface).Children(func() {
		ui.Row(c).FillWidth().Shrink(0).PadSides(10, 14, 6, 14).Gap(8).Items(ui.Center).Children(func() {
			ui.Text(c, kindTitle(language, kind)).FontSize(buildHeading).Weight(gfx.WeightBold).Color(b.text).Shrink(0)
			ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.folderCount", map[string]string{"count": formatCount(total)})).
				FontSize(buildSmall).Color(b.sub).Shrink(1).MinWidth(0).Ellipsis()
			ui.Spacer(c)
			ui.Row(c).Width(folderFilterWidth).Shrink(1).MinWidth(120).Children(func() {
				placeholder := i18n.Shared(language, "desktop.buildSettings.folderFilter")
				w.filterField(c.Part("filter"), &w.folderQuery, placeholder, placeholder, true)
			})
		})
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
		if len(pages) == 0 {
			ui.Row(c).FillWidth().Shrink(0).PadSides(50, 20, 50, 20).Justify(ui.Center).Children(func() {
				ui.Wrap(c, i18n.Shared(language, "desktop.buildSettings.folderEmpty")).FontSize(buildFont).Color(b.faint).TextCenter()
			})
			return
		}
		w.folderList.Key = func(row int) int {
			if row < 0 || row >= len(pages) {
				return 0
			}
			return folderRowKey(pages[row].Key)
		}
		w.folderList.Label = func(row int) string {
			if row < 0 || row >= len(pages) {
				return ""
			}
			return pages[row].Title
		}
		separator := i18n.Shared(language, "desktop.buildSettings.listSeparator")
		ui.List(c, &w.folderList, len(pages), func(r ui.ListRow) {
			page := pages[r.Index]
			k := r.C
			r.Element.Height(folderRowHeight).PadSides(0, 12, 0, 14).Gap(11).Items(ui.Center).Hover(ui.Look{}.Background(b.hover)).Children(func() {
				plugin := folderPlugins(page, separator)
				w.pluginTile(k, plugin, 28)
				ui.Column(k).Grow(1).Shrink(1).MinWidth(0).Children(func() {
					ui.Text(k, page.Title).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Ellipsis()
					ui.Row(k).Height(2).Shrink(0)
					line := plugin
					if summary := folderSummary(page, separator); summary != "" {
						line += " · " + summary
					}
					ui.Text(k, line).FontSize(11).Color(b.faint).Ellipsis()
				})
				ui.Text(k, "›").FontSize(buildFont).Color(b.faint).Shrink(0)
			})
		}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(kindTitle(language, kind))
		if row, ok := w.folderList.Submitted(); ok && row >= 0 && row < len(pages) {
			w.openFolderPage(pages[row])
		} else if row := w.folderList.Selected(); w.folderList.Changed() && row >= 0 && row < len(pages) {
			w.openFolderPage(pages[row])
		}
	})
}

// folderRowKey is a folder page's row identity, its page's key hashed to the list's
// non-negative 31-bit keys.
func folderRowKey(key string) int {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(key))
	return int(hash.Sum32() & 0x7fffffff)
}

// folderPages are the plugin pages of kind the folder page's filter keeps: the ones whose
// title or a contributing plugin's title holds the filter, ignoring case.
func (w *window) folderPages(kind string) []*core.SettingsPage {
	query := strings.ToLower(strings.TrimSpace(w.folderQuery))
	var pages []*core.SettingsPage
	for index := range w.dynamic.pages {
		page := &w.dynamic.pages[index]
		if page.Kind != kind {
			continue
		}
		if query != "" && !folderMatches(page, query) {
			continue
		}
		pages = append(pages, page)
	}
	return pages
}

// folderMatches reports whether a lower-case query is in page's title or a contributor's.
func folderMatches(page *core.SettingsPage, query string) bool {
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

// folderPlugins names the plugins that contribute to page.
func folderPlugins(page *core.SettingsPage, separator string) string {
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

// folderSummary is what a plugin page holds, the titles of its sections.
func folderSummary(page *core.SettingsPage, separator string) string {
	titles := make([]string, 0, len(page.Sections))
	for _, section := range page.Sections {
		if section.Title != "" {
			titles = append(titles, section.Title)
		}
	}
	return strings.Join(titles, separator)
}

// openFolderPage opens a plugin page from its folder's page, with the folder open in the
// sidebar so the page's row is on the screen.
func (w *window) openFolderPage(page *core.SettingsPage) {
	if index := kindIndex(page.Kind); index >= 0 {
		w.folders[index] = true
	}
	// The list forgets the row, so choosing it again the next time the folder shows opens it.
	w.folderList.Select(-1)
	w.folderPage = ""
	w.sess.open[pageBuild] = true
	w.selectSettingsPage(pageBuild, page.Key)
}
