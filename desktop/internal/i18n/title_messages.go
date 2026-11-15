package i18n

// titleMessages reads the title bar labels from the shared catalog.
func titleMessages(language Language) TitleMessages {
	return TitleMessages{
		ProjectMenu:        Shared(language, "desktop.title.projectMenu"),
		OpenProject:        Shared(language, "native.openProject.variant2"),
		CloseProject:       Shared(language, "native.closeProject"),
		RecentProjects:     Shared(language, "titleProject.recentProjects"),
		BranchMenu:         Shared(language, "desktop.title.branchMenu"),
		RunConfiguration:   Shared(language, "run.run"),
		CurrentFile:        Shared(language, "workbench.currentFile"),
		Run:                Shared(language, "menu.run"),
		Debug:              Shared(language, "native.debug"),
		Search:             Shared(language, "workbench.search"),
		Settings:           Shared(language, "menu.settings"),
		Preferences:        Shared(language, "native.settings"),
		Plugins:            Shared(language, "native.plugins"),
		LogsAndDiagnostics: Shared(language, "logs.window.logsAndDiagnostics"),
		ThemeMenu:          Shared(language, "native.theme.variant2"),
		Keymap:             Shared(language, "native.keymap"),
		PluginsLater:       Shared(language, "desktop.title.pluginsLater"),
		KeymapLater:        Shared(language, "desktop.title.keymapLater"),
		LogsUnavailable:    Shared(language, "desktop.title.logsUnavailable"),
		NewProjectItem:     Shared(language, "titleProject.newProject"),
		OpenItem:           Shared(language, "titleProject.open"),
		CloneItem:          Shared(language, "titleProject.cloneRepository"),
		OpenProjects:       Shared(language, "titleProject.openProjects"),
		NoRecentProjects:   Shared(language, "desktop.title.noRecentProjects"),
	}
}
