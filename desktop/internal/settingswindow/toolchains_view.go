package settingswindow

import (
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Toolchains page follows the prototype docs/design/build-execution-settings.html: a
// toolbar with the scope and the filter, the filter chips, the trust banner, then the tool
// list beside the chosen tool's detail. Core projects the list (toolchains.settingsView);
// this file only lays it out, and every state it changes lives in toolchains_state.go.

const (
	// toolchainListWidth is the prototype's width of the tool list. A window too narrow for it
	// and toolchainDetailMin beside it gives the list less, down to toolchainListMin.
	toolchainListWidth = 372
	toolchainListMin   = 280
	toolchainDetailMin = 380
	// toolchainToolRow and toolchainGroupRow are the prototype's row heights.
	toolchainToolRow  = 46
	toolchainGroupRow = 30
)

// toolchainResult is what a tool resolves to in a scope: an installation and the layer that
// chose it, or the reason none applies.
type toolchainResult struct {
	ok                               bool
	version, home, executable, layer string
	reason                           string
}

// toolchainCurrent is what the tool uses now, as Core resolved the scope's snapshot.
func toolchainCurrent(tool *toolchain.Tool) toolchainResult {
	if tool.Effective != nil && tool.Reason == "" {
		result := toolchainResult{ok: true, version: tool.Effective.Version, executable: tool.Effective.Executable, layer: tool.Effective.Layer}
		if tool.Effective.Home != nil {
			result.home = *tool.Effective.Home
		}
		if result.home == "" {
			result.home = result.executable
		}
		return result
	}
	return toolchainResult{reason: toolchainReason(*tool)}
}

// toolchainNext is what the tool will use once the scope's draft applies: the chosen home under
// the scope's own layer, or what the tool falls back to without a pin.
func toolchainNext(scope *toolchainScope, tool *toolchain.Tool) toolchainResult {
	if wanted := scope.wanted(tool.ID); wanted != "" {
		layer := "pinned"
		if scope.name == scopeGlobal {
			layer = "global"
		}
		version := "?"
		if pin, ok := scope.pinFor(tool, wanted); ok && pin.Version != "" {
			version = pin.Version
		}
		return toolchainResult{ok: true, version: version, home: wanted, layer: layer}
	}
	if automatic := tool.Automatic; automatic != nil {
		result := toolchainResult{ok: true, version: automatic.Version, home: tool.AutomaticHome, executable: automatic.Executable, layer: automatic.Layer}
		if result.home == "" && automatic.Home != nil {
			result.home = *automatic.Home
		}
		return result
	}
	reason := tool.AutomaticReason
	if reason == "" {
		reason = "notFound"
	}
	return toolchainResult{reason: reason}
}

// toolchainStatus is the state Core gives a reason: the problems the user may fix in place warn,
// the rest are errors. It matches toolchains.settingsView, for a list Core did not project.
func toolchainStatus(result toolchainResult) string {
	switch {
	case result.ok:
		return "ok"
	case result.reason == "projectCodeRequiresAction" || result.reason == "ambiguousInstallation" || result.reason == "probeFailed":
		return "warning"
	default:
		return "error"
	}
}

// toolchainsPage is the Toolchains page under Build, Execution, Deployment.
func (w *window) toolchainsPage(c ui.C) {
	t := w.toolchains
	if !t.available() {
		w.unavailablePage(c)
		return
	}
	language := w.marketLanguage()
	t.ensureLoaded()
	if t.filter == "changed" && t.drafts(t.scope) == 0 {
		t.filter = "all"
	}
	t.requestView()
	scope := t.current()
	b := &w.bp
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(b.surface).Children(func() {
		w.toolchainsToolbar(c.Part("bar"), language, scope)
		w.toolchainsChips(c.Part("chips"), language)
		w.toolchainsNotices(c, language, scope)
		switch {
		case t.scope == scopeProject && t.noProject():
			w.toolchainsEmpty(c, i18n.Shared(language, "desktop.toolchains.noProject"))
		case !scope.loaded || !t.view.ready:
			if scope.failed == nil && t.view.failed == nil {
				w.toolchainsEmpty(c, i18n.Shared(language, "desktop.toolchains.loading"))
			}
		default:
			w.toolchainsSplit(c.Part("split"), language, scope)
		}
	})
}

// toolchainsEmpty is a sentence in the middle of what is left of the page.
func (w *window) toolchainsEmpty(c ui.C, text string) {
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Center().Children(func() {
		ui.Wrap(c, text).FontSize(buildSmall).LineHeight(21.6).Color(w.bp.faint).TextCenter().MaxWidth(emptyWidth)
	})
}

// toolchainsToolbar is the prototype's .tbar: the scope switch and its help, the project's trust,
// then the filter and the re-detect button.
func (w *window) toolchainsToolbar(c ui.C, language i18n.Language, scope *toolchainScope) {
	t := w.toolchains
	b := &w.bp
	ui.Row(c).FillWidth().Shrink(0).PadSides(10, 14, 6, 14).Gap(8).Items(ui.Center).Children(func() {
		if len(t.order) > 1 {
			project := i18n.Shared(language, "desktop.toolchains.project")
			if name := t.projectName(); name != "" {
				project = i18n.SharedFormat(language, "desktop.buildSettings.scopeProjectNamed", map[string]string{"project": name})
			}
			noProject := t.noProject()
			tip := ""
			if noProject {
				tip = i18n.Shared(language, "desktop.toolchains.noProject")
			}
			value := t.scope
			if w.segmented(c.Part("scope"), &value, []segment{
				{value: scopeGlobal, label: i18n.Shared(language, "desktop.toolchains.global"), changed: t.drafts(scopeGlobal) > 0},
				{value: scopeProject, label: project, changed: t.drafts(scopeProject) > 0, disabled: noProject, tip: tip},
			}) {
				t.setScope(value)
			}
			w.infoButton(c.Part("scope-help"), i18n.Shared(language, "desktop.buildSettings.scopeHelp"))
		}
		if t.scope == scopeProject && scope.loaded && scope.snapshot.ProjectCodeAllowed && t.trustEffect != nil {
			k := c.Part("trust")
			trusted := i18n.Shared(language, "desktop.toolchains.trustStatusTrusted")
			w.tag(k, tagGreen, trusted).HitWith(ui.ID(k), trusted, gfx.HitOptions{Role: gfx.RoleStatus}).
				Tooltip(i18n.Shared(language, "desktop.buildSettings.trustedHelp"))
			if w.button(c.Part("revoke"), buttonLinkSmall, i18n.Shared(language, "desktop.buildSettings.revokeTrust"), t.busy()) {
				t.beginTrust(false)
			}
		}
		ui.Spacer(c)
		filter := i18n.Shared(language, "desktop.buildSettings.filterLabel")
		ui.Row(c).Width(260).Shrink(1).MinWidth(120).Children(func() {
			w.filterField(c.Part("filter"), &t.query, filter, i18n.Shared(language, "desktop.buildSettings.filterPlaceholder"), true)
		})
		if w.iconButton(c.Part("redetect"), icons.RefreshCw, i18n.Shared(language, "desktop.buildSettings.redetect"), t.busy()) {
			t.reload()
		}
	})
	_ = b
}

// toolchainsChips is the prototype's .tbar2: the filter chips with their counts, then the
// grouping.
func (w *window) toolchainsChips(c ui.C, language i18n.Language) {
	t := w.toolchains
	b := &w.bp
	counts := t.view.view.Counts
	ui.Column(c).FillWidth().Shrink(0).Children(func() {
		ui.Row(c).FillWidth().PadSides(2, 14, 8, 14).Gap(6).Items(ui.Center).Children(func() {
			if w.chip(c.Part("all"), i18n.Shared(language, "desktop.buildSettings.filterAll"), counts.Total, t.filter == "all", nil) {
				t.filter = "all"
			}
			var mark *gfx.Color
			if counts.Problems > 0 {
				color := b.warn
				if counts.Errors > 0 {
					color = b.err
				}
				mark = &color
			}
			if w.chip(c.Part("problems"), i18n.Shared(language, "desktop.buildSettings.filterProblems"), counts.Problems, t.filter == "problems", mark) {
				t.filter = "problems"
			}
			if w.chip(c.Part("pinned"), i18n.Shared(language, "desktop.buildSettings.filterPinned"), counts.Pinned, t.filter == "pinned", nil) {
				t.filter = "pinned"
			}
			if counts.Changed > 0 {
				if w.chip(c.Part("changed"), i18n.Shared(language, "desktop.buildSettings.filterChanged"), counts.Changed, t.filter == "changed", nil) {
					t.filter = "changed"
				}
			}
			ui.Spacer(c)
			groupBy := i18n.Shared(language, "desktop.buildSettings.groupBy")
			ui.Text(c, groupBy).FontSize(buildSmall).Color(b.sub).Shrink(0)
			ui.Select(c.Part("group"), &t.groupBy, []string{"category", "plugin", "none"}, func(value string) string {
				switch value {
				case "plugin":
					return i18n.Shared(language, "desktop.buildSettings.groupPlugin")
				case "none":
					return i18n.Shared(language, "desktop.buildSettings.groupNone")
				}
				return i18n.Shared(language, "desktop.buildSettings.groupCategory")
			}).Label(groupBy)
		})
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
	})
}

// toolchainsNotices are the banner and the messages over the list: the project's untrusted
// environments, a read or write that failed, and the request that is out.
func (w *window) toolchainsNotices(c ui.C, language i18n.Language, scope *toolchainScope) {
	t := w.toolchains
	banner := false
	count, sources := 0, []string(nil)
	if t.scope == scopeProject && scope.loaded && !scope.snapshot.ProjectCodeAllowed {
		count, sources = projectSources(scope.snapshot)
		banner = count > 0
	}
	busy := ""
	switch {
	case t.saving:
		busy = i18n.Shared(language, "desktop.toolchains.saving")
	case t.trusting:
		busy = i18n.Shared(language, "desktop.toolchains.updatingTrust")
	case t.preparingRuntime:
		if progress := t.runtimeProgress.Load(); progress != nil {
			busy = RuntimeProgressText(language, *progress)
		} else {
			busy = i18n.Shared(language, "desktop.toolchains.preparingRuntime")
		}
	case t.inspecting:
		busy = i18n.Shared(language, "desktop.toolchains.loading")
	}
	if !banner && !scope.snapshot.DiscoveryIncomplete && scope.failed == nil && t.failed == nil && t.view.failed == nil && busy == "" {
		return
	}
	ui.Column(c.Part("notices")).FillWidth().Shrink(0).PadSides(8, 14, 0, 14).Gap(8).Children(func() {
		if banner {
			if len(sources) > 3 {
				sources = sources[:3]
			}
			text := trustBannerText(language, count, strings.Join(sources, i18n.Shared(language, "desktop.buildSettings.listSeparator")))
			w.box(c.Part("banner"), boxWarn, func(words gfx.Color) {
				boxIcon(c, icons.CircleAlert, words)
				boxText(c, text, words)
				w.infoButton(c.Part("banner-help"), i18n.Shared(language, "desktop.toolchains.trustProjectHelp"))
				if t.trustEffect != nil && w.button(c.Part("banner-trust"), buttonSmall, i18n.Shared(language, "desktop.buildSettings.trustProject"), t.busy()) {
					t.beginTrust(true)
				}
			})
		}
		if scope.loaded && scope.snapshot.DiscoveryIncomplete {
			w.box(c.Part("discovery-incomplete"), boxWarn, func(words gfx.Color) {
				boxIcon(c, icons.CircleAlert, words)
				boxText(c, i18n.Shared(language, "desktop.toolchains.discoveryIncomplete"), words)
				if w.button(c.Part("discovery-reload"), buttonSmall, i18n.Shared(language, "desktop.toolchains.reload"), t.busy()) {
					t.reload()
				}
			})
		}
		if scope.failed != nil {
			message := toolchainFailureMessage(language, scope.failed)
			w.box(c.Part("load-failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
				if w.button(c.Part("load-retry"), buttonSmall, i18n.Shared(language, "desktop.toolchains.reload"), t.busy()) {
					scope.failed = nil
					t.reload()
				}
			})
		}
		if t.failed != nil {
			message := toolchainFailureMessage(language, t.failed)
			w.box(c.Part("failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
			})
		}
		if t.view.failed != nil {
			message := toolchainFailureMessage(language, t.view.failed)
			w.box(c.Part("view-failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
			})
		}
		if busy != "" {
			w.box(c.Part("busy"), boxInfo, func(words gfx.Color) {
				boxIcon(c, icons.Clock, words)
				boxText(c, busy, words)
			})
		}
	})
}

// toolchainsSplit is the list beside the detail of the chosen tool.
func (w *window) toolchainsSplit(c ui.C, language i18n.Language, scope *toolchainScope) {
	b := &w.bp
	width := float32(toolchainListWidth)
	if room := w.extent - 1 - toolchainDetailMin; room < width {
		width = max(toolchainListMin, room)
	}
	ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		ui.Column(c).Width(width).Shrink(0).FillHeight().MinHeight(0).Children(func() {
			w.toolchainsList(c.Part("list"), language, scope)
			ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
			tools := 0
			for _, row := range w.toolchains.view.view.Rows {
				if row.Kind == "tool" {
					tools++
				}
			}
			ui.Row(c).FillWidth().Shrink(0).PadX(12).PadY(5).Gap(8).Children(func() {
				ui.Text(c, toolchainListCount(language, tools, w.toolchains.view.view.Counts.Total)).FontSize(11).Color(b.faint).Ellipsis()
			})
		})
		ui.Row(c).Width(1).Shrink(0).FillHeight().Background(b.line)
		ui.Scroll(c.Key("detail:"+w.toolchains.selected)).Scrollbars().Grow(1).Shrink(1).MinWidth(0).FillHeight().
			PadSides(buildPagePadTop, buildPagePadX, buildPagePadEnd, buildPagePadX).Children(func() {
			w.toolchainDetail(c, language, scope)
		})
	})
}

