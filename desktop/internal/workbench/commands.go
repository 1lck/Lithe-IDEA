package workbench

import (
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
			a.notifyError(a.text.Keymap.FullscreenFailed(err.Error()))
		}
	})
	add("language.en", t.GroupView, t.LanguageEnglish, "", a.settings.Language != "en", func() { a.setLanguage("en") })
	add("language.zh", t.GroupView, t.LanguageChinese, "", a.settings.Language != "zh-Hans", func() { a.setLanguage("zh-Hans") })
	add("editor.vimMode", t.GroupEditor, t.ToggleVim, "", true, func() { a.setVimMode(!a.settings.VimMode) })

	add("project.open", t.GroupProject, t.OpenProject, "", true, func() { a.chooseProject(surfaceMenu) })
	add("project.new", t.GroupProject, t.NewProject, "", true, func() { a.openNewProject(surfaceMenu) })
	add("project.clone", t.GroupProject, t.Clone, "", true, func() { a.openClone(surfaceMenu) })
	if p == nil {
		return sortCommands(list)
	}
	add("editor.newScratch", t.GroupEditor, a.text.Commands.NewScratch, "", true, func() { a.newScratch(p) })
	add("editor.scratchFiles", t.GroupEditor, a.text.Commands.ScratchFiles, "", true, a.openScratchList)
	add("editor.recentFiles", t.GroupEditor, a.text.Commands.RecentFiles, "", true, func() { a.openRecentFiles(false) })
	add("editor.recentEdits", t.GroupEditor, a.text.Commands.RecentEdits, "", true, func() { a.openRecentFiles(true) })
	add("project.close", t.GroupProject, t.CloseProject, "", true, a.closeProject)
	add("documents.saveAll", t.GroupProject, t.SaveAll, "", true, func() { a.saveProjectDocuments(p, func(bool) {}) })
	// The File menu closes the selected tab above its separator and Settings above it, as the
	// old Windows menu bar ordered them.
	if d := p.selectedDocument(p.docs.group); d != nil {
		id := d.id
		if d.scratch {
			add("editor.saveAs", t.GroupEditor, a.text.Commands.SaveAs, "", !d.saving, func() { a.saveScratchAs(p, d) })
			add("editor.discardScratch", t.GroupEditor, i18n.Shared(a.language(), "desktop.drafts.discard"), "", !d.saving, func() { a.discardScratch(p, d) })
		}
		add("tab.close", t.GroupProject, a.text.Editor.CloseTab, "", true, func() { a.closeDocument(p, id) })
	}
	// The Terminal menu runs the editor's selection as one command through the long-command
	// path, so a cmd.exe or PowerShell line over its limit runs from a one-off script instead
	// of being typed into a shell that would truncate it.
	if d := p.selectedDocument(p.docs.group); d != nil {
		if text := strings.TrimSpace(d.view.SelectedText()); text != "" {
			command := text
			add("terminal.runSelection", t.GroupTerminal, i18n.Shared(a.language(), "desktop.terminal.runSelection"), "", true, func() {
				if term := a.newTerminal(p, ""); term != nil {
					a.openTerminals(p)
					a.sendTerminalCommand(term, command)
				}
			})
		}
	}
	if d := p.selectedDocument(p.docs.group); browserPreviewable(d) {
		add("editor.openInBrowser", t.GroupEditor, i18n.Shared(a.language(), "desktop.editorMenu.openInBrowser"), "", true, func() { a.openInBrowser(p, d) })
	}
	// Code folding of the selected document.
	if d := p.selectedDocument(p.docs.group); d != nil {
		add("editor.find", t.GroupEditor, i18n.Shared(a.language(), "desktop.editorFind.find"), "", true, func() { a.openEditorFind(false) })
		add("editor.replace", t.GroupEditor, i18n.Shared(a.language(), "desktop.editorFind.replace"), "", !d.virtual, func() { a.openEditorFind(true) })
		add("editor.fold", t.GroupEditor, t.Fold, "", true, func() { a.foldCommand(d, func(v *editorview.View) { v.FoldAtCaret() }) })
		add("editor.unfold", t.GroupEditor, t.Unfold, "", true, func() { a.foldCommand(d, func(v *editorview.View) { v.UnfoldAtCaret() }) })
		add("editor.foldAll", t.GroupEditor, t.FoldAll, "", true, func() { a.foldCommand(d, (*editorview.View).FoldAll) })
		add("editor.unfoldAll", t.GroupEditor, t.UnfoldAll, "", true, func() { a.foldCommand(d, (*editorview.View).UnfoldAll) })
	}
	// The carets of the selected document: occurrences and clones of the primary caret (multicaret.go).
	if d := p.selectedDocument(p.docs.group); d != nil {
		add("editor.addNextOccurrence", t.GroupEditor, t.AddNextOccurrence, "", true, func() { a.caretCommand(d, (*editorview.View).AddNextOccurrence) })
		add("editor.unselectOccurrence", t.GroupEditor, t.UnselectOccurrence, "", true, func() { a.caretCommand(d, (*editorview.View).UnselectOccurrence) })
		add("editor.selectAllOccurrences", t.GroupEditor, t.SelectAllOccurrences, "", true, func() { a.caretCommand(d, (*editorview.View).SelectAllOccurrences) })
		add("editor.cloneCaretAbove", t.GroupEditor, t.CloneCaretAbove, "", true, func() { a.caretCommand(d, (*editorview.View).CloneCaretAbove) })
		add("editor.cloneCaretBelow", t.GroupEditor, t.CloneCaretBelow, "", true, func() { a.caretCommand(d, (*editorview.View).CloneCaretBelow) })
	}
	// The change markers of the selected document: next and previous, in marker order.
	if d := p.selectedDocument(p.docs.group); d != nil && len(d.gutter.hunks) > 0 {
		add("git.gutter.next", t.GroupGit, t.GitNextChange, "", true, func() { a.gitGutterStep(d, 1) })
		add("git.gutter.previous", t.GroupGit, t.GitPreviousChange, "", true, func() { a.gitGutterStep(d, -1) })
	}
	// The plugin editor actions of the selected document, by name, as its menu runs them.
	if d := p.selectedDocument(p.docs.group); d != nil {
		for index := range d.actions {
			action := d.actions[index]
			add("editorAction."+strconv.Itoa(index), a.text.Commands.GroupEditor, action.Title, "", true, func() { a.runEditorAction(p, d, action, -1) })
		}
	}

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

	// A plugin command opens one of its plugin's tool windows; only commands offered in the palette.
	for _, command := range a.pluginCommands {
		if !pluginCommandOffered(command) {
			continue
		}
		windowID := pluginItemPrefix + command.ToolWindowID
		index := slices.IndexFunc(a.chrome.catalog, func(it item) bool { return it.id == windowID })
		if index < 0 {
			continue
		}
		add(pluginCommandID(command), t.GroupToolWindows, command.Title, "", !a.chrome.isOpen(index), func() {
			a.reduceChrome(core.SetChromeOpen(windowID, true))
		})
	}

	if d := p.selectedDocument(p.docs.group); d != nil && !d.virtual {
		path := d.path
		add("localHistory.show", t.GroupProject, a.text.History.Show, "", true, func() { a.openLocalHistory(p, path) })
	}
	add("search.everywhere", t.GroupSearch, t.SearchEverywhere, "", true, func() { a.openEverywhere(p) })
	add("search.files", t.GroupSearch, t.FindInFiles, "", true, func() { a.openFindInFiles(p, false) })
	add("search.replace", t.GroupSearch, t.ReplaceInFiles, "", true, func() { a.openFindInFiles(p, true) })

	add("git.commit", t.GroupGit, t.Commit, "", true, func() { a.startCommit(p, false, surfaceMenu) })
	add("git.commitPush", t.GroupGit, t.CommitAndPush, "", true, func() { a.startCommit(p, true, surfaceMenu) })
	add("git.branches", t.GroupGit, t.Branches, "", true, a.openBranches)
	add("git.pull", t.GroupGit, a.text.Sync.Pull.MenuItem, "", p.git.isRepository(), func() { a.openPullDialog(p) })
	if d := p.selectedDocument(p.docs.group); d != nil && !d.virtual {
		add("git.lineHistory", t.GroupGit, i18n.Shared(a.language(), "desktop.editorMenu.lineHistory"), "", p.git.isRepository(), func() { a.startLineHistory(p, d) })
	}
	add("git.console", t.GroupGit, t.GitConsole, "", true, func() { a.showGitConsole("") })

	add("run.selected", t.GroupRun, t.Run, "", true, func() { a.runSelectedBuildTask(p) })
	add("debug.start", t.GroupRun, t.Debug, "", true, func() { a.startDebug(p) })
	add("debug.toggleBreakpoint", t.GroupRun, t.ToggleBreakpoint, "", true, func() { a.toggleBreakpoint(p) })

	add("terminal.new", t.GroupTerminal, t.NewTerminal, "", true, func() { a.openToolTerminal("") })
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
	matches := matchCommands(a.commands(), v.actionQuery())
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
	matches := matchCommands(a.commands(), v.actionQuery())
	if v.actionSelected >= 0 && v.actionSelected < len(matches) {
		a.runCommand(matches[v.actionSelected])
	}
}

// caretCommand runs a caret command of the document's view and repaints it. The command reports whether it
// changed the carets; a command that changed nothing needs no repaint of its own.
func (a *App) caretCommand(d *document, action func(*editorview.View) bool) {
	if d == nil {
		return
	}
	action(d.view)
	a.invalidator.Invalidate()
}
