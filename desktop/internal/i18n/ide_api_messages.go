package i18n

// IDEAPIMessages are the words of the IDE Connection settings page.
type IDEAPIMessages struct {
	Title              string
	Intro              string
	Project            string
	NoProject          string
	Enable             string
	Disable            string
	AllowConfigure     string
	AllowConfigureHelp string
	AllowExecute       string
	AllowExecuteHelp   string
	GrantsFixed        string
	CopyConfiguration  string
	HelperMissing      string
	StatusEnabled      string
	StatusDisabled     string
}

// IDEAPIFailed is the message for a connection change the Core or the window refused.
func IDEAPIFailed(language Language, reason string) string {
	return SharedFormat(language, "desktop.ideApi.failed", map[string]string{"reason": reason})
}

func ideAPIMessages(language Language) IDEAPIMessages {
	return IDEAPIMessages{
		Title:              Shared(language, "desktop.ideApi.title"),
		Intro:              Shared(language, "desktop.ideApi.intro"),
		Project:            Shared(language, "desktop.ideApi.project"),
		NoProject:          Shared(language, "desktop.ideApi.noProject"),
		Enable:             Shared(language, "desktop.ideApi.enable"),
		Disable:            Shared(language, "desktop.ideApi.disable"),
		AllowConfigure:     Shared(language, "desktop.ideApi.allowConfigure"),
		AllowConfigureHelp: Shared(language, "desktop.ideApi.allowConfigureHelp"),
		AllowExecute:       Shared(language, "desktop.ideApi.allowExecute"),
		AllowExecuteHelp:   Shared(language, "desktop.ideApi.allowExecuteHelp"),
		GrantsFixed:        Shared(language, "desktop.ideApi.grantsFixed"),
		CopyConfiguration:  Shared(language, "desktop.ideApi.copyConfiguration"),
		HelperMissing:      Shared(language, "desktop.ideApi.helperMissing"),
		StatusEnabled:      Shared(language, "desktop.ideApi.statusEnabled"),
		StatusDisabled:     Shared(language, "desktop.ideApi.statusDisabled"),
	}
}
