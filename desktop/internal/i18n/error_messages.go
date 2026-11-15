package i18n

// errorMessages reads application error labels and templates from the shared catalog.
func errorMessages(language Language) ErrorMessages {
	return ErrorMessages{
		Dismiss: Shared(language, "desktop.errors.dismiss"),
		FolderMissing: func(path string) string {
			return SharedFormat(language, "desktop.errors.folderMissing", map[string]string{"path": path})
		},
		OpenFailed: func(reason string) string {
			return SharedFormat(language, "desktop.errors.openFailed", map[string]string{"reason": reason})
		},
		Core: func(reason string) string {
			return SharedFormat(language, "desktop.errors.core", map[string]string{"reason": reason})
		},
		SaveFailed: func(reason string) string {
			return SharedFormat(language, "desktop.errors.saveFailed", map[string]string{"reason": reason})
		},
		LogsFailed: func(reason string) string {
			return SharedFormat(language, "desktop.errors.logsFailed", map[string]string{"reason": reason})
		},
		SettingsFailed: func(reason string) string {
			return SharedFormat(language, "desktop.errors.settingsFailed", map[string]string{"reason": reason})
		},
	}
}
