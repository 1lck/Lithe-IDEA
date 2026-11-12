package i18n

// UpdatesMessages are the workbench's words about updates outside the settings window.
type UpdatesMessages struct {
	// Available is the notice of the startup check that found a newer version.
	Available func(version string) string
}

func updatesMessages(language Language) UpdatesMessages {
	return UpdatesMessages{
		Available: func(version string) string {
			return SharedFormat(language, "desktop.updates.available", map[string]string{"version": version})
		},
	}
}