// toolchainsList is Core's projected rows: group headers that fold, and the tools under them.
func (w *window) toolchainsList(c ui.C, language i18n.Language, scope *toolchainScope) {
	t := w.toolchains
	b := &w.bp
	rows := t.view.view.Rows
	if t.selected == "" || t.selectedRow(rows) < 0 && scope.tool(t.selected) == nil {
		t.selected = ""
		for _, row := range rows {
			if entry := t.view.entry(row); entry != nil {
				t.selected = entry.tool.ID
				break
			}
		}
	}
	if len(rows) == 0 {
		empty := i18n.Shared(language, "desktop.buildSettings.noMatches")
		check := t.filter == "problems" && strings.TrimSpace(t.query) == ""
		if check {
			empty = i18n.Shared(language, "desktop.buildSettings.noProblems")
		}
		ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).PadSides(50, 20, 50, 20).Items(ui.Center).Children(func() {
			ui.Row(c).Gap(6).Items(ui.Center).Children(func() {
				if check {
					ui.Icon(c, icons.Check).Size(12, 12).Color(b.faint).Shrink(0)
				}
				ui.Wrap(c, empty).FontSize(buildSmall).LineHeight(21.6).Color(b.faint).TextCenter()
			})
		})
		return
	}
	t.list.Key = func(i int) int {
		if i < 0 || i >= len(rows) {
			return 0
		}
		return toolchainRowKey(rows[i])
	}
	t.list.Header = func(i int) bool { return i >= 0 && i < len(rows) && rows[i].Kind == "group" }
	t.list.Label = func(i int) string {
		if i < 0 || i >= len(rows) {
			return ""
		}
		if rows[i].Kind == "group" {
			return w.toolchainGroupLabel(language, rows[i])
		}
		if entry := t.view.entry(rows[i]); entry != nil {
			return toolchainName(&entry.tool)
		}
		return ""
	}
	if at := t.selectedRow(rows); t.list.Selected() != at {
		t.list.Select(at)
		if at >= 0 {
			t.list.ScrollIntoView(at)
		}
	}
	ui.List(c, &t.list, len(rows), func(r ui.ListRow) {
		row := rows[r.Index]
		if row.Kind == "group" {
			w.toolchainGroupRow(r, language, row)
			return
		}
		entry := t.view.entry(row)
		if entry == nil {
			return
		}
		w.toolchainToolRow(r, language, scope, entry, row.Status)
	}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(i18n.Shared(language, "desktop.toolchains.title"))
	if t.list.Changed() {
		if at := t.list.Selected(); at >= 0 && at < len(rows) {
			if entry := t.view.entry(rows[at]); entry != nil && entry.tool.ID != t.selected {
				t.selected, t.whyOpen, t.adding = entry.tool.ID, false, ""
			}
		}
	}
}

