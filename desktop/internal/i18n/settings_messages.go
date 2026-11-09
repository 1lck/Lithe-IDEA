package i18n

// settingsMessages reads settings labels from the generated shared catalog.
func settingsMessages(language Language) SettingsMessages {
	return SettingsMessages{
		Title:              Shared(language, "menu.settings"),
		Search:             Shared(language, "settings.search"),
		NoMatches:          Shared(language, "desktop.settings.noMatches"),
		Categories:         Shared(language, "desktop.settings.categories"),
		AppearanceBehavior: Shared(language, "settings.groups.appearance"),
		General:            Shared(language, "settings.tabs.general"),
		Updates:            Shared(language, "settings.tabs.updates"),
		Network:            Shared(language, "settings.network.title"),
		Editor:             Shared(language, "settings.editor.section"),
		Keymap:             Shared(language, "settings.tabs.keyboard"),
		ProcessTermination: Shared(language, "native.processTerminationPolicy"),
		Plugins:            Shared(language, "settings.tabs.plugins"),
		VersionControl:     Shared(language, "settings.groups.versionControl"),
		Build:              Shared(language, "settings.groups.build"),
		Languages:          Shared(language, "settings.groups.languages"),
		Tools:              Shared(language, "settings.groups.tools"),
		AI:                 Shared(language, "native.ai"),
		PageLater:          Shared(language, "desktop.settings.pageLater"),
		Appearance:         Shared(language, "settings.mac.appearance"),
		AppearanceHelp:     Shared(language, "desktop.settings.appearanceHelp"),
		AppearanceMode:     Shared(language, "settings.mac.appearanceMode"),
		System:             Shared(language, "desktop.settings.system"),
		Light:              Shared(language, "settings.mac.light"),
		Dark:               Shared(language, "settings.mac.dark"),
		Language:           Shared(language, "settings.mac.language"),
		LanguageHelp:       Shared(language, "desktop.settings.languageHelp"),
		Workbench:          Shared(language, "keybindings.categories.Workbench"),
		LayoutHint:         Shared(language, "desktop.settings.layoutHint"),
		ResetLayout:        Shared(language, "desktop.settings.resetLayout"),
		About:              Shared(language, "desktop.settings.about"),
		RestoreDefaults:    Shared(language, "settings.mac.restoreDefaults"),
		Cancel:             Shared(language, "agent.state.cancel"),
		OK:                 Shared(language, "desktop.settings.ok"),
		FollowSystem: func(effective string) string {
			return SharedFormat(language, "desktop.settings.followSystemEffective", map[string]string{"effective": effective})
		},
	}
}
