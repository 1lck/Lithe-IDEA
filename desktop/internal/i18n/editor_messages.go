package i18n

// editorMessages reads editor labels from the shared catalog.
func editorMessages(language Language) EditorMessages {
	return EditorMessages{
		SearchEverywhere: Shared(language, "desktop.everywhere.title"),
		GoToFile:         Shared(language, "desktop.editor.goToFile"),
		FindInFiles:      Shared(language, "native.findInFiles"),
		RecentFiles:      Shared(language, "desktop.editor.recentFiles"),
		DropFiles:        Shared(language, "desktop.editor.dropFiles"),
		CloseTab:         Shared(language, "menu.closeTab"),
		SoftWrap:         Shared(language, "desktop.editor.softWrap"),
		NotText:          Shared(language, "desktop.editor.notText"),
		TooLarge:         Shared(language, "desktop.editor.tooLarge"),
		OpenFailed: func(name, reason string) string {
			return SharedFormat(language, "desktop.editor.openFailed", map[string]string{"name": name, "reason": reason})
		},
		SaveFailed: func(name, reason string) string {
			return SharedFormat(language, "desktop.editor.saveFailed", map[string]string{"name": name, "reason": reason})
		},
	}
}

// projectMessages reads project labels from the shared catalog.
func projectMessages(language Language) ProjectMessages {
	return ProjectMessages{
		Loading: Shared(language, "desktop.project.loading"),
		Empty:   Shared(language, "desktop.project.empty"),
		Failed: func(reason string) string {
			return SharedFormat(language, "desktop.project.readFailed", map[string]string{"reason": reason})
		},
	}
}
