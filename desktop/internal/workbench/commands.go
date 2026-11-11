package workbench

import (
	"sort"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// The command catalog is every workbench action a user can run by name: the
// Actions tab of Search Everywhere (Find Action) lists it. Each command calls the
// same function its button, menu item or shortcut calls, so running it by name
// behaves exactly like those.

// command is one action of the catalog.
type command struct {
	id    string
	title string
	// group is the area the action belongs to, shown beside its title.
	group string
	// shortcut is the chord shown beside the title, when the action has one.
	shortcut string
	// enabled is false for an action that cannot run now; it is listed greyed.
	enabled bool
	run     func()
}

// commands lists the actions available in the current window.
func (a *App) commands() []command {
	t := a.text.Commands
	p := a.project
	var list []command
	keys := a.settings.Keymap
	add := func(id, group, title, _ string, enabled bool, run func()) {
		list = append(list, command{id: id, group: group, title: title, shortcut: keys.Label(id), enabled: enabled, run: run})
	}

	add("settings.open", t.GroupApp, t.Settings, "", true, func() { a.openSettings(surfaceMenu) })
	add("plugins.open", t.GroupApp, t.Plugins, "", true, func() { a.openPluginSettings(surfaceMenu) })
	add("logs.open", t.GroupApp, t.Logs, "", true, a.openLogs)
	add("legacy.import", t.GroupApp, t.ImportLegacy, "", true, a.readLegacyImport)
	add("theme.system", t.GroupView, t.ThemeSystem, "", a.settings.Theme != themeSystem, func() { a.setTheme(themeSystem) })
	add("theme.light", t.GroupView, t.ThemeLight, "", a.settings.Theme != themeLight, func() { a.setTheme(themeLight) })
	add("theme.dark", t.GroupView, t.ThemeDark, "", a.settings.Theme != themeDark, func() { a.setTheme(themeDark) })
	add("window.fullscreen", t.GroupView, a.text.Keymap.ToggleFullscreen, "", a.window != nil, func() {
		if err := a.window.SetFullscreen(!a.window.Fullscreen()); err != nil {
			a.notify(a.text.Keymap.FullscreenFailed(err.Error()))
		}
	})
	add("language.en", t.GroupView, t.LanguageEnglish, "", a.settings.Language != "en", func() { a.setLanguage("en") })
	add("language.zh", t.GroupView, t.LanguageChinese, "", a.settings.Language != "zh-Hans", func() { a.setLanguage("zh-Hans") })

	add("project.open", t.GroupProject, t.OpenProject, "", true, func() { a.chooseProject(surfaceMenu) })
	add("project.new", t.GroupProject, t.NewProject, "", true, func() { a.openNewProject(surfaceMenu) })
	add("project.clone", t.GroupProject, t.Clone, "", true, func() { a.openClone(surfaceMenu) })
	if p == nil {
		return sortCommands(list)
	}
	add("project.close", t.GroupProject, t.CloseProject, "", true, a.closeProject)
	add("documents.saveAll", t.GroupProject, t.SaveAll, "", true, func() { a.saveProjectDocuments(p, func(bool) {}) })

	// Every tool window, plugin ones included, can be shown by name.
	for index, it := range a.chrome.catalog {
		if !it.panel {
			continue
		}
		id := it.id
		open := a.chrome.isOpen(index)
		add("tool."+id, t.GroupToolWindows, t.ShowTool(it.label(a.text)), "", !open, func() {
			a.reduceChrome(core.SetChromeOpen(id, true))
		})
	}

	if d := p.selectedDocument(p.docs.group); d != nil && !d.virtual {
		path := d.path
		add("localHistory.show", t.GroupProject, a.text.History.Show, "", true, func() { a.openLocalHistory(p, path) })
	}
	add("search.everywhere", t.GroupSearch, t.SearchEverywhere, "", true, func() { a.openEverywhere(p) })
	add("search.files", t.GroupSearch, t.FindInFiles, "", true, func() {
		a.reduceChrome(core.SetChromeOpen(itemFind, true))
		a.searchView.focus = true
	})
	add("search.replace", t.GroupSearch, t.ReplaceInFiles, "", true, func() {
		a.reduceChrome(core.SetChromeOpen(itemFind, true))
		a.searchView.replaceOpen = true
		a.searchView.focus = true
	})

	add("git.commit", t.GroupGit, t.Commit, "", true, func() { a.startCommit(p, false, surfaceMenu) })
	add("git.commitPush", t.GroupGit, t.CommitAndPush, "", true, func() { a.startCommit(p, true, surfaceMenu) })
	add("git.branches", t.GroupGit, t.Branches, "", true, a.openBranches)
	add("git.console", t.GroupGit, t.GitConsole, "", true, func() { a.showGitConsole("") })

	add("run.selected", t.GroupRun, t.Run, "", true, func() { a.runSelectedBuildTask(p) })
	add("debug.start", t.GroupRun, t.Debug, "", true, func() { a.startDebug(p) })
	add("debug.toggleBreakpoint", t.GroupRun, t.ToggleBreakpoint, "", true, func() { a.toggleBreakpoint(p) })

	add("terminal.new", t.GroupTerminal, t.NewTerminal, "", true, func() { a.openToolTerminal("") })
	add("agent.new", t.GroupAgent, t.NewAgentConversation, "", a.agentCanStartConversation(p), func() { a.newAgentConversation(p) })
	return sortCommands(list)
}

// sortCommands orders the catalog by group, then title, so the list reads the
// same each time.
func sortCommands(list []command) []command {
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].group != list[j].group {
			return list[i].group < list[j].group
		}
		return list[i].title < list[j].title
	})
	return list
}

