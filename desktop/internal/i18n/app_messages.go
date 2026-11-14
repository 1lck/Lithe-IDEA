package i18n

// appMessages reads application identity and version labels from the shared catalog.
func appMessages(language Language) AppMessages {
	return AppMessages{
		Name: Shared(language, "native.lithe"),
		Version: func(version string, stable bool) string {
			if stable {
				return version
			}
			return SharedFormat(language, "desktop.app.previewVersion", map[string]string{"version": version})
		},
		DevBadge: Shared(language, "desktop.app.devBadge"),
	}
}
