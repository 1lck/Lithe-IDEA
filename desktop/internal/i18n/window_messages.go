package i18n

// windowMessages reads the names of the window buttons from the shared catalog.
func windowMessages(language Language) WindowMessages {
	return WindowMessages{
		Minimize: Shared(language, "window.minimize"),
		Maximize: Shared(language, "window.maximize"),
		Restore:  Shared(language, "window.restore"),
		Close:    Shared(language, "window.close"),
	}
}
