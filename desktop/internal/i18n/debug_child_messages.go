package i18n

// DebugChildMessages are the words of a child debug session an adapter started
// through startDebugging (workbench/debug_child.go).
type DebugChildMessages struct {
	NeedsConfirmation string
	Stopped           string
	Unavailable       string
	// StartedBy labels a child session in the session picker with the session that started it.
	StartedBy func(parent string) string
}

func debugChildMessages(language Language) DebugChildMessages {
	return DebugChildMessages{
		NeedsConfirmation: Shared(language, "desktop.debug.child.needsConfirmation"),
		Stopped:           Shared(language, "desktop.debug.child.stopped"),
		Unavailable:       Shared(language, "desktop.debug.child.unavailable"),
		StartedBy: func(parent string) string {
			return SharedFormat(language, "desktop.debug.child.startedBy", map[string]string{"parent": parent})
		},
	}
}