// selectedRow is the row of the chosen tool, or -1 when the list does not show it.
func (t *toolchainState) selectedRow(rows []core.ToolchainSettingsRow) int {
	for at, row := range rows {
		if entry := t.view.entry(row); entry != nil && entry.tool.ID == t.selected {
			return at
		}
	}
	return -1
}

// toolchainGroupLabel names a group: its plugin, the plugins' own runtimes, or a category.
func (w *window) toolchainGroupLabel(language i18n.Language, row core.ToolchainSettingsRow) string {
	switch {
	case row.PluginID != "":
		if row.Title != "" {
			return row.Title
		}
		return row.PluginID
	case row.Audience == "plugin":
		return i18n.Shared(language, "desktop.buildSettings.categoryPlugin")
	default:
		return toolchainCategoryLabel(language, row.Category, "")
	}
}

// toolchainGroupRow is the prototype's .gh: the caret, the group's name and count and its
// problems on the sidebar's ground. A press anywhere on it folds or opens the group.
func (w *window) toolchainGroupRow(r ui.ListRow, language i18n.Language, row core.ToolchainSettingsRow) {
	t := w.toolchains
	b := &w.bp
	c := r.C
	label := w.toolchainGroupLabel(language, row)
	r.Element.Height(toolchainGroupRow).Background(b.side).Children(func() {
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).FillHeight().Children(func() {
			ui.Row(c).FillWidth().Grow(1).PadX(12).Gap(6).Items(ui.Center).Children(func() {
				toggle := ui.ButtonBase(c.Part("toggle"), label).Shrink(1).MinWidth(0).FillHeight().Gap(6).Items(ui.Center)
				if toggle.Clicked() {
					t.toggleGroup(row)
				}
				toggle.Children(func() {
					caret := icons.ChevronDown
					if row.Collapsed {
						caret = icons.ChevronRight
					}
					ui.Row(c).Width(10).Shrink(0).Center().Children(func() {
						ui.Icon(c, caret).Size(10, 10).Color(b.faint)
					})
					ui.Text(c, label).FontSize(11.5).Weight(gfx.WeightSemibold).Color(b.sub).Shrink(1).Ellipsis()
					ui.Text(c, formatCount(row.Count)).FontSize(11.5).Color(b.faint).Shrink(0)
					if row.Problems > 0 {
						w.badge(c, row.Problems, t.view.view.Counts.Errors == 0).MarginLeft(4)
					}
				})
				if row.Key == "audience:plugin" && t.groupBy == "category" {
					w.infoButton(c.Part("info"), i18n.Shared(language, "desktop.buildSettings.pluginGroupHelp"))
				}
				fill := ui.ButtonBase(c.Part("fill"), label).Grow(1).FillHeight()
				if fill.Clicked() {
					t.toggleGroup(row)
				}
			})
			ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
		})
	})
}

