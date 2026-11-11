package i18n

// CommandMessages name the actions of the command catalog (Find Action).
type CommandMessages struct {
	GroupEditor, GroupApp, GroupView, GroupProject, GroupToolWindows, GroupSearch, GroupGit, GroupRun, GroupTerminal, GroupAgent, Settings, Plugins, Logs, ImportLegacy, ThemeSystem, ThemeLight, ThemeDark, LanguageEnglish, LanguageChinese, OpenProject, NewProject, Clone, CloseProject, SaveAll, SearchEverywhere, FindInFiles, ReplaceInFiles, Commit, CommitAndPush, Branches, GitConsole, Run, Debug, ToggleBreakpoint, NewTerminal, NewAgentConversation, NoActions, FindAction, GitNextChange, GitPreviousChange string
	// ShowTool is the action that shows a tool window by its name.
	ShowTool func(name string) string
}

func commandMessages(language Language) CommandMessages {
	return CommandMessages{
		GroupApp:             Shared(language, "desktop.command.groupApp"),
		GroupView:            Shared(language, "desktop.command.groupView"),
		GroupEditor:          Shared(language, "desktop.command.groupEditor"),
		GitNextChange:        Shared(language, "desktop.command.gitNextChange"),
		GitPreviousChange:    Shared(language, "desktop.command.gitPreviousChange"),
		GroupProject:         Shared(language, "desktop.command.groupProject"),
		GroupToolWindows:     Shared(language, "desktop.command.groupToolWindows"),
		GroupSearch:          Shared(language, "desktop.command.groupSearch"),
		GroupGit:             Shared(language, "desktop.command.groupGit"),
		GroupRun:             Shared(language, "desktop.command.groupRun"),
		GroupTerminal:        Shared(language, "desktop.command.groupTerminal"),
		GroupAgent:           Shared(language, "desktop.command.groupAgent"),
		Settings:             Shared(language, "desktop.command.settings"),
		Plugins:              Shared(language, "desktop.command.plugins"),
		Logs:                 Shared(language, "desktop.command.logs"),
		ImportLegacy:         Shared(language, "desktop.command.importLegacy"),
		ThemeSystem:          Shared(language, "desktop.command.themeSystem"),
		ThemeLight:           Shared(language, "desktop.command.themeLight"),
		ThemeDark:            Shared(language, "desktop.command.themeDark"),
		LanguageEnglish:      Shared(language, "desktop.command.languageEnglish"),
		LanguageChinese:      Shared(language, "desktop.command.languageChinese"),
		OpenProject:          Shared(language, "desktop.command.openProject"),
		NewProject:           Shared(language, "desktop.command.newProject"),
		Clone:                Shared(language, "desktop.command.clone"),
		CloseProject:         Shared(language, "desktop.command.closeProject"),
		SaveAll:              Shared(language, "desktop.command.saveAll"),
		SearchEverywhere:     Shared(language, "desktop.command.searchEverywhere"),
		FindInFiles:          Shared(language, "desktop.command.findInFiles"),
		ReplaceInFiles:       Shared(language, "desktop.command.replaceInFiles"),
		Commit:               Shared(language, "desktop.command.commit"),
		CommitAndPush:        Shared(language, "desktop.command.commitAndPush"),
		Branches:             Shared(language, "desktop.command.branches"),
		GitConsole:           Shared(language, "desktop.command.gitConsole"),
		Run:                  Shared(language, "desktop.command.run"),
		Debug:                Shared(language, "desktop.command.debug"),
		ToggleBreakpoint:     Shared(language, "desktop.command.toggleBreakpoint"),
		NewTerminal:          Shared(language, "desktop.command.newTerminal"),
		NewAgentConversation: Shared(language, "desktop.command.newAgentConversation"),
		NoActions:            Shared(language, "desktop.command.noActions"),
		FindAction:           Shared(language, "desktop.command.findAction"),
		ShowTool: func(name string) string {
			return SharedFormat(language, "desktop.command.showTool", map[string]string{"name": name})
		},
	}
}