// matchCommands keeps the commands whose title or group holds every word of
// query, case-insensitively; an empty query keeps them all.
func matchCommands(list []command, query string) []command {
	words := strings.Fields(strings.ToLower(query))
	if len(words) == 0 {
		return list
	}
	var out []command
	for _, c := range list {
		text := strings.ToLower(c.title + " " + c.group + " " + c.id)
		all := true
		for _, word := range words {
			if !strings.Contains(text, word) {
				all = false
				break
			}
		}
		if all {
			out = append(out, c)
		}
	}
	return out
}

// runCommand closes Search Everywhere and runs one action.
func (a *App) runCommand(c command) {
	if !c.enabled || c.run == nil {
		return
	}
	if p := a.project; p != nil {
		a.closeEverywhere(p)
	} else {
		a.everywhereView.open = false
	}
	a.performed("command."+c.id, surfaceMenu)
	c.run()
}

// openFindAction opens Search Everywhere on its Actions tab.
func (a *App) openFindAction() {
	if p := a.project; p != nil {
		a.openEverywhere(p)
	}
	a.everywhereView.scope = everywhereScopeActions
	a.everywhereView.actionSelected = 0
}

// everywhereActions lists the matching actions in Search Everywhere: a click or
// Enter runs one, a greyed one cannot run now.
func (a *App) everywhereActions(c ui.C) {
	v := &a.everywhereView
	matches := matchCommands(a.commands(), v.query.Text())
	v.actionCount = len(matches)
	if len(matches) == 0 {
		ui.Text(c, a.text.Commands.NoActions).Muted()
		return
	}
	v.actionSelected = min(max(v.actionSelected, 0), len(matches)-1)
	if v.actionSelected != v.actionList.Selected() {
		v.actionList.Select(v.actionSelected)
		v.actionList.ScrollIntoView(v.actionSelected)
	}
	v.actionList.Label = func(i int) string { return matches[i].title }
	run := -1
	ui.List(c, &v.actionList, len(matches), func(row ui.ListRow) {
		command := matches[row.Index]
		color := a.colors.Text
		if !command.enabled {
			color = a.colors.Subtle
		}
		row.Element.FillWidth().Height(everywhereFileHeight).Items(ui.Center).PadX(10).Gap(8).Children(func() {
			ui.Text(row.C, command.title).Grow(1).Shrink(1).MinWidth(0).FontSize(13).Color(color).Ellipsis()
			if command.shortcut != "" {
				ui.Text(row.C, command.shortcut).FontSize(12).Color(a.colors.Subtle).Shrink(0)
			}
			ui.Text(row.C, command.group).FontSize(12).Color(a.colors.Subtle).Shrink(0)
		})
		if row.Element.Clicked() {
			run = row.Index
		}
	}).Label(a.text.Commands.FindAction).Grow(1).MinHeight(0)
	if v.actionList.Changed() {
		v.actionSelected = max(v.actionList.Selected(), 0)
	}
	if run >= 0 {
		command := matches[run]
		c.After(func() { a.runCommand(command) })
	}
}

// runSelectedAction runs the selected action on Enter in the query field.
func (a *App) runSelectedAction() {
	v := &a.everywhereView
	matches := matchCommands(a.commands(), v.query.Text())
	if v.actionSelected >= 0 && v.actionSelected < len(matches) {
		a.runCommand(matches[v.actionSelected])
	}
}
