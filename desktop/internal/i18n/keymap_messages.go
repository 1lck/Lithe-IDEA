package i18n

// KeymapMessages are the words of the Keymap settings page and the actions only the
// keymap names.
type KeymapMessages struct {
	GroupEditor, GoToLine, InlineEdit                         string
	Search, SearchPlaceholder, Add, Remove, Reset, ResetAll   string
	Recording, RecordingHint, Cancel, None, Modified, NoMatch string
	// Conflict says the pressed chord already runs another action.
	Conflict func(keys, action string) string
	// Unbindable says the pressed chord would take plain typing.
	Unbindable string
	Help       string
}

func keymapMessages(language Language) KeymapMessages {
	return KeymapMessages{
		GroupEditor:       Shared(language, "desktop.keymap.groupEditor"),
		GoToLine:          Shared(language, "desktop.keymap.goToLine"),
		InlineEdit:        Shared(language, "desktop.keymap.inlineEdit"),
		Search:            Shared(language, "desktop.keymap.search"),
		SearchPlaceholder: Shared(language, "desktop.keymap.searchPlaceholder"),
		Add:               Shared(language, "desktop.keymap.add"),
		Remove:            Shared(language, "desktop.keymap.remove"),
		Reset:             Shared(language, "desktop.keymap.reset"),
		ResetAll:          Shared(language, "desktop.keymap.resetAll"),
		Recording:         Shared(language, "desktop.keymap.recording"),
		RecordingHint:     Shared(language, "desktop.keymap.recordingHint"),
		Cancel:            Shared(language, "desktop.keymap.cancel"),
		None:              Shared(language, "desktop.keymap.none"),
		Modified:          Shared(language, "desktop.keymap.modified"),
		NoMatch:           Shared(language, "desktop.keymap.noMatch"),
		Conflict: func(keys, action string) string {
			return SharedFormat(language, "desktop.keymap.conflict", map[string]string{"keys": keys, "action": action})
		},
		Unbindable: Shared(language, "desktop.keymap.unbindable"),
		Help:       Shared(language, "desktop.keymap.help"),
	}
}
