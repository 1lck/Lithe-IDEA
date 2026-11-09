package i18n

// welcomeMessages reads the welcome screen labels from the shared catalog.
func welcomeMessages(language Language) WelcomeMessages {
	return WelcomeMessages{
		Projects:          Shared(language, "welcome.projects"),
		Settings:          Shared(language, "menu.settings"),
		SearchLabel:       Shared(language, "welcome.searchProjects"),
		SearchPlaceholder: Shared(language, "welcome.searchProjects"),
		NewProject:        Shared(language, "welcome.newProject"),
		Open:              Shared(language, "projectPicker.open"),
		OpenDialogTitle:   Shared(language, "welcome.openProject"),
		Clone:             Shared(language, "welcome.cloneRepository"),
		Remote:            Shared(language, "native.remoteDevelopment"),
		Unavailable:       Shared(language, "desktop.welcome.unavailable"),
		EmptyTitle:        Shared(language, "desktop.welcome.emptyTitle"),
		EmptyHint:         Shared(language, "desktop.welcome.emptyHint"),
		NoMatches:         Shared(language, "desktop.welcome.noMatches"),
		MoreActions:       Shared(language, "native.moreActions"),
		MenuOpen:          Shared(language, "projectPicker.open"),
		MenuReveal:        Shared(language, "desktop.welcome.menuReveal"),
		MenuPin:           Shared(language, "desktop.welcome.menuPin"),
		MenuUnpin:         Shared(language, "desktop.welcome.menuUnpin"),
		MenuRemove:        Shared(language, "native.removeFromRecentProjects"),
		Pinned:            Shared(language, "layout.pinned"),
		Missing:           Shared(language, "desktop.welcome.missing"),
	}
}
