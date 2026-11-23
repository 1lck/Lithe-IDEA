package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Build, Execution, Deployment page follows pgBuild of the prototype
// docs/design/build-execution-settings.html. It lists its pages with what each holds in one
// line, and the tools that need attention above them; it shows nothing plugins put on their
// pages.

const (
	// buildPageWidth is the widest the Build page grows, the prototype's max-width.
	buildPageWidth = 860
	// directoryRowGap is the room between a row's tile, words and end, the prototype's .drow.
	directoryRowGap = 12
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
			w.buildIssues(c, language)
			w.buildDirectory(c, language)
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
	ui.Column(c.Part("issues")).FillWidth().MinWidth(0).Shrink(0).PadX(10).PadY(8).Radius(8).
		Border(1, colors.border).Background(colors.background).Children(func() {
		ui.Text(c, issuesTitle(language, view.Counts.Problems)).
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
				ui.Text(c, name).FontSize(buildSmall).Weight(gfx.WeightSemibold).Color(colors.text).Shrink(0)
				ui.Text(c, w.toolchainReasonText(language, scope, entry, toolchainReason(entry.tool))).
					FontSize(buildSmall).Color(colors.text).Shrink(1).MinWidth(0).Ellipsis()
				ui.Spacer(c)
				ui.Text(c, "›").FontSize(buildSmall).Color(colors.text).Shrink(0)
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

// directoryEntry is one row of a directory page, the Build page's or the Version Control
// page's: what it opens and what it shows.
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
	w.directory(c, w.directoryEntries(language))
}

// directory is the outlined list of a directory page's rows, each with its tile, title, a line
// on what it holds, a badge of its problems and an arrow; choosing a row opens its page.
func (w *window) directory(c ui.C, entries []directoryEntry) {
	if len(entries) == 0 {
		return
	}
	b := &w.bp
	var open func()
	ui.Column(c.Part("directory")).FillWidth().MinWidth(0).Shrink(0).Pad(4).Radius(10).Border(1, b.line).Background(b.surface).Children(func() {
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
					ui.Text(c, entry.title).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Ellipsis()
					ui.Row(k).Height(2).Shrink(0)
					ui.Text(c, entry.desc).FontSize(buildSmall).Color(b.sub).Ellipsis()
				})
				if entry.problems > 0 {
					w.badge(k, entry.problems, false)
				}
				ui.Text(c, "›").FontSize(buildFont).Color(b.faint).Shrink(0)
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
			entry.desc = toolchainsTileDescription(language, tools, plugins, shown)
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
			entry.desc = steppingTileDescription(language, len(s.adapters), customized)
		}
		entries = append(entries, entry)
	}
	separator := i18n.Shared(language, "desktop.buildSettings.listSeparator")
	for _, kind := range buildKinds {
		var names []string
		count := 0
		for index := range w.dynamic.pages {
			page := &w.dynamic.pages[index]
			if page.Kind != kind {
				continue
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
		entries = append(entries, directoryEntry{
			key: "kind:" + kind, tile: kindTile, icon: icons.LayoutGrid, title: kindTitle(language, kind), desc: desc,
			open: func() { w.openKind(kind) },
		})
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