// toolchainToolRow is the prototype's .trow: the state dot, the name with its version, what a
// draft changes it to and its layer, then the plugin and the home or the reason.
func (w *window) toolchainToolRow(r ui.ListRow, language i18n.Language, scope *toolchainScope, entry *toolchainEntry, status string) {
	b := &w.bp
	r.Element.Height(toolchainToolRow).PadSides(0, 12, 0, 14).Gap(9).Items(ui.Center).Hover(ui.Look{}.Background(b.hover))
	if r.Selected() {
		r.Element.Background(b.sel)
	}
	r.Element.Children(func() { w.toolchainToolContent(r.C, language, scope, entry, status) })
}

// toolchainToolContent is what a tool's row holds, inside the row the caller lays out: the
// toolchains list's row, or a plugin region's tool node, which draws the same row.
func (w *window) toolchainToolContent(c ui.C, language i18n.Language, scope *toolchainScope, entry *toolchainEntry, status string) {
	b := &w.bp
	tool := &entry.tool
	if fresh := scope.tool(tool.ID); fresh != nil {
		tool = fresh
	}
	current := toolchainCurrent(tool)
	if status == "" {
		status = toolchainStatus(current)
	}
	changed := scope.changed(tool.ID)
	if changed {
		ui.Row(c).Absolute().Left(4).Top(20).Size(6, 6).Radius(3).Background(b.accent)
	}
	dot(c, 8, b.statusColor(status))
	ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			ui.Text(c, toolchainName(tool)).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Shrink(1).Ellipsis()
			if current.ok {
				ui.Text(c, current.version).FontSize(11).Mono().Color(b.sub).Shrink(0)
			}
			if changed {
				next := toolchainNext(scope, tool)
				version := "?"
				if next.ok {
					version = next.version
				}
				ui.Text(c, "→ "+version).FontSize(11).Mono().Color(b.accent).Shrink(0)
			}
			ui.Spacer(c)
			if tool.ManagedOnly && current.ok {
				w.tag(c, tagPlain, toolchainSourceLabel(language, "host:managed"))
			} else {
				w.layerTag(c, language, current, status)
			}
		})
		ui.Row(c).FillWidth().Height(2).Shrink(0)
		ui.Row(c).FillWidth().MinWidth(0).Items(ui.Center).Children(func() {
			plugin := toolchainPluginName(scope, tool.PluginID, tool.PluginName)
			if current.ok {
				short := midTrim(current.home, 44)
				box := ui.Text(c, plugin+" · "+short).FontSize(11).Color(b.faint).Shrink(1).Ellipsis()
				if short != current.home {
					box.OverflowTooltip(plugin + " · " + current.home)
				}
				return
			}
			detail := w.toolchainReasonDetail(language, scope, entry, tool)
			if detail == "" {
				ui.Text(c, plugin).FontSize(11).Color(b.faint).Shrink(1).Ellipsis()
				return
			}
			ui.Text(c, plugin+" · ").FontSize(11).Color(b.faint).Shrink(0)
			ui.Text(c, detail).FontSize(11).Color(b.statusColor(status)).Shrink(1).Ellipsis()
		})
	})
}

// toolchainReasonDetail is what a list row says after the plugin for a problem the row can
// name: the project file that waits for trust, or the plugins that declare the same tool.
func (w *window) toolchainReasonDetail(language i18n.Language, scope *toolchainScope, entry *toolchainEntry, tool *toolchain.Tool) string {
	switch toolchainReason(*tool) {
	case "projectCodeRequiresAction":
		if source, _ := toolchainTrustSource(tool); source != "" {
			return i18n.SharedFormat(language, "desktop.buildSettings.fromSource", map[string]string{"source": source})
		}
	case "conflict":
		return toolchainConflictPlugins(language, scope, entry)
	}
	return ""
}

// toolchainConflictPlugins names the plugins that declare a conflicting tool.
func toolchainConflictPlugins(language i18n.Language, scope *toolchainScope, entry *toolchainEntry) string {
	names := make([]string, 0, len(entry.conflict))
	for _, id := range entry.conflict {
		names = append(names, toolchainPluginName(scope, id, ""))
	}
	return strings.Join(names, i18n.Shared(language, "desktop.buildSettings.listSeparator"))
}

// layerTag is the tag at the end of a tool's first line: the layer that chose its
// installation, or the reason none applies.
func (w *window) layerTag(c ui.C, language i18n.Language, result toolchainResult, status string) {
	if !result.ok {
		kind := tagErr
		if status == "warning" {
			kind = tagWarn
		}
		w.tag(c, kind, toolchainReasonLabel(language, result.reason))
		return
	}
	kind := tagPlain
	switch result.layer {
	case "pinned", "project":
		kind = tagGreen
	case "global":
		kind = tagBlue
	}
	w.tag(c, kind, ToolchainLayerLabel(language, result.layer))
}

// toolchainName is a tool's display name, its ID when it has none.
func toolchainName(tool *toolchain.Tool) string {
	if tool.DisplayName != "" {
		return tool.DisplayName
	}
	return tool.ID
}

// toolchainPluginName is a plugin's display name as its tools carry it, else its ID.
func toolchainPluginName(scope *toolchainScope, pluginID, name string) string {
	if name != "" {
		return name
	}
	for _, tool := range scope.snapshot.Tools {
		if tool.PluginID == pluginID && tool.PluginName != "" {
			return tool.PluginName
		}
	}
	return pluginID
}

// toolchainCategoryLabel names a definition's display group.
func toolchainCategoryLabel(language i18n.Language, category, audience string) string {
	if audience == "plugin" {
		return i18n.Shared(language, "desktop.buildSettings.categoryPlugin")
	}
	switch category {
	case "runtime":
		return i18n.Shared(language, "desktop.buildSettings.categoryRuntime")
	case "build":
		return i18n.Shared(language, "desktop.buildSettings.categoryBuild")
	case "package":
		return i18n.Shared(language, "desktop.buildSettings.categoryPackage")
	case "debug":
		return i18n.Shared(language, "desktop.buildSettings.categoryDebug")
	case "lint":
		return i18n.Shared(language, "desktop.buildSettings.categoryLint")
	default:
		return i18n.Shared(language, "desktop.buildSettings.categoryOther")
	}
}

