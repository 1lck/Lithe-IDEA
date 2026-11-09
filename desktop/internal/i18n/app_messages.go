package i18n

// appMessages reads application identity and version labels from the shared catalog.
func appMessages(language Language) AppMessages {
	return AppMessages{
		Name: Shared(language, "native.lithe"),
		Version: func(version string) string {
			return SharedFormat(language, "desktop.app.version", map[string]string{"version": version})
		},
		Core: func(version string) string {
			return SharedFormat(language, "desktop.app.coreVersion", map[string]string{"version": version})
		},
		DevBadge: Shared(language, "desktop.app.devBadge"),
	}
}