// toolchainTrustSource is the project file and home of the first project candidate that waits
// for trust.
func toolchainTrustSource(tool *toolchain.Tool) (source, home string) {
	for _, project := range tool.Project {
		if project.Reason == "projectCodeRequiresAction" {
			home = project.Home
			if home == "" {
				home = project.Path
			}
			return project.Path, home
		}
	}
	return "", ""
}

// toolchainEntryFor is the chosen tool as the scope holds it, or the list's entry of a tool
// that several plugins declare and the snapshot leaves out.
func (t *toolchainState) toolchainEntryFor(scope *toolchainScope, id string) *toolchainEntry {
	if tool := scope.tool(id); tool != nil {
		return &toolchainEntry{tool: *tool}
	}
	for index := range t.view.entries {
		if entry := &t.view.entries[index]; entry.tool.ID == id {
			return entry
		}
	}
	return nil
}

// toolchainDetail is the prototype's .dt: the chosen tool's head, its problem, what it uses
// now and the choices of the scope.
func (w *window) toolchainDetail(c ui.C, language i18n.Language, scope *toolchainScope) {
	t := w.toolchains
	b := &w.bp
	entry := t.toolchainEntryFor(scope, t.selected)
	if entry == nil {
		ui.Column(c).FillWidth().PadY(50).Items(ui.Center).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.buildSettings.selectTool")).FontSize(buildSmall).Color(b.faint)
		})
		return
	}
	tool := &entry.tool
	current := toolchainCurrent(tool)
	status := toolchainStatus(current)
	name := toolchainName(tool)
	plugin := toolchainPluginName(scope, tool.PluginID, tool.PluginName)
	ui.Column(c).FillWidth().MinWidth(0).Children(func() {
		w.toolchainHead(c.Part("head"), language, scope, tool, name, plugin)
		ui.Row(c).Height(14).Shrink(0)
		if w.toolchainProblem(c, language, scope, entry, current, status, name, plugin) {
			ui.Row(c).Height(12).Shrink(0)
		}
		w.toolchainEffective(c.Part("effective"), language, scope, entry, current, status)
		ui.Row(c).Height(12).Shrink(0)
		if tool.ManagedOnly {
			w.toolchainManagedOnlyNote(c.Part("managed"), language, tool, plugin)
		} else {
			w.toolchainChoices(c.Part("choices"), language, scope, tool, current)
		}
		ui.Row(c).Height(12).Shrink(0)
		ui.Row(c).FillWidth().PadSides(10, 12, 0, 12).Children(func() {
			displayID := tool.ID
			if tool.ManagedOnly {
				displayID = strings.TrimPrefix(tool.ID, tool.PluginID+":")
			}
			// Not monospaced as in the prototype: the monospaced face sets CJK words a cell apart.
			ui.Wrap(c, i18n.SharedFormat(language, "desktop.buildSettings.toolFooter", map[string]string{"id": displayID, "plugin": tool.PluginID})).
				FontSize(11).Color(b.faint).Grow(1).Shrink(1).MinWidth(0)
		})
	})
}

// toolchainManagedOnlyNote explains a plugin-managed dependency that cannot be manually pinned.
func (w *window) toolchainManagedOnlyNote(c ui.C, language i18n.Language, tool *toolchain.Tool, plugin string) {
	b := &w.bp
	w.section(c, i18n.Shared(language, "desktop.buildSettings.categoryPlugin"), "", nil, func() {
		ui.Row(c).FillWidth().MinWidth(0).PadSides(2, 12, 10, 12).Items(ui.Center).Children(func() {
			ui.Wrap(c, i18n.SharedFormat(language, "desktop.toolchains.managedOnlyNote", map[string]string{"plugin": plugin})).
				FontSize(buildSmall).Color(b.sub).Grow(1).Shrink(1).MinWidth(0)
		})
	})
}

// toolchainHead is the tile, name and declaring plugin of the chosen tool, with the button that
// drops the scope's choice.
func (w *window) toolchainHead(c ui.C, language i18n.Language, scope *toolchainScope, tool *toolchain.Tool, name, plugin string) {
	b := &w.bp
	ui.Row(c).FillWidth().Gap(12).Items(ui.Start).Children(func() {
		w.tile(c, nameColor(plugin), name, 40)
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
			ui.Text(c, name).FontSize(buildHeading).Weight(gfx.WeightBold).Color(b.text).Ellipsis()
			ui.Row(c).Height(4).Shrink(0)
			ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
				w.pluginTile(c, plugin, 20)
				ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.declaredBy", map[string]string{"plugin": plugin})).
					FontSize(buildSmall).Color(b.sub).Shrink(1).Ellipsis()
				ui.Text(c, "·").FontSize(buildSmall).Color(b.sub).Shrink(0)
				ui.Text(c, toolchainCategoryLabel(language, tool.Category, tool.Audience)).FontSize(buildSmall).Color(b.sub).Shrink(1).Ellipsis()
			})
		})
		if scope.wanted(tool.ID) != "" {
			label := i18n.Shared(language, "desktop.buildSettings.restoreAutomatic")
			tip := i18n.Shared(language, "desktop.buildSettings.restoreAutomaticTip")
			if scope.name == scopeProject {
				label = i18n.Shared(language, "desktop.buildSettings.restoreInherited")
				tip = i18n.Shared(language, "desktop.buildSettings.restoreInheritedTip")
			}
			if w.buttonTip(c.Part("restore"), buttonSmall, label, tip, w.toolchains.saving) {
				scope.choose(tool.ID, "")
			}
		}
	})
}

// toolchainProblem is the box that says what keeps the tool from resolving and what fixes it.
// It reports whether it showed one.
func (w *window) toolchainProblem(c ui.C, language i18n.Language, scope *toolchainScope, entry *toolchainEntry, current toolchainResult, status, name, plugin string) bool {
	if current.ok {
		return false
	}
	t := w.toolchains
	kind, icon := boxErr, icons.CircleX
	if status == "warning" {
		kind, icon = boxWarn, icons.CircleAlert
	}
	var text string
	trust := false
	switch current.reason {
	case "conflict":
		text = i18n.SharedFormat(language, "desktop.buildSettings.problemConflict", map[string]string{"plugins": toolchainConflictPlugins(language, scope, entry)})
	case "notFound":
		kind, icon = boxWarn, icons.CircleAlert
		text = i18n.SharedFormat(language, "desktop.buildSettings.problemNotFound", map[string]string{"tool": name})
	case "versionUnsatisfied":
		text = i18n.SharedFormat(language, "desktop.buildSettings.problemVersion", map[string]string{"plugin": plugin})
	case "probeFailed":
		text = i18n.Shared(language, "desktop.buildSettings.problemProbeFailed")
	case "projectCodeRequiresAction":
		source, home := toolchainTrustSource(&entry.tool)
		text = i18n.SharedFormat(language, "desktop.buildSettings.problemTrust", map[string]string{"source": source, "home": home, "tool": name})
		trust = t.trustEffect != nil
	default:
		text = toolchainReasonLabel(language, current.reason)
	}
	prepareRuntime := entry.tool.ManagedRuntime && t.runtimeEffect != nil && !trust
	w.box(c.Part("problem"), kind, func(words gfx.Color) {
		boxIcon(c, icon, words)
		boxText(c, text, words)
		if trust && w.button(c.Part("trust"), buttonSmall, i18n.Shared(language, "desktop.buildSettings.trustProject"), t.busy()) {
			t.beginTrust(true)
		}
		if prepareRuntime && w.button(c.Part("prepare-runtime"), buttonSmall, i18n.Shared(language, "desktop.toolchains.prepareRuntime"), t.busy()) {
			t.beginPrepareRuntime(entry.tool)
		}
	})
	return true
}

// toolchainEffective is the prototype's 当前生效 card: the program, version and source the tool
// uses now, what the draft changes it to, and the resolution steps on request.
func (w *window) toolchainEffective(c ui.C, language i18n.Language, scope *toolchainScope, entry *toolchainEntry, current toolchainResult, status string) {
	t := w.toolchains
	b := &w.bp
	tool := &entry.tool
	var trailing func()
	if tool.ManagedRuntime && current.ok && t.runtimeEffect != nil {
		trailing = func() {
			if w.button(c.Part("verify-runtime"), buttonSmall, i18n.Shared(language, "desktop.toolchains.verifyRuntime"), t.busy()) {
				t.beginPrepareRuntime(*tool)
			}
		}
	}
	w.section(c, i18n.Shared(language, "desktop.buildSettings.effectiveTitle"), i18n.Shared(language, "desktop.buildSettings.effectiveHelp"), trailing, func() {
		ui.Column(c).FillWidth().MinWidth(0).PadSides(2, 12, 4, 12).Gap(6).Children(func() {
			if !current.ok {
				w.toolchainKV(c, i18n.Shared(language, "desktop.buildSettings.status"), func() {
					dot(c, 8, b.statusColor(status))
					ui.Wrap(c, w.toolchainReasonText(language, scope, entry, current.reason)).FontSize(buildFont).Color(b.text).Grow(1).Shrink(1).MinWidth(0)
				})
				return
			}
			program := current.executable
			if program == "" {
				program = current.home
			}
			pathLabel := i18n.Shared(language, "desktop.buildSettings.program")
			if tool.ManagedOnly {
				pathLabel = i18n.Shared(language, "desktop.toolchains.managedDirectory")
			}
			w.toolchainKVTop(c, pathLabel, func() {
				ui.Wrap(c, program).FontSize(buildMono).Mono().Color(b.text).Grow(1).Shrink(1).MinWidth(0)
				copyLabel := i18n.Shared(language, "desktop.buildSettings.copyPath")
				copyButton := ui.ButtonBase(c.Part("copy"), copyLabel).Size(20, 20).Shrink(0).Radius(6).Center().
					Hover(ui.Look{}.Background(b.hover)).Tooltip(copyLabel)
				if copyButton.Clicked() {
					if err := copyText(program); err != nil {
						t.failed = err
						reportSettingsError(w.ctrl.opts, "settings_toolchain_copy", err)
					}
				}
				copyButton.Children(func() {
					ui.Icon(c, icons.Copy).Size(11, 11).Color(b.sub)
				})
			})
			w.toolchainKV(c, i18n.Shared(language, "desktop.buildSettings.version"), func() {
				ui.Text(c, current.version).FontSize(buildMono).Mono().Color(b.text).Shrink(1).Ellipsis()
			})
			w.toolchainKV(c, i18n.Shared(language, "desktop.buildSettings.source"), func() {
				if tool.ManagedOnly {
					w.tag(c, tagSource, toolchainSourceLabel(language, "host:managed"))
					return
				}
				w.layerTag(c, language, current, status)
				layerLabel := ToolchainLayerLabel(language, current.layer)
				for _, option := range t.options(language, scope, tool) {
					if !option.auto && option.home == current.home {
						for _, source := range option.sources {
							if source == layerLabel {
								continue
							}
							w.tag(c, tagSource, source)
						}
						break
					}
				}
			})
		})
		if scope.changed(tool.ID) {
			next := toolchainNext(scope, tool)
			ui.Row(c).FillWidth().PadSides(8, 12, 2, 12).Children(func() {
				w.box(c.Part("next"), boxNext, func(words gfx.Color) {
					dot(c, 7, b.accent)
					ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
						ui.Text(c, i18n.Shared(language, "desktop.buildSettings.afterApply")).FontSize(buildSmall).Color(words).Shrink(0)
						if !next.ok {
							ui.Text(c, toolchainReasonLabel(language, next.reason)).FontSize(buildSmall).Color(words).Shrink(1).Ellipsis()
							return
						}
						ui.Text(c, next.version).FontSize(buildSmall).Mono().Weight(gfx.WeightBold).Color(words).Shrink(0)
						ui.Text(c, " · ").FontSize(buildSmall).Color(words).Shrink(0)
						short := midTrim(next.home, 60)
						path := ui.Text(c, short).FontSize(buildSmall).Mono().Color(words).Shrink(1).Ellipsis()
						if short != next.home {
							path.OverflowTooltip(next.home)
						}
						ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.parenthesized", map[string]string{"text": ToolchainLayerLabel(language, next.layer)})).
							FontSize(buildSmall).Color(words).Shrink(0)
					})
					if w.button(c.Part("undo"), buttonLinkSmall, i18n.Shared(language, "desktop.buildSettings.undoChange"), t.saving) {
						scope.undo(tool.ID)
					}
				})
			})
		}
		if len(tool.Trace) > 0 {
			ui.Row(c).FillWidth().Children(func() {
				why := i18n.Shared(language, "desktop.buildSettings.why")
				disclose := ui.ButtonBase(c.Part("why"), why).PadX(12).PadY(4).Gap(4).Items(ui.Center).Shrink(0)
				if disclose.Clicked() {
					t.whyOpen = !t.whyOpen
				}
				disclose.Children(func() {
					caret := icons.ChevronRight
					if t.whyOpen {
						caret = icons.ChevronDown
					}
					ui.Icon(c, caret).Size(10, 10).Color(b.accent)
					ui.Text(c, why).FontSize(buildSmall).Color(b.accent)
				})
			})
			if t.whyOpen {
				w.toolchainTrace(c.Part("trace"), language, tool, current)
			}
		}
		ui.Row(c).Height(6).Shrink(0)
	})
}

// toolchainKV is one line of the 当前生效 card: the key in its 72-point column, the value after.
func (w *window) toolchainKV(c ui.C, key string, value func()) {
	w.toolchainKVAt(c, key, ui.Center, value)
}

// toolchainKVTop is a line whose value may wrap: the key stays on its first line.
func (w *window) toolchainKVTop(c ui.C, key string, value func()) {
	w.toolchainKVAt(c, key, ui.Start, value)
}

func (w *window) toolchainKVAt(c ui.C, key string, align ui.Align, value func()) {
	b := &w.bp
	ui.Row(c).FillWidth().MinWidth(0).Gap(10).Items(align).Children(func() {
		ui.Row(c).Width(72).Shrink(0).MinHeight(20).Items(ui.Center).Children(func() {
			ui.Text(c, key).FontSize(buildSmall).Color(b.sub).Ellipsis()
		})
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).MinHeight(20).Gap(6).Items(align).Children(value)
	})
}

// toolchainReasonText is the 状态 line of a tool that does not resolve.
func (w *window) toolchainReasonText(language i18n.Language, scope *toolchainScope, entry *toolchainEntry, reason string) string {
	switch reason {
	case "conflict":
		return i18n.SharedFormat(language, "desktop.buildSettings.conflictReason", map[string]string{"plugins": toolchainConflictPlugins(language, scope, entry)})
	case "projectCodeRequiresAction":
		if source, _ := toolchainTrustSource(&entry.tool); source != "" {
			return i18n.SharedFormat(language, "desktop.buildSettings.trustReason", map[string]string{"source": source})
		}
	}
	return toolchainReasonLabel(language, reason)
}

// toolchainTrace is the prototype's .trace: each layer Core tried, the one it used checked and
// the ones it could not use marked.
func (w *window) toolchainTrace(c ui.C, language i18n.Language, tool *toolchain.Tool, current toolchainResult) {
	b := &w.bp
	ui.Column(c).FillWidth().MinWidth(0).PadSides(4, 12, 2, 12).Children(func() {
		for index, step := range tool.Trace {
			k := c.KeyInt(index)
			layer := ToolchainLayerLabel(language, step.Layer)
			candidate := toolchainTraceCandidate(tool, step.CandidateID)
			var text string
			mark, words := "–", b.sub
			markColor := b.sub
			switch {
			case step.State == "resolved":
				mark, words, markColor = "", b.text, b.ok
				detail := candidate
				if current.ok {
					detail = current.version + " · " + current.home
				}
				text = i18n.SharedFormat(language, "desktop.buildSettings.traceStep", map[string]string{"layer": layer, "detail": detail})
			case step.State == "empty":
				text = i18n.SharedFormat(language, "desktop.buildSettings.traceStep", map[string]string{
					"layer":  layer,
					"detail": i18n.Shared(language, "desktop.buildSettings.notSet"),
				})
			default:
				mark, markColor = "!", b.warn
				reason := ""
				if step.Reason != nil {
					reason = toolchainReasonLabel(language, step.Reason.Code)
				}
				detail := reason
				if candidate != "" && reason != "" {
					detail = i18n.SharedFormat(language, "desktop.buildSettings.traceCandidate", map[string]string{"candidate": candidate, "reason": reason})
				} else if candidate != "" {
					detail = candidate
				}
				text = i18n.SharedFormat(language, "desktop.buildSettings.traceStep", map[string]string{"layer": layer, "detail": detail})
			}
			ui.Row(k).FillWidth().MinWidth(0).PadY(3).Gap(8).Items(ui.Start).Children(func() {
				ui.Row(k).Width(14).Shrink(0).MinHeight(16).Center().Children(func() {
					if mark == "" {
						ui.Icon(c, icons.Check).Size(11, 11).Color(markColor)
						return
					}
					ui.Text(c, mark).FontSize(buildSmall).Weight(gfx.WeightBold).Color(markColor)
				})
				ui.Wrap(c, text).FontSize(buildSmall).Color(words).Grow(1).Shrink(1).MinWidth(0)
			})
		}
	})
}

// toolchainTraceCandidate names a step's candidate by what the user can recognize: the project
// file or the variable behind it, else the ID the plugin gave it.
func toolchainTraceCandidate(tool *toolchain.Tool, id string) string {
	if id == "" {
		return ""
	}
	for _, project := range tool.Project {
		if project.CandidateID == id && project.Path != "" {
			return project.Path
		}
	}
	for _, shell := range tool.Shell {
		if shell.CandidateID == id {
			if shell.Variable != "" {
				return shell.Variable
			}
			if shell.Command != "" {
				return shell.Command
			}
		}
	}
	return id
}

// toolchainChoices is the prototype's 本项目使用 / 全局默认使用 card: the automatic or inherited
// choice, each home the scope knows, and the field that adds a directory.
func (w *window) toolchainChoices(c ui.C, language i18n.Language, scope *toolchainScope, tool *toolchain.Tool, current toolchainResult) {
	t := w.toolchains
	b := &w.bp
	options := t.options(language, scope, tool)
	title := i18n.Shared(language, "desktop.buildSettings.optionsGlobal")
	var help string
	if scope.name == scopeProject {
		title = i18n.Shared(language, "desktop.buildSettings.optionsProject")
		help = i18n.Shared(language, "desktop.buildSettings.optionsProjectHelp")
	} else {
		var order []string
		for _, option := range options {
			if !option.auto && len(option.sources) > 0 && !slices.Contains(order, option.sources[0]) {
				order = append(order, option.sources[0])
			}
		}
		if len(order) > 0 {
			help = i18n.SharedFormat(language, "desktop.buildSettings.optionsGlobalHelp", map[string]string{"order": strings.Join(order, " → ")})
		} else {
			help = i18n.Shared(language, "desktop.buildSettings.optionsGlobalHelpPlain")
		}
	}
	pick := scope.wanted(tool.ID)
	w.section(c, title, help, nil, func() {
		ui.Column(c).FillWidth().MinWidth(0).PadX(4).Children(func() {
			for _, option := range options {
				w.toolchainOption(c.Key("option:"+option.home), language, scope, tool, option, option.home == pick, current)
			}
		})
		w.toolchainAddRow(c.Part("add"), language, scope, tool)
	})
	_ = b
}

// toolchainAutoLabel is the first choice's words: what the tool resolves to without a pin in the
// scope, or why nothing does.
func toolchainAutoLabel(language i18n.Language, scope *toolchainScope, tool *toolchain.Tool) string {
	automatic := tool.Automatic
	if automatic == nil {
		reason := tool.AutomaticReason
		if reason == "" {
			reason = "notFound"
		}
		return i18n.SharedFormat(language, "desktop.buildSettings.autoReason", map[string]string{"reason": toolchainReasonLabel(language, reason)})
	}
	home := tool.AutomaticHome
	if home == "" && automatic.Home != nil {
		home = *automatic.Home
	}
	source := toolchainInstallationSource(language, tool, home, automatic.Provider)
	if scope.name == scopeProject {
		switch automatic.Layer {
		case "project":
			for _, project := range tool.Project {
				if project.Path != "" && (project.Home == home || project.Path == home) {
					source = project.Path
					break
				}
			}
			return i18n.SharedFormat(language, "desktop.buildSettings.autoProject", map[string]string{"version": automatic.Version, "source": source})
		case "global":
			return i18n.SharedFormat(language, "desktop.buildSettings.inheritWith", map[string]string{"version": automatic.Version})
		}
	}
	return i18n.SharedFormat(language, "desktop.buildSettings.autoWith", map[string]string{"version": automatic.Version, "source": source})
}

// toolchainOption is one radio row of the choices: the version, the home and its sources, or
// the reason it cannot be chosen.
func (w *window) toolchainOption(c ui.C, language i18n.Language, scope *toolchainScope, tool *toolchain.Tool, option toolchainOption, on bool, current toolchainResult) {
	t := w.toolchains
	b := &w.bp
	label := option.home
	if option.auto {
		label = toolchainAutoLabel(language, scope, tool)
	}
	disabled := option.why != "" || t.saving
	box := ui.ButtonBase(c, label).FillWidth().MinWidth(0).PadX(8).PadY(6).Gap(8).Radius(7).Items(ui.Center)
	switch {
	case on:
		box = box.Background(b.chip)
	case !disabled:
		box = box.Hover(ui.Look{}.Background(b.hover))
	}
	if !option.auto {
		box = box.Tooltip(option.home)
	}
	if disabled {
		box = box.Disabled(true).Opacity(0.62)
	}
	if box.Clicked() && !disabled {
		scope.choose(tool.ID, option.home)
	}
	box.Children(func() {
		ui.Row(c).Width(18).Shrink(0).Items(ui.Center).Children(func() {
			ring := b.faint
			if on {
				ring = b.accent
			}
			ui.Row(c).Size(14, 14).Shrink(0).Radius(7).Border(1.5, ring).Center().Children(func() {
				if on {
					dot(c, 6, b.accent)
				}
			})
		})
		if option.auto {
			ui.Text(c, label).FontSize(12.5).Color(b.text).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
			return
		}
		version := option.version
		if version == "" {
			version = "—"
		}
		ui.Text(c, version).FontSize(buildMono).Mono().Color(b.text).Width(92).Shrink(0).Ellipsis()
		short := midTrim(option.home, 58)
		path := ui.Text(c, short).FontSize(buildMono).Mono().Color(b.sub).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
		if short != option.home {
			path.OverflowTooltip(option.home)
		}
		ui.Row(c).Shrink(0).Gap(4).Items(ui.Center).Children(func() {
			if option.why != "" {
				kind := tagErr
				if option.why == i18n.Shared(language, "desktop.toolchains.reasonProjectTrustRequired") {
					kind = tagWarn
				}
				w.tag(c, kind, option.why)
				return
			}
			if current.ok && option.home == current.home {
				w.tag(c, tagGreen, i18n.Shared(language, "desktop.buildSettings.inUse"))
			}
			for _, source := range option.sources {
				w.tag(c, tagSource, source)
			}
		})
	})
}

// toolchainAddRow is the prototype's .addrow: a link that opens the field for an installation
// directory, then the field with its browse, check and cancel.
func (w *window) toolchainAddRow(c ui.C, language i18n.Language, scope *toolchainScope, tool *toolchain.Tool) {
	t := w.toolchains
	if t.inspectEffect == nil {
		return
	}
	ui.Row(c).FillWidth().MinWidth(0).PadX(8).PadY(6).Gap(6).Items(ui.Center).Children(func() {
		if t.adding != tool.ID {
			if w.button(c.Part("open"), buttonLinkSmall, i18n.Shared(language, "desktop.buildSettings.addDirectory"), t.saving) {
				t.adding = tool.ID
			}
			return
		}
		input := scope.input(tool.ID)
		directory := i18n.Shared(language, "desktop.toolchains.directory")
		var field ui.Box
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
			field = w.filterField(c.Part("field"), input, directory, i18n.Shared(language, "desktop.buildSettings.addPlaceholder"), false)
		})
		w.infoButton(c.Part("help"), i18n.Shared(language, "desktop.buildSettings.addHelp"))
		if w.button(c.Part("browse"), buttonSmall, i18n.Shared(language, "desktop.pluginSettings.browse"), t.busy()) {
			// The native picker runs a modal message loop on Windows, so it must run after paint.
			c.After(func() { w.pickToolchainDirectory(tool.ID, input, directory) })
		}
		home := strings.TrimSpace(*input)
		check := w.button(c.Part("check"), buttonSmall, i18n.Shared(language, "desktop.buildSettings.checkAndUse"), home == "" || t.busy())
		if (check || field.Submitted()) && home != "" && !t.busy() {
			t.beginInspect(tool.ID, home)
		}
		if w.button(c.Part("cancel"), buttonLinkSmall, i18n.Shared(language, "desktop.buildSettings.cancel"), false) {
			t.adding = ""
		}
	})
}
